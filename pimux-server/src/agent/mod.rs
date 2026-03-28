mod discovery;
mod extension;
mod live;
mod summarizer;
mod transcript;

use std::{
    env,
    path::{Path, PathBuf},
};

use notify::{RecommendedWatcher, RecursiveMode, Watcher};
use reqwest::{Client, Url};
use tokio::{
    sync::mpsc::{UnboundedReceiver, unbounded_channel},
    time::{Duration, interval, timeout},
};

use crate::{
    host::{HostAuth, HostIdentity},
    report::ReportPayload,
    transcript::{
        PendingTranscriptRequestsResponse, SessionMessagesBatchReport, SessionMessagesResponse,
        TranscriptFetchFulfillment, TranscriptFetchQuery,
    },
};

pub use summarizer::DEFAULT_SUMMARY_MODEL;

type BoxError = Box<dyn std::error::Error + Send + Sync>;
const FETCH_POLL_INTERVAL: Duration = Duration::from_secs(1);

pub struct Config {
    pub server_url: String,
    pub location: Option<String>,
    pub auth: HostAuth,
    pub pi_agent_dir: Option<PathBuf>,
    pub summary_model: String,
}

pub struct ListConfig {
    pub pi_agent_dir: Option<PathBuf>,
    pub summary_model: String,
}

pub fn install_extension(pi_agent_dir: Option<PathBuf>, force: bool) -> Result<PathBuf, BoxError> {
    extension::install(pi_agent_dir, force)
}

pub async fn list(config: ListConfig) -> Result<(), BoxError> {
    let pi_agent_dir = discovery::resolve_pi_agent_dir(config.pi_agent_dir)?;
    let summary_config = summarizer::Config {
        model: config.summary_model,
        pi_agent_dir: pi_agent_dir.clone(),
    };
    let mut summary_cache = summarizer::SummaryCache::default();
    let discovered_sessions = discovery::discover_sessions(&pi_agent_dir)?;
    let sessions =
        summarizer::apply_summaries(discovered_sessions, &summary_config, &mut summary_cache).await;

    println!("id\tcreated_at\tlast_activity\tmodel\tcwd\tsummary");
    for session in sessions {
        let last_activity = session
            .last_user_message_at
            .max(session.last_assistant_message_at);
        println!(
            "{}\t{}\t{}\t{}\t{}\t{}",
            session.id,
            session.created_at.to_rfc3339(),
            last_activity.to_rfc3339(),
            session.model,
            session.cwd,
            session.summary,
        );
    }

    Ok(())
}

pub async fn start(config: Config) -> Result<(), BoxError> {
    let pi_agent_dir = discovery::resolve_pi_agent_dir(config.pi_agent_dir)?;
    let session_root = discovery::session_root(&pi_agent_dir);
    let summary_config = summarizer::Config {
        model: config.summary_model,
        pi_agent_dir: pi_agent_dir.clone(),
    };
    let host = HostIdentity {
        location: match config.location {
            Some(location) => location,
            None => detect_host_location()?,
        },
        auth: config.auth,
    };
    let report_url = build_server_url(&config.server_url, "/report")?;
    let transcript_report_url = build_server_url(&config.server_url, "/agent/session-messages")?;
    let pending_fetch_url =
        build_server_url(&config.server_url, "/agent/session-messages/pending")?;
    let fetch_response_url =
        build_server_url(&config.server_url, "/agent/session-messages/fetch-response")?;
    let client = Client::new();
    let live_store = live::LiveSessionStoreHandle::new(
        live::DEFAULT_DETACHED_CAPACITY,
        live::DEFAULT_DETACHED_TTL,
    );
    let live_socket_path = live::socket_path(&pi_agent_dir);

    println!(
        "agent watching {} and reporting to {} as {}",
        session_root.display(),
        report_url,
        host.location
    );

    let (tx, mut rx) = unbounded_channel();
    let (live_updates_tx, mut live_updates_rx) = unbounded_channel::<SessionMessagesResponse>();
    let _watcher = create_watcher(&session_root, tx)?;
    let _live_updates_tx_guard = match live::start_listener(
        live_store.clone(),
        live_socket_path.clone(),
        live_updates_tx.clone(),
    )
    .await
    {
        Ok(()) => {
            println!("live ipc listening on {}", live_socket_path.display());
            None
        }
        Err(error) => {
            eprintln!("live ipc disabled: {error}");
            Some(live_updates_tx)
        }
    };
    let mut last_report = None;
    let mut last_transcript_report = None;
    let mut summary_cache = summarizer::SummaryCache::default();
    let mut fetch_poll = interval(FETCH_POLL_INTERVAL);

    if let Err(error) = publish_if_changed(
        &client,
        &report_url,
        &transcript_report_url,
        &pi_agent_dir,
        &summary_config,
        &host,
        &live_store,
        &mut summary_cache,
        &mut last_report,
        &mut last_transcript_report,
    )
    .await
    {
        eprintln!("initial report failed: {error}");
    }

    if let Err(error) = handle_pending_fetches(
        &client,
        &pending_fetch_url,
        &fetch_response_url,
        &pi_agent_dir,
        &host,
        &live_store,
    )
    .await
    {
        eprintln!("initial fetch poll failed: {error}");
    }

    loop {
        tokio::select! {
            _ = tokio::signal::ctrl_c() => {
                println!("agent shutting down");
                break;
            }
            _ = fetch_poll.tick() => {
                if let Err(error) = handle_pending_fetches(
                    &client,
                    &pending_fetch_url,
                    &fetch_response_url,
                    &pi_agent_dir,
                    &host,
                    &live_store,
                ).await {
                    eprintln!("fetch poll failed: {error}");
                }
            }
            live_update = live_updates_rx.recv() => {
                if let Some(snapshot) = live_update {
                    if let Err(error) = publish_live_snapshot(
                        &client,
                        &transcript_report_url,
                        &host,
                        snapshot,
                    ).await {
                        eprintln!("live snapshot push failed: {error}");
                    }
                }
            }
            change = rx.recv() => {
                if change.is_none() {
                    break;
                }

                debounce_changes(&mut rx).await;
                if let Err(error) = publish_if_changed(
                    &client,
                    &report_url,
                    &transcript_report_url,
                    &pi_agent_dir,
                    &summary_config,
                    &host,
                    &live_store,
                    &mut summary_cache,
                    &mut last_report,
                    &mut last_transcript_report,
                ).await {
                    eprintln!("report failed: {error}");
                }
            }
        }
    }

    Ok(())
}

async fn publish_if_changed(
    client: &Client,
    report_url: &Url,
    transcript_report_url: &Url,
    pi_agent_dir: &Path,
    summary_config: &summarizer::Config,
    host: &HostIdentity,
    live_store: &live::LiveSessionStoreHandle,
    summary_cache: &mut summarizer::SummaryCache,
    last_report: &mut Option<ReportPayload>,
    last_transcript_report: &mut Option<SessionMessagesBatchReport>,
) -> Result<(), BoxError> {
    let discovered_sessions = discovery::discover_sessions(pi_agent_dir)?;
    let active_sessions =
        summarizer::apply_summaries(discovered_sessions.clone(), summary_config, summary_cache)
            .await;
    let report = ReportPayload {
        host: host.clone(),
        active_sessions,
    };

    if last_report.as_ref() != Some(&report) {
        send_json(client, report_url, &report).await?;
        println!("reported {} sessions", report.active_sessions.len());
        *last_report = Some(report);
    }

    let live_overrides = live_store.all_snapshots().await;
    let transcript_report = transcript::build_recent_transcript_report(
        &host.location,
        &discovered_sessions,
        &live_overrides,
    )?;
    if last_transcript_report.as_ref() != Some(&transcript_report) {
        send_json(client, transcript_report_url, &transcript_report).await?;
        println!(
            "reported {} cached transcript snapshots",
            transcript_report.sessions.len()
        );
        *last_transcript_report = Some(transcript_report);
    }

    Ok(())
}

async fn publish_live_snapshot(
    client: &Client,
    transcript_report_url: &Url,
    host: &HostIdentity,
    snapshot: SessionMessagesResponse,
) -> Result<(), BoxError> {
    let report = SessionMessagesBatchReport {
        host_location: host.location.clone(),
        sessions: vec![snapshot],
    };
    send_json(client, transcript_report_url, &report).await
}

async fn handle_pending_fetches(
    client: &Client,
    pending_fetch_url: &Url,
    fetch_response_url: &Url,
    pi_agent_dir: &Path,
    host: &HostIdentity,
    live_store: &live::LiveSessionStoreHandle,
) -> Result<(), BoxError> {
    let response = client
        .get(pending_fetch_url.clone())
        .query(&TranscriptFetchQuery {
            host_location: host.location.clone(),
        })
        .send()
        .await?;

    if !response.status().is_success() {
        let status = response.status();
        let body = response.text().await.unwrap_or_default();
        return Err(format!("server returned {status}: {body}").into());
    }

    let pending = response.json::<PendingTranscriptRequestsResponse>().await?;
    if pending.requests.is_empty() {
        return Ok(());
    }

    let discovered_sessions = discovery::discover_sessions(pi_agent_dir)?;
    for request in pending.requests {
        let fulfillment =
            if let Some(session) = live_store.snapshot_for_session(&request.session_id).await {
                TranscriptFetchFulfillment {
                    request_id: request.request_id,
                    host_location: host.location.clone(),
                    session: Some(session),
                    error: None,
                }
            } else {
                match discovered_sessions
                    .iter()
                    .find(|session| session.id == request.session_id)
                {
                    Some(discovered_session) => {
                        match transcript::build_persisted_snapshot(discovered_session) {
                            Ok(session) => TranscriptFetchFulfillment {
                                request_id: request.request_id,
                                host_location: host.location.clone(),
                                session: Some(session),
                                error: None,
                            },
                            Err(error) => TranscriptFetchFulfillment {
                                request_id: request.request_id,
                                host_location: host.location.clone(),
                                session: None,
                                error: Some(format!(
                                    "failed to reconstruct transcript for session {}: {error}",
                                    request.session_id
                                )),
                            },
                        }
                    }
                    None => TranscriptFetchFulfillment {
                        request_id: request.request_id,
                        host_location: host.location.clone(),
                        session: None,
                        error: Some(format!(
                            "session {} was not found on host {}",
                            request.session_id, host.location
                        )),
                    },
                }
            };

        send_json(client, fetch_response_url, &fulfillment).await?;
    }

    Ok(())
}

async fn send_json<T>(client: &Client, url: &Url, payload: &T) -> Result<(), BoxError>
where
    T: serde::Serialize + ?Sized,
{
    let response = client.post(url.clone()).json(payload).send().await?;
    if response.status().is_success() {
        return Ok(());
    }

    let status = response.status();
    let body = response.text().await.unwrap_or_default();
    Err(format!("server returned {status}: {body}").into())
}

fn build_server_url(server_url: &str, path: &str) -> Result<Url, BoxError> {
    Ok(Url::parse(&format!(
        "{}{}",
        server_url.trim_end_matches('/'),
        path
    ))?)
}

fn detect_host_location() -> Result<String, BoxError> {
    let user = env::var("USER")
        .or_else(|_| env::var("USERNAME"))
        .map_err(|_| "missing USER/USERNAME environment variable")?;
    let hostname = hostname::get()?
        .into_string()
        .map_err(|_| "hostname contains invalid UTF-8")?;

    Ok(format!("{user}@{hostname}"))
}

fn create_watcher(
    session_root: &Path,
    tx: tokio::sync::mpsc::UnboundedSender<()>,
) -> Result<RecommendedWatcher, BoxError> {
    let watched_path = nearest_existing_ancestor(session_root)
        .ok_or_else(|| format!("no existing ancestor found for {}", session_root.display()))?;
    let session_root = session_root.to_path_buf();

    let mut watcher =
        notify::recommended_watcher(move |result: notify::Result<notify::Event>| match result {
            Ok(event) => {
                if event.paths.is_empty()
                    || event
                        .paths
                        .iter()
                        .any(|path| path.starts_with(&session_root))
                {
                    let _ = tx.send(());
                }
            }
            Err(error) => eprintln!("watch error: {error}"),
        })?;

    watcher.watch(&watched_path, RecursiveMode::Recursive)?;
    Ok(watcher)
}

fn nearest_existing_ancestor(path: &Path) -> Option<PathBuf> {
    path.ancestors()
        .find(|candidate| candidate.exists())
        .map(PathBuf::from)
}

async fn debounce_changes(rx: &mut UnboundedReceiver<()>) {
    loop {
        match timeout(Duration::from_millis(250), rx.recv()).await {
            Ok(Some(_)) => continue,
            Ok(None) | Err(_) => break,
        }
    }
}
