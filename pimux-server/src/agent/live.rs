use std::{
    collections::{HashMap, VecDeque},
    fs,
    path::{Path, PathBuf},
    sync::Arc,
    time::{Duration, Instant},
};

use chrono::Utc;
use serde::{Deserialize, Serialize};
use tokio::sync::{Mutex, mpsc::UnboundedSender};

use crate::{
    message::{Message, Role},
    transcript::{
        SessionActivity, SessionMessagesResponse, TranscriptFreshness, TranscriptFreshnessState,
        TranscriptSource,
    },
};

type BoxError = Box<dyn std::error::Error + Send + Sync>;

pub const DEFAULT_DETACHED_CAPACITY: usize = 3;
pub const DEFAULT_DETACHED_TTL: Duration = Duration::from_secs(180);
const MAX_LIVE_MESSAGE_BODY_CHARS: usize = 8_000;

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
}

pub fn socket_path(pi_agent_dir: &Path) -> PathBuf {
    pi_agent_dir.join("pimux").join("live.sock")
}

pub async fn start_listener(
    store: LiveSessionStoreHandle,
    socket_path: PathBuf,
    updates: UnboundedSender<SessionMessagesResponse>,
) -> Result<(), BoxError> {
    start_listener_impl(store, socket_path, updates).await
}

#[cfg(unix)]
async fn start_listener_impl(
    store: LiveSessionStoreHandle,
    socket_path: PathBuf,
    updates: UnboundedSender<SessionMessagesResponse>,
) -> Result<(), BoxError> {
    use tokio::{
        io::{AsyncBufReadExt, BufReader},
        net::UnixListener,
    };

    if let Some(parent) = socket_path.parent() {
        fs::create_dir_all(parent)?;
    }

    if socket_path.exists() {
        fs::remove_file(&socket_path)?;
    }

    let listener = UnixListener::bind(&socket_path)?;

    tokio::spawn(async move {
        loop {
            let (stream, _) = match listener.accept().await {
                Ok(connection) => connection,
                Err(error) => {
                    eprintln!("live ipc accept error: {error}");
                    continue;
                }
            };

            let store = store.clone();
            let updates = updates.clone();
            tokio::spawn(async move {
                let reader = BufReader::new(stream);
                let mut lines = reader.lines();

                loop {
                    match lines.next_line().await {
                        Ok(Some(line)) => {
                            let line = line.trim();
                            if line.is_empty() {
                                continue;
                            }

                            let event = match serde_json::from_str::<LiveSessionEvent>(line) {
                                Ok(event) => event,
                                Err(error) => {
                                    eprintln!("invalid live ipc event: {error}");
                                    continue;
                                }
                            };

                            let snapshot = {
                                let mut store = store.inner.lock().await;
                                store.purge_expired();
                                store.apply_event(event)
                            };

                            if let Some(snapshot) = snapshot {
                                let _ = updates.send(snapshot);
                            }
                        }
                        Ok(None) => break,
                        Err(error) => {
                            eprintln!("live ipc read error: {error}");
                            break;
                        }
                    }
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
    _updates: UnboundedSender<SessionMessagesResponse>,
) -> Result<(), BoxError> {
    Err("live session IPC via Unix sockets is only supported on unix hosts".into())
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
    SessionDetached {
        session_id: String,
    },
}

struct LiveSessionStore {
    active_sessions: HashMap<String, LiveSessionState>,
    recent_detached_sessions: HashMap<String, DetachedSessionState>,
    detached_order: VecDeque<String>,
    detached_capacity: usize,
    detached_ttl: Duration,
}

impl LiveSessionStore {
    fn new(detached_capacity: usize, detached_ttl: Duration) -> Self {
        Self {
            active_sessions: HashMap::new(),
            recent_detached_sessions: HashMap::new(),
            detached_order: VecDeque::new(),
            detached_capacity,
            detached_ttl,
        }
    }

    fn apply_event(&mut self, event: LiveSessionEvent) -> Option<SessionMessagesResponse> {
        match event {
            LiveSessionEvent::SessionAttached { session_id } => {
                let state =
                    if let Some(detached) = self.recent_detached_sessions.remove(&session_id) {
                        self.detached_order
                            .retain(|existing| existing != &session_id);
                        LiveSessionState::from_response(detached.response)
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
            LiveSessionEvent::SessionDetached { session_id } => {
                let mut state = self.active_sessions.remove(&session_id)?;
                if let Some(in_progress) = state.in_progress_assistant.take() {
                    state.messages.push(in_progress);
                }

                state.last_update_at = state.latest_message_timestamp();
                let response = state.as_response(false, false);
                self.insert_detached(response.clone());
                Some(response)
            }
        }
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

    fn insert_detached(&mut self, response: SessionMessagesResponse) {
        let session_id = response.session_id.clone();
        self.detached_order
            .retain(|existing| existing != &session_id);
        self.detached_order.push_back(session_id.clone());
        self.recent_detached_sessions.insert(
            session_id,
            DetachedSessionState {
                response,
                expires_at: Instant::now() + self.detached_ttl,
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
}

impl LiveSessionState {
    fn new(session_id: String) -> Self {
        Self {
            session_id,
            messages: Vec::new(),
            in_progress_assistant: None,
            last_update_at: Utc::now(),
        }
    }

    fn from_response(response: SessionMessagesResponse) -> Self {
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
        }
    }

    fn latest_message_timestamp(&self) -> chrono::DateTime<chrono::Utc> {
        self.in_progress_assistant
            .as_ref()
            .map(|message| message.created_at)
            .or_else(|| self.messages.last().map(|message| message.created_at))
            .unwrap_or(self.last_update_at)
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
}

struct DetachedSessionState {
    response: SessionMessagesResponse,
    expires_at: Instant,
}

fn sanitize_message(mut message: Message) -> Message {
    if message.body.chars().count() > MAX_LIVE_MESSAGE_BODY_CHARS {
        let truncated = message
            .body
            .chars()
            .take(MAX_LIVE_MESSAGE_BODY_CHARS)
            .collect::<String>();
        message.body = format!("{truncated}…");
    }

    message
}
