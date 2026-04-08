use std::env;

use axum::{
    extract::{Query, State},
    http::StatusCode,
    response::{Html, IntoResponse, Response},
};
use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use chrono::{DateTime, Utc};
use sailfish::TemplateSimple;
use serde::Deserialize;
use tokio_postgres::{Client, NoTls};
use tracing::warn;

use crate::session::ActiveSession;

use super::{AppState, HostRecord, postgres_backup};

const COMMON_STYLE: &str = r#"
:root {
  color-scheme: light dark;
  --bg: #0b1020;
  --bg-elevated: #121932;
  --border: #2a365f;
  --fg: #edf2ff;
  --muted: #9aa6c6;
  --accent: #7dd3fc;
  --accent-strong: #38bdf8;
  --green: #34d399;
  --yellow: #fbbf24;
  --red: #f87171;
  --code-bg: rgba(148, 163, 184, 0.15);
  --shadow: 0 18px 50px rgba(15, 23, 42, 0.28);
  font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
}
body {
  margin: 0;
  background: linear-gradient(180deg, #0b1020 0%, #0f172a 100%);
  color: var(--fg);
}
main {
  max-width: 1180px;
  margin: 0 auto;
  padding: 32px 20px 64px;
}
a {
  color: var(--accent);
  text-decoration: none;
}
a:hover {
  color: var(--accent-strong);
  text-decoration: underline;
}
code {
  background: var(--code-bg);
  border-radius: 6px;
  padding: 0.15rem 0.35rem;
  font-size: 0.92em;
}
pre {
  margin: 0;
  white-space: pre-wrap;
  word-break: break-word;
  font: 0.95rem/1.55 ui-monospace, SFMono-Regular, SF Mono, Menlo, Consolas, monospace;
}
.page-header {
  display: flex;
  justify-content: space-between;
  align-items: flex-start;
  gap: 16px;
  margin-bottom: 24px;
}
.page-header h1 {
  margin: 0;
  font-size: clamp(1.8rem, 5vw, 2.6rem);
}
.eyebrow {
  margin: 0 0 8px;
  text-transform: uppercase;
  letter-spacing: 0.14em;
  font-size: 0.72rem;
  color: var(--accent);
}
.nav {
  display: flex;
  flex-wrap: wrap;
  gap: 10px;
}
.nav a {
  display: inline-flex;
  align-items: center;
  border: 1px solid var(--border);
  border-radius: 999px;
  padding: 0.55rem 0.9rem;
  background: rgba(15, 23, 42, 0.35);
}
.card {
  background: rgba(18, 25, 50, 0.92);
  border: 1px solid var(--border);
  border-radius: 18px;
  box-shadow: var(--shadow);
}
.stats {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(150px, 1fr));
  gap: 14px;
  margin-bottom: 22px;
}
.stat-card {
  padding: 16px;
}
.stat-label {
  display: block;
  color: var(--muted);
  font-size: 0.9rem;
  margin-bottom: 6px;
}
.stat-value {
  font-size: 1.7rem;
  font-weight: 700;
}
.stack {
  display: grid;
  gap: 18px;
}
.host-card,
.list-card,
.session-card,
.error-card {
  padding: 18px;
}
.host-header,
.row-header,
.session-header,
.message-header {
  display: flex;
  justify-content: space-between;
  align-items: flex-start;
  gap: 12px;
}
.host-header h2,
.row-header h2,
.session-header h2 {
  margin: 0;
  font-size: 1.2rem;
}
.muted,
.meta,
.empty {
  color: var(--muted);
}
.meta {
  display: block;
  margin-top: 4px;
  font-size: 0.92rem;
}
.status-pill,
.role-pill {
  display: inline-flex;
  align-items: center;
  border-radius: 999px;
  padding: 0.3rem 0.7rem;
  font-size: 0.82rem;
  font-weight: 700;
  border: 1px solid transparent;
  white-space: nowrap;
}
.status-connected {
  color: var(--green);
  background: rgba(52, 211, 153, 0.12);
  border-color: rgba(52, 211, 153, 0.35);
}
.status-missing {
  color: var(--yellow);
  background: rgba(251, 191, 36, 0.12);
  border-color: rgba(251, 191, 36, 0.35);
}
.role-user {
  color: var(--accent);
  background: rgba(56, 189, 248, 0.12);
  border-color: rgba(56, 189, 248, 0.35);
}
.role-assistant {
  color: var(--green);
  background: rgba(52, 211, 153, 0.12);
  border-color: rgba(52, 211, 153, 0.35);
}
.role-tool,
.role-other {
  color: var(--yellow);
  background: rgba(251, 191, 36, 0.12);
  border-color: rgba(251, 191, 36, 0.35);
}
.session-list,
.archive-list,
.message-list,
.key-value-list {
  list-style: none;
  margin: 14px 0 0;
  padding: 0;
}
.session-list,
.archive-list,
.message-list {
  display: grid;
  gap: 12px;
}
.session-item,
.archive-item,
.message-item {
  border: 1px solid rgba(148, 163, 184, 0.14);
  border-radius: 14px;
  padding: 14px;
  background: rgba(15, 23, 42, 0.38);
}
.message-item {
  scroll-margin-top: 18px;
}
.message-item.selected {
  border-color: rgba(125, 211, 252, 0.9);
  box-shadow: 0 0 0 1px rgba(125, 211, 252, 0.65);
}
.actions {
  display: flex;
  flex-wrap: wrap;
  gap: 12px;
  align-items: center;
}
.key-value-list {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
  gap: 12px;
}
.key-value-list li {
  padding: 12px 14px;
  border: 1px solid rgba(148, 163, 184, 0.14);
  border-radius: 14px;
  background: rgba(15, 23, 42, 0.38);
}
.key {
  display: block;
  color: var(--muted);
  font-size: 0.85rem;
  margin-bottom: 4px;
}
.message-body {
  margin-top: 12px;
}
.permalink {
  font-weight: 700;
  font-size: 1rem;
}
.callout {
  margin: 16px 0 0;
  padding: 12px 14px;
  border-radius: 14px;
  border: 1px solid rgba(125, 211, 252, 0.35);
  background: rgba(56, 189, 248, 0.09);
}
.error-card h1 {
  margin-top: 0;
}
@media (max-width: 720px) {
  .page-header,
  .host-header,
  .row-header,
  .session-header,
  .message-header {
    flex-direction: column;
  }
}
"#;
const DEFAULT_ARCHIVE_SESSION_COUNT: i64 = 100;
const MAX_ARCHIVE_SESSION_COUNT: i64 = 500;

#[derive(Debug, TemplateSimple)]
#[template(path = "web/status.stpl")]
struct StatusPageTemplate {
    common_style: &'static str,
    server_version: String,
    postgres_enabled: bool,
    tracked_hosts: usize,
    connected_hosts: usize,
    missing_hosts: usize,
    tracked_sessions: usize,
    hosts: Vec<StatusHostView>,
}

#[derive(Debug)]
struct StatusHostView {
    location: String,
    auth_label: String,
    status_label: String,
    status_class: &'static str,
    last_seen_at: String,
    session_count: usize,
    sessions: Vec<StatusSessionView>,
}

#[derive(Debug)]
struct StatusSessionView {
    id: String,
    summary: String,
    updated_at: String,
    cwd: String,
    model: String,
    json_url: String,
    archive_url: Option<String>,
}

#[derive(Debug, TemplateSimple)]
#[template(path = "web/archive_sessions.stpl")]
struct ArchiveSessionsPageTemplate {
    common_style: &'static str,
    total_sessions: usize,
    sessions: Vec<ArchiveSessionListItemView>,
}

#[derive(Debug)]
struct ArchiveSessionListItemView {
    host_location: String,
    session_id: String,
    summary: String,
    updated_at: String,
    last_seen_at: String,
    cwd: String,
    model: String,
    session_url: String,
}

#[derive(Debug, TemplateSimple)]
#[template(path = "web/archive_session.stpl")]
struct ArchiveSessionPageTemplate {
    common_style: &'static str,
    host_location: String,
    session_id: String,
    summary: String,
    host_auth: String,
    created_at: String,
    updated_at: String,
    last_user_message_at: String,
    last_assistant_message_at: String,
    last_seen_at: String,
    cwd: String,
    model: String,
    transcript_freshness: String,
    activity: String,
    message_count: usize,
    selected_message_key: Option<String>,
    selected_message_found: bool,
    messages: Vec<ArchiveMessageView>,
}

#[derive(Debug)]
struct ArchiveMessageView {
    anchor_id: String,
    message_key: String,
    created_at: String,
    role: String,
    role_class: &'static str,
    tool_name: Option<String>,
    body: String,
    is_selected: bool,
    permalink_url: String,
}

#[derive(Debug, TemplateSimple)]
#[template(path = "web/error.stpl")]
struct ErrorPageTemplate {
    common_style: &'static str,
    title: String,
    headline: String,
    message: String,
    back_url: String,
    back_label: String,
}

#[derive(Debug, Default, Deserialize)]
pub(super) struct ArchiveSessionsQuery {
    count: Option<i64>,
}

#[derive(Debug, Default, Deserialize)]
pub(super) struct ArchiveSessionQuery {
    host: Option<String>,
    id: Option<String>,
    message: Option<String>,
}

#[derive(Debug)]
struct ArchiveSessionRecord {
    host_location: String,
    session_id: String,
    host_auth: String,
    summary: Option<String>,
    created_at: Option<DateTime<Utc>>,
    updated_at: Option<DateTime<Utc>>,
    last_user_message_at: Option<DateTime<Utc>>,
    last_assistant_message_at: Option<DateTime<Utc>>,
    cwd: Option<String>,
    model: Option<String>,
    transcript_freshness_state: Option<String>,
    transcript_freshness_source: Option<String>,
    activity_active: Option<bool>,
    activity_attached: Option<bool>,
    last_seen_at: DateTime<Utc>,
}

#[derive(Debug)]
struct ArchiveMessageRecord {
    message_key: String,
    created_at: DateTime<Utc>,
    role: String,
    tool_name: Option<String>,
    body: String,
}

pub(super) async fn dashboard(State(state): State<AppState>) -> Response {
    let postgres_enabled = state.postgres_backup.is_some();
    let hosts = status_hosts(&state, postgres_enabled).await;
    let tracked_hosts = hosts.len();
    let connected_hosts = hosts
        .iter()
        .filter(|host| host.status_class == "status-connected")
        .count();
    let missing_hosts = tracked_hosts.saturating_sub(connected_hosts);
    let tracked_sessions = hosts.iter().map(|host| host.session_count).sum();

    render_html(
        StatusPageTemplate {
            common_style: COMMON_STYLE,
            server_version: env!("CARGO_PKG_VERSION").to_string(),
            postgres_enabled,
            tracked_hosts,
            connected_hosts,
            missing_hosts,
            tracked_sessions,
            hosts,
        },
        StatusCode::OK,
    )
}

pub(super) async fn archive_sessions(Query(query): Query<ArchiveSessionsQuery>) -> Response {
    let count = query
        .count
        .unwrap_or(DEFAULT_ARCHIVE_SESSION_COUNT)
        .clamp(1, MAX_ARCHIVE_SESSION_COUNT);

    let client = match connect_archive_client().await {
        Ok(client) => client,
        Err(response) => return response,
    };

    let sessions = match load_archive_sessions(&client, count).await {
        Ok(sessions) => sessions,
        Err(error) => {
            return error_response(
                StatusCode::BAD_GATEWAY,
                "archive query failed",
                &error,
                "/",
                "Back to status",
            );
        }
    };

    let views = sessions
        .into_iter()
        .map(|session| ArchiveSessionListItemView {
            session_url: archive_session_url(&session.host_location, &session.session_id, None),
            host_location: session.host_location,
            session_id: session.session_id.clone(),
            summary: display_summary(session.summary.as_deref(), &session.session_id),
            updated_at: format_optional_timestamp(session.updated_at),
            last_seen_at: format_timestamp(session.last_seen_at),
            cwd: display_optional_text(session.cwd.as_deref(), "unknown cwd"),
            model: display_optional_text(session.model.as_deref(), "unknown model"),
        })
        .collect::<Vec<_>>();
    let total_sessions = views.len();

    render_html(
        ArchiveSessionsPageTemplate {
            common_style: COMMON_STYLE,
            total_sessions,
            sessions: views,
        },
        StatusCode::OK,
    )
}

pub(super) async fn archive_session(Query(query): Query<ArchiveSessionQuery>) -> Response {
    let Some(host) = query
        .host
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
    else {
        return error_response(
            StatusCode::BAD_REQUEST,
            "missing host",
            "archive session pages require a `host` query parameter.",
            "/ui/sessions",
            "Back to archived sessions",
        );
    };
    let Some(session_id) = query
        .id
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
    else {
        return error_response(
            StatusCode::BAD_REQUEST,
            "missing session id",
            "archive session pages require an `id` query parameter.",
            "/ui/sessions",
            "Back to archived sessions",
        );
    };

    let selected_message_key = query
        .message
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_owned);

    let client = match connect_archive_client().await {
        Ok(client) => client,
        Err(response) => return response,
    };

    let session = match load_archive_session(&client, host, session_id).await {
        Ok(Some(session)) => session,
        Ok(None) => {
            return error_response(
                StatusCode::NOT_FOUND,
                "session not found",
                &format!("no archived session matched host `{host}` and session `{session_id}`."),
                "/ui/sessions",
                "Back to archived sessions",
            );
        }
        Err(error) => {
            return error_response(
                StatusCode::BAD_GATEWAY,
                "archive query failed",
                &error,
                "/ui/sessions",
                "Back to archived sessions",
            );
        }
    };

    let messages = match load_archive_messages(&client, host, session_id).await {
        Ok(messages) => messages,
        Err(error) => {
            return error_response(
                StatusCode::BAD_GATEWAY,
                "message query failed",
                &error,
                "/ui/sessions",
                "Back to archived sessions",
            );
        }
    };

    let mut selected_message_found = false;
    let message_views = messages
        .into_iter()
        .map(|message| {
            let is_selected = selected_message_key
                .as_deref()
                .map(|selected| selected == message.message_key)
                .unwrap_or(false);
            if is_selected {
                selected_message_found = true;
            }

            let message_key = message.message_key;
            ArchiveMessageView {
                anchor_id: message_anchor_id(&message_key),
                permalink_url: archive_session_url(host, session_id, Some(&message_key)),
                created_at: format_timestamp(message.created_at),
                role_class: role_class(&message.role),
                role: message.role,
                tool_name: message.tool_name,
                body: display_message_body(&message.body),
                is_selected,
                message_key,
            }
        })
        .collect::<Vec<_>>();

    render_html(
        ArchiveSessionPageTemplate {
            common_style: COMMON_STYLE,
            host_location: session.host_location,
            session_id: session.session_id.clone(),
            summary: display_summary(session.summary.as_deref(), &session.session_id),
            host_auth: session.host_auth,
            created_at: format_optional_timestamp(session.created_at),
            updated_at: format_optional_timestamp(session.updated_at),
            last_user_message_at: format_optional_timestamp(session.last_user_message_at),
            last_assistant_message_at: format_optional_timestamp(session.last_assistant_message_at),
            last_seen_at: format_timestamp(session.last_seen_at),
            cwd: display_optional_text(session.cwd.as_deref(), "unknown cwd"),
            model: display_optional_text(session.model.as_deref(), "unknown model"),
            transcript_freshness: transcript_freshness_label(
                session.transcript_freshness_state.as_deref(),
                session.transcript_freshness_source.as_deref(),
            ),
            activity: activity_label(session.activity_active, session.activity_attached),
            message_count: message_views.len(),
            selected_message_key,
            selected_message_found,
            messages: message_views,
        },
        StatusCode::OK,
    )
}

async fn status_hosts(state: &AppState, postgres_enabled: bool) -> Vec<StatusHostView> {
    let hosts = state.hosts.read().await;
    let mut views = hosts
        .values()
        .map(|record| status_host(record, postgres_enabled))
        .collect::<Vec<_>>();
    views.sort_by(|left, right| left.location.cmp(&right.location));
    views
}

fn status_host(record: &HostRecord, postgres_enabled: bool) -> StatusHostView {
    let mut sessions = record.sessions.clone();
    sessions.sort_by(|left, right| {
        right
            .updated_at
            .cmp(&left.updated_at)
            .then_with(|| left.id.cmp(&right.id))
    });

    StatusHostView {
        location: record.host.location.clone(),
        auth_label: super::host_auth_label(record.host.auth).to_string(),
        status_label: if record.connected {
            "connected".to_string()
        } else {
            "missing".to_string()
        },
        status_class: if record.connected {
            "status-connected"
        } else {
            "status-missing"
        },
        last_seen_at: record
            .last_seen_at
            .map(format_timestamp)
            .unwrap_or_else(|| "never".to_string()),
        session_count: sessions.len(),
        sessions: sessions
            .into_iter()
            .map(|session| status_session_view(record, session, postgres_enabled))
            .collect(),
    }
}

fn status_session_view(
    record: &HostRecord,
    session: ActiveSession,
    postgres_enabled: bool,
) -> StatusSessionView {
    StatusSessionView {
        id: session.id.clone(),
        summary: display_summary(Some(&session.summary), &session.id),
        updated_at: format_timestamp(session.updated_at),
        cwd: display_optional_text(Some(&session.cwd), "unknown cwd"),
        model: display_optional_text(Some(&session.model), "unknown model"),
        json_url: live_session_messages_url(&record.host.location, &session.id),
        archive_url: postgres_enabled
            .then(|| archive_session_url(&record.host.location, &session.id, None)),
    }
}

fn display_summary(summary: Option<&str>, fallback: &str) -> String {
    summary
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .unwrap_or(fallback)
        .to_string()
}

fn display_optional_text(value: Option<&str>, fallback: &str) -> String {
    value
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .unwrap_or(fallback)
        .to_string()
}

fn display_message_body(body: &str) -> String {
    let trimmed = body.trim();
    if trimmed.is_empty() {
        "(empty message body)".to_string()
    } else {
        body.to_string()
    }
}

fn format_timestamp(value: DateTime<Utc>) -> String {
    value.to_rfc3339()
}

fn format_optional_timestamp(value: Option<DateTime<Utc>>) -> String {
    value
        .map(format_timestamp)
        .unwrap_or_else(|| "unknown".to_string())
}

fn transcript_freshness_label(state: Option<&str>, source: Option<&str>) -> String {
    match (state, source) {
        (Some(state), Some(source)) => format!("{state} via {source}"),
        (Some(state), None) => state.to_string(),
        (None, Some(source)) => format!("via {source}"),
        (None, None) => "unknown".to_string(),
    }
}

fn activity_label(active: Option<bool>, attached: Option<bool>) -> String {
    match (active, attached) {
        (Some(active), Some(attached)) => format!("active={active}, attached={attached}"),
        (Some(active), None) => format!("active={active}"),
        (None, Some(attached)) => format!("attached={attached}"),
        (None, None) => "unknown".to_string(),
    }
}

fn role_class(role: &str) -> &'static str {
    match role {
        "user" => "role-user",
        "assistant" => "role-assistant",
        "toolResult" | "bashExecution" => "role-tool",
        _ => "role-other",
    }
}

fn live_session_messages_url(host_location: &str, session_id: &str) -> String {
    format!(
        "/sessions/{}/messages?hostLocation={}",
        percent_encode_component(session_id),
        percent_encode_component(host_location),
    )
}

fn archive_session_url(host_location: &str, session_id: &str, message_key: Option<&str>) -> String {
    let mut url = format!(
        "/ui/session?host={}&id={}",
        percent_encode_component(host_location),
        percent_encode_component(session_id),
    );
    if let Some(message_key) = message_key {
        url.push_str("&message=");
        url.push_str(&percent_encode_component(message_key));
        url.push('#');
        url.push_str(&message_anchor_id(message_key));
    }
    url
}

fn message_anchor_id(message_key: &str) -> String {
    format!("m-{}", URL_SAFE_NO_PAD.encode(message_key.as_bytes()))
}

fn percent_encode_component(value: &str) -> String {
    let mut encoded = String::with_capacity(value.len());
    for byte in value.as_bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => {
                encoded.push(char::from(*byte));
            }
            _ => encoded.push_str(&format!("%{:02X}", byte)),
        }
    }
    encoded
}

async fn connect_archive_client() -> Result<Client, Response> {
    let Some(url) = env::var(postgres_backup::POSTGRES_BACKUP_URL_ENV)
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
    else {
        return Err(error_response(
            StatusCode::SERVICE_UNAVAILABLE,
            "archive is disabled",
            &format!(
                "set {} and restart the server to enable the archived session browser.",
                postgres_backup::POSTGRES_BACKUP_URL_ENV
            ),
            "/",
            "Back to status",
        ));
    };

    let (client, connection) = match tokio_postgres::connect(&url, NoTls).await {
        Ok(connection) => connection,
        Err(error) => {
            return Err(error_response(
                StatusCode::BAD_GATEWAY,
                "archive connection failed",
                &format!(
                    "could not connect to the archive database configured by {}: {error}",
                    postgres_backup::POSTGRES_BACKUP_URL_ENV
                ),
                "/",
                "Back to status",
            ));
        }
    };

    tokio::spawn(async move {
        if let Err(error) = connection.await {
            warn!(%error, "archive postgres connection ended");
        }
    });

    Ok(client)
}

async fn load_archive_sessions(
    client: &Client,
    count: i64,
) -> Result<Vec<ArchiveSessionRecord>, String> {
    let rows = client
        .query(
            concat!(
                "SELECT host_location, session_id, host_auth, summary, created_at, updated_at, ",
                "last_user_message_at, last_assistant_message_at, cwd, model, ",
                "transcript_freshness_state, transcript_freshness_source, ",
                "activity_active, activity_attached, last_seen_at ",
                "FROM sessions ",
                "ORDER BY COALESCE(updated_at, last_seen_at) DESC, host_location ASC, session_id ASC ",
                "LIMIT $1"
            ),
            &[&count],
        )
        .await
        .map_err(|error| error.to_string())?;

    Ok(rows.into_iter().map(map_archive_session_row).collect())
}

async fn load_archive_session(
    client: &Client,
    host_location: &str,
    session_id: &str,
) -> Result<Option<ArchiveSessionRecord>, String> {
    let row = client
        .query_opt(
            concat!(
                "SELECT host_location, session_id, host_auth, summary, created_at, updated_at, ",
                "last_user_message_at, last_assistant_message_at, cwd, model, ",
                "transcript_freshness_state, transcript_freshness_source, ",
                "activity_active, activity_attached, last_seen_at ",
                "FROM sessions ",
                "WHERE host_location = $1 AND session_id = $2"
            ),
            &[&host_location, &session_id],
        )
        .await
        .map_err(|error| error.to_string())?;

    Ok(row.map(map_archive_session_row))
}

fn map_archive_session_row(row: tokio_postgres::Row) -> ArchiveSessionRecord {
    ArchiveSessionRecord {
        host_location: row.get("host_location"),
        session_id: row.get("session_id"),
        host_auth: row.get("host_auth"),
        summary: row.get("summary"),
        created_at: row.get("created_at"),
        updated_at: row.get("updated_at"),
        last_user_message_at: row.get("last_user_message_at"),
        last_assistant_message_at: row.get("last_assistant_message_at"),
        cwd: row.get("cwd"),
        model: row.get("model"),
        transcript_freshness_state: row.get("transcript_freshness_state"),
        transcript_freshness_source: row.get("transcript_freshness_source"),
        activity_active: row.get("activity_active"),
        activity_attached: row.get("activity_attached"),
        last_seen_at: row.get("last_seen_at"),
    }
}

async fn load_archive_messages(
    client: &Client,
    host_location: &str,
    session_id: &str,
) -> Result<Vec<ArchiveMessageRecord>, String> {
    let rows = client
        .query(
            concat!(
                "SELECT dedupe_key, created_at, role, tool_name, body ",
                "FROM messages ",
                "WHERE host_location = $1 AND session_id = $2 ",
                "ORDER BY created_at ASC, ordinal ASC"
            ),
            &[&host_location, &session_id],
        )
        .await
        .map_err(|error| error.to_string())?;

    Ok(rows
        .into_iter()
        .map(|row| ArchiveMessageRecord {
            message_key: row.get("dedupe_key"),
            created_at: row.get("created_at"),
            role: row.get("role"),
            tool_name: row.get("tool_name"),
            body: row.get("body"),
        })
        .collect())
}

fn render_html<T: TemplateSimple>(template: T, status: StatusCode) -> Response {
    match template.render_once() {
        Ok(body) => (status, Html(body)).into_response(),
        Err(error) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Html(format!(
                "<!doctype html><html><body><h1>template render failed</h1><pre>{error}</pre></body></html>"
            )),
        )
            .into_response(),
    }
}

fn error_response(
    status: StatusCode,
    headline: &str,
    message: &str,
    back_url: &str,
    back_label: &str,
) -> Response {
    render_html(
        ErrorPageTemplate {
            common_style: COMMON_STYLE,
            title: format!("{headline} · pimux"),
            headline: headline.to_string(),
            message: message.to_string(),
            back_url: back_url.to_string(),
            back_label: back_label.to_string(),
        },
        status,
    )
}

#[cfg(test)]
mod tests {
    use super::{
        archive_session_url, message_anchor_id, percent_encode_component,
        transcript_freshness_label,
    };

    #[test]
    fn percent_encodes_query_components() {
        assert_eq!(
            percent_encode_component("dev@mac/local"),
            "dev%40mac%2Flocal"
        );
        assert_eq!(percent_encode_component("id:entry 1"), "id%3Aentry%201");
    }

    #[test]
    fn archive_message_permalink_includes_query_and_anchor() {
        let url = archive_session_url("dev@mac", "session-1", Some("id:entry-1"));
        assert!(url.starts_with("/ui/session?host=dev%40mac&id=session-1&message=id%3Aentry-1#"));
        assert!(url.ends_with(&message_anchor_id("id:entry-1")));
    }

    #[test]
    fn transcript_freshness_label_combines_state_and_source() {
        assert_eq!(
            transcript_freshness_label(Some("live"), Some("extension")),
            "live via extension"
        );
    }
}
