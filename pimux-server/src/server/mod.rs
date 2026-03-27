use std::{collections::HashMap, sync::Arc};

use axum::{
    Json, Router,
    extract::State,
    http::StatusCode,
    routing::{get, post},
};
use tokio::sync::RwLock;

use crate::{
    host::HostSessions,
    report::{ReportPayload, VersionResponse},
};

type BoxError = Box<dyn std::error::Error + Send + Sync>;

#[derive(Clone, Default)]
struct AppState {
    hosts: Arc<RwLock<HashMap<String, HostRecord>>>,
}

#[derive(Clone)]
struct HostRecord {
    sessions: Vec<crate::session::ActiveSession>,
}

pub async fn start() -> Result<(), BoxError> {
    let app = Router::new()
        .route("/health", get(health))
        .route("/version", get(version))
        .route("/report", post(report))
        .route("/hosts", get(hosts))
        .with_state(AppState::default());
    let port = port_from_env()?;

    let listener = tokio::net::TcpListener::bind(("0.0.0.0", port)).await?;
    println!("server listening on http://{}", listener.local_addr()?);

    axum::serve(listener, app).await?;

    Ok(())
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
        payload.host.location,
        HostRecord {
            sessions: payload.active_sessions,
        },
    );

    StatusCode::NO_CONTENT
}

async fn hosts(State(state): State<AppState>) -> Json<Vec<HostSessions>> {
    let hosts = state.hosts.read().await;
    let mut response = hosts
        .iter()
        .map(|(location, record)| HostSessions {
            location: location.clone(),
            sessions: record.sessions.clone(),
        })
        .collect::<Vec<_>>();

    response.sort_by(|left, right| left.location.cmp(&right.location));
    Json(response)
}
