use std::{
    env, fs,
    path::{Path, PathBuf},
};

use axum::{
    extract::{Query, State},
    http::{StatusCode, header},
    response::{Html, IntoResponse, Response},
};
use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use bytes::Bytes;
use chrono::{DateTime, Days, NaiveDate, Utc};
use pulldown_cmark::{Options, Parser};
use sailfish::{TemplateSimple, runtime::escape::escape_to_string};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use tokio_postgres::{Client, NoTls};
use tracing::warn;

use crate::{
    message::{Message, MessageContentBlockKind, normalized_display_text},
    report::{self, DayConfig},
    session::{ActiveSession, parse_local_date_filter},
};

use super::{AppState, HostRecord, postgres_backup};

const DEFAULT_ARCHIVE_SESSION_COUNT: i64 = 100;
const MAX_ARCHIVE_SESSION_COUNT: i64 = 500;
const DEFAULT_REPORT_DAY_COUNT: u32 = 14;
const MAX_REPORT_DAY_COUNT: u32 = 90;
const REPORTS_DIR_ENV: &str = "PIMUX_REPORTS_DIR";
const WEB_TIMESTAMP_FORMAT: &str = "%Y-%m-%d %H:%M:%S";
const RESET_CSS_GZ: &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/reset.css.gz"));
const PIMUX_CSS_GZ: &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/pimux.css.gz"));

#[derive(Debug, TemplateSimple)]
#[template(path = "web/status.stpl")]
struct StatusPageTemplate {
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
    tool_call_badge: Option<String>,
    related_tool_call: Option<ArchiveToolLinkView>,
    tool_call_blocks: Vec<ArchiveToolCallBlockView>,
    body_html: String,
    body_format_class: &'static str,
    is_selected: bool,
    permalink_url: String,
}

#[derive(Debug)]
struct ArchiveToolLinkView {
    label: String,
    url: String,
}

#[derive(Debug)]
struct ArchiveToolCallBlockView {
    anchor_id: String,
    tool_name: String,
    tool_call_badge: Option<String>,
    body_html: String,
    result_link: Option<ArchiveToolLinkView>,
}

#[derive(Debug)]
struct ParsedArchiveMessage {
    record: ArchiveMessageRecord,
    normalized: Option<Message>,
}

#[derive(Debug, TemplateSimple)]
#[template(path = "web/reports.stpl")]
struct ReportsPageTemplate {
    timezone: String,
    day_count: usize,
    reports_dir: String,
    days: Vec<ReportDayListItemView>,
}

#[derive(Debug)]
struct ReportDayListItemView {
    date: String,
    report_url: String,
    status_label: &'static str,
    status_class: &'static str,
    saved_at: Option<String>,
}

#[derive(Debug, TemplateSimple)]
#[template(path = "web/report.stpl")]
struct ReportPageTemplate {
    date: String,
    timezone: String,
    source_label: String,
    saved_at: Option<String>,
    warning: Option<ReportWarningView>,
    report_html: String,
}

#[derive(Debug, Clone)]
struct ReportWarningView {
    title: String,
    message: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct SavedReportMetadata {
    timezone: String,
    used_heuristic_fallback: bool,
    heuristic_project_keys: Vec<String>,
}

#[derive(Debug)]
struct RenderedMessageBody {
    html: String,
    format_class: &'static str,
}

#[derive(Debug, TemplateSimple)]
#[template(path = "web/error.stpl")]
struct ErrorPageTemplate {
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

#[derive(Debug, Default, Deserialize)]
pub(super) struct ReportsQuery {
    count: Option<u32>,
}

#[derive(Debug, Default, Deserialize)]
pub(super) struct ReportQuery {
    date: Option<String>,
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
    message_json: Value,
}

pub(super) async fn static_reset_css() -> Response {
    css_response(RESET_CSS_GZ)
}

pub(super) async fn static_pimux_css() -> Response {
    css_response(PIMUX_CSS_GZ)
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
            total_sessions,
            sessions: views,
        },
        StatusCode::OK,
    )
}

pub(super) async fn reports(Query(query): Query<ReportsQuery>) -> Response {
    let count = query
        .count
        .unwrap_or(DEFAULT_REPORT_DAY_COUNT)
        .clamp(1, MAX_REPORT_DAY_COUNT) as usize;

    let reports_dir = match resolve_reports_dir() {
        Ok(path) => path,
        Err(error) => {
            return error_response(
                StatusCode::INTERNAL_SERVER_ERROR,
                "reports directory unavailable",
                &error,
                "/",
                "Back to status",
            );
        }
    };

    let client = match connect_archive_client().await {
        Ok(client) => client,
        Err(response) => return response,
    };

    let today =
        match report::current_report_date(&client, Some(report::DEFAULT_REPORT_TIMEZONE)).await {
            Ok(today) => today,
            Err(error) => {
                return error_response(
                    StatusCode::BAD_GATEWAY,
                    "report date query failed",
                    &error.to_string(),
                    "/",
                    "Back to status",
                );
            }
        };

    let days = recent_report_dates(today, count)
        .into_iter()
        .map(|date| {
            let path = daily_report_path(&reports_dir, date);
            let exists = path.is_file();
            let saved_at = report_saved_at(&path);
            ReportDayListItemView {
                date: date.to_string(),
                report_url: report_url(date),
                status_label: if exists {
                    "available"
                } else {
                    "missing · generate on open"
                },
                status_class: if exists {
                    "status-connected"
                } else {
                    "status-missing"
                },
                saved_at,
            }
        })
        .collect::<Vec<_>>();

    render_html(
        ReportsPageTemplate {
            timezone: report::DEFAULT_REPORT_TIMEZONE.to_string(),
            day_count: days.len(),
            reports_dir: reports_dir.display().to_string(),
            days,
        },
        StatusCode::OK,
    )
}

pub(super) async fn report(Query(query): Query<ReportQuery>) -> Response {
    let Some(date_value) = query
        .date
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
    else {
        return error_response(
            StatusCode::BAD_REQUEST,
            "missing report date",
            "report pages require a `date` query parameter like `2026-04-08`.",
            "/ui/reports",
            "Back to reports",
        );
    };

    let report_date = match parse_local_date_filter(date_value) {
        Ok(date) => date,
        Err(error) => {
            return error_response(
                StatusCode::BAD_REQUEST,
                "invalid report date",
                &error,
                "/ui/reports",
                "Back to reports",
            );
        }
    };

    let reports_dir = match resolve_reports_dir() {
        Ok(path) => path,
        Err(error) => {
            return error_response(
                StatusCode::INTERNAL_SERVER_ERROR,
                "reports directory unavailable",
                &error,
                "/ui/reports",
                "Back to reports",
            );
        }
    };
    let report_path = daily_report_path(&reports_dir, report_date);
    let metadata_path = report_metadata_path(&report_path);
    let loaded_from_saved_report = report_path.is_file();

    let (markdown, source_label, metadata) = if loaded_from_saved_report {
        let markdown = match fs::read_to_string(&report_path) {
            Ok(markdown) => markdown,
            Err(error) => {
                return error_response(
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "report read failed",
                    &format!(
                        "could not read saved report `{}`: {error}",
                        report_path.display()
                    ),
                    "/ui/reports",
                    "Back to reports",
                );
            }
        };
        let metadata = match load_report_metadata(&metadata_path) {
            Ok(metadata) => metadata,
            Err(error) => {
                return error_response(
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "report metadata read failed",
                    &format!(
                        "could not read report metadata `{}`: {error}",
                        metadata_path.display()
                    ),
                    "/ui/reports",
                    "Back to reports",
                );
            }
        };
        (markdown, "loaded from saved report".to_string(), metadata)
    } else {
        let generated = match report::generate_day_report(DayConfig {
            date: Some(report_date.to_string()),
            timezone: Some(report::DEFAULT_REPORT_TIMEZONE.to_string()),
            pi_agent_dir: None,
            summary_model: None,
            ui_base_url: Some("/".to_string()),
        })
        .await
        {
            Ok(report) => report,
            Err(error) => {
                return error_response(
                    StatusCode::BAD_GATEWAY,
                    "report generation failed",
                    &error.to_string(),
                    "/ui/reports",
                    "Back to reports",
                );
            }
        };

        if let Err(error) = save_report_markdown(&report_path, &generated.markdown) {
            return error_response(
                StatusCode::INTERNAL_SERVER_ERROR,
                "report save failed",
                &format!(
                    "could not save generated report `{}`: {error}",
                    report_path.display()
                ),
                "/ui/reports",
                "Back to reports",
            );
        }

        let metadata = SavedReportMetadata {
            timezone: generated.timezone.clone(),
            used_heuristic_fallback: generated.used_heuristic_fallback,
            heuristic_project_keys: generated.heuristic_project_keys,
        };
        if let Err(error) = save_report_metadata(&metadata_path, &metadata) {
            return error_response(
                StatusCode::INTERNAL_SERVER_ERROR,
                "report metadata save failed",
                &format!(
                    "could not save report metadata `{}`: {error}",
                    metadata_path.display()
                ),
                "/ui/reports",
                "Back to reports",
            );
        }

        (
            generated.markdown,
            "generated on demand".to_string(),
            Some(metadata),
        )
    };

    let timezone = metadata
        .as_ref()
        .map(|metadata| metadata.timezone.clone())
        .unwrap_or_else(|| report::DEFAULT_REPORT_TIMEZONE.to_string());

    render_html(
        ReportPageTemplate {
            date: report_date.to_string(),
            timezone,
            source_label,
            saved_at: report_saved_at(&report_path),
            warning: report_warning(metadata.as_ref(), loaded_from_saved_report),
            report_html: markdown_to_html(&markdown),
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

    let parsed_messages = messages
        .into_iter()
        .map(|record| ParsedArchiveMessage {
            normalized: serde_json::from_value::<Message>(record.message_json.clone()).ok(),
            record,
        })
        .collect::<Vec<_>>();

    let tool_calls_by_id = parsed_messages
        .iter()
        .flat_map(|message| {
            message
                .normalized
                .as_ref()
                .into_iter()
                .flat_map(move |normalized| {
                    normalized
                        .blocks
                        .iter()
                        .enumerate()
                        .filter_map(move |(index, block)| {
                            (block.kind == MessageContentBlockKind::ToolCall)
                                .then_some(())
                                .and(block.tool_call_id.as_ref())
                                .map(|tool_call_id| {
                                    (
                                        tool_call_id.clone(),
                                        (
                                            message.record.message_key.clone(),
                                            tool_call_block_anchor_id(
                                                &message.record.message_key,
                                                index,
                                            ),
                                            block
                                                .tool_call_name
                                                .clone()
                                                .unwrap_or_else(|| "unknown tool".to_string()),
                                        ),
                                    )
                                })
                        })
                })
        })
        .collect::<std::collections::HashMap<_, _>>();

    let tool_results_by_id = parsed_messages
        .iter()
        .filter_map(|message| {
            let normalized = message.normalized.as_ref()?;
            let tool_call_id = normalized.tool_call_id.as_ref()?;
            Some((
                tool_call_id.clone(),
                (
                    message.record.message_key.clone(),
                    normalized
                        .tool_name
                        .clone()
                        .or_else(|| message.record.tool_name.clone())
                        .unwrap_or_else(|| "tool result".to_string()),
                ),
            ))
        })
        .collect::<std::collections::HashMap<_, _>>();

    let mut selected_message_found = false;
    let message_views = parsed_messages
        .into_iter()
        .map(|message| {
            let is_selected = selected_message_key
                .as_deref()
                .map(|selected| selected == message.record.message_key)
                .unwrap_or(false);
            if is_selected {
                selected_message_found = true;
            }

            let rendered_body = render_message_body(
                &message.record.role,
                message.normalized.as_ref(),
                &message.record.message_json,
                &message.record.body,
            );
            let message_key = message.record.message_key;
            let related_tool_call = message
                .normalized
                .as_ref()
                .and_then(|normalized| normalized.tool_call_id.as_ref())
                .and_then(|tool_call_id| {
                    tool_calls_by_id.get(tool_call_id).map(
                        |(call_message_key, anchor_id, tool_name)| ArchiveToolLinkView {
                            label: format!(
                                "for call: {tool_name} · {}",
                                short_tool_call_id(tool_call_id)
                            ),
                            url: archive_session_anchor_url(
                                host,
                                session_id,
                                call_message_key,
                                anchor_id,
                            ),
                        },
                    )
                });
            let tool_call_badge = message
                .normalized
                .as_ref()
                .and_then(|normalized| normalized.tool_call_id.as_ref())
                .map(|tool_call_id| short_tool_call_id(tool_call_id));
            let tool_call_blocks = message
                .normalized
                .as_ref()
                .map(|normalized| {
                    normalized
                        .blocks
                        .iter()
                        .enumerate()
                        .filter_map(|(index, block)| {
                            if block.kind != MessageContentBlockKind::ToolCall {
                                return None;
                            }

                            let result_link =
                                block.tool_call_id.as_ref().and_then(|tool_call_id| {
                                    tool_results_by_id.get(tool_call_id).map(
                                        |(result_message_key, tool_name)| ArchiveToolLinkView {
                                            label: format!(
                                                "result: {tool_name} · {}",
                                                short_tool_call_id(tool_call_id)
                                            ),
                                            url: archive_session_anchor_url(
                                                host,
                                                session_id,
                                                result_message_key,
                                                &message_anchor_id(result_message_key),
                                            ),
                                        },
                                    )
                                });

                            Some(ArchiveToolCallBlockView {
                                anchor_id: tool_call_block_anchor_id(&message_key, index),
                                tool_name: block
                                    .tool_call_name
                                    .clone()
                                    .unwrap_or_else(|| "unknown tool".to_string()),
                                tool_call_badge: block
                                    .tool_call_id
                                    .as_ref()
                                    .map(|tool_call_id| short_tool_call_id(tool_call_id)),
                                body_html: escape_html(
                                    block
                                        .text
                                        .as_deref()
                                        .unwrap_or("(no tool call summary available)"),
                                ),
                                result_link,
                            })
                        })
                        .collect::<Vec<_>>()
                })
                .unwrap_or_default();

            ArchiveMessageView {
                anchor_id: message_anchor_id(&message_key),
                permalink_url: archive_session_url(host, session_id, Some(&message_key)),
                created_at: format_timestamp(message.record.created_at),
                role_class: role_class(&message.record.role),
                role: message.record.role,
                tool_name: message.record.tool_name,
                tool_call_badge,
                related_tool_call,
                tool_call_blocks,
                body_html: rendered_body.html,
                body_format_class: rendered_body.format_class,
                is_selected,
                message_key,
            }
        })
        .collect::<Vec<_>>();

    render_html(
        ArchiveSessionPageTemplate {
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

fn render_message_body(
    role: &str,
    normalized_message: Option<&Message>,
    message_json: &Value,
    body: &str,
) -> RenderedMessageBody {
    let body_text = display_message_body_text(role, normalized_message, message_json, body);
    if body_text.is_empty() {
        return RenderedMessageBody {
            html: String::new(),
            format_class: "message-body-empty",
        };
    }

    if renders_markdown(role) {
        RenderedMessageBody {
            html: markdown_to_html(&body_text),
            format_class: "message-body-markdown",
        }
    } else {
        RenderedMessageBody {
            html: escape_html(&body_text),
            format_class: "message-body-plain",
        }
    }
}

fn display_message_body_text(
    role: &str,
    normalized_message: Option<&Message>,
    message_json: &Value,
    body: &str,
) -> String {
    let parsed_message = normalized_message
        .cloned()
        .or_else(|| parse_archived_message(message_json));

    if role == "assistant"
        && let Some(message) = parsed_message.as_ref()
    {
        if let Some(text) = archived_message_body_from_message(message) {
            return text;
        }
        if message
            .blocks
            .iter()
            .any(|block| block.kind == MessageContentBlockKind::ToolCall)
        {
            return String::new();
        }
    }

    let trimmed = body.trim();
    if !trimmed.is_empty() {
        return body.to_string();
    }

    archived_message_body_from_blocks(message_json)
        .unwrap_or_else(|| "(empty message body)".to_string())
}

fn renders_markdown(role: &str) -> bool {
    !matches!(role, "toolResult" | "bashExecution")
}

fn markdown_to_html(markdown: &str) -> String {
    let mut options = Options::empty();
    options.insert(Options::ENABLE_STRIKETHROUGH);
    options.insert(Options::ENABLE_TABLES);
    options.insert(Options::ENABLE_FOOTNOTES);

    let parser = Parser::new_ext(markdown, options);
    let mut rendered = String::new();
    pulldown_cmark::html::push_html(&mut rendered, parser);
    ammonia::clean(&rendered)
}

fn escape_html(text: &str) -> String {
    let mut escaped = String::new();
    escape_to_string(text, &mut escaped);
    escaped
}

fn parse_archived_message(message_json: &Value) -> Option<Message> {
    serde_json::from_value::<Message>(message_json.clone()).ok()
}

fn archived_message_body_from_blocks(message_json: &Value) -> Option<String> {
    let message = parse_archived_message(message_json)?;
    archived_message_body_from_message(&message)
}

fn archived_message_body_from_message(message: &Message) -> Option<String> {
    let parts = message
        .blocks
        .iter()
        .filter_map(|block| match block.kind {
            MessageContentBlockKind::Text
            | MessageContentBlockKind::Thinking
            | MessageContentBlockKind::Other => {
                block.text.as_deref().and_then(normalized_display_text)
            }
            MessageContentBlockKind::ToolCall | MessageContentBlockKind::Image => None,
        })
        .collect::<Vec<_>>();

    if parts.is_empty() {
        None
    } else {
        Some(parts.join("\n\n"))
    }
}

fn format_timestamp(value: DateTime<Utc>) -> String {
    value.format(WEB_TIMESTAMP_FORMAT).to_string()
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

fn report_url(date: NaiveDate) -> String {
    format!("/ui/report?date={date}")
}

fn recent_report_dates(today: NaiveDate, count: usize) -> Vec<NaiveDate> {
    (0..count)
        .filter_map(|offset| today.checked_sub_days(Days::new(offset as u64)))
        .collect()
}

fn resolve_reports_dir() -> Result<PathBuf, String> {
    if let Ok(path) = env::var(REPORTS_DIR_ENV) {
        let trimmed = path.trim();
        if trimmed.is_empty() {
            return Err(format!("{REPORTS_DIR_ENV} must not be empty when set"));
        }
        return Ok(PathBuf::from(trimmed));
    }

    super::default_state_dir()
        .map(|path| path.join("reports").join("daily"))
        .map_err(|error| error.to_string())
}

fn daily_report_path(reports_dir: &Path, date: NaiveDate) -> PathBuf {
    reports_dir.join(format!("{date}.md"))
}

fn report_metadata_path(report_path: &Path) -> PathBuf {
    report_path.with_extension("meta.json")
}

fn load_report_metadata(path: &Path) -> Result<Option<SavedReportMetadata>, String> {
    if !path.is_file() {
        return Ok(None);
    }

    let metadata = fs::read_to_string(path).map_err(|error| error.to_string())?;
    serde_json::from_str(&metadata)
        .map(Some)
        .map_err(|error| error.to_string())
}

fn save_report_metadata(path: &Path, metadata: &SavedReportMetadata) -> Result<(), String> {
    let Some(parent) = path.parent() else {
        return Err(format!(
            "report metadata path `{}` has no parent directory",
            path.display()
        ));
    };
    fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    let serialized = serde_json::to_string_pretty(metadata).map_err(|error| error.to_string())?;
    fs::write(path, serialized).map_err(|error| error.to_string())
}

fn report_warning(
    metadata: Option<&SavedReportMetadata>,
    loaded_from_saved_report: bool,
) -> Option<ReportWarningView> {
    match metadata {
        Some(metadata) if metadata.used_heuristic_fallback => Some(ReportWarningView {
            title: "Generated with heuristic fallback".to_string(),
            message: heuristic_fallback_warning_message(&metadata.heuristic_project_keys),
        }),
        Some(_) => None,
        None if loaded_from_saved_report => Some(ReportWarningView {
            title: "Saved report predates fallback tracking".to_string(),
            message: "This saved report was created before pimux started recording whether Pi summarization succeeded, so it may have been generated heuristically. If it looks wrong, fix the server's Pi auth/settings and regenerate it.".to_string(),
        }),
        None => None,
    }
}

fn heuristic_fallback_warning_message(project_keys: &[String]) -> String {
    if project_keys.is_empty() {
        return "Pi summarization failed and pimux fell back to heuristic report generation, so this report may contain raw requests, generic confirmations, or low-quality LLM miss summaries. Fix the server's Pi auth/settings and regenerate it.".to_string();
    }

    let preview = project_keys
        .iter()
        .take(3)
        .cloned()
        .collect::<Vec<_>>()
        .join(", ");
    let suffix = if project_keys.len() > 3 { "…" } else { "" };
    format!(
        "Pi summarization failed for {} project(s) ({preview}{suffix}), so pimux fell back to heuristic report generation. This report may contain raw requests, generic confirmations, or low-quality LLM miss summaries. Fix the server's Pi auth/settings and regenerate it.",
        project_keys.len()
    )
}

fn report_saved_at(path: &Path) -> Option<String> {
    let modified = fs::metadata(path).ok()?.modified().ok()?;
    let modified: DateTime<Utc> = modified.into();
    Some(format_timestamp(modified))
}

fn save_report_markdown(path: &Path, markdown: &str) -> Result<(), String> {
    let Some(parent) = path.parent() else {
        return Err(format!(
            "report path `{}` has no parent directory",
            path.display()
        ));
    };
    fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    fs::write(path, markdown).map_err(|error| error.to_string())
}

fn message_anchor_id(message_key: &str) -> String {
    format!("m-{}", URL_SAFE_NO_PAD.encode(message_key.as_bytes()))
}

fn tool_call_block_anchor_id(message_key: &str, block_index: usize) -> String {
    format!(
        "tc-{}",
        URL_SAFE_NO_PAD.encode(format!("{message_key}:{block_index}").as_bytes())
    )
}

fn archive_session_anchor_url(
    host_location: &str,
    session_id: &str,
    message_key: &str,
    anchor_id: &str,
) -> String {
    let mut url = archive_session_url(host_location, session_id, Some(message_key));
    if let Some(index) = url.find('#') {
        url.truncate(index);
    }
    url.push('#');
    url.push_str(anchor_id);
    url
}

fn short_tool_call_id(tool_call_id: &str) -> String {
    let trimmed = tool_call_id
        .split('|')
        .next()
        .unwrap_or(tool_call_id)
        .trim();
    if trimmed.chars().count() <= 18 {
        trimmed.to_string()
    } else {
        format!("{}…", trimmed.chars().take(18).collect::<String>())
    }
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
                "SELECT dedupe_key, created_at, role, tool_name, body, message_json ",
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
            message_json: row.get("message_json"),
        })
        .collect())
}

fn css_response(compressed: &'static [u8]) -> Response {
    (
        [
            (header::CONTENT_TYPE, "text/css; charset=utf-8"),
            (header::CONTENT_ENCODING, "gzip"),
        ],
        Bytes::from_static(compressed),
    )
        .into_response()
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
    use chrono::{NaiveDate, TimeZone, Utc};
    use serde_json::{Value, json};

    use super::{
        SavedReportMetadata, archive_session_url, display_message_body_text, format_timestamp,
        markdown_to_html, message_anchor_id, percent_encode_component, recent_report_dates,
        render_message_body, report_warning, short_tool_call_id, transcript_freshness_label,
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

    #[test]
    fn formats_web_timestamps_without_timezone() {
        let value = Utc.with_ymd_and_hms(2026, 4, 8, 13, 37, 42).unwrap();
        assert_eq!(format_timestamp(value), "2026-04-08 13:37:42");
    }

    #[test]
    fn displays_thinking_blocks_when_archived_body_is_empty() {
        let message_json = json!({
            "created_at": "2026-04-08T19:01:21Z",
            "role": "assistant",
            "body": "",
            "blocks": [
                {
                    "type": "thinking",
                    "text": "considering the next step"
                }
            ]
        });

        assert_eq!(
            display_message_body_text("assistant", None, &message_json, ""),
            "considering the next step"
        );
    }

    #[test]
    fn hides_duplicate_assistant_body_for_tool_call_only_messages() {
        let message_json = json!({
            "created_at": "2026-04-08T19:01:21Z",
            "role": "assistant",
            "body": "Tool call: read",
            "blocks": [
                {
                    "type": "toolCall",
                    "toolCallName": "read",
                    "toolCallId": "call-123",
                    "text": "foo.txt"
                }
            ]
        });

        assert_eq!(
            display_message_body_text("assistant", None, &message_json, "Tool call: read"),
            ""
        );
    }

    #[test]
    fn renders_markdown_for_assistant_messages() {
        let rendered = render_message_body(
            "assistant",
            None,
            &Value::Null,
            "# Hello\n\n- one\n- two\n\n<script>alert('xss')</script>",
        );

        assert_eq!(rendered.format_class, "message-body-markdown");
        assert!(rendered.html.contains("<h1>Hello</h1>"));
        assert!(rendered.html.contains("<ul>"));
        assert!(!rendered.html.contains("<script>"));
    }

    #[test]
    fn keeps_bash_output_as_plain_escaped_text() {
        let rendered =
            render_message_body("bashExecution", None, &Value::Null, "echo <ok>\nline 2");

        assert_eq!(rendered.format_class, "message-body-plain");
        assert_eq!(rendered.html, "echo &lt;ok&gt;\nline 2");
    }

    #[test]
    fn short_tool_call_id_drops_hash_suffix() {
        assert_eq!(
            short_tool_call_id("call_abcdef123456|fc_deadbeef"),
            "call_abcdef123456"
        );
    }

    #[test]
    fn recent_report_dates_descend_from_today() {
        let today = NaiveDate::from_ymd_opt(2026, 4, 9).unwrap();
        assert_eq!(
            recent_report_dates(today, 3),
            vec![
                NaiveDate::from_ymd_opt(2026, 4, 9).unwrap(),
                NaiveDate::from_ymd_opt(2026, 4, 8).unwrap(),
                NaiveDate::from_ymd_opt(2026, 4, 7).unwrap(),
            ]
        );
    }

    #[test]
    fn markdown_renderer_supports_footnotes() {
        let html = markdown_to_html("hello[^1]\n\n[^1]: footnote text");

        assert!(html.contains("<sup"));
        assert!(html.contains("footnote text"));
        assert!(!html.contains("[^1]"));
    }

    #[test]
    fn report_warning_flags_saved_reports_with_heuristic_fallback() {
        let warning = report_warning(
            Some(&SavedReportMetadata {
                timezone: "America/Los_Angeles".to_string(),
                used_heuristic_fallback: true,
                heuristic_project_keys: vec![
                    "~/apps/mi".to_string(),
                    "~/apps/pimux2000".to_string(),
                ],
            }),
            true,
        )
        .unwrap();

        assert!(warning.title.contains("heuristic fallback"));
        assert!(warning.message.contains("~/apps/mi"));
        assert!(warning.message.contains("regenerate"));
    }

    #[test]
    fn report_warning_flags_legacy_saved_reports_without_metadata() {
        let warning = report_warning(None, true).unwrap();

        assert!(warning.title.contains("predates fallback tracking"));
        assert!(
            warning
                .message
                .contains("may have been generated heuristically")
        );
    }
}
