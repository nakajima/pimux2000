use std::{
    collections::{HashMap, VecDeque},
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
};

use axum::{
    Json, Router,
    extract::{Path, Query, State},
    http::StatusCode,
    routing::{get, post},
};
use serde::Serialize;
use tokio::{
    sync::{Mutex, RwLock, oneshot},
    time::{Duration, timeout},
};

use crate::{
    host::{HostIdentity, HostSessions},
    report::{ReportPayload, VersionResponse},
    transcript::{
        PendingTranscriptRequest, PendingTranscriptRequestsResponse, SessionMessagesBatchReport,
        SessionMessagesResponse, TranscriptFetchFulfillment, TranscriptFetchQuery,
        TranscriptFreshnessState, TranscriptSource,
    },
};

type BoxError = Box<dyn std::error::Error + Send + Sync>;
type FetchResult = Result<SessionMessagesResponse, String>;
const ON_DEMAND_FETCH_TIMEOUT: Duration = Duration::from_secs(5);

#[derive(Clone)]
struct AppState {
    hosts: Arc<RwLock<HashMap<String, HostRecord>>>,
    transcripts: Arc<RwLock<HashMap<String, CachedTranscript>>>,
    pending_fetches: Arc<Mutex<HashMap<String, VecDeque<PendingTranscriptRequest>>>>,
    inflight_fetches: Arc<Mutex<HashMap<String, oneshot::Sender<FetchResult>>>>,
    next_request_id: Arc<AtomicU64>,
}

impl Default for AppState {
    fn default() -> Self {
        Self {
            hosts: Arc::new(RwLock::new(HashMap::new())),
            transcripts: Arc::new(RwLock::new(HashMap::new())),
            pending_fetches: Arc::new(Mutex::new(HashMap::new())),
            inflight_fetches: Arc::new(Mutex::new(HashMap::new())),
            next_request_id: Arc::new(AtomicU64::new(1)),
        }
    }
}

#[derive(Clone)]
struct HostRecord {
    host: HostIdentity,
    sessions: Vec<crate::session::ActiveSession>,
}

#[derive(Clone)]
struct CachedTranscript {
    host_location: String,
    response: SessionMessagesResponse,
}

#[derive(Debug, Serialize)]
struct ErrorResponse {
    error: String,
}

pub async fn start() -> Result<(), BoxError> {
    let app = app(AppState::default());
    let port = port_from_env()?;

    let listener = tokio::net::TcpListener::bind(("0.0.0.0", port)).await?;
    println!("server listening on http://{}", listener.local_addr()?);

    axum::serve(listener, app).await?;

    Ok(())
}

fn app(state: AppState) -> Router {
    Router::new()
        .route("/health", get(health))
        .route("/version", get(version))
        .route("/report", post(report))
        .route("/hosts", get(hosts))
        .route("/sessions/{id}/messages", get(session_messages))
        .route("/agent/session-messages", post(report_session_messages))
        .route(
            "/agent/session-messages/pending",
            get(pending_session_message_requests),
        )
        .route(
            "/agent/session-messages/fetch-response",
            post(fulfill_session_message_request),
        )
        .with_state(state)
}

fn port_from_env() -> Result<u16, BoxError> {
    match std::env::var("PORT") {
        Ok(value) => Ok(value.parse()?),
        Err(std::env::VarError::NotPresent) => Ok(3000),
        Err(err) => Err(Box::new(err)),
    }
}

async fn health() -> &'static str {
    "OK"
}

async fn version() -> Json<VersionResponse> {
    Json(VersionResponse {
        version: env!("CARGO_PKG_VERSION").to_string(),
    })
}

async fn report(State(state): State<AppState>, Json(payload): Json<ReportPayload>) -> StatusCode {
    let mut hosts = state.hosts.write().await;
    hosts.insert(
        payload.host.location.clone(),
        HostRecord {
            host: payload.host,
            sessions: payload.active_sessions,
        },
    );

    StatusCode::NO_CONTENT
}

async fn report_session_messages(
    State(state): State<AppState>,
    Json(payload): Json<SessionMessagesBatchReport>,
) -> StatusCode {
    let mut transcripts = state.transcripts.write().await;
    for session in payload.sessions {
        upsert_cached_transcript(&mut transcripts, payload.host_location.clone(), session);
    }

    StatusCode::NO_CONTENT
}

async fn pending_session_message_requests(
    State(state): State<AppState>,
    Query(query): Query<TranscriptFetchQuery>,
) -> Json<PendingTranscriptRequestsResponse> {
    let mut pending_fetches = state.pending_fetches.lock().await;
    let requests = pending_fetches
        .remove(&query.host_location)
        .map(VecDeque::into_iter)
        .map(Iterator::collect)
        .unwrap_or_default();

    Json(PendingTranscriptRequestsResponse { requests })
}

async fn fulfill_session_message_request(
    State(state): State<AppState>,
    Json(payload): Json<TranscriptFetchFulfillment>,
) -> StatusCode {
    if let Some(session) = payload.session.clone() {
        let mut transcripts = state.transcripts.write().await;
        upsert_cached_transcript(&mut transcripts, payload.host_location.clone(), session);
    }

    let mut inflight_fetches = state.inflight_fetches.lock().await;
    if let Some(sender) = inflight_fetches.remove(&payload.request_id) {
        let result = match (payload.session, payload.error) {
            (Some(session), _) => Ok(session),
            (None, Some(error)) => Err(error),
            (None, None) => Err("agent returned an empty fetch response".to_string()),
        };
        let _ = sender.send(result);
    }

    StatusCode::NO_CONTENT
}

async fn hosts(State(state): State<AppState>) -> Json<Vec<HostSessions>> {
    let hosts = state.hosts.read().await;
    let mut response = hosts
        .values()
        .map(|record| HostSessions {
            location: record.host.location.clone(),
            sessions: record.sessions.clone(),
        })
        .collect::<Vec<_>>();

    response.sort_by(|left, right| left.location.cmp(&right.location));
    Json(response)
}

async fn session_messages(
    State(state): State<AppState>,
    Path(session_id): Path<String>,
) -> Result<Json<SessionMessagesResponse>, (StatusCode, Json<ErrorResponse>)> {
    if let Some(cached) = cached_transcript(&state, &session_id).await {
        let _host_location = &cached.host_location;
        return Ok(Json(cached.response));
    }

    let Some(host_location) = host_for_session(&state, &session_id).await else {
        return Err((
            StatusCode::NOT_FOUND,
            Json(ErrorResponse {
                error: format!("session {session_id} is not known to the server"),
            }),
        ));
    };

    let (request_id, receiver) = enqueue_fetch(&state, &host_location, &session_id).await;
    let result = timeout(ON_DEMAND_FETCH_TIMEOUT, receiver).await;

    match result {
        Ok(Ok(Ok(session))) => Ok(Json(session)),
        Ok(Ok(Err(error))) => Err((
            status_for_fetch_error(&error),
            Json(ErrorResponse { error }),
        )),
        Ok(Err(_)) => Err((
            StatusCode::BAD_GATEWAY,
            Json(ErrorResponse {
                error: format!(
                    "host {} disconnected before fulfilling transcript fetch for session {}",
                    host_location, session_id
                ),
            }),
        )),
        Err(_) => {
            cancel_fetch(&state, &request_id).await;
            Err((
                StatusCode::GATEWAY_TIMEOUT,
                Json(ErrorResponse {
                    error: format!(
                        "timed out waiting for host {} to provide transcript for session {}",
                        host_location, session_id
                    ),
                }),
            ))
        }
    }
}

async fn cached_transcript(state: &AppState, session_id: &str) -> Option<CachedTranscript> {
    let transcripts = state.transcripts.read().await;
    transcripts.get(session_id).cloned()
}

async fn host_for_session(state: &AppState, session_id: &str) -> Option<String> {
    let hosts = state.hosts.read().await;
    hosts.values().find_map(|record| {
        record
            .sessions
            .iter()
            .any(|session| session.id == session_id)
            .then(|| record.host.location.clone())
    })
}

async fn enqueue_fetch(
    state: &AppState,
    host_location: &str,
    session_id: &str,
) -> (String, oneshot::Receiver<FetchResult>) {
    let request_id = format!(
        "fetch-{}",
        state.next_request_id.fetch_add(1, Ordering::Relaxed)
    );
    let request = PendingTranscriptRequest {
        request_id: request_id.clone(),
        session_id: session_id.to_string(),
    };
    let (sender, receiver) = oneshot::channel();

    {
        let mut inflight_fetches = state.inflight_fetches.lock().await;
        inflight_fetches.insert(request_id.clone(), sender);
    }

    {
        let mut pending_fetches = state.pending_fetches.lock().await;
        pending_fetches
            .entry(host_location.to_string())
            .or_default()
            .push_back(request);
    }

    (request_id, receiver)
}

async fn cancel_fetch(state: &AppState, request_id: &str) {
    let mut inflight_fetches = state.inflight_fetches.lock().await;
    inflight_fetches.remove(request_id);
}

fn upsert_cached_transcript(
    transcripts: &mut HashMap<String, CachedTranscript>,
    host_location: String,
    response: SessionMessagesResponse,
) {
    let session_id = response.session_id.clone();

    match transcripts.get_mut(&session_id) {
        Some(existing)
            if !should_replace_cached_transcript(existing, &host_location, &response) => {}
        Some(existing) => {
            *existing = CachedTranscript {
                host_location,
                response,
            };
        }
        None => {
            transcripts.insert(
                session_id,
                CachedTranscript {
                    host_location,
                    response,
                },
            );
        }
    }
}

fn should_replace_cached_transcript(
    existing: &CachedTranscript,
    _incoming_host_location: &str,
    incoming: &SessionMessagesResponse,
) -> bool {
    let incoming_score = transcript_score(incoming);
    let existing_score = transcript_score(&existing.response);

    incoming_score >= existing_score
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

fn status_for_fetch_error(error: &str) -> StatusCode {
    if error.contains("was not found") {
        StatusCode::NOT_FOUND
    } else {
        StatusCode::BAD_GATEWAY
    }
}

#[cfg(test)]
mod tests {
    use axum::{
        body::{Body, to_bytes},
        extract::{Path, State},
        http::{Method, Request},
    };
    use chrono::{TimeZone, Utc};
    use serde::{Serialize, de::DeserializeOwned};
    use tower::util::ServiceExt;

    use crate::{
        host::{HostAuth, HostIdentity, HostSessions},
        message::{Message, Role},
        session::ActiveSession,
        transcript::{
            PendingTranscriptRequestsResponse, SessionActivity, SessionMessagesBatchReport,
            SessionMessagesResponse, TranscriptFetchFulfillment, TranscriptFreshness,
        },
    };

    use super::*;

    #[tokio::test]
    async fn reports_hosts_and_sessions() {
        let app = app(AppState::default());
        let report = ReportPayload {
            host: HostIdentity {
                location: "dev@mac".to_string(),
                auth: HostAuth::None,
            },
            active_sessions: vec![sample_active_session("session-1")],
        };

        let response = app
            .clone()
            .oneshot(json_request(Method::POST, "/report", &report))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::NO_CONTENT);

        let response = app
            .oneshot(empty_request(Method::GET, "/hosts"))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);

        let hosts: Vec<HostSessions> = json_response(response).await;
        assert_eq!(hosts.len(), 1);
        assert_eq!(hosts[0].location, "dev@mac");
        assert_eq!(hosts[0].sessions.len(), 1);
        assert_eq!(hosts[0].sessions[0].id, "session-1");
    }

    #[tokio::test]
    async fn returns_cached_transcript_snapshot() {
        let app = app(AppState::default());
        let snapshot = sample_transcript(
            "session-1",
            "cached transcript",
            TranscriptFreshnessState::Live,
            TranscriptSource::Extension,
            true,
            true,
            2_000,
        );
        let report = SessionMessagesBatchReport {
            host_location: "dev@mac".to_string(),
            sessions: vec![snapshot.clone()],
        };

        let response = app
            .clone()
            .oneshot(json_request(
                Method::POST,
                "/agent/session-messages",
                &report,
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::NO_CONTENT);

        let response = app
            .oneshot(empty_request(Method::GET, "/sessions/session-1/messages"))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);

        let returned: SessionMessagesResponse = json_response(response).await;
        assert_eq!(returned, snapshot);
    }

    #[tokio::test]
    async fn fetches_transcript_on_cache_miss() {
        let state = AppState::default();
        let app = app(state.clone());
        let payload = ReportPayload {
            host: HostIdentity {
                location: "dev@mac".to_string(),
                auth: HostAuth::None,
            },
            active_sessions: vec![sample_active_session("session-1")],
        };

        let response = report(State(state.clone()), Json(payload)).await;
        assert_eq!(response, StatusCode::NO_CONTENT);
        assert_eq!(
            host_for_session(&state, "session-1").await,
            Some("dev@mac".to_string())
        );

        let snapshot = sample_transcript(
            "session-1",
            "fetched transcript",
            TranscriptFreshnessState::Live,
            TranscriptSource::Extension,
            true,
            true,
            3_000,
        );

        let waiter = tokio::spawn({
            let state = state.clone();
            async move {
                session_messages(State(state), Path("session-1".to_string()))
                    .await
                    .unwrap()
                    .0
            }
        });

        let pending = poll_pending_requests(&app, "dev@mac").await;
        assert_eq!(pending.requests.len(), 1);
        assert_eq!(pending.requests[0].session_id, "session-1");

        let fulfillment = TranscriptFetchFulfillment {
            request_id: pending.requests[0].request_id.clone(),
            host_location: "dev@mac".to_string(),
            session: Some(snapshot.clone()),
            error: None,
        };

        let response = app
            .clone()
            .oneshot(json_request(
                Method::POST,
                "/agent/session-messages/fetch-response",
                &fulfillment,
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::NO_CONTENT);

        let returned = waiter.await.unwrap();
        assert_eq!(returned, snapshot);
    }

    #[tokio::test]
    async fn prefers_live_snapshot_over_equally_fresh_persisted_snapshot() {
        let app = app(AppState::default());
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

        let response = app
            .clone()
            .oneshot(json_request(
                Method::POST,
                "/agent/session-messages",
                &SessionMessagesBatchReport {
                    host_location: "dev@mac".to_string(),
                    sessions: vec![live.clone()],
                },
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::NO_CONTENT);

        let response = app
            .clone()
            .oneshot(json_request(
                Method::POST,
                "/agent/session-messages",
                &SessionMessagesBatchReport {
                    host_location: "dev@mac".to_string(),
                    sessions: vec![persisted],
                },
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::NO_CONTENT);

        let response = app
            .oneshot(empty_request(Method::GET, "/sessions/session-1/messages"))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);

        let returned: SessionMessagesResponse = json_response(response).await;
        assert_eq!(returned, live);
    }

    #[tokio::test]
    async fn replaces_equally_fresh_attached_snapshot_with_detached_snapshot() {
        let app = app(AppState::default());
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

        let response = app
            .clone()
            .oneshot(json_request(
                Method::POST,
                "/agent/session-messages",
                &SessionMessagesBatchReport {
                    host_location: "dev@mac".to_string(),
                    sessions: vec![attached],
                },
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::NO_CONTENT);

        let response = app
            .clone()
            .oneshot(json_request(
                Method::POST,
                "/agent/session-messages",
                &SessionMessagesBatchReport {
                    host_location: "dev@mac".to_string(),
                    sessions: vec![detached.clone()],
                },
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::NO_CONTENT);

        let response = app
            .oneshot(empty_request(Method::GET, "/sessions/session-1/messages"))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);

        let returned: SessionMessagesResponse = json_response(response).await;
        assert_eq!(returned, detached);
    }

    async fn poll_pending_requests(
        app: &Router,
        host_location: &str,
    ) -> PendingTranscriptRequestsResponse {
        for _ in 0..20 {
            tokio::time::sleep(Duration::from_millis(10)).await;
            let response = app
                .clone()
                .oneshot(empty_request(
                    Method::GET,
                    &format!("/agent/session-messages/pending?hostLocation={host_location}"),
                ))
                .await
                .unwrap();

            if response.status() != StatusCode::OK {
                continue;
            }

            let pending: PendingTranscriptRequestsResponse = json_response(response).await;
            if !pending.requests.is_empty() {
                return pending;
            }
        }

        panic!("no pending transcript requests were queued");
    }

    fn sample_active_session(id: &str) -> ActiveSession {
        ActiveSession {
            id: id.to_string(),
            summary: "Sample session".to_string(),
            created_at: timestamp(1_000),
            last_user_message_at: timestamp(1_500),
            last_assistant_message_at: timestamp(2_000),
            cwd: "/tmp/project".to_string(),
            model: "anthropic/claude-sonnet-4-5".to_string(),
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
            messages: vec![Message {
                created_at: timestamp(millis),
                role: Role::Assistant,
                body: body.to_string(),
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

    fn timestamp(millis: i64) -> chrono::DateTime<Utc> {
        Utc.timestamp_millis_opt(millis).single().unwrap()
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
