mod discovery;
mod summarizer;

use std::{
    env,
    path::{Path, PathBuf},
};

use notify::{RecommendedWatcher, RecursiveMode, Watcher};
use reqwest::{Client, Url};
use tokio::{
    sync::mpsc::{UnboundedReceiver, unbounded_channel},
    time::{Duration, timeout},
};

use crate::{
    host::{HostAuth, HostIdentity},
    report::ReportPayload,
};

pub use summarizer::DEFAULT_SUMMARY_MODEL;

type BoxError = Box<dyn std::error::Error + Send + Sync>;

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
    let report_url = build_report_url(&config.server_url)?;
    let client = Client::new();

    println!(
        "agent watching {} and reporting to {} as {}",
        session_root.display(),
        report_url,
        host.location
    );

    let (tx, mut rx) = unbounded_channel();
    let _watcher = create_watcher(&session_root, tx)?;
    let mut last_report = None;
    let mut summary_cache = summarizer::SummaryCache::default();

    if let Err(error) = publish_if_changed(
        &client,
        &report_url,
        &pi_agent_dir,
        &summary_config,
        &host,
        &mut summary_cache,
        &mut last_report,
    )
    .await
    {
        eprintln!("initial report failed: {error}");
    }

    loop {
        tokio::select! {
            _ = tokio::signal::ctrl_c() => {
                println!("agent shutting down");
                break;
            }
            change = rx.recv() => {
                if change.is_none() {
                    break;
                }

                debounce_changes(&mut rx).await;
                if let Err(error) = publish_if_changed(
                    &client,
                    &report_url,
                    &pi_agent_dir,
                    &summary_config,
                    &host,
                    &mut summary_cache,
                    &mut last_report,
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
    pi_agent_dir: &Path,
    summary_config: &summarizer::Config,
    host: &HostIdentity,
    summary_cache: &mut summarizer::SummaryCache,
    last_report: &mut Option<ReportPayload>,
) -> Result<(), BoxError> {
    let discovered_sessions = discovery::discover_sessions(pi_agent_dir)?;
    let active_sessions =
        summarizer::apply_summaries(discovered_sessions, summary_config, summary_cache).await;
    let report = ReportPayload {
        host: host.clone(),
        active_sessions,
    };

    if last_report.as_ref() == Some(&report) {
        return Ok(());
    }

    send_report(client, report_url, &report).await?;
    println!("reported {} sessions", report.active_sessions.len());
    *last_report = Some(report);

    Ok(())
}

async fn send_report(
    client: &Client,
    report_url: &Url,
    report: &ReportPayload,
) -> Result<(), BoxError> {
    let response = client.post(report_url.clone()).json(report).send().await?;
    if response.status().is_success() {
        return Ok(());
    }

    let status = response.status();
    let body = response.text().await.unwrap_or_default();
    Err(format!("server returned {status}: {body}").into())
}

fn build_report_url(server_url: &str) -> Result<Url, BoxError> {
    Ok(Url::parse(&format!(
        "{}/report",
        server_url.trim_end_matches('/')
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
