mod connection;
mod discovery;
mod extension;
mod live;
mod send;
mod service;
mod summarizer;
mod transcript;

use std::{
    env, fs,
    path::{Path, PathBuf},
    time::Instant,
};

use tracing::{error, info, warn};

use notify::{RecommendedWatcher, RecursiveMode, Watcher};
use reqwest::{Client, Url};
use tokio::{
    sync::mpsc::{UnboundedReceiver, unbounded_channel},
    time::{Duration, timeout},
};

use crate::{
    channel::{AgentToServerMessage, ServerToAgentMessage},
    host::{HostAuth, HostIdentity},
    message::{ImageContent, attachment_payload, strip_inline_image_data},
    report::{ReportPayload, VersionResponse},
    session::{
        ForkMessage, SessionBuiltinCommandRequest, SessionBuiltinCommandResponse,
        parse_local_date_filter, utc_range_for_local_date,
    },
    transcript::{SessionMessagesResponse, TranscriptFetchFulfillment},
};

pub use summarizer::DEFAULT_SUMMARY_MODEL;

type BoxError = Box<dyn std::error::Error + Send + Sync>;

const SUMMARY_REFRESH_INTERVAL: Duration = Duration::from_secs(5 * 60);

pub struct Config {
    pub server_url: String,
    pub location: Option<String>,
    pub auth: HostAuth,
    pub pi_agent_dir: Option<PathBuf>,
    pub summary_model: String,
}

#[derive(Debug)]
pub struct NormalizedServerUrl {
    pub url: String,
    pub inferred_http: bool,
}

pub struct ListConfig {
    pub pi_agent_dir: Option<PathBuf>,
    pub summary_model: String,
    pub date: Option<String>,
}

pub fn install_extension(pi_agent_dir: Option<PathBuf>, force: bool) -> Result<PathBuf, BoxError> {
    extension::install(pi_agent_dir, force)
}

pub fn install_service(config: Config) -> Result<service::InstallResult, BoxError> {
    service::install(config)
}

pub fn uninstall_service() -> Result<service::UninstallResult, BoxError> {
    service::uninstall()
}

pub fn service_status(pi_agent_dir: Option<PathBuf>) -> Result<String, BoxError> {
    service::status(pi_agent_dir)
}

pub fn service_logs(lines: usize, follow: bool) -> Result<(), BoxError> {
    service::logs(lines, follow)
}

pub fn restart_service_if_installed() -> Result<Option<&'static str>, BoxError> {
    service::restart_if_installed()
}

pub fn normalize_server_url(server_url: &str) -> Result<NormalizedServerUrl, BoxError> {
    let trimmed = server_url.trim();
    if trimmed.is_empty() {
        return Err("server URL must not be empty".into());
    }

    let inferred_http = !trimmed.contains("://");
    let candidate = if inferred_http {
        format!("http://{trimmed}")
    } else {
        trimmed.to_string()
    };

    let parsed = Url::parse(&candidate).map_err(|error| {
        format!("invalid server URL `{trimmed}`: {error}. Example: http://localhost:3000")
    })?;

    if !matches!(parsed.scheme(), "http" | "https") {
        return Err(format!(
            "unsupported server URL scheme `{}` in `{trimmed}`; use http:// or https://",
            parsed.scheme()
        )
        .into());
    }

    Ok(NormalizedServerUrl {
        url: candidate,
        inferred_http,
    })
}

pub async fn list(config: ListConfig) -> Result<(), BoxError> {
    let pi_agent_dir = discovery::resolve_pi_agent_dir(config.pi_agent_dir)?;
    eprintln!("discovering sessions in {}...", pi_agent_dir.display());

    let summary_config = summarizer::Config {
        model: summarizer::resolve_summary_model(&pi_agent_dir, &config.summary_model),
        pi_agent_dir: pi_agent_dir.clone(),
    };
    let mut summary_cache = summarizer::SummaryCache::load(&pi_agent_dir);
    let discovered_sessions = discovery::discover_sessions(&pi_agent_dir)?;
    eprintln!(
        "discovered {} sessions before filtering",
        discovered_sessions.len()
    );

    let filter_label = config.date.clone();
    let discovered_sessions = filter_discovered_sessions_by_date(discovered_sessions, config.date)?;
    if let Some(date) = filter_label {
        eprintln!(
            "filtered to {} session{} for local date {}",
            discovered_sessions.len(),
            if discovered_sessions.len() == 1 {
                ""
            } else {
                "s"
            },
            date,
        );
    }

    let sessions = summarizer::apply_summaries_with_stderr_progress(
        discovered_sessions,
        &summary_config,
        &mut summary_cache,
    )
    .await;

    eprintln!(
        "rendering {} session{}",
        sessions.len(),
        if sessions.len() == 1 { "" } else { "s" }
    );
    println!("id\tupdated_at\tcreated_at\tlast_activity\tmodel\tcwd\tsummary");
    for session in sessions {
        println!(
            "{}\t{}\t{}\t{}\t{}\t{}\t{}",
            session.id,
            session.updated_at.to_rfc3339(),
            session.created_at.to_rfc3339(),
            session.last_activity_at().to_rfc3339(),
            session.model,
            session.cwd,
            session.summary,
        );
    }

    Ok(())
}

fn filter_discovered_sessions_by_date(
    sessions: Vec<discovery::DiscoveredSession>,
    date: Option<String>,
) -> Result<Vec<discovery::DiscoveredSession>, BoxError> {
    let Some(date) = date else {
        return Ok(sessions);
    };

    let date = parse_local_date_filter(&date)?;
    let (start, end) = utc_range_for_local_date(date)?;

    Ok(sessions
        .into_iter()
        .filter(|session| session.updated_at >= start && session.updated_at < end)
        .collect())
}

pub async fn start(config: Config) -> Result<(), BoxError> {
    crate::self_update::spawn_auto_update_task();

    let pi_agent_dir = discovery::resolve_pi_agent_dir(config.pi_agent_dir)?;
    let session_root = discovery::session_root(&pi_agent_dir);
    let summary_config = summarizer::Config {
        model: summarizer::resolve_summary_model(&pi_agent_dir, &config.summary_model),
        pi_agent_dir: pi_agent_dir.clone(),
    };
    let host = HostIdentity {
        location: match config.location {
            Some(location) => location,
            None => detect_host_location()?,
        },
        auth: config.auth,
    };
    let health_url = build_server_url(&config.server_url, "/health")?;
    let version_url = build_server_url(&config.server_url, "/version")?;
    let websocket_url = build_websocket_url(&config.server_url, "/agent/connect")?;
    let client = Client::new();
    match ensure_server_reachable(&client, &config.server_url, &health_url, &version_url).await {
        Ok(()) => {
            info!("verified pimux server at {}", config.server_url);
        }
        Err(error) => {
            warn!(%error, "server is unavailable at startup; agent will keep retrying the websocket connection in the background");
        }
    }
    let live_store = live::LiveSessionStoreHandle::new(
        live::DEFAULT_DETACHED_CAPACITY,
        live::DEFAULT_DETACHED_TTL,
    );
    let live_socket_path = live::socket_path(&pi_agent_dir);

    match extension::ensure_current(&pi_agent_dir) {
        Ok(result) => match result.status {
            extension::SyncStatus::AlreadyCurrent => {
                info!(
                    "pimux live extension is current at {}",
                    result.path.display()
                );
            }
            extension::SyncStatus::Installed => {
                info!(
                    "installed bundled pimux live extension to {}",
                    result.path.display()
                );
            }
            extension::SyncStatus::Updated => {
                warn!(
                    "updated bundled pimux live extension at {}; newly started pi sessions will pick it up, but already-running pi sessions may still be using older loaded extension code",
                    result.path.display()
                );
            }
        },
        Err(error) => {
            warn!(%error, "failed to sync bundled pimux live extension at startup");
        }
    }

    info!(
        "agent watching {} and connecting to {} as {}",
        session_root.display(),
        websocket_url,
        host.location
    );

    let (tx, mut rx) = unbounded_channel();
    let (live_updates_tx, mut live_updates_rx) = unbounded_channel::<live::LiveUpdate>();
    let _watcher = create_watcher(&session_root, tx)?;
    let _live_updates_tx_guard = match live::start_listener(
        live_store.clone(),
        live_socket_path.clone(),
        live_updates_tx.clone(),
    )
    .await
    {
        Ok(()) => {
            info!("live ipc listening on {}", live_socket_path.display());
            None
        }
        Err(error) => {
            warn!(%error, "live ipc disabled");
            Some(live_updates_tx.clone())
        }
    };

    let (connection_events_tx, mut connection_events_rx) = unbounded_channel();
    let channel_tx = connection::start(websocket_url.clone(), host.clone(), connection_events_tx);
    let mut connected = false;
    let mut last_report: Option<ReportPayload> = None;
    let mut summary_cache = summarizer::SummaryCache::load(&pi_agent_dir);
    let mut last_full_summary_at: Option<Instant> = None;

    if let Err(error) = refresh_host_snapshot(
        &pi_agent_dir,
        &summary_config,
        &host,
        &live_store,
        &mut summary_cache,
        &mut last_report,
        &mut last_full_summary_at,
        false,
        false,
        &channel_tx,
    )
    .await
    {
        error!(%error, "initial snapshot build failed");
    }

    loop {
        tokio::select! {
            _ = tokio::signal::ctrl_c() => {
                info!("agent shutting down");
                break;
            }
            connection_event = connection_events_rx.recv() => {
                let Some(connection_event) = connection_event else {
                    break;
                };

                match connection_event {
                    connection::Event::Connected => {
                        connected = true;
                        info!("connected to server websocket");
                        if let Err(error) = send_current_state(
                            &pi_agent_dir,
                            &summary_config,
                            &host,
                            &live_store,
                            &mut summary_cache,
                            &mut last_report,
                            &mut last_full_summary_at,
                            &channel_tx,
                        ).await {
                            error!(%error, "failed to publish current state after connect");
                        }
                    }
                    connection::Event::Disconnected => {
                        connected = false;
                        warn!("server websocket disconnected; waiting to reconnect...");
                    }
                    connection::Event::Message(message) => {
                        if let Err(error) = handle_server_message(
                            message,
                            &pi_agent_dir,
                            &summary_config,
                            &host,
                            &live_store,
                            &live_updates_tx,
                            &channel_tx,
                        ).await {
                            error!(%error, "failed to handle server message");
                        }
                    }
                }
            }
            live_update = live_updates_rx.recv() => {
                if let Some(live_update) = live_update {
                    if connected {
                        match live_update {
                            live::LiveUpdate::Transcript {
                                snapshot,
                                active_session,
                            } => {
                                let _ = channel_tx.send(AgentToServerMessage::LiveSessionUpdate {
                                    session: session_for_transport(snapshot),
                                    active_session,
                                });
                            }
                            live::LiveUpdate::UiState { session_id, ui_state } => {
                                let _ = channel_tx.send(AgentToServerMessage::LiveUiUpdate {
                                    session_id,
                                    ui_state,
                                });
                            }
                            live::LiveUpdate::UiDialogState {
                                session_id,
                                ui_dialog_state,
                            } => {
                                let _ = channel_tx.send(AgentToServerMessage::LiveUiDialogUpdate {
                                    session_id,
                                    ui_dialog_state,
                                });
                            }
                            live::LiveUpdate::TerminalOnlyUiState {
                                session_id,
                                terminal_only_ui_state,
                            } => {
                                let _ = channel_tx.send(
                                    AgentToServerMessage::LiveTerminalOnlyUiUpdate {
                                        session_id,
                                        terminal_only_ui_state,
                                    },
                                );
                            }
                        }
                    }
                }
            }
            change = rx.recv() => {
                if change.is_none() {
                    break;
                }

                debounce_changes(&mut rx).await;
                if let Err(error) = refresh_host_snapshot(
                    &pi_agent_dir,
                    &summary_config,
                    &host,
                    &live_store,
                    &mut summary_cache,
                    &mut last_report,
                    &mut last_full_summary_at,
                    connected,
                    false,
                    &channel_tx,
                ).await {
                    error!(%error, "failed to refresh host snapshot");
                }
            }
        }
    }

    Ok(())
}

async fn send_current_state(
    pi_agent_dir: &Path,
    summary_config: &summarizer::Config,
    host: &HostIdentity,
    live_store: &live::LiveSessionStoreHandle,
    summary_cache: &mut summarizer::SummaryCache,
    last_report: &mut Option<ReportPayload>,
    last_full_summary_at: &mut Option<Instant>,
    channel_tx: &tokio::sync::mpsc::UnboundedSender<AgentToServerMessage>,
) -> Result<(), BoxError> {
    refresh_host_snapshot(
        pi_agent_dir,
        summary_config,
        host,
        live_store,
        summary_cache,
        last_report,
        last_full_summary_at,
        true,
        true,
        channel_tx,
    )
    .await?;

    for snapshot in live_store.all_snapshots().await.into_values() {
        let active_session = live_store
            .listed_session_for_session(&snapshot.session_id)
            .await;
        let _ = channel_tx.send(AgentToServerMessage::LiveSessionUpdate {
            session: session_for_transport(snapshot),
            active_session,
        });
    }

    for (session_id, ui_state) in live_store.all_ui_states().await {
        let _ = channel_tx.send(AgentToServerMessage::LiveUiUpdate {
            session_id,
            ui_state,
        });
    }

    for (session_id, ui_dialog_state) in live_store.all_ui_dialog_states().await {
        let _ = channel_tx.send(AgentToServerMessage::LiveUiDialogUpdate {
            session_id,
            ui_dialog_state: Some(ui_dialog_state),
        });
    }

    for (session_id, terminal_only_ui_state) in live_store.all_terminal_only_ui_states().await {
        let _ = channel_tx.send(AgentToServerMessage::LiveTerminalOnlyUiUpdate {
            session_id,
            terminal_only_ui_state: Some(terminal_only_ui_state),
        });
    }

    Ok(())
}

async fn refresh_host_snapshot(
    pi_agent_dir: &Path,
    summary_config: &summarizer::Config,
    host: &HostIdentity,
    live_store: &live::LiveSessionStoreHandle,
    summary_cache: &mut summarizer::SummaryCache,
    last_report: &mut Option<ReportPayload>,
    last_full_summary_at: &mut Option<Instant>,
    publish: bool,
    force_send: bool,
    channel_tx: &tokio::sync::mpsc::UnboundedSender<AgentToServerMessage>,
) -> Result<(), BoxError> {
    let discovered_sessions = discovery::discover_sessions(pi_agent_dir)?;
    let needs_full_summary = last_full_summary_at
        .map(|t| t.elapsed() >= SUMMARY_REFRESH_INTERVAL)
        .unwrap_or(true);
    let active_sessions = if needs_full_summary {
        let sessions =
            summarizer::apply_summaries(discovered_sessions, summary_config, summary_cache).await;
        *last_full_summary_at = Some(Instant::now());
        sessions
    } else {
        summarizer::apply_summaries_cached_only(discovered_sessions, summary_cache)
    };
    let active_sessions =
        merge_live_sessions(active_sessions, live_store.all_listed_sessions().await);
    let report = ReportPayload {
        host: host.clone(),
        active_sessions,
    };

    let changed = last_report.as_ref() != Some(&report);
    if changed {
        *last_report = Some(report.clone());
    }

    if publish && (changed || force_send) {
        let _ = channel_tx.send(AgentToServerMessage::HostSnapshot {
            sessions: report.active_sessions.clone(),
        });
        info!("reported {} sessions", report.active_sessions.len());
    }

    Ok(())
}

fn merge_live_sessions(
    sessions: Vec<crate::session::ActiveSession>,
    live_sessions: Vec<crate::session::ActiveSession>,
) -> Vec<crate::session::ActiveSession> {
    use std::collections::HashMap;

    let mut sessions_by_id = sessions
        .into_iter()
        .map(|session| (session.id.clone(), session))
        .collect::<HashMap<_, _>>();

    for live_session in live_sessions {
        match sessions_by_id.get(&live_session.id) {
            Some(existing) if existing.updated_at > live_session.updated_at => {}
            _ => {
                sessions_by_id.insert(live_session.id.clone(), live_session);
            }
        }
    }

    let mut merged = sessions_by_id.into_values().collect::<Vec<_>>();
    sort_active_sessions(&mut merged);
    merged
}

fn sort_active_sessions(sessions: &mut [crate::session::ActiveSession]) {
    sessions.sort_by(|left, right| {
        right
            .updated_at
            .cmp(&left.updated_at)
            .then_with(|| left.id.cmp(&right.id))
    });
}

async fn handle_server_message(
    message: ServerToAgentMessage,
    pi_agent_dir: &Path,
    summary_config: &summarizer::Config,
    host: &HostIdentity,
    live_store: &live::LiveSessionStoreHandle,
    live_updates_tx: &tokio::sync::mpsc::UnboundedSender<live::LiveUpdate>,
    channel_tx: &tokio::sync::mpsc::UnboundedSender<AgentToServerMessage>,
) -> Result<(), BoxError> {
    match message {
        ServerToAgentMessage::FetchTranscript {
            request_id,
            session_id,
        } => {
            let fulfillment =
                build_fetch_fulfillment(request_id, session_id, pi_agent_dir, host, live_store)
                    .await;
            let _ = channel_tx.send(AgentToServerMessage::FetchTranscriptResult {
                request_id: fulfillment.request_id,
                session: fulfillment.session.map(session_for_transport),
                error: fulfillment.error,
            });
        }
        ServerToAgentMessage::FetchAttachment {
            request_id,
            session_id,
            attachment_id,
        } => {
            let fulfillment = build_attachment_fulfillment(
                request_id,
                session_id,
                attachment_id,
                pi_agent_dir,
                host,
                live_store,
            )
            .await;
            let _ = channel_tx.send(AgentToServerMessage::FetchAttachmentResult {
                request_id: fulfillment.request_id,
                mime_type: fulfillment.mime_type,
                data: fulfillment.data,
                error: fulfillment.error,
            });
        }
        ServerToAgentMessage::SendMessage {
            request_id,
            session_id,
            body,
            images,
        } => {
            let result = handle_send_message(
                &session_id,
                body,
                images,
                pi_agent_dir,
                summary_config,
                live_store,
                live_updates_tx,
            )
            .await;

            if matches!(result.as_ref(), Ok(SendMessageDispatch::HeadlessRpc))
                && let Some(snapshot) = live_store.snapshot_for_session(&session_id).await
            {
                // Push the latest transcript snapshot before the send acknowledgement so
                // the server cache is updated before the iOS app follows up with GET /messages.
                let _ = channel_tx.send(AgentToServerMessage::LiveSessionUpdate {
                    session: session_for_transport(snapshot),
                    active_session: None,
                });
            }

            let _ = channel_tx.send(AgentToServerMessage::SendMessageResult {
                request_id,
                error: result.err(),
            });
        }
        ServerToAgentMessage::GetCommands {
            request_id,
            session_id,
        } => {
            let result = live_store.get_commands(&session_id).await;
            let (commands, error) = match result {
                Ok(commands) => (Some(commands), None),
                Err(error) => (None, Some(error.to_string())),
            };
            let _ = channel_tx.send(AgentToServerMessage::GetCommandsResult {
                request_id,
                commands,
                error,
            });
        }
        ServerToAgentMessage::GetCommandArgumentCompletions {
            request_id,
            session_id,
            command_name,
            argument_prefix,
        } => {
            let result = live_store
                .get_command_argument_completions(&session_id, &command_name, &argument_prefix)
                .await;
            let (completions, error) = match result {
                Ok(completions) => (Some(completions), None),
                Err(error) => (None, Some(error.to_string())),
            };
            let _ = channel_tx.send(AgentToServerMessage::GetCommandArgumentCompletionsResult {
                request_id,
                completions,
                error,
            });
        }
        ServerToAgentMessage::GetAtCompletions {
            request_id,
            session_id,
            prefix,
        } => {
            let result = live_store.get_at_completions(&session_id, &prefix).await;
            let (completions, error) = match result {
                Ok(completions) => (Some(completions), None),
                Err(error) => (None, Some(error.to_string())),
            };
            let _ = channel_tx.send(AgentToServerMessage::GetAtCompletionsResult {
                request_id,
                completions,
                error,
            });
        }
        ServerToAgentMessage::UiDialogAction {
            request_id,
            session_id,
            dialog_id,
            action,
        } => {
            let error = live_store
                .send_ui_dialog_action(&session_id, &dialog_id, action)
                .await
                .err()
                .map(|error| error.to_string());
            let _ =
                channel_tx.send(AgentToServerMessage::UiDialogActionResult { request_id, error });
        }
        ServerToAgentMessage::BuiltinCommand {
            request_id,
            session_id,
            action,
        } => {
            let (response, error) = match handle_builtin_command(
                &session_id,
                action,
                pi_agent_dir,
                live_store,
                live_updates_tx,
            )
            .await
            {
                Ok(response) => (Some(response), None),
                Err(error) => (None, Some(error)),
            };
            let _ = channel_tx.send(AgentToServerMessage::BuiltinCommandResult {
                request_id,
                response,
                error,
            });
        }
        ServerToAgentMessage::InterruptSession { session_id } => {
            if let Err(error) = live_store.interrupt_session(&session_id).await {
                eprintln!("failed to interrupt session {session_id}: {error}");
            }
        }
        ServerToAgentMessage::Ping => {
            let _ = channel_tx.send(AgentToServerMessage::Pong);
        }
        ServerToAgentMessage::Pong => {}
    }

    Ok(())
}

struct AttachmentFetchFulfillment {
    request_id: String,
    mime_type: Option<String>,
    data: Option<String>,
    error: Option<String>,
}

fn session_for_transport(mut session: SessionMessagesResponse) -> SessionMessagesResponse {
    for message in &mut session.messages {
        strip_inline_image_data(message);
    }
    session
}

async fn build_fetch_fulfillment(
    request_id: String,
    session_id: String,
    pi_agent_dir: &Path,
    host: &HostIdentity,
    live_store: &live::LiveSessionStoreHandle,
) -> TranscriptFetchFulfillment {
    if let Some(session) = live_store.snapshot_for_session(&session_id).await {
        return TranscriptFetchFulfillment {
            request_id,
            host_location: host.location.clone(),
            session: Some(session),
            error: None,
        };
    }

    let discovered_sessions = match discovery::discover_sessions(pi_agent_dir) {
        Ok(discovered_sessions) => discovered_sessions,
        Err(error) => {
            return TranscriptFetchFulfillment {
                request_id,
                host_location: host.location.clone(),
                session: None,
                error: Some(format!("failed to discover sessions: {error}")),
            };
        }
    };

    match discovered_sessions
        .iter()
        .find(|session| session.id == session_id)
    {
        Some(discovered_session) => {
            match transcript::build_persisted_snapshot(discovered_session) {
                Ok(session) => TranscriptFetchFulfillment {
                    request_id,
                    host_location: host.location.clone(),
                    session: Some(session),
                    error: None,
                },
                Err(error) => TranscriptFetchFulfillment {
                    request_id,
                    host_location: host.location.clone(),
                    session: None,
                    error: Some(format!(
                        "failed to reconstruct transcript for session {}: {error}",
                        session_id
                    )),
                },
            }
        }
        None => TranscriptFetchFulfillment {
            request_id,
            host_location: host.location.clone(),
            session: None,
            error: Some(format!(
                "session {} was not found on host {}",
                session_id, host.location
            )),
        },
    }
}

async fn build_attachment_fulfillment(
    request_id: String,
    session_id: String,
    attachment_id: String,
    pi_agent_dir: &Path,
    host: &HostIdentity,
    live_store: &live::LiveSessionStoreHandle,
) -> AttachmentFetchFulfillment {
    if let Some(session) = live_store.snapshot_for_session(&session_id).await
        && let Some((mime_type, data)) = attachment_payload(&session.messages, &attachment_id)
    {
        return AttachmentFetchFulfillment {
            request_id,
            mime_type: Some(mime_type),
            data: Some(data),
            error: None,
        };
    }

    let discovered_sessions = match discovery::discover_sessions(pi_agent_dir) {
        Ok(discovered_sessions) => discovered_sessions,
        Err(error) => {
            return AttachmentFetchFulfillment {
                request_id,
                mime_type: None,
                data: None,
                error: Some(format!("failed to discover sessions: {error}")),
            };
        }
    };

    let Some(discovered_session) = discovered_sessions
        .iter()
        .find(|session| session.id == session_id)
    else {
        return AttachmentFetchFulfillment {
            request_id,
            mime_type: None,
            data: None,
            error: Some(format!(
                "session {} was not found on host {}",
                session_id, host.location
            )),
        };
    };

    match transcript::build_persisted_snapshot(discovered_session) {
        Ok(session) => match attachment_payload(&session.messages, &attachment_id) {
            Some((mime_type, data)) => AttachmentFetchFulfillment {
                request_id,
                mime_type: Some(mime_type),
                data: Some(data),
                error: None,
            },
            None => AttachmentFetchFulfillment {
                request_id,
                mime_type: None,
                data: None,
                error: Some(format!(
                    "attachment {} was not found for session {}",
                    attachment_id, session_id
                )),
            },
        },
        Err(error) => AttachmentFetchFulfillment {
            request_id,
            mime_type: None,
            data: None,
            error: Some(format!(
                "failed to reconstruct transcript for session {}: {error}",
                session_id
            )),
        },
    }
}

enum SendMessageDispatch {
    LiveExtension,
    HeadlessRpc,
}

async fn handle_send_message(
    session_id: &str,
    body: String,
    images: Vec<ImageContent>,
    pi_agent_dir: &Path,
    summary_config: &summarizer::Config,
    live_store: &live::LiveSessionStoreHandle,
    live_updates_tx: &tokio::sync::mpsc::UnboundedSender<live::LiveUpdate>,
) -> Result<SendMessageDispatch, String> {
    let is_slash_command_message = looks_like_slash_command_message(&body);

    if is_pimux_resummarize_command(&body, &images)
        && !live_store.has_command_connection(session_id).await
    {
        handle_pimux_resummarize_command(
            session_id,
            pi_agent_dir,
            summary_config,
            live_store,
            live_updates_tx,
        )
        .await?;
        return Ok(SendMessageDispatch::HeadlessRpc);
    }

    match live_store
        .send_user_message(session_id, &body, images.clone())
        .await
    {
        Ok(()) => return Ok(SendMessageDispatch::LiveExtension),
        Err(live::SendUserMessageError::Unavailable) if is_slash_command_message => {
            return Err("slash commands require an attached live pi session".to_string());
        }
        Err(live::SendUserMessageError::Unavailable) => {}
        Err(error) => return Err(error.to_string()),
    }

    let discovered_sessions =
        discovery::discover_sessions(pi_agent_dir).map_err(|error| error.to_string())?;
    let Some(discovered_session) = discovered_sessions
        .into_iter()
        .find(|session| session.id == session_id)
    else {
        return Err(format!("session {} was not found", session_id));
    };

    send::send_message_to_session(
        discovered_session,
        body,
        images,
        pi_agent_dir.to_path_buf(),
        live_store.clone(),
        live_updates_tx.clone(),
    )
    .await
    .map(|_| SendMessageDispatch::HeadlessRpc)
}

fn looks_like_slash_command_message(body: &str) -> bool {
    body.trim_start().starts_with('/')
}

fn is_pimux_resummarize_command(body: &str, images: &[ImageContent]) -> bool {
    if !images.is_empty() {
        return false;
    }

    let mut parts = body.split_whitespace();
    matches!(
        (parts.next(), parts.next(), parts.next()),
        (Some("/pimux"), Some("resummarize"), None)
    )
}

async fn handle_pimux_resummarize_command(
    session_id: &str,
    pi_agent_dir: &Path,
    summary_config: &summarizer::Config,
    live_store: &live::LiveSessionStoreHandle,
    live_updates_tx: &tokio::sync::mpsc::UnboundedSender<live::LiveUpdate>,
) -> Result<(), String> {
    let discovered_sessions =
        discovery::discover_sessions(pi_agent_dir).map_err(|error| error.to_string())?;
    let Some(discovered_session) = discovered_sessions
        .into_iter()
        .find(|session| session.id == session_id)
    else {
        return Err(format!("session {} was not found", session_id));
    };

    let summary = summarizer::resummarize_session(&discovered_session, summary_config).await;
    let rename_command = format!("/name {summary}");

    send::send_message_to_session(
        discovered_session,
        rename_command,
        Vec::new(),
        pi_agent_dir.to_path_buf(),
        live_store.clone(),
        live_updates_tx.clone(),
    )
    .await
}

async fn handle_builtin_command(
    session_id: &str,
    action: SessionBuiltinCommandRequest,
    pi_agent_dir: &Path,
    live_store: &live::LiveSessionStoreHandle,
    live_updates_tx: &tokio::sync::mpsc::UnboundedSender<live::LiveUpdate>,
) -> Result<SessionBuiltinCommandResponse, String> {
    match action {
        SessionBuiltinCommandRequest::SetSessionName { name } => {
            let name = name.trim().to_string();
            if name.is_empty() {
                return Err("session name must not be empty".to_string());
            }

            let live_action = SessionBuiltinCommandRequest::SetSessionName { name: name.clone() };
            if try_run_live_builtin_command(session_id, &live_action, live_store).await? {
                return Ok(SessionBuiltinCommandResponse::default());
            }

            let discovered_session = find_discovered_session(pi_agent_dir, session_id)?;
            send::set_session_name(discovered_session, name, pi_agent_dir.to_path_buf()).await?;
            Ok(SessionBuiltinCommandResponse::default())
        }
        SessionBuiltinCommandRequest::Compact {
            custom_instructions,
        } => {
            let custom_instructions = custom_instructions.and_then(trimmed_non_empty);
            let live_action = SessionBuiltinCommandRequest::Compact {
                custom_instructions: custom_instructions.clone(),
            };
            if try_run_live_builtin_command(session_id, &live_action, live_store).await? {
                return Ok(SessionBuiltinCommandResponse::default());
            }

            let discovered_session = find_discovered_session(pi_agent_dir, session_id)?;
            send::compact_session(
                discovered_session,
                custom_instructions,
                pi_agent_dir.to_path_buf(),
            )
            .await?;
            publish_persisted_snapshot_for_session(session_id, pi_agent_dir, live_updates_tx).await;
            Ok(SessionBuiltinCommandResponse::default())
        }
        SessionBuiltinCommandRequest::Reload => {
            if try_run_live_builtin_command(
                session_id,
                &SessionBuiltinCommandRequest::Reload,
                live_store,
            )
            .await?
            {
                return Ok(SessionBuiltinCommandResponse::default());
            }

            Err("reload requires an attached live pi session".to_string())
        }
        SessionBuiltinCommandRequest::NewSession => {
            let discovered_session = find_discovered_session(pi_agent_dir, session_id)?;
            let state = send::new_session(discovered_session, pi_agent_dir.to_path_buf()).await?;
            publish_persisted_snapshot_for_session(
                &state.session_id,
                pi_agent_dir,
                live_updates_tx,
            )
            .await;
            Ok(SessionBuiltinCommandResponse {
                session_id: Some(state.session_id),
                fork_messages: None,
            })
        }
        SessionBuiltinCommandRequest::GetForkMessages => {
            let discovered_session = find_discovered_session(pi_agent_dir, session_id)?;
            let messages = send::get_fork_messages(discovered_session, pi_agent_dir.to_path_buf())
                .await?
                .into_iter()
                .map(|message| ForkMessage {
                    entry_id: message.entry_id,
                    text: message.text,
                })
                .collect();
            Ok(SessionBuiltinCommandResponse {
                session_id: None,
                fork_messages: Some(messages),
            })
        }
        SessionBuiltinCommandRequest::Fork { entry_id } => {
            let entry_id = entry_id.trim().to_string();
            if entry_id.is_empty() {
                return Err("fork entry id must not be empty".to_string());
            }

            let discovered_session = find_discovered_session(pi_agent_dir, session_id)?;
            let state =
                send::fork_session(discovered_session, entry_id, pi_agent_dir.to_path_buf())
                    .await?;
            publish_persisted_snapshot_for_session(
                &state.session_id,
                pi_agent_dir,
                live_updates_tx,
            )
            .await;
            Ok(SessionBuiltinCommandResponse {
                session_id: Some(state.session_id),
                fork_messages: None,
            })
        }
    }
}

fn find_discovered_session(
    pi_agent_dir: &Path,
    session_id: &str,
) -> Result<discovery::DiscoveredSession, String> {
    let discovered_sessions =
        discovery::discover_sessions(pi_agent_dir).map_err(|error| error.to_string())?;
    discovered_sessions
        .into_iter()
        .find(|session| session.id == session_id)
        .ok_or_else(|| format!("session {} was not found", session_id))
}

fn trimmed_non_empty(value: String) -> Option<String> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_string())
    }
}

async fn try_run_live_builtin_command(
    session_id: &str,
    action: &SessionBuiltinCommandRequest,
    live_store: &live::LiveSessionStoreHandle,
) -> Result<bool, String> {
    match live_store
        .send_builtin_command(session_id, action.clone())
        .await
    {
        Ok(()) => Ok(true),
        Err(live::BuiltinCommandError::Unavailable) => Ok(false),
        Err(error) => Err(error.to_string()),
    }
}

async fn publish_persisted_snapshot_for_session(
    session_id: &str,
    pi_agent_dir: &Path,
    live_updates_tx: &tokio::sync::mpsc::UnboundedSender<live::LiveUpdate>,
) {
    let Ok(discovered_sessions) = discovery::discover_sessions(pi_agent_dir) else {
        return;
    };
    let Some(discovered_session) = discovered_sessions
        .into_iter()
        .find(|session| session.id == session_id)
    else {
        return;
    };
    let Ok(snapshot) = transcript::build_persisted_snapshot(&discovered_session) else {
        return;
    };
    let _ = live_updates_tx.send(live::LiveUpdate::Transcript {
        snapshot,
        active_session: None,
    });
}

fn build_server_url(server_url: &str, path: &str) -> Result<Url, BoxError> {
    join_server_url(server_url, path)
}

fn build_websocket_url(server_url: &str, path: &str) -> Result<String, BoxError> {
    let mut url = join_server_url(server_url, path)?;
    match url.scheme() {
        "http" => url
            .set_scheme("ws")
            .map_err(|()| "failed to set ws scheme")?,
        "https" => url
            .set_scheme("wss")
            .map_err(|()| "failed to set wss scheme")?,
        scheme => {
            return Err(format!(
                "unsupported server URL scheme `{scheme}`; use http:// or https://"
            )
            .into());
        }
    }
    Ok(url.to_string())
}

fn join_server_url(server_url: &str, path: &str) -> Result<Url, BoxError> {
    let mut url = Url::parse(server_url)?;
    if url.query().is_some() || url.fragment().is_some() {
        return Err("server URL must not contain a query string or fragment".into());
    }

    let suffix = path.trim_start_matches('/');
    let joined_path = match url.path().trim_end_matches('/') {
        "" | "/" => format!("/{suffix}"),
        base_path => format!("{base_path}/{suffix}"),
    };
    url.set_path(&joined_path);
    Ok(url)
}

async fn ensure_server_reachable(
    client: &Client,
    server_url: &str,
    health_url: &Url,
    version_url: &Url,
) -> Result<(), BoxError> {
    let response = client
        .get(health_url.clone())
        .send()
        .await
        .map_err(|error| {
            format!(
                "server {server_url} is not reachable at {}: {error}",
                health_url
            )
        })?;

    if !response.status().is_success() {
        let status = response.status();
        let body = response.text().await.unwrap_or_default();
        return Err(format!(
            "server {server_url} responded to {} with {status}: {body}",
            health_url
        )
        .into());
    }

    let response = client
        .get(version_url.clone())
        .send()
        .await
        .map_err(|error| {
            format!(
                "server {server_url} is reachable but {} failed: {error}",
                version_url
            )
        })?;

    if !response.status().is_success() {
        let status = response.status();
        let body = response.text().await.unwrap_or_default();
        return Err(format!(
            "server {server_url} is reachable but responded to {} with {status}: {body}",
            version_url
        )
        .into());
    }

    response
        .json::<VersionResponse>()
        .await
        .map(|_| ())
        .map_err(|error| {
            format!(
                "server {server_url} is reachable but {} did not return a valid pimux version response: {error}",
                version_url
            )
            .into()
        })
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
    let watched_path = watch_path_for_session_root(session_root)?;
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
            Err(error) => warn!(%error, "watch error"),
        })?;

    watcher.watch(&watched_path, RecursiveMode::Recursive)?;
    Ok(watcher)
}

fn watch_path_for_session_root(session_root: &Path) -> Result<PathBuf, BoxError> {
    if session_root.exists() {
        return Ok(session_root.to_path_buf());
    }

    let parent = session_root.parent().ok_or_else(|| {
        format!(
            "session root {} does not have a parent directory to watch",
            session_root.display()
        )
    })?;
    fs::create_dir_all(parent)?;
    Ok(parent.to_path_buf())
}

async fn debounce_changes(rx: &mut UnboundedReceiver<()>) {
    loop {
        match timeout(Duration::from_millis(250), rx.recv()).await {
            Ok(Some(_)) => continue,
            Ok(None) | Err(_) => break,
        }
    }
}

#[cfg(test)]
mod tests {
    use chrono::{Duration as ChronoDuration, Local, Utc};

    use super::*;

    #[test]
    fn normalizes_server_url_by_assuming_http() {
        let normalized = normalize_server_url("localhost:3000").unwrap();
        assert_eq!(normalized.url, "http://localhost:3000");
        assert!(normalized.inferred_http);
    }

    #[test]
    fn rejects_unsupported_server_url_scheme() {
        let error = normalize_server_url("ftp://localhost:3000").unwrap_err();
        assert!(error.to_string().contains("unsupported server URL scheme"));
    }

    #[test]
    fn builds_websocket_url_from_http_server() {
        let url = build_websocket_url("http://localhost:3000", "/agent/connect").unwrap();
        assert_eq!(url, "ws://localhost:3000/agent/connect");
    }

    #[test]
    fn preserves_base_path_when_building_server_urls() {
        let health = build_server_url("https://example.com/pimux", "/health").unwrap();
        let websocket = build_websocket_url("https://example.com/pimux", "/agent/connect").unwrap();

        assert_eq!(health.as_str(), "https://example.com/pimux/health");
        assert_eq!(websocket, "wss://example.com/pimux/agent/connect");
    }

    #[test]
    fn watch_path_prefers_session_root_when_present() {
        let base = temp_test_dir("watch-root-present");
        let session_root = base.join("sessions");
        fs::create_dir_all(&session_root).unwrap();

        let watched = watch_path_for_session_root(&session_root).unwrap();
        assert_eq!(watched, session_root);

        let _ = fs::remove_dir_all(base);
    }

    #[test]
    fn watch_path_falls_back_to_direct_parent_and_creates_it() {
        let base = temp_test_dir("watch-parent");
        let session_root = base.join("missing").join("sessions");

        let watched = watch_path_for_session_root(&session_root).unwrap();
        assert_eq!(watched, base.join("missing"));
        assert!(watched.exists());
        assert!(!session_root.exists());

        let _ = fs::remove_dir_all(base);
    }

    #[test]
    fn filters_discovered_sessions_by_local_date() {
        let today = Local::now().date_naive();
        let (start, _) = utc_range_for_local_date(today).unwrap();
        let sessions = vec![
            sample_discovered_session("today", start + ChronoDuration::hours(12)),
            sample_discovered_session("previous", start - ChronoDuration::hours(12)),
        ];

        let filtered = filter_discovered_sessions_by_date(
            sessions,
            Some(today.format("%Y-%m-%d").to_string()),
        )
        .unwrap();

        assert_eq!(filtered.len(), 1);
        assert_eq!(filtered[0].id, "today");
    }

    #[test]
    fn detects_slash_command_messages() {
        assert!(looks_like_slash_command_message("/bump"));
        assert!(looks_like_slash_command_message("  /todo later"));
        assert!(looks_like_slash_command_message(
            "/skill:swift-app-conventions"
        ));
        assert!(!looks_like_slash_command_message("hello /bump"));
        assert!(!looks_like_slash_command_message("hello"));
    }

    #[test]
    fn detects_pimux_resummarize_command() {
        assert!(is_pimux_resummarize_command("/pimux resummarize", &[]));
        assert!(is_pimux_resummarize_command(
            "  /pimux   resummarize  ",
            &[]
        ));
        assert!(!is_pimux_resummarize_command("/pimux", &[]));
        assert!(!is_pimux_resummarize_command("/pimux resummarize now", &[]));
        assert!(!is_pimux_resummarize_command(
            "/pimux resummarize",
            &[ImageContent::new("image/png", "abc")]
        ));
    }

    #[test]
    fn merge_live_sessions_sorts_deterministically() {
        let updated_at = Utc::now();
        let merged = merge_live_sessions(
            vec![
                sample_active_session("b", updated_at),
                sample_active_session("a", updated_at),
                sample_active_session("stale", updated_at - ChronoDuration::minutes(1)),
            ],
            vec![sample_active_session(
                "live",
                updated_at + ChronoDuration::minutes(1),
            )],
        );

        assert_eq!(
            merged
                .into_iter()
                .map(|session| session.id)
                .collect::<Vec<_>>(),
            vec!["live", "a", "b", "stale"]
        );
    }

    fn sample_active_session(
        id: &str,
        updated_at: chrono::DateTime<Utc>,
    ) -> crate::session::ActiveSession {
        sample_discovered_session(id, updated_at).into_active_session(format!("Summary {id}"))
    }

    fn temp_test_dir(name: &str) -> PathBuf {
        let root = std::env::temp_dir().join(format!(
            "pimux-agent-test-{name}-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).unwrap();
        root
    }

    fn sample_discovered_session(
        id: &str,
        updated_at: chrono::DateTime<Utc>,
    ) -> discovery::DiscoveredSession {
        discovery::DiscoveredSession {
            session_file: PathBuf::from(format!("/tmp/{id}.jsonl")),
            fingerprint: discovery::SessionFingerprint {
                file_size: 1,
                modified_at_millis: 1,
            },
            id: id.to_string(),
            explicit_summary: None,
            heuristic_summary: format!("Summary {id}"),
            summary_input: Some(format!("User: {id}")),
            created_at: updated_at - ChronoDuration::minutes(5),
            updated_at,
            last_user_message_at: updated_at - ChronoDuration::minutes(4),
            last_assistant_message_at: updated_at - ChronoDuration::minutes(3),
            cwd: "/tmp/project".to_string(),
            model: "anthropic/claude-sonnet-4-5".to_string(),
            context_usage: None,
            supports_images: None,
        }
    }
}
