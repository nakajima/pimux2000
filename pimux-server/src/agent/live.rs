use std::{
    collections::{HashMap, HashSet, VecDeque},
    fs,
    path::{Path, PathBuf},
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
    time::{Duration, Instant},
};

use chrono::Utc;
use serde::{Deserialize, Serialize};
use tokio::sync::{
    Mutex,
    mpsc::{self, UnboundedSender},
    oneshot,
};

use crate::{
    message::{ImageContent, Message, Role, truncate_text},
    session::{
        ActiveSession, SessionBuiltinCommandRequest, SessionCommand, SessionCommandCompletion,
        SessionContextUsage,
    },
    transcript::{
        SessionActivity, SessionMessagesResponse, SessionTerminalOnlyUiState,
        SessionUiDialogAction, SessionUiDialogState, SessionUiState, TranscriptFreshness,
        TranscriptFreshnessState, TranscriptSource,
    },
};

type BoxError = Box<dyn std::error::Error + Send + Sync>;

pub const DEFAULT_DETACHED_CAPACITY: usize = 3;
pub const DEFAULT_DETACHED_TTL: Duration = Duration::from_secs(180);
const MAX_LIVE_MESSAGE_BODY_CHARS: usize = 8_000;
const LIVE_PROTOCOL_VERSION: u32 = 8;
const MIN_COMMAND_PROTOCOL_VERSION: u32 = 7;
const COMMAND_ARGUMENT_COMPLETIONS_PROTOCOL_VERSION: u32 = 8;
const SEND_USER_MESSAGE_TIMEOUT: Duration = Duration::from_secs(5);
const GET_COMMANDS_TIMEOUT: Duration = Duration::from_secs(5);
const GET_COMMAND_ARGUMENT_COMPLETIONS_TIMEOUT: Duration = Duration::from_secs(5);
const UI_DIALOG_ACTION_TIMEOUT: Duration = Duration::from_secs(5);
const BUILTIN_COMMAND_TIMEOUT: Duration = Duration::from_secs(5);

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LiveSessionMetadata {
    pub created_at: chrono::DateTime<chrono::Utc>,
    pub cwd: String,
    pub summary: String,
    pub model: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub context_usage: Option<SessionContextUsage>,
}

#[derive(Debug, Clone)]
pub enum LiveUpdate {
    Transcript {
        snapshot: SessionMessagesResponse,
        active_session: Option<ActiveSession>,
    },
    UiState {
        session_id: String,
        ui_state: SessionUiState,
    },
    UiDialogState {
        session_id: String,
        ui_dialog_state: Option<SessionUiDialogState>,
    },
    TerminalOnlyUiState {
        session_id: String,
        terminal_only_ui_state: Option<SessionTerminalOnlyUiState>,
    },
}

#[derive(Clone)]
pub struct LiveSessionStoreHandle {
    inner: Arc<Mutex<LiveSessionStore>>,
}

impl LiveSessionStoreHandle {
    pub fn new(detached_capacity: usize, detached_ttl: Duration) -> Self {
        Self {
            inner: Arc::new(Mutex::new(LiveSessionStore::new(
                detached_capacity,
                detached_ttl,
            ))),
        }
    }

    pub async fn apply_event(&self, event: LiveSessionEvent) -> Option<SessionMessagesResponse> {
        let mut store = self.inner.lock().await;
        store.purge_expired();
        store.apply_event(event)
    }

    pub async fn snapshot_for_session(&self, session_id: &str) -> Option<SessionMessagesResponse> {
        let mut store = self.inner.lock().await;
        store.purge_expired();
        store.snapshot_for_session(session_id)
    }

    pub async fn all_snapshots(&self) -> HashMap<String, SessionMessagesResponse> {
        let mut store = self.inner.lock().await;
        store.purge_expired();
        store.all_snapshots()
    }

    pub async fn all_ui_states(&self) -> HashMap<String, SessionUiState> {
        let mut store = self.inner.lock().await;
        store.purge_expired();
        store.all_ui_states()
    }

    pub async fn all_ui_dialog_states(&self) -> HashMap<String, SessionUiDialogState> {
        let mut store = self.inner.lock().await;
        store.purge_expired();
        store.all_ui_dialog_states()
    }

    pub async fn all_terminal_only_ui_states(&self) -> HashMap<String, SessionTerminalOnlyUiState> {
        let mut store = self.inner.lock().await;
        store.purge_expired();
        store.all_terminal_only_ui_states()
    }

    pub async fn listed_session_for_session(&self, session_id: &str) -> Option<ActiveSession> {
        let mut store = self.inner.lock().await;
        store.purge_expired();
        store.listed_session_for(session_id)
    }

    pub async fn all_listed_sessions(&self) -> Vec<ActiveSession> {
        let mut store = self.inner.lock().await;
        store.purge_expired();
        store.all_listed_sessions()
    }

    pub async fn has_command_connection(&self, session_id: &str) -> bool {
        let mut store = self.inner.lock().await;
        store.purge_expired();
        store.has_command_connection(session_id)
    }

    async fn register_command_connection(
        &self,
        connection_id: u64,
        sender: UnboundedSender<LiveAgentCommand>,
    ) {
        self.register_command_connection_with_protocol(
            connection_id,
            sender,
            LIVE_PROTOCOL_VERSION,
        )
        .await;
    }

    async fn register_command_connection_with_protocol(
        &self,
        connection_id: u64,
        sender: UnboundedSender<LiveAgentCommand>,
        protocol_version: u32,
    ) {
        let mut store = self.inner.lock().await;
        store.register_command_connection(connection_id, sender, protocol_version);
    }

    async fn bind_command_connection_to_session(
        &self,
        connection_id: u64,
        session_id: String,
    ) -> Option<SessionMessagesResponse> {
        let mut store = self.inner.lock().await;
        store.purge_expired();
        store.bind_command_connection_to_session(connection_id, session_id)
    }

    async fn unbind_command_connection_from_session(&self, connection_id: u64, session_id: &str) {
        let mut store = self.inner.lock().await;
        store.unbind_command_connection_from_session(connection_id, session_id);
    }

    async fn fulfill_send_user_message(
        &self,
        connection_id: u64,
        request_id: &str,
        error: Option<String>,
    ) {
        let mut store = self.inner.lock().await;
        store.fulfill_send_user_message(connection_id, request_id, error);
    }

    async fn disconnect_command_connection(
        &self,
        connection_id: u64,
    ) -> Option<SessionMessagesResponse> {
        let mut store = self.inner.lock().await;
        store.purge_expired();
        store.disconnect_command_connection(connection_id)
    }

    pub async fn get_commands(
        &self,
        session_id: &str,
    ) -> Result<Vec<SessionCommand>, GetCommandsError> {
        let (sender, request_id, receiver) = {
            let mut store = self.inner.lock().await;
            store.purge_expired();
            store.prepare_get_commands(session_id)?
        };

        if sender
            .send(LiveAgentCommand::GetCommands {
                request_id: request_id.clone(),
                session_id: session_id.to_string(),
            })
            .is_err()
        {
            let mut store = self.inner.lock().await;
            store.cancel_get_commands(&request_id);
            return Err(GetCommandsError::Unavailable);
        }

        match tokio::time::timeout(GET_COMMANDS_TIMEOUT, receiver).await {
            Ok(Ok(result)) => result,
            Ok(Err(_)) => Err(GetCommandsError::Disconnected),
            Err(_) => {
                let mut store = self.inner.lock().await;
                store.cancel_get_commands(&request_id);
                Err(GetCommandsError::TimedOut)
            }
        }
    }

    pub async fn fulfill_get_commands(
        &self,
        connection_id: u64,
        request_id: &str,
        commands: Vec<SessionCommand>,
        error: Option<String>,
    ) {
        let mut store = self.inner.lock().await;
        store.fulfill_get_commands(connection_id, request_id, commands, error);
    }

    pub async fn get_command_argument_completions(
        &self,
        session_id: &str,
        command_name: &str,
        argument_prefix: &str,
    ) -> Result<Vec<SessionCommandCompletion>, GetCommandArgumentCompletionsError> {
        let (sender, request_id, receiver) = {
            let mut store = self.inner.lock().await;
            store.purge_expired();
            store.prepare_get_command_argument_completions(session_id)?
        };

        if sender
            .send(LiveAgentCommand::GetCommandArgumentCompletions {
                request_id: request_id.clone(),
                session_id: session_id.to_string(),
                command_name: command_name.to_string(),
                argument_prefix: argument_prefix.to_string(),
            })
            .is_err()
        {
            let mut store = self.inner.lock().await;
            store.cancel_get_command_argument_completions(&request_id);
            return Err(GetCommandArgumentCompletionsError::Unavailable);
        }

        match tokio::time::timeout(GET_COMMAND_ARGUMENT_COMPLETIONS_TIMEOUT, receiver).await {
            Ok(Ok(result)) => result,
            Ok(Err(_)) => Err(GetCommandArgumentCompletionsError::Disconnected),
            Err(_) => {
                let mut store = self.inner.lock().await;
                store.cancel_get_command_argument_completions(&request_id);
                Err(GetCommandArgumentCompletionsError::TimedOut)
            }
        }
    }

    pub async fn fulfill_get_command_argument_completions(
        &self,
        connection_id: u64,
        request_id: &str,
        completions: Vec<SessionCommandCompletion>,
        error: Option<String>,
    ) {
        let mut store = self.inner.lock().await;
        store.fulfill_get_command_argument_completions(connection_id, request_id, completions, error);
    }

    pub async fn send_ui_dialog_action(
        &self,
        session_id: &str,
        dialog_id: &str,
        action: SessionUiDialogAction,
    ) -> Result<(), UiDialogActionError> {
        let (sender, request_id, receiver) = {
            let mut store = self.inner.lock().await;
            store.purge_expired();
            store.prepare_ui_dialog_action(session_id, dialog_id)?
        };

        if sender
            .send(LiveAgentCommand::UiDialogAction {
                request_id: request_id.clone(),
                session_id: session_id.to_string(),
                dialog_id: dialog_id.to_string(),
                action,
            })
            .is_err()
        {
            let mut store = self.inner.lock().await;
            store.cancel_ui_dialog_action(&request_id);
            return Err(UiDialogActionError::Unavailable);
        }

        match tokio::time::timeout(UI_DIALOG_ACTION_TIMEOUT, receiver).await {
            Ok(Ok(result)) => result,
            Ok(Err(_)) => Err(UiDialogActionError::Disconnected),
            Err(_) => {
                let mut store = self.inner.lock().await;
                store.cancel_ui_dialog_action(&request_id);
                Err(UiDialogActionError::TimedOut)
            }
        }
    }

    pub async fn fulfill_ui_dialog_action(
        &self,
        connection_id: u64,
        request_id: &str,
        error: Option<String>,
    ) {
        let mut store = self.inner.lock().await;
        store.fulfill_ui_dialog_action(connection_id, request_id, error);
    }

    pub async fn send_builtin_command(
        &self,
        session_id: &str,
        action: SessionBuiltinCommandRequest,
    ) -> Result<(), BuiltinCommandError> {
        let (sender, request_id, receiver) = {
            let mut store = self.inner.lock().await;
            store.purge_expired();
            store.prepare_builtin_command(session_id)?
        };

        if sender
            .send(LiveAgentCommand::BuiltinCommand {
                request_id: request_id.clone(),
                session_id: session_id.to_string(),
                action,
            })
            .is_err()
        {
            let mut store = self.inner.lock().await;
            store.cancel_builtin_command(&request_id);
            return Err(BuiltinCommandError::Unavailable);
        }

        match tokio::time::timeout(BUILTIN_COMMAND_TIMEOUT, receiver).await {
            Ok(Ok(result)) => result,
            Ok(Err(_)) => Err(BuiltinCommandError::Disconnected),
            Err(_) => {
                let mut store = self.inner.lock().await;
                store.cancel_builtin_command(&request_id);
                Err(BuiltinCommandError::TimedOut)
            }
        }
    }

    pub async fn fulfill_builtin_command(
        &self,
        connection_id: u64,
        request_id: &str,
        error: Option<String>,
    ) {
        let mut store = self.inner.lock().await;
        store.fulfill_builtin_command(connection_id, request_id, error);
    }

    pub async fn send_user_message(
        &self,
        session_id: &str,
        body: &str,
        images: Vec<ImageContent>,
    ) -> Result<(), SendUserMessageError> {
        let (sender, request_id, receiver) = {
            let mut store = self.inner.lock().await;
            store.purge_expired();
            store.prepare_send_user_message(session_id)?
        };

        if sender
            .send(LiveAgentCommand::SendUserMessage {
                request_id: request_id.clone(),
                session_id: session_id.to_string(),
                body: body.to_string(),
                images,
            })
            .is_err()
        {
            let mut store = self.inner.lock().await;
            store.cancel_send_user_message(&request_id);
            return Err(SendUserMessageError::Unavailable);
        }

        match tokio::time::timeout(SEND_USER_MESSAGE_TIMEOUT, receiver).await {
            Ok(Ok(result)) => result,
            Ok(Err(_)) => Err(SendUserMessageError::Disconnected),
            Err(_) => {
                let mut store = self.inner.lock().await;
                store.cancel_send_user_message(&request_id);
                Err(SendUserMessageError::TimedOut)
            }
        }
    }
}

pub fn socket_path(pi_agent_dir: &Path) -> PathBuf {
    pi_agent_dir.join("pimux").join("live.sock")
}

pub async fn start_listener(
    store: LiveSessionStoreHandle,
    socket_path: PathBuf,
    updates: UnboundedSender<LiveUpdate>,
) -> Result<(), BoxError> {
    start_listener_impl(store, socket_path, updates).await
}

async fn maybe_request_extension_reload(
    store: &LiveSessionStoreHandle,
    supports_commands: bool,
    session_id: &str,
) {
    let should_attempt_reload = {
        let mut guard = store.inner.lock().await;
        if !guard
            .warned_missing_metadata_sessions
            .insert(session_id.to_string())
        {
            return;
        }

        supports_commands
    };

    if !should_attempt_reload {
        eprintln!(
            "live extension warning for session {}: received live payloads without session metadata from an older pimux-live extension, but that runtime does not support inbound commands. Run /reload in pi or restart the pi session to load the updated extension.",
            session_id
        );
        return;
    }

    eprintln!(
        "live extension warning for session {}: received live payloads without session metadata from an older pimux-live extension; auto-requesting /reload in the attached pi session to load the updated extension.",
        session_id
    );

    let store = store.clone();
    let session_id = session_id.to_string();
    tokio::spawn(async move {
        match store
            .send_user_message(&session_id, "/reload", Vec::new())
            .await
        {
            Ok(()) => {
                eprintln!(
                    "requested /reload in attached pi session {} to load the updated pimux-live extension",
                    session_id
                );
            }
            Err(error) => {
                eprintln!(
                    "failed to auto-request /reload for attached pi session {}: {}",
                    session_id, error
                );
            }
        }
    });
}

#[cfg(unix)]
async fn start_listener_impl(
    store: LiveSessionStoreHandle,
    socket_path: PathBuf,
    updates: UnboundedSender<LiveUpdate>,
) -> Result<(), BoxError> {
    use tokio::{
        io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
        net::UnixListener,
    };

    if let Some(parent) = socket_path.parent() {
        fs::create_dir_all(parent)?;
    }

    if socket_path.exists() {
        fs::remove_file(&socket_path)?;
    }

    let listener = UnixListener::bind(&socket_path)?;
    let next_connection_id = Arc::new(AtomicU64::new(1));

    tokio::spawn(async move {
        loop {
            let (stream, _) = match listener.accept().await {
                Ok(connection) => connection,
                Err(error) => {
                    eprintln!("live ipc accept error: {error}");
                    continue;
                }
            };

            let connection_id = next_connection_id.fetch_add(1, Ordering::Relaxed);
            let (command_tx, mut command_rx) = mpsc::unbounded_channel::<LiveAgentCommand>();
            let (reader, mut writer) = tokio::io::split(stream);
            let store = store.clone();
            let updates = updates.clone();
            let writer_task = tokio::spawn(async move {
                while let Some(command) = command_rx.recv().await {
                    let Ok(payload) = serde_json::to_string(&command) else {
                        break;
                    };
                    if writer.write_all(payload.as_bytes()).await.is_err() {
                        break;
                    }
                    if writer.write_all(b"\n").await.is_err() {
                        break;
                    }
                    if writer.flush().await.is_err() {
                        break;
                    }
                }
            });

            tokio::spawn(async move {
                let mut supports_commands = false;
                let reader = BufReader::new(reader);
                let mut lines = reader.lines();

                loop {
                    match lines.next_line().await {
                        Ok(Some(line)) => {
                            let line = line.trim();
                            if line.is_empty() {
                                continue;
                            }

                            let message = match serde_json::from_str::<LiveSessionIpcMessage>(line)
                            {
                                Ok(message) => message,
                                Err(error) => {
                                    eprintln!("invalid live ipc message: {error}");
                                    continue;
                                }
                            };

                            match message {
                                LiveSessionIpcMessage::Hello { protocol_version } => {
                                    if !(MIN_COMMAND_PROTOCOL_VERSION
                                        ..=LIVE_PROTOCOL_VERSION)
                                        .contains(&protocol_version)
                                    {
                                        eprintln!(
                                            "live ipc protocol mismatch for connection {connection_id}: extension reported version {protocol_version}, agent supports {MIN_COMMAND_PROTOCOL_VERSION}...{LIVE_PROTOCOL_VERSION}"
                                        );
                                        continue;
                                    }

                                    supports_commands = true;
                                    store
                                        .register_command_connection_with_protocol(
                                            connection_id,
                                            command_tx.clone(),
                                            protocol_version,
                                        )
                                        .await;
                                }
                                LiveSessionIpcMessage::SendUserMessageResult {
                                    request_id,
                                    session_id: _,
                                    error,
                                } => {
                                    store
                                        .fulfill_send_user_message(
                                            connection_id,
                                            &request_id,
                                            error,
                                        )
                                        .await;
                                }
                                LiveSessionIpcMessage::GetCommandsResult {
                                    request_id,
                                    session_id: _,
                                    commands,
                                    error,
                                } => {
                                    store
                                        .fulfill_get_commands(
                                            connection_id,
                                            &request_id,
                                            commands,
                                            error,
                                        )
                                        .await;
                                }
                                LiveSessionIpcMessage::GetCommandArgumentCompletionsResult {
                                    request_id,
                                    session_id: _,
                                    completions,
                                    error,
                                } => {
                                    store
                                        .fulfill_get_command_argument_completions(
                                            connection_id,
                                            &request_id,
                                            completions,
                                            error,
                                        )
                                        .await;
                                }
                                LiveSessionIpcMessage::UiDialogActionResult {
                                    request_id,
                                    session_id: _,
                                    error,
                                } => {
                                    store
                                        .fulfill_ui_dialog_action(connection_id, &request_id, error)
                                        .await;
                                }
                                LiveSessionIpcMessage::BuiltinCommandResult {
                                    request_id,
                                    session_id: _,
                                    error,
                                } => {
                                    store
                                        .fulfill_builtin_command(connection_id, &request_id, error)
                                        .await;
                                }
                                LiveSessionIpcMessage::SessionAttached {
                                    session_id,
                                    metadata,
                                } => {
                                    if supports_commands
                                        && let Some(snapshot) = store
                                            .bind_command_connection_to_session(
                                                connection_id,
                                                session_id.clone(),
                                            )
                                            .await
                                    {
                                        let active_session = store
                                            .listed_session_for_session(&snapshot.session_id)
                                            .await;
                                        let _ = updates.send(LiveUpdate::Transcript {
                                            snapshot,
                                            active_session,
                                        });
                                    }

                                    let missing_metadata = metadata.is_none();
                                    let snapshot = {
                                        let mut guard = store.inner.lock().await;
                                        guard.purge_expired();
                                        if let Some(metadata) = metadata {
                                            guard.upsert_session_metadata(&session_id, metadata);
                                        }
                                        guard.apply_event(LiveSessionEvent::SessionAttached {
                                            session_id: session_id.clone(),
                                        })
                                    };

                                    if missing_metadata {
                                        maybe_request_extension_reload(
                                            &store,
                                            supports_commands,
                                            &session_id,
                                        )
                                        .await;
                                    }

                                    if let Some(snapshot) = snapshot {
                                        let active_session = store
                                            .listed_session_for_session(&snapshot.session_id)
                                            .await;
                                        let _ = updates.send(LiveUpdate::Transcript {
                                            snapshot,
                                            active_session,
                                        });
                                    }
                                }
                                LiveSessionIpcMessage::SessionSnapshot {
                                    session_id,
                                    messages,
                                    metadata,
                                } => {
                                    let snapshot = {
                                        let mut guard = store.inner.lock().await;
                                        guard.purge_expired();
                                        if let Some(metadata) = metadata {
                                            guard.upsert_session_metadata(&session_id, metadata);
                                        }
                                        guard.apply_event(LiveSessionEvent::SessionSnapshot {
                                            session_id,
                                            messages,
                                        })
                                    };

                                    if let Some(snapshot) = snapshot {
                                        let active_session = store
                                            .listed_session_for_session(&snapshot.session_id)
                                            .await;
                                        let _ = updates.send(LiveUpdate::Transcript {
                                            snapshot,
                                            active_session,
                                        });
                                    }
                                }
                                LiveSessionIpcMessage::SessionAppend {
                                    session_id,
                                    messages,
                                    metadata,
                                } => {
                                    let snapshot = {
                                        let mut guard = store.inner.lock().await;
                                        guard.purge_expired();
                                        if let Some(metadata) = metadata {
                                            guard.upsert_session_metadata(&session_id, metadata);
                                        }
                                        guard.apply_event(LiveSessionEvent::SessionAppend {
                                            session_id,
                                            messages,
                                        })
                                    };

                                    if let Some(snapshot) = snapshot {
                                        let active_session = store
                                            .listed_session_for_session(&snapshot.session_id)
                                            .await;
                                        let _ = updates.send(LiveUpdate::Transcript {
                                            snapshot,
                                            active_session,
                                        });
                                    }
                                }
                                LiveSessionIpcMessage::AssistantPartial {
                                    session_id,
                                    message,
                                } => {
                                    let snapshot = {
                                        let mut guard = store.inner.lock().await;
                                        guard.purge_expired();
                                        guard.apply_event(LiveSessionEvent::AssistantPartial {
                                            session_id,
                                            message,
                                        })
                                    };

                                    if let Some(snapshot) = snapshot {
                                        let _ = updates.send(LiveUpdate::Transcript {
                                            snapshot,
                                            active_session: None,
                                        });
                                    }
                                }
                                LiveSessionIpcMessage::UiState { session_id, state } => {
                                    {
                                        let mut guard = store.inner.lock().await;
                                        guard.purge_expired();
                                        guard.apply_event(LiveSessionEvent::UiState {
                                            session_id: session_id.clone(),
                                            state: state.clone(),
                                        });
                                    }

                                    let _ = updates.send(LiveUpdate::UiState {
                                        session_id,
                                        ui_state: state,
                                    });
                                }
                                LiveSessionIpcMessage::UiDialogState { session_id, state } => {
                                    {
                                        let mut guard = store.inner.lock().await;
                                        guard.purge_expired();
                                        guard.apply_event(LiveSessionEvent::UiDialogState {
                                            session_id: session_id.clone(),
                                            state: state.clone(),
                                        });
                                    }

                                    let _ = updates.send(LiveUpdate::UiDialogState {
                                        session_id,
                                        ui_dialog_state: state,
                                    });
                                }
                                LiveSessionIpcMessage::TerminalOnlyUiState {
                                    session_id,
                                    state,
                                } => {
                                    {
                                        let mut guard = store.inner.lock().await;
                                        guard.purge_expired();
                                        guard.apply_event(LiveSessionEvent::TerminalOnlyUiState {
                                            session_id: session_id.clone(),
                                            state: state.clone(),
                                        });
                                    }

                                    let _ = updates.send(LiveUpdate::TerminalOnlyUiState {
                                        session_id,
                                        terminal_only_ui_state: state,
                                    });
                                }
                                LiveSessionIpcMessage::SessionDetached { session_id } => {
                                    if supports_commands {
                                        store
                                            .unbind_command_connection_from_session(
                                                connection_id,
                                                &session_id,
                                            )
                                            .await;
                                    }

                                    let snapshot = {
                                        let mut guard = store.inner.lock().await;
                                        guard.purge_expired();
                                        guard.apply_event(LiveSessionEvent::SessionDetached {
                                            session_id,
                                        })
                                    };

                                    if let Some(snapshot) = snapshot {
                                        let active_session = store
                                            .listed_session_for_session(&snapshot.session_id)
                                            .await;
                                        let _ = updates.send(LiveUpdate::Transcript {
                                            snapshot,
                                            active_session,
                                        });
                                    }
                                }
                            }
                        }
                        Ok(None) => break,
                        Err(error) => {
                            eprintln!("live ipc read error: {error}");
                            break;
                        }
                    }
                }

                writer_task.abort();

                if supports_commands
                    && let Some(snapshot) = store.disconnect_command_connection(connection_id).await
                {
                    let active_session =
                        store.listed_session_for_session(&snapshot.session_id).await;
                    let _ = updates.send(LiveUpdate::Transcript {
                        snapshot,
                        active_session,
                    });
                }
            });
        }
    });

    Ok(())
}

#[cfg(not(unix))]
async fn start_listener_impl(
    _store: LiveSessionStoreHandle,
    _socket_path: PathBuf,
    _updates: UnboundedSender<LiveUpdate>,
) -> Result<(), BoxError> {
    Err("live session IPC via Unix sockets is only supported on unix hosts".into())
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SendUserMessageError {
    Unavailable,
    Disconnected,
    TimedOut,
    Rejected(String),
}

impl std::fmt::Display for SendUserMessageError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Unavailable => write!(
                f,
                "no live attached pimux extension is available for this session"
            ),
            Self::Disconnected => write!(f, "live session command connection disconnected"),
            Self::TimedOut => write!(
                f,
                "timed out waiting for live session command acknowledgement"
            ),
            Self::Rejected(error) => write!(f, "{error}"),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GetCommandsError {
    Unavailable,
    Disconnected,
    TimedOut,
    Failed(String),
}

impl std::fmt::Display for GetCommandsError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Unavailable => write!(
                f,
                "no live attached pimux extension is available for this session"
            ),
            Self::Disconnected => write!(f, "live session command connection disconnected"),
            Self::TimedOut => write!(f, "timed out waiting for commands response"),
            Self::Failed(error) => write!(f, "{error}"),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GetCommandArgumentCompletionsError {
    Unavailable,
    Disconnected,
    TimedOut,
    Failed(String),
}

impl std::fmt::Display for GetCommandArgumentCompletionsError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Unavailable => write!(
                f,
                "no live attached pimux extension is available for this session"
            ),
            Self::Disconnected => write!(f, "live session command connection disconnected"),
            Self::TimedOut => write!(
                f,
                "timed out waiting for command argument completions response"
            ),
            Self::Failed(error) => write!(f, "{error}"),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum UiDialogActionError {
    Unavailable,
    Disconnected,
    TimedOut,
    Rejected(String),
}

impl std::fmt::Display for UiDialogActionError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Unavailable => write!(
                f,
                "no live attached pimux extension is available for this session"
            ),
            Self::Disconnected => write!(f, "live session command connection disconnected"),
            Self::TimedOut => write!(f, "timed out waiting for ui dialog action acknowledgement"),
            Self::Rejected(error) => write!(f, "{error}"),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BuiltinCommandError {
    Unavailable,
    Disconnected,
    TimedOut,
    Rejected(String),
}

impl std::fmt::Display for BuiltinCommandError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Unavailable => write!(
                f,
                "no live attached pimux extension is available for this session"
            ),
            Self::Disconnected => write!(f, "live session command connection disconnected"),
            Self::TimedOut => write!(f, "timed out waiting for builtin command acknowledgement"),
            Self::Rejected(error) => write!(f, "{error}"),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(
    tag = "type",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
enum LiveSessionIpcMessage {
    Hello {
        protocol_version: u32,
    },
    SessionAttached {
        session_id: String,
        #[serde(default)]
        metadata: Option<LiveSessionMetadata>,
    },
    SessionSnapshot {
        session_id: String,
        messages: Vec<Message>,
        #[serde(default)]
        metadata: Option<LiveSessionMetadata>,
    },
    SessionAppend {
        session_id: String,
        messages: Vec<Message>,
        #[serde(default)]
        metadata: Option<LiveSessionMetadata>,
    },
    AssistantPartial {
        session_id: String,
        message: Message,
    },
    UiState {
        session_id: String,
        state: SessionUiState,
    },
    UiDialogState {
        session_id: String,
        state: Option<SessionUiDialogState>,
    },
    TerminalOnlyUiState {
        session_id: String,
        state: Option<SessionTerminalOnlyUiState>,
    },
    SessionDetached {
        session_id: String,
    },
    SendUserMessageResult {
        request_id: String,
        session_id: String,
        error: Option<String>,
    },
    GetCommandsResult {
        request_id: String,
        session_id: String,
        commands: Vec<SessionCommand>,
        #[serde(skip_serializing_if = "Option::is_none")]
        error: Option<String>,
    },
    GetCommandArgumentCompletionsResult {
        request_id: String,
        session_id: String,
        completions: Vec<SessionCommandCompletion>,
        #[serde(skip_serializing_if = "Option::is_none")]
        error: Option<String>,
    },
    UiDialogActionResult {
        request_id: String,
        session_id: String,
        error: Option<String>,
    },
    BuiltinCommandResult {
        request_id: String,
        session_id: String,
        error: Option<String>,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(
    tag = "type",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
enum LiveAgentCommand {
    SendUserMessage {
        request_id: String,
        session_id: String,
        body: String,
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        images: Vec<ImageContent>,
    },
    GetCommands {
        request_id: String,
        session_id: String,
    },
    GetCommandArgumentCompletions {
        request_id: String,
        session_id: String,
        command_name: String,
        argument_prefix: String,
    },
    UiDialogAction {
        request_id: String,
        session_id: String,
        dialog_id: String,
        action: SessionUiDialogAction,
    },
    BuiltinCommand {
        request_id: String,
        session_id: String,
        action: SessionBuiltinCommandRequest,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(
    tag = "type",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
pub enum LiveSessionEvent {
    SessionAttached {
        session_id: String,
    },
    SessionSnapshot {
        session_id: String,
        messages: Vec<Message>,
    },
    SessionAppend {
        session_id: String,
        messages: Vec<Message>,
    },
    AssistantPartial {
        session_id: String,
        message: Message,
    },
    UiState {
        session_id: String,
        state: SessionUiState,
    },
    UiDialogState {
        session_id: String,
        state: Option<SessionUiDialogState>,
    },
    TerminalOnlyUiState {
        session_id: String,
        state: Option<SessionTerminalOnlyUiState>,
    },
    SessionDetached {
        session_id: String,
    },
}

struct LiveSessionStore {
    active_sessions: HashMap<String, LiveSessionState>,
    recent_detached_sessions: HashMap<String, DetachedSessionState>,
    detached_order: VecDeque<String>,
    warned_legacy_sessions: HashSet<String>,
    warned_missing_metadata_sessions: HashSet<String>,
    command_connections: HashMap<u64, LiveCommandConnection>,
    command_session_connections: HashMap<String, u64>,
    inflight_send_user_messages: HashMap<String, InflightSendUserMessage>,
    inflight_get_commands: HashMap<String, InflightGetCommands>,
    inflight_get_command_argument_completions:
        HashMap<String, InflightGetCommandArgumentCompletions>,
    inflight_ui_dialog_actions: HashMap<String, InflightUiDialogAction>,
    inflight_builtin_commands: HashMap<String, InflightBuiltinCommand>,
    next_send_request_id: u64,
    detached_capacity: usize,
    detached_ttl: Duration,
}

impl LiveSessionStore {
    fn new(detached_capacity: usize, detached_ttl: Duration) -> Self {
        Self {
            active_sessions: HashMap::new(),
            recent_detached_sessions: HashMap::new(),
            detached_order: VecDeque::new(),
            warned_legacy_sessions: HashSet::new(),
            warned_missing_metadata_sessions: HashSet::new(),
            command_connections: HashMap::new(),
            command_session_connections: HashMap::new(),
            inflight_send_user_messages: HashMap::new(),
            inflight_get_commands: HashMap::new(),
            inflight_get_command_argument_completions: HashMap::new(),
            inflight_ui_dialog_actions: HashMap::new(),
            inflight_builtin_commands: HashMap::new(),
            next_send_request_id: 1,
            detached_capacity,
            detached_ttl,
        }
    }

    fn apply_event(&mut self, event: LiveSessionEvent) -> Option<SessionMessagesResponse> {
        match event {
            LiveSessionEvent::SessionAttached { session_id } => {
                self.warned_legacy_sessions.remove(&session_id);
                self.warned_missing_metadata_sessions.remove(&session_id);
                if self.active_sessions.contains_key(&session_id) {
                    return None;
                }

                let state =
                    if let Some(detached) = self.recent_detached_sessions.remove(&session_id) {
                        self.detached_order
                            .retain(|existing| existing != &session_id);
                        LiveSessionState::from_response(
                            detached.response,
                            detached.metadata,
                            detached.ui_state,
                            detached.ui_dialog_state,
                            detached.terminal_only_ui_state,
                        )
                    } else {
                        LiveSessionState::new(session_id.clone())
                    };

                self.active_sessions.insert(session_id, state);
                None
            }
            LiveSessionEvent::SessionSnapshot {
                session_id,
                messages,
            } => {
                self.maybe_warn_legacy_payload(&session_id, &messages);
                let state = self
                    .active_sessions
                    .entry(session_id.clone())
                    .or_insert_with(|| LiveSessionState::new(session_id.clone()));
                state.messages = messages.into_iter().map(sanitize_message).collect();
                state.in_progress_assistant = None;
                state.last_update_at = state.latest_message_timestamp();
                Some(state.as_response(true, true))
            }
            LiveSessionEvent::SessionAppend {
                session_id,
                messages,
            } => {
                self.maybe_warn_legacy_payload(&session_id, &messages);
                let state = self
                    .active_sessions
                    .entry(session_id.clone())
                    .or_insert_with(|| LiveSessionState::new(session_id.clone()));
                let messages = messages
                    .into_iter()
                    .map(sanitize_message)
                    .collect::<Vec<_>>();

                if messages
                    .iter()
                    .any(|message| message.role == Role::Assistant)
                {
                    state.in_progress_assistant = None;
                }

                state.messages.extend(messages);
                state.last_update_at = state.latest_message_timestamp();
                Some(state.as_response(true, true))
            }
            LiveSessionEvent::AssistantPartial {
                session_id,
                mut message,
            } => {
                self.maybe_warn_legacy_payload(&session_id, std::slice::from_ref(&message));
                let state = self
                    .active_sessions
                    .entry(session_id.clone())
                    .or_insert_with(|| LiveSessionState::new(session_id.clone()));
                message.role = Role::Assistant;
                let message = sanitize_message(message);
                state.in_progress_assistant = Some(message.clone());
                state.last_update_at = message.created_at;
                Some(state.as_response(true, true))
            }
            LiveSessionEvent::UiState { session_id, state } => {
                let entry = self
                    .active_sessions
                    .entry(session_id.clone())
                    .or_insert_with(|| LiveSessionState::new(session_id.clone()));
                entry.ui_state = (!state.is_empty()).then_some(state);
                None
            }
            LiveSessionEvent::UiDialogState { session_id, state } => {
                let entry = self
                    .active_sessions
                    .entry(session_id.clone())
                    .or_insert_with(|| LiveSessionState::new(session_id.clone()));
                entry.ui_dialog_state = state;
                None
            }
            LiveSessionEvent::TerminalOnlyUiState { session_id, state } => {
                let entry = self
                    .active_sessions
                    .entry(session_id.clone())
                    .or_insert_with(|| LiveSessionState::new(session_id.clone()));
                entry.terminal_only_ui_state = state;
                None
            }
            LiveSessionEvent::SessionDetached { session_id } => {
                let mut state = self.active_sessions.remove(&session_id)?;
                if let Some(in_progress) = state.in_progress_assistant.take() {
                    state.messages.push(in_progress);
                }

                state.last_update_at = state.latest_message_timestamp();
                let metadata = state.metadata.clone();
                let ui_state = state.ui_state.clone();
                let ui_dialog_state = state.ui_dialog_state.clone();
                let terminal_only_ui_state = state.terminal_only_ui_state.clone();
                let response = state.as_response(false, false);
                self.insert_detached(
                    response.clone(),
                    metadata,
                    ui_state,
                    ui_dialog_state,
                    terminal_only_ui_state,
                );
                Some(response)
            }
        }
    }

    fn maybe_warn_legacy_payload(&mut self, session_id: &str, messages: &[Message]) {
        if self.warned_legacy_sessions.contains(session_id) {
            return;
        }

        let has_body_only_messages = messages
            .iter()
            .any(|message| !message.body.is_empty() && message.blocks.is_empty());
        if !has_body_only_messages {
            return;
        }

        self.warned_legacy_sessions.insert(session_id.to_string());
        eprintln!(
            "live extension warning for session {}: received body-only live payloads without structured blocks; the running pi session may be using an outdated pimux-live extension. The agent keeps the on-disk extension current on startup, but already-running pi sessions may need restart to load the update.",
            session_id
        );
    }

    fn snapshot_for_session(&self, session_id: &str) -> Option<SessionMessagesResponse> {
        self.active_sessions
            .get(session_id)
            .map(|state| state.as_response(true, true))
            .or_else(|| {
                self.recent_detached_sessions
                    .get(session_id)
                    .map(|state| state.response.clone())
            })
    }

    fn all_snapshots(&self) -> HashMap<String, SessionMessagesResponse> {
        let mut snapshots = self
            .active_sessions
            .iter()
            .map(|(session_id, state)| (session_id.clone(), state.as_response(true, true)))
            .collect::<HashMap<_, _>>();

        for (session_id, state) in &self.recent_detached_sessions {
            snapshots
                .entry(session_id.clone())
                .or_insert_with(|| state.response.clone());
        }

        snapshots
    }

    fn all_ui_states(&self) -> HashMap<String, SessionUiState> {
        let mut ui_states = self
            .active_sessions
            .iter()
            .filter_map(|(session_id, state)| {
                state
                    .ui_state
                    .clone()
                    .map(|ui_state| (session_id.clone(), ui_state))
            })
            .collect::<HashMap<_, _>>();

        for (session_id, state) in &self.recent_detached_sessions {
            if let Some(ui_state) = &state.ui_state {
                ui_states
                    .entry(session_id.clone())
                    .or_insert_with(|| ui_state.clone());
            }
        }

        ui_states
    }

    fn all_ui_dialog_states(&self) -> HashMap<String, SessionUiDialogState> {
        let mut ui_dialog_states = self
            .active_sessions
            .iter()
            .filter_map(|(session_id, state)| {
                state
                    .ui_dialog_state
                    .clone()
                    .map(|ui_dialog_state| (session_id.clone(), ui_dialog_state))
            })
            .collect::<HashMap<_, _>>();

        for (session_id, state) in &self.recent_detached_sessions {
            if let Some(ui_dialog_state) = &state.ui_dialog_state {
                ui_dialog_states
                    .entry(session_id.clone())
                    .or_insert_with(|| ui_dialog_state.clone());
            }
        }

        ui_dialog_states
    }

    fn all_terminal_only_ui_states(&self) -> HashMap<String, SessionTerminalOnlyUiState> {
        let mut terminal_only_ui_states = self
            .active_sessions
            .iter()
            .filter_map(|(session_id, state)| {
                state
                    .terminal_only_ui_state
                    .clone()
                    .map(|terminal_only_ui_state| (session_id.clone(), terminal_only_ui_state))
            })
            .collect::<HashMap<_, _>>();

        for (session_id, state) in &self.recent_detached_sessions {
            if let Some(terminal_only_ui_state) = &state.terminal_only_ui_state {
                terminal_only_ui_states
                    .entry(session_id.clone())
                    .or_insert_with(|| terminal_only_ui_state.clone());
            }
        }

        terminal_only_ui_states
    }

    fn listed_session_for(&self, session_id: &str) -> Option<ActiveSession> {
        self.active_sessions
            .get(session_id)
            .and_then(LiveSessionState::as_active_session)
            .or_else(|| {
                self.recent_detached_sessions
                    .get(session_id)
                    .and_then(DetachedSessionState::as_active_session)
            })
    }

    fn all_listed_sessions(&self) -> Vec<ActiveSession> {
        let mut sessions = self
            .active_sessions
            .values()
            .filter_map(LiveSessionState::as_active_session)
            .collect::<Vec<_>>();

        for state in self.recent_detached_sessions.values() {
            if let Some(session) = state.as_active_session()
                && !sessions.iter().any(|existing| existing.id == session.id)
            {
                sessions.push(session);
            }
        }

        sessions
    }

    fn has_command_connection(&self, session_id: &str) -> bool {
        self.command_session_connections.contains_key(session_id)
    }

    fn upsert_session_metadata(&mut self, session_id: &str, metadata: LiveSessionMetadata) {
        if let Some(state) = self.active_sessions.get_mut(session_id) {
            state.last_update_at = metadata.created_at;
            state.metadata = Some(metadata);
            return;
        }

        if let Some(state) = self.recent_detached_sessions.get_mut(session_id) {
            state.metadata = Some(metadata);
            return;
        }

        let mut state = LiveSessionState::new(session_id.to_string());
        state.last_update_at = metadata.created_at;
        state.metadata = Some(metadata);
        self.active_sessions.insert(session_id.to_string(), state);
    }

    fn register_command_connection(
        &mut self,
        connection_id: u64,
        sender: UnboundedSender<LiveAgentCommand>,
        protocol_version: u32,
    ) {
        self.command_connections.insert(
            connection_id,
            LiveCommandConnection {
                sender,
                current_session_id: None,
                protocol_version,
            },
        );
    }

    fn bind_command_connection_to_session(
        &mut self,
        connection_id: u64,
        session_id: String,
    ) -> Option<SessionMessagesResponse> {
        let Some(connection) = self.command_connections.get_mut(&connection_id) else {
            return None;
        };

        let previous_session_id = connection.current_session_id.replace(session_id.clone());
        self.command_session_connections
            .insert(session_id.clone(), connection_id);

        if let Some(previous_session_id) = previous_session_id
            && previous_session_id != session_id
        {
            if self
                .command_session_connections
                .get(&previous_session_id)
                .copied()
                == Some(connection_id)
            {
                self.command_session_connections
                    .remove(&previous_session_id);
            }
            return self.apply_event(LiveSessionEvent::SessionDetached {
                session_id: previous_session_id,
            });
        }

        None
    }

    fn unbind_command_connection_from_session(&mut self, connection_id: u64, session_id: &str) {
        let Some(connection) = self.command_connections.get_mut(&connection_id) else {
            return;
        };

        if connection.current_session_id.as_deref() == Some(session_id) {
            connection.current_session_id = None;
        }

        if self.command_session_connections.get(session_id).copied() == Some(connection_id) {
            self.command_session_connections.remove(session_id);
        }
    }

    fn prepare_send_user_message(
        &mut self,
        session_id: &str,
    ) -> Result<
        (
            UnboundedSender<LiveAgentCommand>,
            String,
            oneshot::Receiver<Result<(), SendUserMessageError>>,
        ),
        SendUserMessageError,
    > {
        let Some(connection_id) = self.command_session_connections.get(session_id).copied() else {
            return Err(SendUserMessageError::Unavailable);
        };
        let Some(connection) = self.command_connections.get(&connection_id) else {
            self.command_session_connections.remove(session_id);
            return Err(SendUserMessageError::Unavailable);
        };

        let request_id = format!("live-send-{}", self.next_send_request_id);
        self.next_send_request_id += 1;

        let (sender, receiver) = oneshot::channel();
        self.inflight_send_user_messages.insert(
            request_id.clone(),
            InflightSendUserMessage {
                connection_id,
                sender,
            },
        );

        Ok((connection.sender.clone(), request_id, receiver))
    }

    fn fulfill_send_user_message(
        &mut self,
        connection_id: u64,
        request_id: &str,
        error: Option<String>,
    ) {
        let Some(inflight) = self.inflight_send_user_messages.remove(request_id) else {
            return;
        };

        if inflight.connection_id != connection_id {
            return;
        }

        let result = match error {
            Some(error) => Err(SendUserMessageError::Rejected(error)),
            None => Ok(()),
        };
        let _ = inflight.sender.send(result);
    }

    fn cancel_send_user_message(&mut self, request_id: &str) {
        self.inflight_send_user_messages.remove(request_id);
    }

    fn prepare_get_commands(
        &mut self,
        session_id: &str,
    ) -> Result<
        (
            UnboundedSender<LiveAgentCommand>,
            String,
            oneshot::Receiver<Result<Vec<SessionCommand>, GetCommandsError>>,
        ),
        GetCommandsError,
    > {
        let Some(connection_id) = self.command_session_connections.get(session_id).copied() else {
            return Err(GetCommandsError::Unavailable);
        };
        let Some(connection) = self.command_connections.get(&connection_id) else {
            self.command_session_connections.remove(session_id);
            return Err(GetCommandsError::Unavailable);
        };

        let request_id = format!("live-cmds-{}", self.next_send_request_id);
        self.next_send_request_id += 1;

        let (sender, receiver) = oneshot::channel();
        self.inflight_get_commands.insert(
            request_id.clone(),
            InflightGetCommands {
                connection_id,
                sender,
            },
        );

        Ok((connection.sender.clone(), request_id, receiver))
    }

    fn fulfill_get_commands(
        &mut self,
        connection_id: u64,
        request_id: &str,
        commands: Vec<SessionCommand>,
        error: Option<String>,
    ) {
        let Some(inflight) = self.inflight_get_commands.remove(request_id) else {
            return;
        };

        if inflight.connection_id != connection_id {
            return;
        }

        let result = match error {
            Some(error) => Err(GetCommandsError::Failed(error)),
            None => Ok(commands),
        };
        let _ = inflight.sender.send(result);
    }

    fn cancel_get_commands(&mut self, request_id: &str) {
        self.inflight_get_commands.remove(request_id);
    }

    fn prepare_get_command_argument_completions(
        &mut self,
        session_id: &str,
    ) -> Result<
        (
            UnboundedSender<LiveAgentCommand>,
            String,
            oneshot::Receiver<
                Result<Vec<SessionCommandCompletion>, GetCommandArgumentCompletionsError>,
            >,
        ),
        GetCommandArgumentCompletionsError,
    > {
        let Some(connection_id) = self.command_session_connections.get(session_id).copied() else {
            return Err(GetCommandArgumentCompletionsError::Unavailable);
        };
        let Some(connection) = self.command_connections.get(&connection_id) else {
            self.command_session_connections.remove(session_id);
            return Err(GetCommandArgumentCompletionsError::Unavailable);
        };
        if connection.protocol_version < COMMAND_ARGUMENT_COMPLETIONS_PROTOCOL_VERSION {
            return Err(GetCommandArgumentCompletionsError::Unavailable);
        }

        let request_id = format!("live-cmd-args-{}", self.next_send_request_id);
        self.next_send_request_id += 1;

        let (sender, receiver) = oneshot::channel();
        self.inflight_get_command_argument_completions.insert(
            request_id.clone(),
            InflightGetCommandArgumentCompletions {
                connection_id,
                sender,
            },
        );

        Ok((connection.sender.clone(), request_id, receiver))
    }

    fn fulfill_get_command_argument_completions(
        &mut self,
        connection_id: u64,
        request_id: &str,
        completions: Vec<SessionCommandCompletion>,
        error: Option<String>,
    ) {
        let Some(inflight) = self
            .inflight_get_command_argument_completions
            .remove(request_id)
        else {
            return;
        };

        if inflight.connection_id != connection_id {
            return;
        }

        let result = match error {
            Some(error) => Err(GetCommandArgumentCompletionsError::Failed(error)),
            None => Ok(completions),
        };
        let _ = inflight.sender.send(result);
    }

    fn cancel_get_command_argument_completions(&mut self, request_id: &str) {
        self.inflight_get_command_argument_completions
            .remove(request_id);
    }

    fn prepare_ui_dialog_action(
        &mut self,
        session_id: &str,
        dialog_id: &str,
    ) -> Result<
        (
            UnboundedSender<LiveAgentCommand>,
            String,
            oneshot::Receiver<Result<(), UiDialogActionError>>,
        ),
        UiDialogActionError,
    > {
        let Some(connection_id) = self.command_session_connections.get(session_id).copied() else {
            return Err(UiDialogActionError::Unavailable);
        };
        let Some(connection) = self.command_connections.get(&connection_id) else {
            self.command_session_connections.remove(session_id);
            return Err(UiDialogActionError::Unavailable);
        };
        let Some(state) = self.active_sessions.get(session_id) else {
            return Err(UiDialogActionError::Unavailable);
        };
        if state
            .ui_dialog_state
            .as_ref()
            .map(|state| state.id.as_str())
            != Some(dialog_id)
        {
            return Err(UiDialogActionError::Rejected(format!(
                "dialog {dialog_id} is not active for session {session_id}"
            )));
        }

        let request_id = format!("live-ui-dialog-{}", self.next_send_request_id);
        self.next_send_request_id += 1;

        let (sender, receiver) = oneshot::channel();
        self.inflight_ui_dialog_actions.insert(
            request_id.clone(),
            InflightUiDialogAction {
                connection_id,
                sender,
            },
        );

        Ok((connection.sender.clone(), request_id, receiver))
    }

    fn fulfill_ui_dialog_action(
        &mut self,
        connection_id: u64,
        request_id: &str,
        error: Option<String>,
    ) {
        let Some(inflight) = self.inflight_ui_dialog_actions.remove(request_id) else {
            return;
        };

        if inflight.connection_id != connection_id {
            return;
        }

        let result = match error {
            Some(error) => Err(UiDialogActionError::Rejected(error)),
            None => Ok(()),
        };
        let _ = inflight.sender.send(result);
    }

    fn cancel_ui_dialog_action(&mut self, request_id: &str) {
        self.inflight_ui_dialog_actions.remove(request_id);
    }

    fn prepare_builtin_command(
        &mut self,
        session_id: &str,
    ) -> Result<
        (
            UnboundedSender<LiveAgentCommand>,
            String,
            oneshot::Receiver<Result<(), BuiltinCommandError>>,
        ),
        BuiltinCommandError,
    > {
        let Some(connection_id) = self.command_session_connections.get(session_id).copied() else {
            return Err(BuiltinCommandError::Unavailable);
        };
        let Some(connection) = self.command_connections.get(&connection_id) else {
            self.command_session_connections.remove(session_id);
            return Err(BuiltinCommandError::Unavailable);
        };

        let request_id = format!("live-builtin-{}", self.next_send_request_id);
        self.next_send_request_id += 1;

        let (sender, receiver) = oneshot::channel();
        self.inflight_builtin_commands.insert(
            request_id.clone(),
            InflightBuiltinCommand {
                connection_id,
                sender,
            },
        );

        Ok((connection.sender.clone(), request_id, receiver))
    }

    fn fulfill_builtin_command(
        &mut self,
        connection_id: u64,
        request_id: &str,
        error: Option<String>,
    ) {
        let Some(inflight) = self.inflight_builtin_commands.remove(request_id) else {
            return;
        };

        if inflight.connection_id != connection_id {
            return;
        }

        let result = match error {
            Some(error) => Err(BuiltinCommandError::Rejected(error)),
            None => Ok(()),
        };
        let _ = inflight.sender.send(result);
    }

    fn cancel_builtin_command(&mut self, request_id: &str) {
        self.inflight_builtin_commands.remove(request_id);
    }

    fn disconnect_command_connection(
        &mut self,
        connection_id: u64,
    ) -> Option<SessionMessagesResponse> {
        let connection = self.command_connections.remove(&connection_id)?;

        self.fail_inflight_send_user_messages_for_connection(
            connection_id,
            SendUserMessageError::Disconnected,
        );
        self.fail_inflight_get_commands_for_connection(
            connection_id,
            GetCommandsError::Disconnected,
        );
        self.fail_inflight_get_command_argument_completions_for_connection(
            connection_id,
            GetCommandArgumentCompletionsError::Disconnected,
        );
        self.fail_inflight_ui_dialog_actions_for_connection(
            connection_id,
            UiDialogActionError::Disconnected,
        );
        self.fail_inflight_builtin_commands_for_connection(
            connection_id,
            BuiltinCommandError::Disconnected,
        );

        let session_id = connection.current_session_id?;
        if self.command_session_connections.get(&session_id).copied() == Some(connection_id) {
            self.command_session_connections.remove(&session_id);
        }

        self.apply_event(LiveSessionEvent::SessionDetached { session_id })
    }

    fn fail_inflight_send_user_messages_for_connection(
        &mut self,
        connection_id: u64,
        error: SendUserMessageError,
    ) {
        let request_ids = self
            .inflight_send_user_messages
            .iter()
            .filter_map(|(request_id, inflight)| {
                (inflight.connection_id == connection_id).then_some(request_id.clone())
            })
            .collect::<Vec<_>>();

        for request_id in request_ids {
            if let Some(inflight) = self.inflight_send_user_messages.remove(&request_id) {
                let _ = inflight.sender.send(Err(error.clone()));
            }
        }
    }

    fn fail_inflight_get_commands_for_connection(
        &mut self,
        connection_id: u64,
        error: GetCommandsError,
    ) {
        let request_ids = self
            .inflight_get_commands
            .iter()
            .filter_map(|(request_id, inflight)| {
                (inflight.connection_id == connection_id).then_some(request_id.clone())
            })
            .collect::<Vec<_>>();

        for request_id in request_ids {
            if let Some(inflight) = self.inflight_get_commands.remove(&request_id) {
                let _ = inflight.sender.send(Err(error.clone()));
            }
        }
    }

    fn fail_inflight_get_command_argument_completions_for_connection(
        &mut self,
        connection_id: u64,
        error: GetCommandArgumentCompletionsError,
    ) {
        let request_ids = self
            .inflight_get_command_argument_completions
            .iter()
            .filter_map(|(request_id, inflight)| {
                (inflight.connection_id == connection_id).then_some(request_id.clone())
            })
            .collect::<Vec<_>>();

        for request_id in request_ids {
            if let Some(inflight) = self
                .inflight_get_command_argument_completions
                .remove(&request_id)
            {
                let _ = inflight.sender.send(Err(error.clone()));
            }
        }
    }

    fn fail_inflight_ui_dialog_actions_for_connection(
        &mut self,
        connection_id: u64,
        error: UiDialogActionError,
    ) {
        let request_ids = self
            .inflight_ui_dialog_actions
            .iter()
            .filter_map(|(request_id, inflight)| {
                (inflight.connection_id == connection_id).then_some(request_id.clone())
            })
            .collect::<Vec<_>>();

        for request_id in request_ids {
            if let Some(inflight) = self.inflight_ui_dialog_actions.remove(&request_id) {
                let _ = inflight.sender.send(Err(error.clone()));
            }
        }
    }

    fn fail_inflight_builtin_commands_for_connection(
        &mut self,
        connection_id: u64,
        error: BuiltinCommandError,
    ) {
        let request_ids = self
            .inflight_builtin_commands
            .iter()
            .filter_map(|(request_id, inflight)| {
                (inflight.connection_id == connection_id).then_some(request_id.clone())
            })
            .collect::<Vec<_>>();

        for request_id in request_ids {
            if let Some(inflight) = self.inflight_builtin_commands.remove(&request_id) {
                let _ = inflight.sender.send(Err(error.clone()));
            }
        }
    }

    fn insert_detached(
        &mut self,
        response: SessionMessagesResponse,
        metadata: Option<LiveSessionMetadata>,
        ui_state: Option<SessionUiState>,
        ui_dialog_state: Option<SessionUiDialogState>,
        terminal_only_ui_state: Option<SessionTerminalOnlyUiState>,
    ) {
        let session_id = response.session_id.clone();
        self.detached_order
            .retain(|existing| existing != &session_id);
        self.detached_order.push_back(session_id.clone());
        self.recent_detached_sessions.insert(
            session_id,
            DetachedSessionState {
                response,
                expires_at: Instant::now() + self.detached_ttl,
                metadata,
                ui_state,
                ui_dialog_state,
                terminal_only_ui_state,
            },
        );
        self.enforce_detached_capacity();
    }

    fn purge_expired(&mut self) {
        let now = Instant::now();
        let expired = self
            .recent_detached_sessions
            .iter()
            .filter_map(|(session_id, state)| {
                (state.expires_at <= now).then_some(session_id.clone())
            })
            .collect::<Vec<_>>();

        for session_id in expired {
            self.recent_detached_sessions.remove(&session_id);
            self.detached_order
                .retain(|existing| existing != &session_id);
        }
    }

    fn enforce_detached_capacity(&mut self) {
        while self.recent_detached_sessions.len() > self.detached_capacity {
            let Some(evicted) = self.detached_order.pop_front() else {
                break;
            };
            self.recent_detached_sessions.remove(&evicted);
        }
    }
}

struct LiveSessionState {
    session_id: String,
    messages: Vec<Message>,
    in_progress_assistant: Option<Message>,
    last_update_at: chrono::DateTime<chrono::Utc>,
    metadata: Option<LiveSessionMetadata>,
    ui_state: Option<SessionUiState>,
    ui_dialog_state: Option<SessionUiDialogState>,
    terminal_only_ui_state: Option<SessionTerminalOnlyUiState>,
}

impl LiveSessionState {
    fn new(session_id: String) -> Self {
        Self {
            session_id,
            messages: Vec::new(),
            in_progress_assistant: None,
            last_update_at: Utc::now(),
            metadata: None,
            ui_state: None,
            ui_dialog_state: None,
            terminal_only_ui_state: None,
        }
    }

    fn from_response(
        response: SessionMessagesResponse,
        metadata: Option<LiveSessionMetadata>,
        ui_state: Option<SessionUiState>,
        ui_dialog_state: Option<SessionUiDialogState>,
        terminal_only_ui_state: Option<SessionTerminalOnlyUiState>,
    ) -> Self {
        let last_update_at = response
            .messages
            .last()
            .map(|message| message.created_at)
            .unwrap_or(response.freshness.as_of);

        Self {
            session_id: response.session_id,
            messages: response.messages,
            in_progress_assistant: None,
            last_update_at,
            metadata,
            ui_state,
            ui_dialog_state,
            terminal_only_ui_state,
        }
    }

    fn latest_message_timestamp(&self) -> chrono::DateTime<chrono::Utc> {
        self.in_progress_assistant
            .as_ref()
            .map(|message| message.created_at)
            .or_else(|| self.messages.last().map(|message| message.created_at))
            .unwrap_or_else(|| {
                self.metadata
                    .as_ref()
                    .map(|metadata| metadata.created_at)
                    .unwrap_or(self.last_update_at)
            })
    }

    fn last_user_message_at(&self) -> chrono::DateTime<chrono::Utc> {
        self.messages
            .iter()
            .rev()
            .find(|message| message.role == Role::User)
            .map(|message| message.created_at)
            .unwrap_or_else(|| {
                self.metadata
                    .as_ref()
                    .map(|metadata| metadata.created_at)
                    .unwrap_or(self.last_update_at)
            })
    }

    fn last_assistant_message_at(&self) -> chrono::DateTime<chrono::Utc> {
        self.in_progress_assistant
            .as_ref()
            .filter(|message| message.role == Role::Assistant)
            .map(|message| message.created_at)
            .or_else(|| {
                self.messages
                    .iter()
                    .rev()
                    .find(|message| message.role == Role::Assistant)
                    .map(|message| message.created_at)
            })
            .unwrap_or_else(|| {
                self.metadata
                    .as_ref()
                    .map(|metadata| metadata.created_at)
                    .unwrap_or(self.last_update_at)
            })
    }

    fn as_response(&self, active: bool, attached: bool) -> SessionMessagesResponse {
        let mut messages = self.messages.clone();
        if let Some(in_progress) = &self.in_progress_assistant {
            messages.push(in_progress.clone());
        }

        SessionMessagesResponse {
            session_id: self.session_id.clone(),
            messages,
            freshness: TranscriptFreshness {
                state: TranscriptFreshnessState::Live,
                source: TranscriptSource::Extension,
                as_of: self.latest_message_timestamp(),
            },
            activity: SessionActivity { active, attached },
            warnings: Vec::new(),
        }
    }

    fn as_active_session(&self) -> Option<ActiveSession> {
        let metadata = self.metadata.as_ref()?;
        Some(ActiveSession {
            id: self.session_id.clone(),
            summary: metadata.summary.clone(),
            created_at: metadata.created_at,
            updated_at: self.latest_message_timestamp(),
            last_user_message_at: self.last_user_message_at(),
            last_assistant_message_at: self.last_assistant_message_at(),
            cwd: metadata.cwd.clone(),
            model: metadata.model.clone(),
            context_usage: metadata.context_usage.clone(),
            supports_images: None,
        })
    }
}

struct DetachedSessionState {
    response: SessionMessagesResponse,
    expires_at: Instant,
    metadata: Option<LiveSessionMetadata>,
    ui_state: Option<SessionUiState>,
    ui_dialog_state: Option<SessionUiDialogState>,
    terminal_only_ui_state: Option<SessionTerminalOnlyUiState>,
}

impl DetachedSessionState {
    fn as_active_session(&self) -> Option<ActiveSession> {
        let metadata = self.metadata.as_ref()?;
        let last_message_at = self
            .response
            .messages
            .last()
            .map(|message| message.created_at)
            .unwrap_or(metadata.created_at);
        let last_user_message_at = self
            .response
            .messages
            .iter()
            .rev()
            .find(|message| message.role == Role::User)
            .map(|message| message.created_at)
            .unwrap_or(metadata.created_at);
        let last_assistant_message_at = self
            .response
            .messages
            .iter()
            .rev()
            .find(|message| message.role == Role::Assistant)
            .map(|message| message.created_at)
            .unwrap_or(metadata.created_at);

        Some(ActiveSession {
            id: self.response.session_id.clone(),
            summary: metadata.summary.clone(),
            created_at: metadata.created_at,
            updated_at: last_message_at,
            last_user_message_at,
            last_assistant_message_at,
            cwd: metadata.cwd.clone(),
            model: metadata.model.clone(),
            context_usage: metadata.context_usage.clone(),
            supports_images: None,
        })
    }
}

struct LiveCommandConnection {
    sender: UnboundedSender<LiveAgentCommand>,
    current_session_id: Option<String>,
    protocol_version: u32,
}

struct InflightSendUserMessage {
    connection_id: u64,
    sender: oneshot::Sender<Result<(), SendUserMessageError>>,
}

struct InflightGetCommands {
    connection_id: u64,
    sender: oneshot::Sender<Result<Vec<SessionCommand>, GetCommandsError>>,
}

struct InflightGetCommandArgumentCompletions {
    connection_id: u64,
    sender: oneshot::Sender<Result<Vec<SessionCommandCompletion>, GetCommandArgumentCompletionsError>>,
}

struct InflightUiDialogAction {
    connection_id: u64,
    sender: oneshot::Sender<Result<(), UiDialogActionError>>,
}

struct InflightBuiltinCommand {
    connection_id: u64,
    sender: oneshot::Sender<Result<(), BuiltinCommandError>>,
}

fn sanitize_message(mut message: Message) -> Message {
    message.body = truncate_text(&message.body, MAX_LIVE_MESSAGE_BODY_CHARS);
    for block in &mut message.blocks {
        if let Some(text) = block.text.as_deref() {
            block.text = Some(truncate_text(text, MAX_LIVE_MESSAGE_BODY_CHARS));
        }
        if let Some(name) = block.tool_call_name.as_deref() {
            block.tool_call_name = Some(truncate_text(name, MAX_LIVE_MESSAGE_BODY_CHARS));
        }
    }

    message
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::message::MessageContentBlock;

    fn sample_message(role: Role, text: &str) -> Message {
        Message::from_blocks(
            Utc::now(),
            role,
            vec![MessageContentBlock::text(text).unwrap()],
        )
        .unwrap()
    }

    #[tokio::test]
    async fn send_user_message_dispatches_to_attached_command_connection() {
        let handle = LiveSessionStoreHandle::new(3, Duration::from_secs(60));
        let (command_tx, mut command_rx) = mpsc::unbounded_channel();

        handle.register_command_connection(1, command_tx).await;
        handle
            .bind_command_connection_to_session(1, "session-1".to_string())
            .await;

        let sender_handle = handle.clone();
        let send_task = tokio::spawn(async move {
            sender_handle
                .send_user_message("session-1", "hello live", Vec::new())
                .await
        });

        let command = command_rx.recv().await.unwrap();
        let LiveAgentCommand::SendUserMessage {
            request_id,
            session_id,
            body,
            images,
        } = command
        else {
            panic!("expected SendUserMessage command");
        };
        assert_eq!(request_id, "live-send-1");
        assert_eq!(session_id, "session-1");
        assert_eq!(body, "hello live");
        assert!(images.is_empty());

        handle.fulfill_send_user_message(1, &request_id, None).await;

        assert_eq!(send_task.await.unwrap(), Ok(()));
    }

    #[tokio::test]
    async fn send_user_message_requires_command_capable_connection() {
        let handle = LiveSessionStoreHandle::new(3, Duration::from_secs(60));
        assert_eq!(
            handle
                .send_user_message("session-1", "hello", Vec::new())
                .await,
            Err(SendUserMessageError::Unavailable)
        );
    }

    #[tokio::test]
    async fn ui_dialog_action_dispatches_to_attached_command_connection() {
        let handle = LiveSessionStoreHandle::new(3, Duration::from_secs(60));
        let (command_tx, mut command_rx) = mpsc::unbounded_channel();

        handle.register_command_connection(1, command_tx).await;
        handle
            .apply_event(LiveSessionEvent::SessionAttached {
                session_id: "session-1".to_string(),
            })
            .await;
        handle
            .bind_command_connection_to_session(1, "session-1".to_string())
            .await;
        handle
            .apply_event(LiveSessionEvent::UiDialogState {
                session_id: "session-1".to_string(),
                state: Some(SessionUiDialogState {
                    id: "dialog-1".to_string(),
                    kind: crate::transcript::SessionUiDialogKind::Confirm,
                    title: "Confirm".to_string(),
                    message: "Proceed?".to_string(),
                    options: vec!["Yes".to_string(), "No".to_string()],
                    selected_index: 0,
                    placeholder: None,
                    value: None,
                }),
            })
            .await;

        let sender_handle = handle.clone();
        let action_task = tokio::spawn(async move {
            sender_handle
                .send_ui_dialog_action("session-1", "dialog-1", SessionUiDialogAction::Submit)
                .await
        });

        let command = command_rx.recv().await.unwrap();
        let LiveAgentCommand::UiDialogAction {
            request_id,
            session_id,
            dialog_id,
            action,
        } = command
        else {
            panic!("expected UiDialogAction command");
        };
        assert_eq!(request_id, "live-ui-dialog-1");
        assert_eq!(session_id, "session-1");
        assert_eq!(dialog_id, "dialog-1");
        assert_eq!(action, SessionUiDialogAction::Submit);

        handle.fulfill_ui_dialog_action(1, &request_id, None).await;

        assert_eq!(action_task.await.unwrap(), Ok(()));
    }

    #[tokio::test]
    async fn builtin_command_dispatches_to_attached_command_connection() {
        let handle = LiveSessionStoreHandle::new(3, Duration::from_secs(60));
        let (command_tx, mut command_rx) = mpsc::unbounded_channel();

        handle.register_command_connection(1, command_tx).await;
        handle
            .bind_command_connection_to_session(1, "session-1".to_string())
            .await;

        let sender_handle = handle.clone();
        let command_task = tokio::spawn(async move {
            sender_handle
                .send_builtin_command("session-1", SessionBuiltinCommandRequest::Reload)
                .await
        });

        let command = command_rx.recv().await.unwrap();
        let LiveAgentCommand::BuiltinCommand {
            request_id,
            session_id,
            action,
        } = command
        else {
            panic!("expected BuiltinCommand command");
        };
        assert_eq!(request_id, "live-builtin-1");
        assert_eq!(session_id, "session-1");
        assert_eq!(action, SessionBuiltinCommandRequest::Reload);

        handle.fulfill_builtin_command(1, &request_id, None).await;

        assert_eq!(command_task.await.unwrap(), Ok(()));
    }

    #[tokio::test]
    async fn command_argument_completions_dispatch_to_attached_command_connection() {
        let handle = LiveSessionStoreHandle::new(3, Duration::from_secs(60));
        let (command_tx, mut command_rx) = mpsc::unbounded_channel();

        handle.register_command_connection(1, command_tx).await;
        handle
            .bind_command_connection_to_session(1, "session-1".to_string())
            .await;

        let sender_handle = handle.clone();
        let completion_task = tokio::spawn(async move {
            sender_handle
                .get_command_argument_completions("session-1", "pirot", "re")
                .await
        });

        let command = command_rx.recv().await.unwrap();
        let LiveAgentCommand::GetCommandArgumentCompletions {
            request_id,
            session_id,
            command_name,
            argument_prefix,
        } = command
        else {
            panic!("expected GetCommandArgumentCompletions command");
        };
        assert_eq!(request_id, "live-cmd-args-1");
        assert_eq!(session_id, "session-1");
        assert_eq!(command_name, "pirot");
        assert_eq!(argument_prefix, "re");

        handle
            .fulfill_get_command_argument_completions(
                1,
                &request_id,
                vec![SessionCommandCompletion {
                    value: "restart-server".to_string(),
                    label: "restart-server".to_string(),
                    description: Some("Restart the pirot server".to_string()),
                }],
                None,
            )
            .await;

        assert_eq!(
            completion_task.await.unwrap(),
            Ok(vec![SessionCommandCompletion {
                value: "restart-server".to_string(),
                label: "restart-server".to_string(),
                description: Some("Restart the pirot server".to_string()),
            }])
        );
    }

    #[tokio::test]
    async fn disconnecting_command_connection_detaches_live_session() {
        let handle = LiveSessionStoreHandle::new(3, Duration::from_secs(60));
        let (command_tx, _command_rx) = mpsc::unbounded_channel();

        handle.register_command_connection(1, command_tx).await;
        handle
            .apply_event(LiveSessionEvent::SessionAttached {
                session_id: "session-1".to_string(),
            })
            .await;
        handle
            .apply_event(LiveSessionEvent::SessionSnapshot {
                session_id: "session-1".to_string(),
                messages: vec![sample_message(Role::User, "hello")],
            })
            .await;
        handle
            .bind_command_connection_to_session(1, "session-1".to_string())
            .await;

        let detached = handle.disconnect_command_connection(1).await.unwrap();
        assert_eq!(detached.session_id, "session-1");
        assert!(!detached.activity.active);
        assert!(!detached.activity.attached);
    }

    #[tokio::test]
    async fn listed_session_uses_live_metadata_for_new_session() {
        let handle = LiveSessionStoreHandle::new(3, Duration::from_secs(60));
        let created_at = Utc::now();
        let session_id = "session-1".to_string();

        handle
            .apply_event(LiveSessionEvent::SessionAttached {
                session_id: session_id.clone(),
            })
            .await;

        {
            let mut store = handle.inner.lock().await;
            store.upsert_session_metadata(
                &session_id,
                LiveSessionMetadata {
                    created_at,
                    cwd: "/tmp/project".to_string(),
                    summary: "Brand new session".to_string(),
                    model: "anthropic/claude-sonnet-4-5".to_string(),
                    context_usage: Some(SessionContextUsage {
                        used_tokens: Some(12_345),
                        max_tokens: Some(200_000),
                    }),
                },
            );
        }

        let listed = handle
            .listed_session_for_session(&session_id)
            .await
            .unwrap();
        assert_eq!(listed.summary, "Brand new session");
        assert_eq!(listed.created_at, created_at);
        assert_eq!(listed.updated_at, created_at);
        assert_eq!(listed.cwd, "/tmp/project");
        assert_eq!(
            listed.context_usage,
            Some(SessionContextUsage {
                used_tokens: Some(12_345),
                max_tokens: Some(200_000),
            })
        );
    }

    #[test]
    fn legacy_session_attached_without_metadata_still_deserializes() {
        let message = serde_json::from_str::<LiveSessionIpcMessage>(
            r#"{"type":"sessionAttached","sessionId":"session-1"}"#,
        )
        .unwrap();

        match message {
            LiveSessionIpcMessage::SessionAttached {
                session_id,
                metadata,
            } => {
                assert_eq!(session_id, "session-1");
                assert_eq!(metadata, None);
            }
            other => panic!("unexpected message: {other:?}"),
        }
    }
}
