use std::{
    collections::HashMap,
    env, fs,
    path::{Path as FsPath, PathBuf},
    process::Command,
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
};

use axum::{
    Json, Router,
    body::Body,
    extract::{
        DefaultBodyLimit, Path, Query, State,
        ws::{Message, WebSocket, WebSocketUpgrade},
    },
    http::{HeaderValue, StatusCode, header},
    response::{IntoResponse, Response},
    routing::get,
};
use base64::{Engine as _, engine::general_purpose::STANDARD as BASE64_STANDARD};
use bytes::Bytes;
use chrono::{DateTime, Utc};
use futures_util::{sink::SinkExt, stream::StreamExt};
use mdns_sd::{DaemonEvent, ServiceDaemon, ServiceInfo};
use serde::{Deserialize, Serialize};
use tokio::{
    sync::{Mutex, RwLock, mpsc, oneshot},
    time::interval,
};
use tokio_stream::wrappers::UnboundedReceiverStream;

use crate::{
    channel::{AgentToServerMessage, ServerToAgentMessage},
    host::{HostIdentity, HostSessions},
    message::{ImageContent, normalize_mime_type},
    report::VersionResponse,
    session::{ActiveSession, ListedSession},
    transcript::{
        ApiSessionMessagesResponse, SessionMessagesResponse, SessionStreamEvent,
        TranscriptFreshnessState, TranscriptSource,
    },
};

type BoxError = Box<dyn std::error::Error + Send + Sync>;
type FetchResult = Result<SessionMessagesResponse, String>;
type SendResult = Result<(), String>;
const ON_DEMAND_FETCH_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(5);
const SEND_MESSAGE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(10);
const STREAM_KEEPALIVE_INTERVAL: std::time::Duration = std::time::Duration::from_secs(10);
const MAX_REQUEST_BODY_BYTES: usize = 16 * 1024 * 1024;
const MAX_SEND_MESSAGE_IMAGES: usize = 8;
const MAX_SEND_MESSAGE_IMAGE_BASE64_CHARS: usize = 8 * 1024 * 1024;
const MAX_SEND_MESSAGE_TOTAL_IMAGE_BASE64_CHARS: usize = 12 * 1024 * 1024;
const SYSTEMD_UNIT_NAME: &str = "pimux-server.service";
const LAUNCH_AGENT_LABEL: &str = "dev.pimux.server";
const LAUNCH_AGENT_FILE_NAME: &str = "dev.pimux.server.plist";
const HOST_REGISTRY_FILE_NAME: &str = "expected-hosts.json";
const PIMUX_MDNS_SERVICE_TYPE: &str = "_pimux._tcp.local.";
const PIMUX_MDNS_PROTOCOL: &str = "http";
const PIMUX_MDNS_PATH: &str = "/";

struct MdnsAdvertisement {
    daemon: ServiceDaemon,
}

impl Drop for MdnsAdvertisement {
    fn drop(&mut self) {
        let _ = self.daemon.shutdown();
    }
}

pub struct ServiceConfig {
    pub port: Option<u16>,
}

pub struct InstallResult {
    pub kind: &'static str,
    pub path: PathBuf,
}

pub struct UninstallResult {
    pub kind: &'static str,
    pub path: PathBuf,
    pub removed: bool,
}

#[derive(Clone)]
struct AppState {
    hosts: Arc<RwLock<HashMap<String, HostRecord>>>,
    transcripts: Arc<RwLock<HashMap<String, CachedTranscript>>>,
    agent_connections: Arc<RwLock<HashMap<String, AgentConnection>>>,
    inflight_fetches: Arc<Mutex<HashMap<String, InflightFetch>>>,
    inflight_send_messages: Arc<Mutex<HashMap<String, InflightSendMessage>>>,
    session_subscribers:
        Arc<Mutex<HashMap<String, Vec<mpsc::UnboundedSender<SessionSubscriptionEvent>>>>>,
    next_request_id: Arc<AtomicU64>,
    next_connection_id: Arc<AtomicU64>,
    host_registry_path: Option<PathBuf>,
}

impl AppState {
    fn new(hosts: HashMap<String, HostRecord>, host_registry_path: Option<PathBuf>) -> Self {
        Self {
            hosts: Arc::new(RwLock::new(hosts)),
            transcripts: Arc::new(RwLock::new(HashMap::new())),
            agent_connections: Arc::new(RwLock::new(HashMap::new())),
            inflight_fetches: Arc::new(Mutex::new(HashMap::new())),
            inflight_send_messages: Arc::new(Mutex::new(HashMap::new())),
            session_subscribers: Arc::new(Mutex::new(HashMap::new())),
            next_request_id: Arc::new(AtomicU64::new(1)),
            next_connection_id: Arc::new(AtomicU64::new(1)),
            host_registry_path,
        }
    }

    fn with_persistent_hosts() -> Result<Self, BoxError> {
        let path = default_host_registry_path()?;
        let hosts = match load_host_registry(&path) {
            Ok(hosts) => hosts,
            Err(error) => {
                eprintln!(
                    "warning: failed to load persisted host registry from {}: {error}",
                    path.display()
                );
                HashMap::new()
            }
        };
        Ok(Self::new(hosts, Some(path)))
    }
}

impl Default for AppState {
    fn default() -> Self {
        Self::new(HashMap::new(), None)
    }
}

#[derive(Clone)]
struct HostRecord {
    host: HostIdentity,
    sessions: Vec<ActiveSession>,
    connected: bool,
    last_seen_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Serialize, Deserialize)]
struct PersistedHostRegistry {
    hosts: Vec<PersistedHostRecord>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct PersistedHostRecord {
    host: HostIdentity,
    sessions: Vec<ActiveSession>,
    last_seen_at: Option<DateTime<Utc>>,
}

#[derive(Clone)]
struct CachedTranscript {
    response: SessionMessagesResponse,
}

#[derive(Clone)]
struct AgentConnection {
    connection_id: u64,
    sender: mpsc::UnboundedSender<ServerToAgentMessage>,
    close_sender: mpsc::UnboundedSender<()>,
}

struct InflightFetch {
    host_location: String,
    sender: oneshot::Sender<FetchResult>,
}

struct InflightSendMessage {
    host_location: String,
    sender: oneshot::Sender<SendResult>,
}

#[derive(Debug, Clone)]
enum SessionSubscriptionEvent {
    Snapshot(SessionMessagesResponse),
    SessionState {
        connected: bool,
        missing: bool,
        last_seen_at: Option<DateTime<Utc>>,
    },
}

#[derive(Debug, Serialize, Deserialize)]
struct ErrorResponse {
    error: String,
}

const DEFAULT_SESSION_PAGE_SIZE: usize = 25;

#[derive(Debug, Default, Deserialize)]
struct SessionsQuery {
    count: Option<usize>,
    before_id: Option<String>,
}

#[derive(Debug, Default, Serialize, Deserialize)]
struct SendMessageRequest {
    #[serde(default)]
    body: String,
    #[serde(default)]
    images: Vec<ImageContent>,
}


pub async fn start() -> Result<(), BoxError> {
    let app = app(AppState::with_persistent_hosts()?);
    let port = port_from_env()?;

    let listener = tokio::net::TcpListener::bind(("0.0.0.0", port)).await?;
    println!("server listening on http://{}", listener.local_addr()?);

    let _mdns = match start_mdns_advertisement(port) {
        Ok(advertisement) => advertisement,
        Err(error) => {
            eprintln!("warning: failed to start Bonjour advertisement: {error}");
            None
        }
    };

    axum::serve(listener, app).await?;

    Ok(())
}

pub fn install_service(config: ServiceConfig) -> Result<InstallResult, BoxError> {
    match env::consts::OS {
        "linux" => install_systemd_user_service(config.port),
        "macos" => install_launch_agent(config.port),
        other => Err(format!("server service install is not supported on {other}").into()),
    }
}

pub fn uninstall_service() -> Result<UninstallResult, BoxError> {
    match env::consts::OS {
        "linux" => uninstall_systemd_user_service(),
        "macos" => uninstall_launch_agent(),
        other => Err(format!("server service uninstall is not supported on {other}").into()),
    }
}

pub fn restart_service_if_installed() -> Result<Option<&'static str>, BoxError> {
    match env::consts::OS {
        "linux" => restart_systemd_user_service(),
        "macos" => restart_launch_agent(),
        other => Err(format!("server service restart is not supported on {other}").into()),
    }
}

fn app(state: AppState) -> Router {
    Router::new()
        .route("/health", get(health))
        .route("/version", get(version))
        .route("/hosts", get(hosts))
        .route("/sessions", get(sessions))
        .route(
            "/sessions/{id}/messages",
            get(session_messages).post(send_session_message),
        )
        .route(
            "/sessions/{id}/attachments/{attachment_id}",
            get(session_attachment),
        )
        .route("/sessions/{id}/stream", get(session_stream))
        .route("/agent/connect", get(agent_connect))
        .layer(DefaultBodyLimit::max(MAX_REQUEST_BODY_BYTES))
        .with_state(state)
}

fn port_from_env() -> Result<u16, BoxError> {
    match std::env::var("PORT") {
        Ok(value) => Ok(value.parse()?),
        Err(std::env::VarError::NotPresent) => Ok(3000),
        Err(err) => Err(Box::new(err)),
    }
}

fn start_mdns_advertisement(port: u16) -> Result<Option<MdnsAdvertisement>, BoxError> {
    if mdns_disabled_from_env() {
        return Ok(None);
    }

    let host_label = mdns_host_label()?;
    let host_name = format!("{host_label}.local.");
    let instance_name = format!("pimux on {host_label}:{port}");
    let daemon = ServiceDaemon::new()?;

    if let Ok(receiver) = daemon.monitor() {
        std::thread::spawn(move || {
            while let Ok(event) = receiver.recv() {
                if let DaemonEvent::Error(error) = event {
                    eprintln!("warning: pimux Bonjour error: {error}");
                }
            }
        });
    }

    let properties = [
        ("version", env!("CARGO_PKG_VERSION")),
        ("proto", PIMUX_MDNS_PROTOCOL),
        ("path", PIMUX_MDNS_PATH),
    ];

    let service_info = ServiceInfo::new(
        PIMUX_MDNS_SERVICE_TYPE,
        &instance_name,
        &host_name,
        "",
        port,
        &properties[..],
    )?
    .enable_addr_auto();

    daemon.register(service_info)?;
    println!(
        "advertising {PIMUX_MDNS_SERVICE_TYPE} via Bonjour as `{instance_name}` on {host_name}:{port}"
    );

    Ok(Some(MdnsAdvertisement { daemon }))
}

fn mdns_disabled_from_env() -> bool {
    let Ok(value) = env::var("PIMUX_DISABLE_MDNS") else {
        return false;
    };
    let normalized = value.trim().to_ascii_lowercase();
    matches!(normalized.as_str(), "1" | "true" | "yes" | "on")
}

fn mdns_host_label() -> Result<String, BoxError> {
    let raw = hostname::get()?
        .to_string_lossy()
        .trim()
        .trim_matches('.')
        .to_string();
    let sanitized = sanitize_mdns_host_label(&raw);
    if sanitized.is_empty() {
        return Err("could not derive a valid hostname for Bonjour advertisement".into());
    }
    Ok(sanitized)
}

fn sanitize_mdns_host_label(raw: &str) -> String {
    let mut label = String::new();
    let mut last_was_hyphen = false;

    for ch in raw.chars() {
        let mapped = match ch {
            'a'..='z' | '0'..='9' => Some(ch),
            'A'..='Z' => Some(ch.to_ascii_lowercase()),
            '-' | '_' | ' ' => Some('-'),
            _ => None,
        };

        let Some(mapped) = mapped else {
            continue;
        };

        if mapped == '-' {
            if label.is_empty() || last_was_hyphen {
                continue;
            }
            last_was_hyphen = true;
        } else {
            last_was_hyphen = false;
        }

        label.push(mapped);
        if label.len() >= 63 {
            break;
        }
    }

    while label.ends_with('-') {
        label.pop();
    }

    label
}

async fn health() -> &'static str {
    "OK"
}

async fn version() -> Json<VersionResponse> {
    Json(VersionResponse {
        version: env!("CARGO_PKG_VERSION").to_string(),
    })
}

async fn hosts(State(state): State<AppState>) -> Json<Vec<HostSessions>> {
    let hosts = state.hosts.read().await;
    let mut response = hosts
        .values()
        .map(|record| HostSessions {
            location: record.host.location.clone(),
            auth: record.host.auth,
            connected: record.connected,
            missing: !record.connected,
            last_seen_at: record.last_seen_at.clone(),
            sessions: record.sessions.clone(),
        })
        .collect::<Vec<_>>();

    response.sort_by(|left, right| left.location.cmp(&right.location));
    Json(response)
}



async fn sessions(
    State(state): State<AppState>,
    Query(query): Query<SessionsQuery>,
) -> Result<Json<Vec<ListedSession>>, (StatusCode, Json<ErrorResponse>)> {
    let mut sessions = listed_sessions(&state).await;

    sessions.sort_by(|left, right| {
        right
            .session
            .updated_at
            .cmp(&left.session.updated_at)
            .then_with(|| left.host_location.cmp(&right.host_location))
            .then_with(|| left.session.id.cmp(&right.session.id))
    });

    if let Some(before_id) = &query.before_id {
        let cursor_pos = sessions
            .iter()
            .position(|s| s.session.id == *before_id)
            .ok_or_else(|| bad_request(format!("session `{before_id}` not found")))?;
        sessions = sessions.split_off(cursor_pos + 1);
    }

    let count = query.count.unwrap_or(DEFAULT_SESSION_PAGE_SIZE);
    sessions.truncate(count);

    Ok(Json(sessions))
}

async fn session_messages(
    State(state): State<AppState>,
    Path(session_id): Path<String>,
) -> Result<Json<ApiSessionMessagesResponse>, (StatusCode, Json<ErrorResponse>)> {
    let snapshot = resolve_session_snapshot(&state, &session_id).await?;
    Ok(Json(ApiSessionMessagesResponse::from(&snapshot)))
}

async fn session_attachment(
    State(state): State<AppState>,
    Path((session_id, attachment_id)): Path<(String, String)>,
) -> Result<Response, (StatusCode, Json<ErrorResponse>)> {
    let snapshot = resolve_session_snapshot(&state, &session_id).await?;
    let Some((mime_type, base64_data)) = attachment_payload(&snapshot, &attachment_id) else {
        return Err(not_found(format!(
            "attachment {attachment_id} was not found for session {session_id}"
        )));
    };

    let bytes = BASE64_STANDARD.decode(base64_data).map_err(|error| {
        bad_gateway(format!(
            "attachment {attachment_id} for session {session_id} could not be decoded: {error}"
        ))
    })?;

    let mut response = Response::new(Body::from(bytes));
    response.headers_mut().insert(
        header::CONTENT_TYPE,
        HeaderValue::from_str(mime_type)
            .unwrap_or_else(|_| HeaderValue::from_static("application/octet-stream")),
    );
    response.headers_mut().insert(
        header::CACHE_CONTROL,
        HeaderValue::from_static("private, max-age=300"),
    );
    Ok(response)
}

async fn session_stream(
    State(state): State<AppState>,
    Path(session_id): Path<String>,
) -> Result<Response, (StatusCode, Json<ErrorResponse>)> {
    let snapshot = resolve_session_snapshot(&state, &session_id).await?;
    let initial_state = current_session_subscription_state(&state, &session_id).await;

    let (subscription_tx, mut subscription_rx) = mpsc::unbounded_channel();
    subscribe_session(&state, &session_id, subscription_tx).await;

    let (body_tx, body_rx) = mpsc::unbounded_channel::<Bytes>();
    tokio::spawn(async move {
        let mut sequence = 1_u64;
        if send_stream_event(
            &body_tx,
            SessionStreamEvent::Snapshot {
                sequence,
                session: ApiSessionMessagesResponse::from(&snapshot),
            },
        )
        .is_err()
        {
            return;
        }
        sequence += 1;

        if let Some(event) = initial_state {
            let stream_event = match event {
                SessionSubscriptionEvent::Snapshot(session) => SessionStreamEvent::Snapshot {
                    sequence,
                    session: ApiSessionMessagesResponse::from(&session),
                },
                SessionSubscriptionEvent::SessionState {
                    connected,
                    missing,
                    last_seen_at,
                } => SessionStreamEvent::SessionState {
                    sequence,
                    connected,
                    missing,
                    last_seen_at,
                },
            };
            if send_stream_event(&body_tx, stream_event).is_err() {
                return;
            }
            sequence += 1;
        }

        let mut keepalive = interval(STREAM_KEEPALIVE_INTERVAL);
        loop {
            tokio::select! {
                maybe_event = subscription_rx.recv() => {
                    let Some(event) = maybe_event else {
                        break;
                    };
                    let stream_event = match event {
                        SessionSubscriptionEvent::Snapshot(session) => SessionStreamEvent::Snapshot {
                            sequence,
                            session: ApiSessionMessagesResponse::from(&session),
                        },
                        SessionSubscriptionEvent::SessionState {
                            connected,
                            missing,
                            last_seen_at,
                        } => SessionStreamEvent::SessionState {
                            sequence,
                            connected,
                            missing,
                            last_seen_at,
                        },
                    };
                    if send_stream_event(&body_tx, stream_event).is_err() {
                        break;
                    }
                    sequence += 1;
                }
                _ = keepalive.tick() => {
                    if send_stream_event(
                        &body_tx,
                        SessionStreamEvent::Keepalive {
                            sequence,
                            timestamp: Utc::now(),
                        },
                    ).is_err() {
                        break;
                    }
                    sequence += 1;
                }
            }
        }
    });

    let stream = UnboundedReceiverStream::new(body_rx).map(Ok::<Bytes, std::convert::Infallible>);
    let mut response = Response::new(Body::from_stream(stream));
    response.headers_mut().insert(
        header::CONTENT_TYPE,
        HeaderValue::from_static("application/x-ndjson"),
    );
    response
        .headers_mut()
        .insert(header::CACHE_CONTROL, HeaderValue::from_static("no-cache"));
    response
        .headers_mut()
        .insert(header::CONNECTION, HeaderValue::from_static("keep-alive"));
    Ok(response)
}

fn attachment_payload<'a>(
    snapshot: &'a SessionMessagesResponse,
    attachment_id: &str,
) -> Option<(&'a str, &'a str)> {
    snapshot.messages.iter().find_map(|message| {
        message.blocks.iter().find_map(|block| {
            let mime_type = block.mime_type.as_deref()?;
            let data = block.data.as_deref()?;
            let block_attachment_id = block.attachment_id()?;
            (block_attachment_id == attachment_id).then_some((mime_type, data))
        })
    })
}

fn normalize_image_base64(data: &str) -> String {
    data.chars().filter(|char| !char.is_whitespace()).collect()
}

fn validate_request_images(images: Vec<ImageContent>) -> Result<Vec<ImageContent>, String> {
    if images.len() > MAX_SEND_MESSAGE_IMAGES {
        return Err(format!(
            "too many images: received {}, limit is {}",
            images.len(),
            MAX_SEND_MESSAGE_IMAGES
        ));
    }

    let mut total_base64_chars = 0usize;
    let mut normalized_images = Vec::with_capacity(images.len());
    for (index, image) in images.into_iter().enumerate() {
        let image_number = index + 1;
        let Some(mime_type) = normalize_mime_type(&image.mime_type) else {
            return Err(format!("image {image_number} is missing a valid mimeType"));
        };
        if !mime_type.starts_with("image/") {
            return Err(format!(
                "image {image_number} must use an image/* mimeType, got {mime_type}"
            ));
        }

        let data = normalize_image_base64(&image.data);
        if data.is_empty() {
            return Err(format!("image {image_number} must not have empty data"));
        }
        BASE64_STANDARD.decode(&data).map_err(|error| {
            format!("image {image_number} must contain valid base64 data: {error}")
        })?;
        if data.len() > MAX_SEND_MESSAGE_IMAGE_BASE64_CHARS {
            return Err(format!(
                "image {image_number} is too large: base64 payload exceeds {} characters",
                MAX_SEND_MESSAGE_IMAGE_BASE64_CHARS
            ));
        }

        total_base64_chars += data.len();
        if total_base64_chars > MAX_SEND_MESSAGE_TOTAL_IMAGE_BASE64_CHARS {
            return Err(format!(
                "images are too large: combined base64 payload exceeds {} characters",
                MAX_SEND_MESSAGE_TOTAL_IMAGE_BASE64_CHARS
            ));
        }

        normalized_images.push(ImageContent::new(mime_type, data));
    }

    Ok(normalized_images)
}

async fn send_session_message(
    State(state): State<AppState>,
    Path(session_id): Path<String>,
    Json(request): Json<SendMessageRequest>,
) -> Result<StatusCode, (StatusCode, Json<ErrorResponse>)> {
    let body = request.body.trim().to_string();
    let images = validate_request_images(request.images).map_err(bad_request)?;
    if body.is_empty() && images.is_empty() {
        return Err(bad_request(
            "message body or images must not both be empty".to_string(),
        ));
    }

    let Some(host_location) = host_for_session(&state, &session_id).await else {
        return Err(not_found(format!(
            "session {session_id} is not known to the server"
        )));
    };

    let request_id = next_request_id(&state, "send");
    let (sender, receiver) = oneshot::channel();
    {
        let mut inflight_send_messages = state.inflight_send_messages.lock().await;
        inflight_send_messages.insert(
            request_id.clone(),
            InflightSendMessage {
                host_location: host_location.clone(),
                sender,
            },
        );
    }

    send_to_agent(
        &state,
        &host_location,
        ServerToAgentMessage::SendMessage {
            request_id: request_id.clone(),
            session_id: session_id.clone(),
            body,
            images,
        },
    )
    .await?;

    match tokio::time::timeout(SEND_MESSAGE_TIMEOUT, receiver).await {
        Ok(Ok(Ok(()))) => Ok(StatusCode::NO_CONTENT),
        Ok(Ok(Err(error))) => Err((status_for_send_error(&error), Json(ErrorResponse { error }))),
        Ok(Err(_)) => Err(bad_gateway(format!(
            "host {} disconnected before confirming message delivery for session {}",
            host_location, session_id
        ))),
        Err(_) => {
            cancel_send_message(&state, &request_id).await;
            Err(gateway_timeout(format!(
                "timed out waiting for host {} to confirm message delivery for session {}",
                host_location, session_id
            )))
        }
    }
}

async fn agent_connect(ws: WebSocketUpgrade, State(state): State<AppState>) -> impl IntoResponse {
    ws.on_upgrade(move |socket| handle_agent_socket(state, socket))
}

async fn handle_agent_socket(state: AppState, socket: WebSocket) {
    let connection_id = state.next_connection_id.fetch_add(1, Ordering::Relaxed);
    let (sender, mut receiver) = mpsc::unbounded_channel::<ServerToAgentMessage>();
    let (close_sender, mut close_receiver) = mpsc::unbounded_channel::<()>();
    let (mut ws_sender, mut ws_receiver) = socket.split();
    let writer = tokio::spawn(async move {
        loop {
            tokio::select! {
                maybe_close = close_receiver.recv() => {
                    if maybe_close.is_some() {
                        let _ = ws_sender.send(Message::Close(None)).await;
                    }
                    break;
                }
                maybe_message = receiver.recv() => {
                    let Some(message) = maybe_message else {
                        break;
                    };
                    let Ok(payload) = serde_json::to_string(&message) else {
                        break;
                    };
                    if ws_sender.send(Message::Text(payload.into())).await.is_err() {
                        break;
                    }
                }
            }
        }
    });

    let mut current_host: Option<HostIdentity> = None;

    while let Some(message) = ws_receiver.next().await {
        let message = match message {
            Ok(message) => message,
            Err(error) => {
                eprintln!("agent websocket error: {error}");
                break;
            }
        };

        match message {
            Message::Text(text) => {
                let incoming = match serde_json::from_str::<AgentToServerMessage>(&text) {
                    Ok(incoming) => incoming,
                    Err(error) => {
                        eprintln!("invalid agent websocket message: {error}");
                        continue;
                    }
                };

                match incoming {
                    AgentToServerMessage::Hello { host } => {
                        let accepted = register_agent_connection(
                            &state,
                            &host,
                            connection_id,
                            sender.clone(),
                            close_sender.clone(),
                        )
                        .await;
                        if !accepted {
                            break;
                        }
                        current_host = Some(host);
                    }
                    AgentToServerMessage::HostSnapshot { sessions } => {
                        let Some(host) = current_host.clone() else {
                            eprintln!("received host snapshot before hello");
                            continue;
                        };
                        update_host_snapshot(&state, host, sessions).await;
                    }
                    AgentToServerMessage::LiveSessionUpdate {
                        session,
                        active_session,
                    } => {
                        let Some(host) = current_host.as_ref() else {
                            eprintln!("received live session update before hello");
                            continue;
                        };
                        let changed = {
                            let mut transcripts = state.transcripts.write().await;
                            upsert_cached_transcript(
                                &mut transcripts,
                                host.location.clone(),
                                session,
                            )
                        };
                        if let Some(active_session) = active_session {
                            upsert_live_host_session(&state, host, active_session).await;
                        }
                        if let Some(session) = changed {
                            broadcast_session_snapshot(&state, session).await;
                        }
                    }
                    AgentToServerMessage::FetchTranscriptResult {
                        request_id,
                        session,
                        error,
                    } => {
                        let Some(host) = current_host.as_ref() else {
                            eprintln!("received transcript result before hello");
                            continue;
                        };
                        fulfill_fetch_result(&state, &host.location, &request_id, session, error)
                            .await;
                    }
                    AgentToServerMessage::SendMessageResult { request_id, error } => {
                        let Some(host) = current_host.as_ref() else {
                            eprintln!("received send message result before hello");
                            continue;
                        };
                        fulfill_send_result(&state, &host.location, &request_id, error).await;
                    }
                    AgentToServerMessage::Ping => {
                        let _ = sender.send(ServerToAgentMessage::Pong);
                    }
                    AgentToServerMessage::Pong => {}
                }
            }
            Message::Close(_) => break,
            Message::Ping(_) | Message::Pong(_) | Message::Binary(_) => {}
        }
    }

    writer.abort();

    if let Some(host) = current_host {
        disconnect_agent(&state, &host.location, connection_id).await;
    }
}

async fn register_agent_connection(
    state: &AppState,
    host: &HostIdentity,
    connection_id: u64,
    sender: mpsc::UnboundedSender<ServerToAgentMessage>,
    close_sender: mpsc::UnboundedSender<()>,
) -> bool {
    {
        let mut connections = state.agent_connections.write().await;
        connections.insert(
            host.location.clone(),
            AgentConnection {
                connection_id,
                sender,
                close_sender,
            },
        );
    }

    let now = Utc::now();
    let session_ids = {
        let mut hosts = state.hosts.write().await;
        let record = hosts
            .entry(host.location.clone())
            .or_insert_with(|| HostRecord {
                host: host.clone(),
                sessions: Vec::new(),
                connected: true,
                last_seen_at: Some(now),
            });
        record.host = host.clone();
        record.connected = true;
        record.last_seen_at = Some(now);
        record
            .sessions
            .iter()
            .map(|session| session.id.clone())
            .collect::<Vec<_>>()
    };

    persist_hosts(state).await;
    for session_id in session_ids {
        broadcast_session_state(state, &session_id, true, false, Some(now)).await;
    }

    true
}

async fn update_host_snapshot(state: &AppState, host: HostIdentity, sessions: Vec<ActiveSession>) {
    let now = Utc::now();
    let session_ids = sessions
        .iter()
        .map(|session| session.id.clone())
        .collect::<Vec<_>>();
    {
        let mut hosts = state.hosts.write().await;
        hosts.insert(
            host.location.clone(),
            HostRecord {
                host,
                sessions,
                connected: true,
                last_seen_at: Some(now),
            },
        );
    }

    persist_hosts(state).await;
    for session_id in session_ids {
        broadcast_session_state(state, &session_id, true, false, Some(now)).await;
    }
}

async fn upsert_live_host_session(state: &AppState, host: &HostIdentity, session: ActiveSession) {
    let now = Utc::now();
    {
        let mut hosts = state.hosts.write().await;
        let record = hosts
            .entry(host.location.clone())
            .or_insert_with(|| HostRecord {
                host: host.clone(),
                sessions: Vec::new(),
                connected: true,
                last_seen_at: Some(now),
            });

        record.host = host.clone();
        record.connected = true;
        record.last_seen_at = Some(now);

        if let Some(existing) = record
            .sessions
            .iter_mut()
            .find(|existing| existing.id == session.id)
        {
            *existing = session;
        } else {
            record.sessions.push(session);
        }
    }

    persist_hosts(state).await;
}

async fn disconnect_agent(state: &AppState, host_location: &str, connection_id: u64) {
    {
        let mut connections = state.agent_connections.write().await;
        let should_remove = connections
            .get(host_location)
            .map(|connection| connection.connection_id == connection_id)
            .unwrap_or(false);
        if should_remove {
            connections.remove(host_location);
        } else {
            return;
        }
    }

    let (session_ids, last_seen_at) = {
        let mut hosts = state.hosts.write().await;
        if let Some(record) = hosts.get_mut(host_location) {
            record.connected = false;
            (
                record
                    .sessions
                    .iter()
                    .map(|session| session.id.clone())
                    .collect::<Vec<_>>(),
                record.last_seen_at.clone(),
            )
        } else {
            (Vec::new(), None)
        }
    };

    persist_hosts(state).await;
    for session_id in session_ids {
        broadcast_session_state(state, &session_id, false, true, last_seen_at.clone()).await;
    }
    fail_inflight_for_host(state, host_location).await;
}



async fn send_to_agent(
    state: &AppState,
    host_location: &str,
    message: ServerToAgentMessage,
) -> Result<(), (StatusCode, Json<ErrorResponse>)> {
    let sender = {
        let connections = state.agent_connections.read().await;
        connections
            .get(host_location)
            .map(|connection| connection.sender.clone())
    }
    .ok_or_else(|| {
        bad_gateway(format!(
            "host {} is not currently connected to the server",
            host_location
        ))
    })?;

    sender.send(message).map_err(|_| {
        bad_gateway(format!(
            "host {} is no longer able to receive server requests",
            host_location
        ))
    })
}

async fn resolve_session_snapshot(
    state: &AppState,
    session_id: &str,
) -> Result<SessionMessagesResponse, (StatusCode, Json<ErrorResponse>)> {
    if let Some(cached) = cached_transcript(state, session_id).await {
        return Ok(cached.response);
    }

    let Some(host_location) = host_for_session(state, session_id).await else {
        return Err(not_found(format!(
            "session {session_id} is not known to the server"
        )));
    };

    let request_id = next_request_id(state, "fetch");
    let (sender, receiver) = oneshot::channel();
    {
        let mut inflight_fetches = state.inflight_fetches.lock().await;
        inflight_fetches.insert(
            request_id.clone(),
            InflightFetch {
                host_location: host_location.clone(),
                sender,
            },
        );
    }

    send_to_agent(
        state,
        &host_location,
        ServerToAgentMessage::FetchTranscript {
            request_id: request_id.clone(),
            session_id: session_id.to_string(),
        },
    )
    .await?;

    match tokio::time::timeout(ON_DEMAND_FETCH_TIMEOUT, receiver).await {
        Ok(Ok(Ok(session))) => Ok(session),
        Ok(Ok(Err(error))) => Err((
            status_for_fetch_error(&error),
            Json(ErrorResponse { error }),
        )),
        Ok(Err(_)) => Err(bad_gateway(format!(
            "host {} disconnected before fulfilling transcript fetch for session {}",
            host_location, session_id
        ))),
        Err(_) => {
            cancel_fetch(state, &request_id).await;
            Err(gateway_timeout(format!(
                "timed out waiting for host {} to provide transcript for session {}",
                host_location, session_id
            )))
        }
    }
}

async fn subscribe_session(
    state: &AppState,
    session_id: &str,
    sender: mpsc::UnboundedSender<SessionSubscriptionEvent>,
) {
    state
        .session_subscribers
        .lock()
        .await
        .entry(session_id.to_string())
        .or_default()
        .push(sender);
}

async fn current_session_subscription_state(
    state: &AppState,
    session_id: &str,
) -> Option<SessionSubscriptionEvent> {
    let hosts = state.hosts.read().await;
    preferred_listed_session(&hosts, session_id).map(|session| {
        SessionSubscriptionEvent::SessionState {
            connected: session.host_connected,
            missing: session.host_missing,
            last_seen_at: session.host_last_seen_at,
        }
    })
}

async fn broadcast_session_snapshot(state: &AppState, session: SessionMessagesResponse) {
    let session_id = session.session_id.clone();
    broadcast_session_event(
        state,
        &session_id,
        SessionSubscriptionEvent::Snapshot(session),
    )
    .await;
}

async fn broadcast_session_state(
    state: &AppState,
    session_id: &str,
    connected: bool,
    missing: bool,
    last_seen_at: Option<DateTime<Utc>>,
) {
    broadcast_session_event(
        state,
        session_id,
        SessionSubscriptionEvent::SessionState {
            connected,
            missing,
            last_seen_at,
        },
    )
    .await;
}

async fn broadcast_session_event(
    state: &AppState,
    session_id: &str,
    event: SessionSubscriptionEvent,
) {
    let mut subscribers = state.session_subscribers.lock().await;
    let mut remove_entry = false;

    if let Some(entries) = subscribers.get_mut(session_id) {
        entries.retain(|sender| sender.send(event.clone()).is_ok());
        remove_entry = entries.is_empty();
    }

    if remove_entry {
        subscribers.remove(session_id);
    }
}

fn send_stream_event(
    sender: &mpsc::UnboundedSender<Bytes>,
    event: SessionStreamEvent,
) -> Result<(), ()> {
    let mut payload = serde_json::to_string(&event).map_err(|_| ())?;
    payload.push('\n');
    sender.send(Bytes::from(payload)).map_err(|_| ())
}

async fn fulfill_fetch_result(
    state: &AppState,
    host_location: &str,
    request_id: &str,
    session: Option<SessionMessagesResponse>,
    error: Option<String>,
) {
    if let Some(session) = session.clone() {
        let changed = {
            let mut transcripts = state.transcripts.write().await;
            upsert_cached_transcript(&mut transcripts, host_location.to_string(), session)
        };
        if let Some(session) = changed {
            broadcast_session_snapshot(state, session).await;
        }
    }

    let sender = {
        let mut inflight_fetches = state.inflight_fetches.lock().await;
        inflight_fetches.remove(request_id)
    };

    if let Some(inflight) = sender {
        let result = match (session, error) {
            (Some(session), _) => Ok(session),
            (None, Some(error)) => Err(error),
            (None, None) => Err("agent returned an empty transcript response".to_string()),
        };
        let _ = inflight.sender.send(result);
    }
}

async fn fulfill_send_result(
    state: &AppState,
    _host_location: &str,
    request_id: &str,
    error: Option<String>,
) {
    let sender = {
        let mut inflight_send_messages = state.inflight_send_messages.lock().await;
        inflight_send_messages.remove(request_id)
    };

    if let Some(inflight) = sender {
        let result = match error {
            Some(error) => Err(error),
            None => Ok(()),
        };
        let _ = inflight.sender.send(result);
    }
}

async fn fail_inflight_for_host(state: &AppState, host_location: &str) {
    let fetch_senders = {
        let mut inflight_fetches = state.inflight_fetches.lock().await;
        let request_ids = inflight_fetches
            .iter()
            .filter(|(_, inflight)| inflight.host_location == host_location)
            .map(|(request_id, _)| request_id.clone())
            .collect::<Vec<_>>();
        request_ids
            .into_iter()
            .filter_map(|request_id| inflight_fetches.remove(&request_id))
            .collect::<Vec<_>>()
    };

    for inflight in fetch_senders {
        let _ = inflight.sender.send(Err(format!(
            "host {} disconnected before fulfilling transcript fetch",
            host_location
        )));
    }

    let send_senders = {
        let mut inflight_send_messages = state.inflight_send_messages.lock().await;
        let request_ids = inflight_send_messages
            .iter()
            .filter(|(_, inflight)| inflight.host_location == host_location)
            .map(|(request_id, _)| request_id.clone())
            .collect::<Vec<_>>();
        request_ids
            .into_iter()
            .filter_map(|request_id| inflight_send_messages.remove(&request_id))
            .collect::<Vec<_>>()
    };

    for inflight in send_senders {
        let _ = inflight.sender.send(Err(format!(
            "host {} disconnected before confirming message delivery",
            host_location
        )));
    }
}

async fn listed_sessions(state: &AppState) -> Vec<ListedSession> {
    let hosts = state.hosts.read().await;
    let mut sessions_by_id = HashMap::new();

    for record in hosts.values() {
        for session in &record.sessions {
            let candidate = listed_session(record, session);
            match sessions_by_id.get(&candidate.session.id) {
                Some(existing) if !should_prefer_listed_session(&candidate, existing) => {}
                _ => {
                    sessions_by_id.insert(candidate.session.id.clone(), candidate);
                }
            }
        }
    }

    sessions_by_id.into_values().collect()
}

fn listed_session(record: &HostRecord, session: &ActiveSession) -> ListedSession {
    ListedSession::new(
        record.host.location.clone(),
        record.connected,
        !record.connected,
        record.last_seen_at.clone(),
        session.clone(),
    )
}

fn preferred_listed_session(
    hosts: &HashMap<String, HostRecord>,
    session_id: &str,
) -> Option<ListedSession> {
    let mut preferred = None;

    for record in hosts.values() {
        let Some(session) = record
            .sessions
            .iter()
            .find(|session| session.id == session_id)
        else {
            continue;
        };

        let candidate = listed_session(record, session);
        match preferred.as_ref() {
            Some(existing) if !should_prefer_listed_session(&candidate, existing) => {}
            _ => preferred = Some(candidate),
        }
    }

    preferred
}

fn should_prefer_listed_session(candidate: &ListedSession, existing: &ListedSession) -> bool {
    if candidate.host_connected != existing.host_connected {
        return candidate.host_connected;
    }

    if candidate.session.updated_at != existing.session.updated_at {
        return candidate.session.updated_at > existing.session.updated_at;
    }

    if candidate.host_last_seen_at != existing.host_last_seen_at {
        return candidate.host_last_seen_at > existing.host_last_seen_at;
    }

    candidate.host_location < existing.host_location
}

async fn cached_transcript(state: &AppState, session_id: &str) -> Option<CachedTranscript> {
    state.transcripts.read().await.get(session_id).cloned()
}

async fn host_for_session(state: &AppState, session_id: &str) -> Option<String> {
    let hosts = state.hosts.read().await;
    preferred_listed_session(&hosts, session_id).map(|session| session.host_location)
}

async fn cancel_fetch(state: &AppState, request_id: &str) {
    state.inflight_fetches.lock().await.remove(request_id);
}

async fn cancel_send_message(state: &AppState, request_id: &str) {
    state.inflight_send_messages.lock().await.remove(request_id);
}

async fn persist_hosts(state: &AppState) {
    let Some(path) = state.host_registry_path.clone() else {
        return;
    };

    let hosts = state.hosts.read().await.clone();
    if let Err(error) = persist_host_registry(&path, &hosts) {
        eprintln!(
            "warning: failed to persist host registry to {}: {error}",
            path.display()
        );
    }
}

fn load_host_registry(path: &FsPath) -> Result<HashMap<String, HostRecord>, BoxError> {
    if !path.exists() {
        return Ok(HashMap::new());
    }

    let contents = fs::read_to_string(path)?;
    if contents.trim().is_empty() {
        return Ok(HashMap::new());
    }

    let persisted: PersistedHostRegistry = serde_json::from_str(&contents)?;
    let hosts = persisted
        .hosts
        .into_iter()
        .map(|record| {
            (
                record.host.location.clone(),
                HostRecord {
                    host: record.host,
                    sessions: record.sessions,
                    connected: false,
                    last_seen_at: record.last_seen_at,
                },
            )
        })
        .collect();

    Ok(hosts)
}

fn persist_host_registry(
    path: &FsPath,
    hosts: &HashMap<String, HostRecord>,
) -> Result<(), BoxError> {
    ensure_parent_dir(path)?;

    let mut persisted_hosts = hosts
        .values()
        .map(|record| PersistedHostRecord {
            host: record.host.clone(),
            sessions: record.sessions.clone(),
            last_seen_at: record.last_seen_at.clone(),
        })
        .collect::<Vec<_>>();
    persisted_hosts.sort_by(|left, right| left.host.location.cmp(&right.host.location));

    let contents = serde_json::to_string_pretty(&PersistedHostRegistry {
        hosts: persisted_hosts,
    })?;

    let temp_path = path.with_extension("tmp");
    fs::write(&temp_path, contents)?;
    fs::rename(&temp_path, path)?;
    Ok(())
}

fn default_host_registry_path() -> Result<PathBuf, BoxError> {
    if let Ok(path) = env::var("PIMUX_SERVER_STATE_PATH") {
        return Ok(PathBuf::from(path));
    }

    match env::consts::OS {
        "macos" => Ok(home_dir()?
            .join("Library")
            .join("Application Support")
            .join("pimux")
            .join(HOST_REGISTRY_FILE_NAME)),
        "linux" => {
            let base = match env::var("XDG_STATE_HOME") {
                Ok(value) if !value.is_empty() => PathBuf::from(value),
                _ => home_dir()?.join(".local").join("state"),
            };
            Ok(base.join("pimux").join(HOST_REGISTRY_FILE_NAME))
        }
        _ => Ok(home_dir()?.join(".pimux").join(HOST_REGISTRY_FILE_NAME)),
    }
}

fn next_request_id(state: &AppState, prefix: &str) -> String {
    format!(
        "{prefix}-{}",
        state.next_request_id.fetch_add(1, Ordering::Relaxed)
    )
}

fn upsert_cached_transcript(
    transcripts: &mut HashMap<String, CachedTranscript>,
    _host_location: String,
    response: SessionMessagesResponse,
) -> Option<SessionMessagesResponse> {
    let session_id = response.session_id.clone();

    match transcripts.get_mut(&session_id) {
        Some(existing) if !should_replace_cached_transcript(existing, &response) => None,
        Some(existing) => {
            *existing = CachedTranscript {
                response: response.clone(),
            };
            Some(response)
        }
        None => {
            transcripts.insert(
                session_id,
                CachedTranscript {
                    response: response.clone(),
                },
            );
            Some(response)
        }
    }
}

fn should_replace_cached_transcript(
    existing: &CachedTranscript,
    incoming: &SessionMessagesResponse,
) -> bool {
    transcript_score(incoming) >= transcript_score(&existing.response)
}

fn transcript_score(response: &SessionMessagesResponse) -> (i64, u8, u8, usize) {
    (
        response.freshness.as_of.timestamp_millis(),
        freshness_rank(response.freshness.state),
        source_rank(response.freshness.source),
        response.messages.len(),
    )
}

fn freshness_rank(state: TranscriptFreshnessState) -> u8 {
    match state {
        TranscriptFreshnessState::Persisted => 0,
        TranscriptFreshnessState::LiveUnknown => 1,
        TranscriptFreshnessState::Live => 2,
    }
}

fn source_rank(source: TranscriptSource) -> u8 {
    match source {
        TranscriptSource::File => 0,
        TranscriptSource::Helper => 1,
        TranscriptSource::Extension => 2,
    }
}

fn bad_request(error: String) -> (StatusCode, Json<ErrorResponse>) {
    (StatusCode::BAD_REQUEST, Json(ErrorResponse { error }))
}

fn bad_gateway(error: String) -> (StatusCode, Json<ErrorResponse>) {
    (StatusCode::BAD_GATEWAY, Json(ErrorResponse { error }))
}

fn gateway_timeout(error: String) -> (StatusCode, Json<ErrorResponse>) {
    (StatusCode::GATEWAY_TIMEOUT, Json(ErrorResponse { error }))
}

fn not_found(error: String) -> (StatusCode, Json<ErrorResponse>) {
    (StatusCode::NOT_FOUND, Json(ErrorResponse { error }))
}

fn status_for_fetch_error(error: &str) -> StatusCode {
    if error.contains("was not found") {
        StatusCode::NOT_FOUND
    } else {
        StatusCode::BAD_GATEWAY
    }
}

fn status_for_send_error(error: &str) -> StatusCode {
    if error.contains("was not found") {
        StatusCode::NOT_FOUND
    } else {
        StatusCode::BAD_GATEWAY
    }
}

fn restart_systemd_user_service() -> Result<Option<&'static str>, BoxError> {
    let unit_path = systemd_unit_path()?;
    if !unit_path.exists() {
        return Ok(None);
    }

    run_command("systemctl", &["--user", "restart", SYSTEMD_UNIT_NAME])?;
    Ok(Some("systemd --user"))
}

fn install_systemd_user_service(port: Option<u16>) -> Result<InstallResult, BoxError> {
    let unit_path = systemd_unit_path()?;
    let executable = env::current_exe()?;
    let unit = render_systemd_unit(&executable, port);

    write_file(&unit_path, &unit)?;
    run_command("systemctl", &["--user", "daemon-reload"])?;
    run_command(
        "systemctl",
        &["--user", "enable", "--now", SYSTEMD_UNIT_NAME],
    )?;
    run_command("systemctl", &["--user", "restart", SYSTEMD_UNIT_NAME])?;

    Ok(InstallResult {
        kind: "systemd --user",
        path: unit_path,
    })
}

fn uninstall_systemd_user_service() -> Result<UninstallResult, BoxError> {
    let unit_path = systemd_unit_path()?;
    let _ = run_command(
        "systemctl",
        &["--user", "disable", "--now", SYSTEMD_UNIT_NAME],
    );
    let removed = remove_file_if_exists(&unit_path)?;
    let _ = run_command("systemctl", &["--user", "daemon-reload"]);

    Ok(UninstallResult {
        kind: "systemd --user",
        path: unit_path,
        removed,
    })
}

fn restart_launch_agent() -> Result<Option<&'static str>, BoxError> {
    let plist_path = launch_agent_path()?;
    if !plist_path.exists() {
        return Ok(None);
    }

    let domain = launchctl_domain()?;
    run_command(
        "launchctl",
        &["kickstart", "-k", &format!("{domain}/{LAUNCH_AGENT_LABEL}")],
    )?;
    Ok(Some("launchctl"))
}

fn install_launch_agent(port: Option<u16>) -> Result<InstallResult, BoxError> {
    let plist_path = launch_agent_path()?;
    let executable = env::current_exe()?;
    let stdout_log = launch_agent_log_path("out")?;
    let stderr_log = launch_agent_log_path("err")?;
    let plist = render_launch_agent_plist(&executable, port, &stdout_log, &stderr_log);

    touch_file(&stdout_log)?;
    touch_file(&stderr_log)?;
    write_file(&plist_path, &plist)?;

    let domain = launchctl_domain()?;
    let _ = run_command(
        "launchctl",
        &["bootout", &format!("{domain}/{LAUNCH_AGENT_LABEL}")],
    );
    run_command(
        "launchctl",
        &["bootstrap", &domain, &plist_path.display().to_string()],
    )?;
    run_command(
        "launchctl",
        &["kickstart", "-k", &format!("{domain}/{LAUNCH_AGENT_LABEL}")],
    )?;

    Ok(InstallResult {
        kind: "launchctl",
        path: plist_path,
    })
}

fn uninstall_launch_agent() -> Result<UninstallResult, BoxError> {
    let plist_path = launch_agent_path()?;
    let domain = launchctl_domain()?;
    let _ = run_command(
        "launchctl",
        &["bootout", &format!("{domain}/{LAUNCH_AGENT_LABEL}")],
    );
    let removed = remove_file_if_exists(&plist_path)?;

    Ok(UninstallResult {
        kind: "launchctl",
        path: plist_path,
        removed,
    })
}

fn render_systemd_unit(executable: &FsPath, port: Option<u16>) -> String {
    let mut lines = vec![
        "[Unit]".to_string(),
        "Description=pimux server".to_string(),
        String::new(),
        "[Service]".to_string(),
        "Type=simple".to_string(),
        format!("ExecStart=\"{}\" \"server\"", executable.display()),
        "Restart=always".to_string(),
        "RestartSec=2".to_string(),
    ];

    if let Some(port) = port {
        lines.push(format!("Environment=PORT=\"{port}\""));
    }

    lines.push(String::new());
    lines.push("[Install]".to_string());
    lines.push("WantedBy=default.target".to_string());
    lines.push(String::new());
    lines.join("\n")
}

fn render_launch_agent_plist(
    executable: &FsPath,
    port: Option<u16>,
    stdout_log: &FsPath,
    stderr_log: &FsPath,
) -> String {
    let environment = match port {
        Some(port) => format!(
            "\n\t<key>EnvironmentVariables</key>\n\t<dict>\n\t\t<key>PORT</key>\n\t\t<string>{port}</string>\n\t</dict>"
        ),
        None => String::new(),
    };

    format!(
        concat!(
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n",
            "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n",
            "<plist version=\"1.0\">\n",
            "<dict>\n",
            "\t<key>Label</key>\n",
            "\t<string>{label}</string>\n",
            "\t<key>ProgramArguments</key>\n",
            "\t<array>\n",
            "\t\t<string>{exe}</string>\n",
            "\t\t<string>server</string>\n",
            "\t</array>{environment}\n",
            "\t<key>RunAtLoad</key>\n",
            "\t<true/>\n",
            "\t<key>KeepAlive</key>\n",
            "\t<true/>\n",
            "\t<key>StandardOutPath</key>\n",
            "\t<string>{stdout}</string>\n",
            "\t<key>StandardErrorPath</key>\n",
            "\t<string>{stderr}</string>\n",
            "</dict>\n",
            "</plist>\n"
        ),
        label = LAUNCH_AGENT_LABEL,
        exe = executable.display(),
        environment = environment,
        stdout = stdout_log.display(),
        stderr = stderr_log.display(),
    )
}

fn systemd_unit_path() -> Result<PathBuf, BoxError> {
    Ok(home_dir()?
        .join(".config")
        .join("systemd")
        .join("user")
        .join(SYSTEMD_UNIT_NAME))
}

fn launch_agent_path() -> Result<PathBuf, BoxError> {
    Ok(home_dir()?
        .join("Library")
        .join("LaunchAgents")
        .join(LAUNCH_AGENT_FILE_NAME))
}

fn launch_agent_log_path(suffix: &str) -> Result<PathBuf, BoxError> {
    Ok(home_dir()?
        .join("Library")
        .join("Logs")
        .join(format!("pimux-server.{suffix}.log")))
}

fn launchctl_domain() -> Result<String, BoxError> {
    let uid = run_command("id", &["-u"])?;
    Ok(format!("gui/{}", uid.trim()))
}

fn home_dir() -> Result<PathBuf, BoxError> {
    Ok(PathBuf::from(env::var("HOME")?))
}

fn write_file(path: &FsPath, contents: &str) -> Result<(), BoxError> {
    ensure_parent_dir(path)?;
    fs::write(path, contents)?;
    Ok(())
}

fn touch_file(path: &FsPath) -> Result<(), BoxError> {
    ensure_parent_dir(path)?;
    fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)?;
    Ok(())
}

fn ensure_parent_dir(path: &FsPath) -> Result<(), BoxError> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    Ok(())
}

fn remove_file_if_exists(path: &FsPath) -> Result<bool, BoxError> {
    if path.exists() {
        fs::remove_file(path)?;
        Ok(true)
    } else {
        Ok(false)
    }
}

fn run_command(command: &str, args: &[&str]) -> Result<String, BoxError> {
    let output = Command::new(command).args(args).output()?;
    if output.status.success() {
        return Ok(String::from_utf8_lossy(&output.stdout).trim().to_string());
    }

    let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
    let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
    let details = if !stderr.is_empty() {
        stderr
    } else if !stdout.is_empty() {
        stdout
    } else {
        format!("{command} exited with status {}", output.status)
    };
    Err(format!("{command} {}: {details}", args.join(" ")).into())
}

#[cfg(test)]
mod tests {
    use axum::{
        body::{Body, to_bytes},
        http::{Method, Request, header},
    };
    use chrono::{Duration as ChronoDuration, TimeZone, Utc};
    use serde::{Serialize, de::DeserializeOwned};
    use tower::util::ServiceExt;

    use crate::{
        host::{HostAuth, HostIdentity, HostSessions},
        message::{
            ImageContent, Message as TranscriptMessage, MessageContentBlock, Role,
            image_attachment_id,
        },
        session::{ActiveSession, ListedSession},
        transcript::{SessionActivity, TranscriptFreshness},
    };

    use super::*;

    #[tokio::test]
    async fn reports_hosts_and_sessions() {
        let state = AppState::default();
        update_host_snapshot(
            &state,
            HostIdentity {
                location: "dev@mac".to_string(),
                auth: HostAuth::None,
            },
            vec![sample_active_session("session-1")],
        )
        .await;

        let app = app(state);
        let response = app
            .oneshot(empty_request(Method::GET, "/hosts"))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);

        let hosts: Vec<HostSessions> = json_response(response).await;
        assert_eq!(hosts.len(), 1);
        assert_eq!(hosts[0].location, "dev@mac");
        assert_eq!(hosts[0].auth, HostAuth::None);
        assert!(hosts[0].connected);
        assert!(!hosts[0].missing);
        assert!(hosts[0].last_seen_at.is_some());
        assert_eq!(hosts[0].sessions.len(), 1);
        assert_eq!(hosts[0].sessions[0].id, "session-1");
    }

    #[tokio::test]
    async fn keeps_disconnected_hosts_as_missing() {
        let state = AppState::default();
        let host = HostIdentity {
            location: "dev@mac".to_string(),
            auth: HostAuth::None,
        };
        update_host_snapshot(
            &state,
            host.clone(),
            vec![sample_active_session("session-1")],
        )
        .await;
        let _receiver = register_test_agent(&state, host.clone()).await;
        disconnect_agent(&state, &host.location, 1).await;

        let app = app(state);
        let response = app
            .oneshot(empty_request(Method::GET, "/hosts"))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);

        let hosts: Vec<HostSessions> = json_response(response).await;
        assert_eq!(hosts.len(), 1);
        assert_eq!(hosts[0].location, "dev@mac");
        assert!(!hosts[0].connected);
        assert!(hosts[0].missing);
        assert!(hosts[0].last_seen_at.is_some());
        assert_eq!(hosts[0].sessions.len(), 1);
        assert_eq!(hosts[0].sessions[0].id, "session-1");
    }


    #[tokio::test]
    async fn returns_default_page_of_sessions() {
        let state = AppState::default();
        let mut all_sessions = Vec::new();
        for i in 0..30 {
            all_sessions.push(sample_active_session_with_updated(
                &format!("session-{i}"),
                Utc::now() - ChronoDuration::hours(i as i64),
            ));
        }
        update_host_snapshot(
            &state,
            HostIdentity {
                location: "dev@mac".to_string(),
                auth: HostAuth::None,
            },
            all_sessions,
        )
        .await;

        let app = app(state);
        let response = app
            .oneshot(empty_request(Method::GET, "/sessions"))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);

        let sessions: Vec<ListedSession> = json_response(response).await;
        assert_eq!(sessions.len(), 25);
        assert_eq!(sessions[0].session.id, "session-0");
        assert_eq!(sessions[24].session.id, "session-24");
    }

    #[tokio::test]
    async fn respects_count_param() {
        let state = AppState::default();
        update_host_snapshot(
            &state,
            HostIdentity {
                location: "dev@mac".to_string(),
                auth: HostAuth::None,
            },
            vec![
                sample_active_session_with_updated(
                    "session-a",
                    Utc::now() - ChronoDuration::hours(1),
                ),
                sample_active_session_with_updated(
                    "session-b",
                    Utc::now() - ChronoDuration::hours(2),
                ),
                sample_active_session_with_updated(
                    "session-c",
                    Utc::now() - ChronoDuration::hours(3),
                ),
            ],
        )
        .await;

        let app = app(state);
        let response = app
            .oneshot(empty_request(Method::GET, "/sessions?count=2"))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);

        let sessions: Vec<ListedSession> = json_response(response).await;
        assert_eq!(sessions.len(), 2);
        assert_eq!(sessions[0].session.id, "session-a");
        assert_eq!(sessions[1].session.id, "session-b");
    }

    #[tokio::test]
    async fn paginates_with_before_id() {
        let state = AppState::default();
        update_host_snapshot(
            &state,
            HostIdentity {
                location: "dev@mac".to_string(),
                auth: HostAuth::None,
            },
            vec![
                sample_active_session_with_updated(
                    "session-a",
                    Utc::now() - ChronoDuration::hours(1),
                ),
                sample_active_session_with_updated(
                    "session-b",
                    Utc::now() - ChronoDuration::hours(2),
                ),
                sample_active_session_with_updated(
                    "session-c",
                    Utc::now() - ChronoDuration::hours(3),
                ),
                sample_active_session_with_updated(
                    "session-d",
                    Utc::now() - ChronoDuration::hours(4),
                ),
            ],
        )
        .await;

        let app = app(state);
        let response = app
            .oneshot(empty_request(
                Method::GET,
                "/sessions?count=2&before_id=session-b",
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);

        let sessions: Vec<ListedSession> = json_response(response).await;
        assert_eq!(sessions.len(), 2);
        assert_eq!(sessions[0].session.id, "session-c");
        assert_eq!(sessions[1].session.id, "session-d");
    }

    #[tokio::test]
    async fn before_id_not_found_returns_400() {
        let state = AppState::default();
        update_host_snapshot(
            &state,
            HostIdentity {
                location: "dev@mac".to_string(),
                auth: HostAuth::None,
            },
            vec![sample_active_session_with_updated(
                "session-a",
                Utc::now() - ChronoDuration::hours(1),
            )],
        )
        .await;

        let app = app(state);
        let response = app
            .oneshot(empty_request(
                Method::GET,
                "/sessions?before_id=nonexistent",
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    }

    #[tokio::test]
    async fn deduplicates_sessions_by_id_preferring_connected_host() {
        let state = AppState::default();
        let connected_updated_at = Utc::now() - ChronoDuration::hours(2);
        let missing_updated_at = Utc::now() - ChronoDuration::hours(1);
        let connected_host = HostIdentity {
            location: "dev@mac".to_string(),
            auth: HostAuth::None,
        };
        let missing_host = HostIdentity {
            location: "tester@host".to_string(),
            auth: HostAuth::None,
        };
        let connected_session =
            sample_active_session_with_updated("session-1", connected_updated_at);
        let missing_session = sample_active_session_with_updated("session-1", missing_updated_at);

        {
            let mut hosts = state.hosts.write().await;
            hosts.insert(
                missing_host.location.clone(),
                HostRecord {
                    host: missing_host,
                    sessions: vec![missing_session],
                    connected: false,
                    last_seen_at: Some(Utc::now() - ChronoDuration::minutes(30)),
                },
            );
            hosts.insert(
                connected_host.location.clone(),
                HostRecord {
                    host: connected_host,
                    sessions: vec![connected_session],
                    connected: true,
                    last_seen_at: Some(Utc::now() - ChronoDuration::minutes(5)),
                },
            );
        }

        let app = app(state);
        let response = app
            .oneshot(empty_request(Method::GET, "/sessions"))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);

        let sessions: Vec<ListedSession> = json_response(response).await;
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0].session.id, "session-1");
        assert_eq!(sessions[0].host_location, "dev@mac");
        assert!(sessions[0].host_connected);
    }

    #[tokio::test]
    async fn before_id_at_end_returns_empty() {
        let state = AppState::default();
        update_host_snapshot(
            &state,
            HostIdentity {
                location: "dev@mac".to_string(),
                auth: HostAuth::None,
            },
            vec![sample_active_session_with_updated(
                "only-session",
                Utc::now() - ChronoDuration::hours(1),
            )],
        )
        .await;

        let app = app(state);
        let response = app
            .oneshot(empty_request(
                Method::GET,
                "/sessions?before_id=only-session",
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);

        let sessions: Vec<ListedSession> = json_response(response).await;
        assert!(sessions.is_empty());
    }

    #[tokio::test]
    async fn returns_cached_transcript_snapshot() {
        let state = AppState::default();
        {
            let mut transcripts = state.transcripts.write().await;
            upsert_cached_transcript(
                &mut transcripts,
                "dev@mac".to_string(),
                sample_transcript(
                    "session-1",
                    "cached transcript",
                    TranscriptFreshnessState::Live,
                    TranscriptSource::Extension,
                    true,
                    true,
                    2_000,
                ),
            );
        }

        let app = app(state);
        let response = app
            .oneshot(empty_request(Method::GET, "/sessions/session-1/messages"))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
    }

    #[tokio::test]
    async fn fetches_transcript_on_cache_miss() {
        let state = AppState::default();
        let host = HostIdentity {
            location: "dev@mac".to_string(),
            auth: HostAuth::None,
        };
        update_host_snapshot(
            &state,
            host.clone(),
            vec![sample_active_session("session-1")],
        )
        .await;
        let mut receiver = register_test_agent(&state, host.clone()).await;

        let waiter = tokio::spawn({
            let state = state.clone();
            async move {
                session_messages(State(state), Path("session-1".to_string()))
                    .await
                    .unwrap()
                    .0
            }
        });

        let message = receiver.recv().await.unwrap();
        let request_id = match message {
            ServerToAgentMessage::FetchTranscript {
                request_id,
                session_id,
            } => {
                assert_eq!(session_id, "session-1");
                request_id
            }
            other => panic!("unexpected message: {other:?}"),
        };

        fulfill_fetch_result(
            &state,
            &host.location,
            &request_id,
            Some(sample_transcript(
                "session-1",
                "fetched transcript",
                TranscriptFreshnessState::Live,
                TranscriptSource::Extension,
                true,
                true,
                3_000,
            )),
            None,
        )
        .await;

        let returned = waiter.await.unwrap();
        assert_eq!(returned.session_id, "session-1");
        assert_eq!(returned.messages[0].body, "fetched transcript");
    }

    #[tokio::test]
    async fn queues_send_message_for_connected_host() {
        let state = AppState::default();
        let host = HostIdentity {
            location: "dev@mac".to_string(),
            auth: HostAuth::None,
        };
        update_host_snapshot(
            &state,
            host.clone(),
            vec![sample_active_session("session-1")],
        )
        .await;
        let mut receiver = register_test_agent(&state, host.clone()).await;
        let app = app(state.clone());

        let waiter = tokio::spawn(async move {
            app.oneshot(json_request(
                Method::POST,
                "/sessions/session-1/messages",
                &SendMessageRequest {
                    body: "hello".to_string(),
                    images: Vec::new(),
                },
            ))
            .await
            .unwrap()
        });

        let message = receiver.recv().await.unwrap();
        let request_id = match message {
            ServerToAgentMessage::SendMessage {
                request_id,
                session_id,
                body,
                images,
            } => {
                assert_eq!(session_id, "session-1");
                assert_eq!(body, "hello");
                assert!(images.is_empty());
                request_id
            }
            other => panic!("unexpected message: {other:?}"),
        };

        fulfill_send_result(&state, &host.location, &request_id, None).await;
        let response = waiter.await.unwrap();
        assert_eq!(response.status(), StatusCode::NO_CONTENT);
    }

    #[tokio::test]
    async fn message_snapshots_expose_attachment_ids_without_inline_data() {
        let state = AppState::default();
        let response = sample_image_transcript("session-1");
        {
            let mut transcripts = state.transcripts.write().await;
            upsert_cached_transcript(&mut transcripts, "dev@mac".to_string(), response);
        }

        let response = session_messages(State(state), Path("session-1".to_string()))
            .await
            .unwrap()
            .0;
        let payload = serde_json::to_value(&response).unwrap();
        let block = &payload["messages"][0]["blocks"][0];

        assert_eq!(block["type"], "image");
        assert_eq!(block["mimeType"], "image/png");
        assert_eq!(
            block["attachmentId"],
            image_attachment_id("image/png", "ZmFrZQ==")
        );
        assert!(block.get("data").is_none());
    }

    #[tokio::test]
    async fn attachment_endpoint_returns_image_bytes() {
        let state = AppState::default();
        let response = sample_image_transcript("session-1");
        let attachment_id = image_attachment_id("image/png", "ZmFrZQ==");
        {
            let mut transcripts = state.transcripts.write().await;
            upsert_cached_transcript(&mut transcripts, "dev@mac".to_string(), response);
        }

        let app = app(state.clone());
        let response = app
            .oneshot(empty_request(
                Method::GET,
                &format!("/sessions/session-1/attachments/{attachment_id}"),
            ))
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(
            response.headers().get(header::CONTENT_TYPE).unwrap(),
            "image/png"
        );
        let body = to_bytes(response.into_body(), usize::MAX).await.unwrap();
        assert_eq!(&body[..], b"fake");
    }

    #[tokio::test]
    async fn accepts_image_only_send_messages() {
        let state = AppState::default();
        let host = HostIdentity {
            location: "dev@mac".to_string(),
            auth: HostAuth::None,
        };
        update_host_snapshot(
            &state,
            host.clone(),
            vec![sample_active_session("session-1")],
        )
        .await;
        let mut receiver = register_test_agent(&state, host.clone()).await;
        let app = app(state.clone());

        let waiter = tokio::spawn(async move {
            app.oneshot(json_request(
                Method::POST,
                "/sessions/session-1/messages",
                &SendMessageRequest {
                    body: String::new(),
                    images: vec![ImageContent::new("image/png", "ZmFrZQ==")],
                },
            ))
            .await
            .unwrap()
        });

        let message = receiver.recv().await.unwrap();
        let request_id = match message {
            ServerToAgentMessage::SendMessage {
                request_id,
                session_id,
                body,
                images,
            } => {
                assert_eq!(session_id, "session-1");
                assert_eq!(body, "");
                assert_eq!(images.len(), 1);
                assert_eq!(images[0], ImageContent::new("image/png", "ZmFrZQ=="));
                request_id
            }
            other => panic!("unexpected message: {other:?}"),
        };

        fulfill_send_result(&state, &host.location, &request_id, None).await;
        let response = waiter.await.unwrap();
        assert_eq!(response.status(), StatusCode::NO_CONTENT);
    }

    #[tokio::test]
    async fn rejects_send_message_when_body_and_images_are_empty() {
        let state = AppState::default();
        let host = HostIdentity {
            location: "dev@mac".to_string(),
            auth: HostAuth::None,
        };
        update_host_snapshot(&state, host, vec![sample_active_session("session-1")]).await;
        let app = app(state.clone());

        let response = app
            .oneshot(json_request(
                Method::POST,
                "/sessions/session-1/messages",
                &SendMessageRequest::default(),
            ))
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::BAD_REQUEST);
        let body = to_bytes(response.into_body(), usize::MAX).await.unwrap();
        let payload: ErrorResponse = serde_json::from_slice(&body).unwrap();
        assert_eq!(
            payload.error,
            "message body or images must not both be empty"
        );
    }

    #[tokio::test]
    async fn prefers_live_snapshot_over_equally_fresh_persisted_snapshot() {
        let live = sample_transcript(
            "session-1",
            "live transcript",
            TranscriptFreshnessState::Live,
            TranscriptSource::Extension,
            true,
            true,
            4_000,
        );
        let persisted = sample_transcript(
            "session-1",
            "persisted transcript",
            TranscriptFreshnessState::LiveUnknown,
            TranscriptSource::File,
            false,
            false,
            4_000,
        );

        let mut transcripts = HashMap::new();
        upsert_cached_transcript(&mut transcripts, "dev@mac".to_string(), live.clone());
        upsert_cached_transcript(&mut transcripts, "dev@mac".to_string(), persisted);
        assert_eq!(transcripts.get("session-1").unwrap().response, live);
    }

    #[tokio::test]
    async fn replaces_equally_fresh_attached_snapshot_with_detached_snapshot() {
        let attached = sample_transcript(
            "session-1",
            "final live reply",
            TranscriptFreshnessState::Live,
            TranscriptSource::Extension,
            true,
            true,
            4_000,
        );
        let detached = sample_transcript(
            "session-1",
            "final live reply",
            TranscriptFreshnessState::Live,
            TranscriptSource::Extension,
            false,
            false,
            4_000,
        );

        let mut transcripts = HashMap::new();
        upsert_cached_transcript(&mut transcripts, "dev@mac".to_string(), attached);
        upsert_cached_transcript(&mut transcripts, "dev@mac".to_string(), detached.clone());
        assert_eq!(transcripts.get("session-1").unwrap().response, detached);
    }

    #[test]
    fn persists_and_loads_expected_hosts() {
        let path = unique_test_path("expected-hosts.json");
        let host = HostIdentity {
            location: "dev@mac".to_string(),
            auth: HostAuth::Pk,
        };
        let mut hosts = HashMap::new();
        hosts.insert(
            host.location.clone(),
            HostRecord {
                host: host.clone(),
                sessions: vec![sample_active_session("session-1")],
                connected: true,
                last_seen_at: Some(timestamp(5_000)),
            },
        );

        persist_host_registry(&path, &hosts).unwrap();
        let loaded = load_host_registry(&path).unwrap();
        let record = loaded.get(&host.location).unwrap();
        assert_eq!(record.host, host);
        assert_eq!(record.sessions.len(), 1);
        assert_eq!(record.sessions[0].id, "session-1");
        assert!(!record.connected);
        assert_eq!(record.last_seen_at, Some(timestamp(5_000)));

        let _ = std::fs::remove_file(&path);
        let _ = path.parent().map(std::fs::remove_dir_all);
    }

    async fn register_test_agent(
        state: &AppState,
        host: HostIdentity,
    ) -> mpsc::UnboundedReceiver<ServerToAgentMessage> {
        let (sender, receiver) = mpsc::unbounded_channel();
        let (close_sender, _close_receiver) = mpsc::unbounded_channel();
        let _ = register_agent_connection(state, &host, 1, sender, close_sender).await;
        receiver
    }

    fn sample_active_session(id: &str) -> ActiveSession {
        sample_active_session_with_updated(id, timestamp(2_500))
    }

    fn sample_active_session_with_updated(
        id: &str,
        updated_at: chrono::DateTime<Utc>,
    ) -> ActiveSession {
        ActiveSession {
            id: id.to_string(),
            summary: "Sample session".to_string(),
            created_at: timestamp(1_000),
            updated_at,
            last_user_message_at: timestamp(1_500),
            last_assistant_message_at: timestamp(2_000),
            cwd: "/tmp/project".to_string(),
            model: "anthropic/claude-sonnet-4-5".to_string(),
            context_usage: None,
        }
    }

    fn sample_transcript(
        session_id: &str,
        body: &str,
        state: TranscriptFreshnessState,
        source: TranscriptSource,
        active: bool,
        attached: bool,
        millis: i64,
    ) -> SessionMessagesResponse {
        SessionMessagesResponse {
            session_id: session_id.to_string(),
            messages: vec![TranscriptMessage {
                created_at: timestamp(millis),
                role: Role::Assistant,
                body: body.to_string(),
                blocks: vec![MessageContentBlock::text(body).unwrap()],
            }],
            freshness: TranscriptFreshness {
                state,
                source,
                as_of: timestamp(millis),
            },
            activity: SessionActivity { active, attached },
            warnings: Vec::new(),
        }
    }

    fn sample_image_transcript(session_id: &str) -> SessionMessagesResponse {
        SessionMessagesResponse {
            session_id: session_id.to_string(),
            messages: vec![TranscriptMessage {
                created_at: timestamp(2_500),
                role: Role::User,
                body: "[Image]".to_string(),
                blocks: vec![MessageContentBlock::image(
                    Some("image/png"),
                    Some("ZmFrZQ=="),
                )],
            }],
            freshness: TranscriptFreshness {
                state: TranscriptFreshnessState::Live,
                source: TranscriptSource::Extension,
                as_of: timestamp(2_500),
            },
            activity: SessionActivity {
                active: true,
                attached: true,
            },
            warnings: Vec::new(),
        }
    }

    #[test]
    fn sanitizes_mdns_host_label() {
        assert_eq!(sanitize_mdns_host_label("My Mac_Studio"), "my-mac-studio");
        assert_eq!(sanitize_mdns_host_label("---"), "");
    }

    fn timestamp(millis: i64) -> chrono::DateTime<Utc> {
        Utc.timestamp_millis_opt(millis).single().unwrap()
    }

    fn unique_test_path(name: &str) -> PathBuf {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        std::env::temp_dir()
            .join(format!("pimux-server-test-{}-{nanos}", std::process::id()))
            .join(name)
    }

    fn empty_request(method: Method, uri: &str) -> Request<Body> {
        Request::builder()
            .method(method)
            .uri(uri)
            .body(Body::empty())
            .unwrap()
    }

    fn json_request<T>(method: Method, uri: &str, payload: &T) -> Request<Body>
    where
        T: Serialize,
    {
        Request::builder()
            .method(method)
            .uri(uri)
            .header("content-type", "application/json")
            .body(Body::from(serde_json::to_vec(payload).unwrap()))
            .unwrap()
    }

    async fn json_response<T>(response: axum::response::Response) -> T
    where
        T: DeserializeOwned,
    {
        let bytes = to_bytes(response.into_body(), usize::MAX).await.unwrap();
        serde_json::from_slice(&bytes).unwrap()
    }
}
