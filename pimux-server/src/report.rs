use std::{
    collections::{HashMap, HashSet},
    env,
    error::Error as StdError,
    path::PathBuf,
};

use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use chrono::{DateTime, Duration as ChronoDuration, NaiveDate, Utc};
use serde::{Deserialize, Serialize, de::DeserializeOwned};
use serde_json::Value;
use tokio::process::Command;
use tokio_postgres::{Client, NoTls};
use tracing::warn;

use crate::{
    agent,
    host::HostIdentity,
    message::{Message, MessageContentBlockKind, collapse_whitespace},
    session::{ActiveSession, parse_local_date_filter},
};

type BoxError = Box<dyn StdError + Send + Sync>;

pub const POSTGRES_BACKUP_URL_ENV: &str = "PIMUX_BACKUP_POSTGRES_URL";
pub const REPORT_UI_BASE_URL_ENV: &str = "PIMUX_UI_BASE_URL";
const DEFAULT_REPORT_UI_BASE_URL: &str = "http://127.0.0.1:3000";
pub(crate) const DEFAULT_REPORT_TIMEZONE: &str = "America/Los_Angeles";
const NO_WORKING_DIRECTORY: &str = "No working directory";
const MAX_CANDIDATE_EXCERPTS: usize = 24;
const MAX_OUTCOME_EXCERPTS: usize = 10;
const MIN_STRICT_EXCERPTS: usize = 8;
const MAX_EXCERPT_CHARS: usize = 220;
const MAX_WORKED_ON_ITEMS: usize = 5;
const MAX_ACCOMPLISHMENTS: usize = 5;
const MAX_EXCERPTS_PER_ACCOMPLISHMENT: usize = 2;
const MAX_MISS_CANDIDATES: usize = 10;
const MAX_LLM_MISSES: usize = 5;
const MAX_EVIDENCE_LINES_PER_MISS: usize = 3;
const MAX_CORRECTION_WINDOW_GAP_MINUTES: i64 = 120;
const MAX_FOOTNOTE_CHARS: usize = 160;
const MIN_FOOTNOTE_SCORE: i32 = 35;

#[derive(Debug, Clone)]
pub struct DayConfig {
    pub date: Option<String>,
    pub timezone: Option<String>,
    pub pi_agent_dir: Option<PathBuf>,
    pub summary_model: Option<String>,
    pub ui_base_url: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct GeneratedDayReport {
    pub report_date: NaiveDate,
    pub timezone: String,
    pub markdown: String,
    pub used_heuristic_fallback: bool,
    pub heuristic_project_keys: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReportPayload {
    pub host: HostIdentity,
    #[serde(rename = "active_sessions")]
    pub active_sessions: Vec<ActiveSession>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct VersionResponse {
    pub version: String,
}

#[derive(Debug, Clone)]
struct ArchivedMessage {
    host_location: String,
    session_id: String,
    message_key: String,
    project_cwd: Option<String>,
    created_at: DateTime<Utc>,
    role: String,
    text: Option<String>,
}

#[derive(Debug, Clone)]
struct ProjectDayData {
    project_key: String,
    messages: Vec<ArchivedMessage>,
    last_activity_at: DateTime<Utc>,
}

#[derive(Debug, Clone)]
struct ExcerptCandidate {
    id: String,
    created_at: DateTime<Utc>,
    role: String,
    text: String,
    score: i32,
    link_target: MessageLinkTarget,
}

#[derive(Debug, Clone)]
struct MissCandidate {
    id: String,
    created_at: DateTime<Utc>,
    assistant_text: Option<String>,
    assistant_link_target: Option<MessageLinkTarget>,
    correction_text: String,
    correction_link_target: MessageLinkTarget,
    score: i32,
}

#[derive(Debug, Clone)]
struct AssistantContext {
    created_at: DateTime<Utc>,
    text: String,
    link_target: MessageLinkTarget,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct MessageLinkTarget {
    host_location: String,
    session_id: String,
    message_key: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct FootnoteEvidence {
    text: String,
    ui_url: Option<String>,
}

#[derive(Debug, Clone, Default, Deserialize)]
struct ProjectSummaryResponse {
    #[serde(default, rename = "workedOn")]
    worked_on: Vec<String>,
    #[serde(default)]
    accomplishments: Vec<ProjectSummaryAccomplishment>,
    #[serde(default, rename = "llmMisses")]
    llm_misses: Vec<ProjectSummaryMiss>,
}

#[derive(Debug, Clone, Default, Deserialize)]
struct ProjectSummaryAccomplishment {
    #[serde(default)]
    summary: String,
    #[serde(default, rename = "excerptIds")]
    excerpt_ids: Vec<String>,
}

#[derive(Debug, Clone, Default, Deserialize)]
struct ProjectSummaryMiss {
    #[serde(default)]
    summary: String,
    #[serde(default)]
    lesson: String,
    #[serde(default, rename = "missIds")]
    miss_ids: Vec<String>,
    #[serde(default, rename = "excerptIds")]
    excerpt_ids: Vec<String>,
}

#[derive(Debug, Clone)]
struct RenderedProjectReport {
    project_key: String,
    worked_on: Vec<String>,
    accomplishments: Vec<RenderedAccomplishment>,
    llm_misses: Vec<RenderedMiss>,
}

#[derive(Debug, Clone)]
struct RenderedAccomplishment {
    summary: String,
    excerpts: Vec<FootnoteEvidence>,
}

#[derive(Debug, Clone)]
struct RenderedMiss {
    summary: String,
    lesson: Option<String>,
    evidence_lines: Vec<FootnoteEvidence>,
}

pub async fn day(config: DayConfig) -> Result<(), BoxError> {
    let report = generate_day_report(config).await?;
    print!("{}", report.markdown);
    Ok(())
}

pub(crate) async fn generate_day_report(config: DayConfig) -> Result<GeneratedDayReport, BoxError> {
    generate_day_report_with_logger(config, |line| eprintln!("{line}")).await
}

pub(crate) async fn generate_day_report_with_logger<F>(
    config: DayConfig,
    mut logger: F,
) -> Result<GeneratedDayReport, BoxError>
where
    F: FnMut(String),
{
    let Some(postgres_url) = postgres_url_from_env() else {
        return Err(format!("{POSTGRES_BACKUP_URL_ENV} is not set").into());
    };

    let timezone = resolve_report_timezone(config.timezone.as_deref())?;
    let pi_agent_dir = agent::resolve_pi_agent_dir(config.pi_agent_dir)?;
    let summary_model =
        agent::resolve_summary_model_or_default(&pi_agent_dir, config.summary_model.as_deref());
    let ui_base_url = resolve_ui_base_url(config.ui_base_url.as_deref())?;

    let client = connect_postgres(&postgres_url).await?;
    let report_date = resolve_report_date(&client, config.date.as_deref(), &timezone).await?;
    let (start, end) = utc_range_for_report_date(&client, report_date, &timezone).await?;

    logger(format!(
        "loading archived activity for {} in {} from {}...",
        report_date, timezone, POSTGRES_BACKUP_URL_ENV
    ));
    let messages = load_archived_messages(&client, start, end).await?;

    if messages.is_empty() {
        logger("no archived project activity found for that day".to_string());
        return Ok(GeneratedDayReport {
            report_date,
            timezone,
            markdown: format!(
                "# Daily report for {report_date}\n\nNo archived project activity found.\n"
            ),
            used_heuristic_fallback: false,
            heuristic_project_keys: Vec::new(),
        });
    }

    let mut projects = group_messages_by_project(messages);
    projects.sort_by(|left, right| {
        right
            .last_activity_at
            .cmp(&left.last_activity_at)
            .then_with(|| left.project_key.cmp(&right.project_key))
    });

    logger(format!(
        "generating report for {} project(s) using {}...",
        projects.len(),
        summary_model
    ));

    let mut rendered_projects = Vec::with_capacity(projects.len());
    let mut heuristic_project_keys = Vec::new();
    for (index, project) in projects.iter().enumerate() {
        logger(format!(
            "[{}/{}] summarizing {}",
            index + 1,
            projects.len(),
            project.project_key
        ));

        let excerpts = build_candidate_excerpts(project);
        let misses = build_miss_candidates(project);
        let rendered = match summarize_project_day_via_pi(
            report_date,
            project,
            &excerpts,
            &misses,
            &pi_agent_dir,
            &summary_model,
            &ui_base_url,
        )
        .await
        {
            Ok(rendered) => rendered,
            Err(error) => {
                logger(format!(
                    "report summary failed for project {}: {error}",
                    project.project_key
                ));
                heuristic_project_keys.push(project.project_key.clone());
                heuristic_project_report(project, &excerpts, &misses, &ui_base_url)
            }
        };
        rendered_projects.push(rendered);
    }

    logger("finished generating daily report".to_string());
    Ok(GeneratedDayReport {
        report_date,
        timezone,
        markdown: render_day_report(report_date, &rendered_projects),
        used_heuristic_fallback: !heuristic_project_keys.is_empty(),
        heuristic_project_keys,
    })
}

fn resolve_report_timezone(value: Option<&str>) -> Result<String, BoxError> {
    let timezone = value.unwrap_or(DEFAULT_REPORT_TIMEZONE).trim();
    if timezone.is_empty() {
        return Err("timezone must not be empty".into());
    }
    Ok(timezone.to_string())
}

async fn resolve_report_date(
    client: &Client,
    value: Option<&str>,
    timezone: &str,
) -> Result<NaiveDate, BoxError> {
    match value {
        Some(value) => Ok(parse_local_date_filter(value)?),
        None => current_date_in_timezone(client, timezone).await,
    }
}

pub(crate) async fn current_report_date(
    client: &Client,
    timezone: Option<&str>,
) -> Result<NaiveDate, BoxError> {
    let timezone = resolve_report_timezone(timezone)?;
    current_date_in_timezone(client, &timezone).await
}

async fn current_date_in_timezone(client: &Client, timezone: &str) -> Result<NaiveDate, BoxError> {
    let row = client
        .query_one(
            "SELECT (now() AT TIME ZONE $1)::date AS local_date",
            &[&timezone],
        )
        .await
        .map_err(|error| timezone_query_error(timezone, error))?;
    Ok(row.get("local_date"))
}

async fn utc_range_for_report_date(
    client: &Client,
    date: NaiveDate,
    timezone: &str,
) -> Result<(DateTime<Utc>, DateTime<Utc>), BoxError> {
    let row = client
        .query_one(
            concat!(
                "SELECT ($1::date::timestamp AT TIME ZONE $2) AS start_utc, ",
                "(($1::date + 1)::timestamp AT TIME ZONE $2) AS end_utc"
            ),
            &[&date, &timezone],
        )
        .await
        .map_err(|error| timezone_query_error(timezone, error))?;
    Ok((row.get("start_utc"), row.get("end_utc")))
}

fn timezone_query_error(timezone: &str, error: tokio_postgres::Error) -> BoxError {
    format!("failed to resolve report timezone `{timezone}`: {error}").into()
}

fn postgres_url_from_env() -> Option<String> {
    env::var(POSTGRES_BACKUP_URL_ENV)
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
}

fn resolve_ui_base_url(value: Option<&str>) -> Result<String, BoxError> {
    let value = value.unwrap_or(DEFAULT_REPORT_UI_BASE_URL).trim();
    if value.is_empty() {
        return Err("UI base URL must not be empty".into());
    }
    if value.starts_with('/') {
        return Ok(value.trim_end_matches('/').to_string());
    }

    let normalized = agent::normalize_server_url(value)?;
    Ok(normalized.url.trim_end_matches('/').to_string())
}

async fn connect_postgres(url: &str) -> Result<Client, BoxError> {
    let (client, connection) = tokio_postgres::connect(url, NoTls).await?;
    tokio::spawn(async move {
        if let Err(error) = connection.await {
            warn!(%error, "report postgres connection ended");
        }
    });
    Ok(client)
}

async fn load_archived_messages(
    client: &Client,
    start: DateTime<Utc>,
    end: DateTime<Utc>,
) -> Result<Vec<ArchivedMessage>, BoxError> {
    let rows = client
        .query(
            concat!(
                "SELECT m.host_location AS host_location, m.session_id AS session_id, ",
                "m.dedupe_key AS dedupe_key, s.cwd AS cwd, m.created_at AS created_at, m.role AS role, ",
                "m.body AS body, m.message_json AS message_json ",
                "FROM messages m ",
                "JOIN sessions s ON s.host_location = m.host_location AND s.session_id = m.session_id ",
                "WHERE m.created_at >= $1 AND m.created_at < $2 ",
                "ORDER BY m.created_at ASC, m.ordinal ASC, m.session_id ASC, m.host_location ASC"
            ),
            &[&start, &end],
        )
        .await?;

    Ok(rows
        .into_iter()
        .map(|row| {
            let body: String = row.get("body");
            let message_json: Value = row.get("message_json");
            ArchivedMessage {
                host_location: row.get("host_location"),
                session_id: row.get("session_id"),
                message_key: row.get("dedupe_key"),
                project_cwd: row.get("cwd"),
                created_at: row.get("created_at"),
                role: row.get("role"),
                text: extract_archived_message_text(&message_json, &body),
            }
        })
        .collect())
}

fn extract_archived_message_text(message_json: &Value, body: &str) -> Option<String> {
    if let Ok(message) = serde_json::from_value::<Message>(message_json.clone()) {
        let mut parts = Vec::new();
        for block in message.blocks {
            match block.kind {
                MessageContentBlockKind::Text | MessageContentBlockKind::Other => {
                    if let Some(text) = block.text.as_deref().and_then(normalize_report_line) {
                        parts.push(text);
                    }
                }
                MessageContentBlockKind::Thinking
                | MessageContentBlockKind::ToolCall
                | MessageContentBlockKind::Image => {}
            }
        }

        if !parts.is_empty() {
            return normalize_report_line(&parts.join("\n\n"));
        }
    }

    let fallback = body
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .filter(|line| !line.starts_with("Tool call:"))
        .filter(|line| !line.starts_with("$ "))
        .collect::<Vec<_>>()
        .join("\n\n");

    normalize_report_line(&fallback)
}

fn group_messages_by_project(messages: Vec<ArchivedMessage>) -> Vec<ProjectDayData> {
    let mut project_indexes = HashMap::<String, usize>::new();
    let mut projects = Vec::<ProjectDayData>::new();

    for message in messages {
        let project_key = normalized_project_key(message.project_cwd.as_deref());
        let index = match project_indexes.get(&project_key) {
            Some(index) => *index,
            None => {
                let index = projects.len();
                project_indexes.insert(project_key.clone(), index);
                projects.push(ProjectDayData {
                    project_key,
                    messages: Vec::new(),
                    last_activity_at: message.created_at,
                });
                index
            }
        };

        let project = &mut projects[index];
        project.last_activity_at = project.last_activity_at.max(message.created_at);
        project.messages.push(message);
    }

    projects
}

fn normalized_project_key(cwd: Option<&str>) -> String {
    let Some(cwd) = cwd.map(str::trim).filter(|cwd| !cwd.is_empty()) else {
        return NO_WORKING_DIRECTORY.to_string();
    };

    normalize_home_directory_prefix(cwd)
}

fn normalize_home_directory_prefix(path: &str) -> String {
    if let Some(rest) = strip_named_home_prefix(path, "/Users/") {
        return if rest.is_empty() {
            "~".to_string()
        } else {
            format!("~/{rest}")
        };
    }

    if let Some(rest) = strip_named_home_prefix(path, "/home/") {
        return if rest.is_empty() {
            "~".to_string()
        } else {
            format!("~/{rest}")
        };
    }

    path.to_string()
}

fn strip_named_home_prefix(path: &str, prefix: &str) -> Option<String> {
    let remainder = path.strip_prefix(prefix)?;
    let mut parts = remainder.splitn(2, '/');
    let username = parts.next()?;
    if username.is_empty() {
        return None;
    }

    let rest = parts.next().unwrap_or("").trim_matches('/').to_string();
    Some(rest)
}

fn build_candidate_excerpts(project: &ProjectDayData) -> Vec<ExcerptCandidate> {
    let mut candidates = collect_candidate_excerpts(project, true);
    if candidates.len() < MIN_STRICT_EXCERPTS {
        let seen = candidates
            .iter()
            .map(|candidate| canonical_excerpt_text(&candidate.text))
            .collect::<HashSet<_>>();
        let relaxed = collect_candidate_excerpts_with_seen(project, false, seen);
        candidates.extend(relaxed);
    }

    candidates.sort_by(|left, right| {
        right
            .score
            .cmp(&left.score)
            .then_with(|| left.created_at.cmp(&right.created_at))
            .then_with(|| left.text.cmp(&right.text))
    });

    let mut selected = Vec::new();
    let mut seen = HashSet::new();

    for candidate in candidates
        .iter()
        .filter(|candidate| is_outcome_excerpt_candidate(candidate))
        .take(MAX_OUTCOME_EXCERPTS)
    {
        let canonical = canonical_excerpt_text(&candidate.text);
        if seen.insert(canonical) {
            selected.push(candidate.clone());
        }
    }

    for candidate in candidates {
        if selected.len() >= MAX_CANDIDATE_EXCERPTS {
            break;
        }

        let canonical = canonical_excerpt_text(&candidate.text);
        if seen.insert(canonical) {
            selected.push(candidate);
        }
    }

    selected.sort_by(|left, right| {
        left.created_at
            .cmp(&right.created_at)
            .then_with(|| left.text.cmp(&right.text))
    });

    for (index, candidate) in selected.iter_mut().enumerate() {
        candidate.id = format!("E{}", index + 1);
    }

    selected
}

fn collect_candidate_excerpts(project: &ProjectDayData, strict: bool) -> Vec<ExcerptCandidate> {
    collect_candidate_excerpts_with_seen(project, strict, HashSet::new())
}

fn collect_candidate_excerpts_with_seen(
    project: &ProjectDayData,
    strict: bool,
    mut seen: HashSet<String>,
) -> Vec<ExcerptCandidate> {
    let mut candidates = Vec::new();

    for message in &project.messages {
        let Some(text) = message.text.as_deref() else {
            continue;
        };
        let Some(text) = candidate_excerpt_text(&message.role, text, strict) else {
            continue;
        };

        let canonical = canonical_excerpt_text(&text);
        if !seen.insert(canonical) {
            continue;
        }

        candidates.push(ExcerptCandidate {
            id: String::new(),
            created_at: message.created_at,
            role: message.role.clone(),
            score: excerpt_score(&message.role, &text),
            text,
            link_target: MessageLinkTarget {
                host_location: message.host_location.clone(),
                session_id: message.session_id.clone(),
                message_key: message.message_key.clone(),
            },
        });
    }

    candidates
}

fn candidate_excerpt_text(role: &str, text: &str, strict: bool) -> Option<String> {
    if !matches!(role, "user" | "assistant" | "custom" | "other") {
        return None;
    }

    let text = collapse_whitespace(text);
    if text.is_empty() || text == "[Image]" {
        return None;
    }

    if role == "assistant" && is_low_signal_excerpt(role, &text) {
        return None;
    }

    if strict {
        if text.chars().count() < 16 || is_low_signal_excerpt(role, &text) {
            return None;
        }
    } else if text.chars().count() < 6 || is_extremely_low_signal_excerpt(&text) {
        return None;
    }

    Some(truncate_chars(&text, MAX_EXCERPT_CHARS))
}

fn is_low_signal_excerpt(role: &str, text: &str) -> bool {
    let lower = text.trim().to_ascii_lowercase();
    if is_extremely_low_signal_excerpt(&lower) {
        return true;
    }

    if lower.contains("tool call:") || lower.contains("timeout:") {
        return true;
    }

    if role == "assistant" && is_assistant_self_instruction(&lower) {
        return true;
    }

    false
}

fn is_assistant_self_instruction(text: &str) -> bool {
    let assistant_meta_prefixes = [
        "let me ",
        "now let me ",
        "ok let me ",
        "okay let me ",
        "i'll ",
        "i will ",
        "i can ",
        "i'm going to ",
        "first, let me ",
        "first let me ",
        "next, let me ",
        "to start, ",
        "if that sounds right",
        "if you want, i can",
        "now add ",
        "now update ",
        "now remove ",
        "now change ",
        "now create ",
        "now make ",
        "good, now ",
        "great, now ",
        "let's ",
    ];

    assistant_meta_prefixes
        .iter()
        .any(|prefix| text.starts_with(prefix))
}

fn is_extremely_low_signal_excerpt(text: &str) -> bool {
    let lower = text.trim().to_ascii_lowercase();
    if matches!(
        lower.as_str(),
        "ok" | "okay"
            | "yes"
            | "yep"
            | "sure"
            | "thanks"
            | "thank you"
            | "sounds good"
            | "great"
            | "done"
            | "sgtm"
    ) {
        return true;
    }

    lower.starts_with("$ ")
        || lower.starts_with("trace: ")
        || lower.starts_with("stdout:")
        || lower.starts_with("stderr:")
}

fn excerpt_score(role: &str, text: &str) -> i32 {
    let role_score = match role {
        "user" => 45,
        "assistant" => 30,
        "custom" => 18,
        "other" => 12,
        _ => 0,
    };

    let length = i32::try_from(text.chars().count()).unwrap_or(i32::MAX);
    let ideal_length = 96;
    let length_score = (30 - ((length - ideal_length).abs() / 4)).clamp(0, 30);
    let correction_bonus = if looks_like_user_correction(text) {
        16
    } else {
        0
    };
    let accomplishment_bonus = if looks_like_outcome_statement(text) {
        10
    } else {
        0
    };
    let punctuation_bonus = if text.contains('?') || text.contains(':') {
        4
    } else {
        0
    };

    role_score + length_score + correction_bonus + accomplishment_bonus + punctuation_bonus
}

fn build_miss_candidates(project: &ProjectDayData) -> Vec<MissCandidate> {
    let mut last_assistant_by_session = HashMap::<String, AssistantContext>::new();
    let mut candidates = Vec::new();
    let mut seen = HashSet::new();

    for message in &project.messages {
        let Some(text) = message.text.as_deref() else {
            continue;
        };
        let session_key = format!("{}\u{1F}{}", message.host_location, message.session_id);

        match message.role.as_str() {
            "assistant" => {
                if !is_extremely_low_signal_excerpt(text) {
                    last_assistant_by_session.insert(
                        session_key,
                        AssistantContext {
                            created_at: message.created_at,
                            text: truncate_chars(text, MAX_EXCERPT_CHARS),
                            link_target: MessageLinkTarget {
                                host_location: message.host_location.clone(),
                                session_id: message.session_id.clone(),
                                message_key: message.message_key.clone(),
                            },
                        },
                    );
                }
            }
            "user" => {
                if !looks_like_user_correction(text) {
                    continue;
                }

                let Some(previous_assistant) = last_assistant_by_session.get(&session_key) else {
                    continue;
                };
                if message.created_at - previous_assistant.created_at
                    > ChronoDuration::minutes(MAX_CORRECTION_WINDOW_GAP_MINUTES)
                {
                    continue;
                }

                let correction_text = truncate_chars(text, MAX_EXCERPT_CHARS);
                let canonical = format!(
                    "{}\n{}",
                    canonical_excerpt_text(&previous_assistant.text),
                    canonical_excerpt_text(&correction_text)
                );
                if !seen.insert(canonical) {
                    continue;
                }

                candidates.push(MissCandidate {
                    id: String::new(),
                    created_at: message.created_at,
                    assistant_text: Some(previous_assistant.text.clone()),
                    assistant_link_target: Some(previous_assistant.link_target.clone()),
                    correction_text: correction_text.clone(),
                    correction_link_target: MessageLinkTarget {
                        host_location: message.host_location.clone(),
                        session_id: message.session_id.clone(),
                        message_key: message.message_key.clone(),
                    },
                    score: miss_candidate_score(&correction_text, previous_assistant.text.as_str()),
                });
            }
            _ => {}
        }
    }

    candidates.sort_by(|left, right| {
        right
            .score
            .cmp(&left.score)
            .then_with(|| left.created_at.cmp(&right.created_at))
            .then_with(|| left.correction_text.cmp(&right.correction_text))
    });
    candidates.truncate(MAX_MISS_CANDIDATES);
    candidates.sort_by(|left, right| {
        left.created_at
            .cmp(&right.created_at)
            .then_with(|| left.correction_text.cmp(&right.correction_text))
    });

    for (index, candidate) in candidates.iter_mut().enumerate() {
        candidate.id = format!("M{}", index + 1);
    }

    candidates
}

fn looks_like_user_correction(text: &str) -> bool {
    let lower = text.trim().to_ascii_lowercase();
    let strong_prefixes = [
        "no ",
        "no,",
        "sorry but ",
        "i meant ",
        "i mean ",
        "i'm not talking about",
        "im not talking about",
        "that is wrong",
        "that's wrong",
        "this is wrong",
        "that summary is garbage",
        "this summary is garbage",
        "we don't ",
        "we do not ",
        "it should ",
        "instead ",
        "not ",
    ];
    if strong_prefixes
        .iter()
        .any(|prefix| lower.starts_with(prefix))
    {
        return true;
    }

    let strong_contains = [
        "not talking about",
        "should be",
        "instead of",
        "rather than",
        "that was wrong",
        "summary is garbage",
        "missed the mark",
    ];
    strong_contains.iter().any(|needle| lower.contains(needle))
}

fn looks_like_outcome_statement(text: &str) -> bool {
    let lower = text.trim().to_ascii_lowercase();
    if is_assistant_self_instruction(&lower) {
        return false;
    }

    [
        "added ",
        "implemented ",
        "updated ",
        "fixed ",
        "switched ",
        "changed ",
        "defined ",
        "introduced ",
        "supports ",
        "renders ",
        "groups ",
        "uses ",
        "done",
        "completed ",
        "verified ",
        "confirmed ",
        "all ",
        "tests pass",
        "tests passed",
        "now supports",
        "now renders",
        "now groups",
        "now uses",
        "made ",
        "removed ",
        "normalized ",
    ]
    .iter()
    .any(|needle| lower.starts_with(needle) || lower.contains(&format!(" {needle}")))
}

fn is_outcome_excerpt_candidate(candidate: &ExcerptCandidate) -> bool {
    candidate.role == "assistant" && looks_like_outcome_statement(&candidate.text)
}

fn is_topic_excerpt_candidate(candidate: &ExcerptCandidate) -> bool {
    candidate.role == "user" && !looks_like_user_correction(&candidate.text)
}

fn excerpt_tags(candidate: &ExcerptCandidate) -> String {
    let mut tags = Vec::new();
    if is_topic_excerpt_candidate(candidate) {
        tags.push("topic");
    }
    if is_outcome_excerpt_candidate(candidate) {
        tags.push("outcome");
    }
    if looks_like_user_correction(&candidate.text) {
        tags.push("correction");
    }
    if tags.is_empty() {
        tags.push("other");
    }
    tags.join(",")
}

fn miss_candidate_score(correction_text: &str, assistant_text: &str) -> i32 {
    let correction_lower = correction_text.to_ascii_lowercase();
    let strong_signal_bonus = if correction_lower.contains("garbage")
        || correction_lower.contains("wrong")
        || correction_lower.contains("not talking about")
    {
        25
    } else if correction_lower.contains("should be") || correction_lower.contains("instead") {
        15
    } else {
        8
    };

    let assistant_length_bonus = i32::try_from(assistant_text.chars().count().min(120)).unwrap();
    strong_signal_bonus + assistant_length_bonus / 8
}

async fn summarize_project_day_via_pi(
    report_date: NaiveDate,
    project: &ProjectDayData,
    excerpts: &[ExcerptCandidate],
    misses: &[MissCandidate],
    pi_agent_dir: &PathBuf,
    summary_model: &str,
    ui_base_url: &str,
) -> Result<RenderedProjectReport, BoxError> {
    if excerpts.is_empty() && misses.is_empty() {
        return Err("no usable evidence found for project".into());
    }

    let prompt = build_project_summary_prompt(report_date, project, excerpts, misses);
    let mut command = Command::new(agent::resolve_pi_executable(pi_agent_dir));
    command
        .arg("-p")
        .arg("--no-session")
        .arg("--no-extensions")
        .arg("--no-skills")
        .arg("--thinking")
        .arg("off")
        .arg("--model")
        .arg(summary_model)
        .arg(prompt)
        .env("PI_SKIP_VERSION_CHECK", "1")
        .env("PI_CODING_AGENT_DIR", pi_agent_dir)
        .current_dir(pi_agent_dir)
        .kill_on_drop(true);

    let output = command.output().await?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
        let details = if !stderr.is_empty() {
            stderr
        } else if !stdout.is_empty() {
            stdout
        } else {
            format!("pi exited with status {}", output.status)
        };
        return Err(details.into());
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    let response = parse_json_response::<ProjectSummaryResponse>(&stdout)
        .map_err(|error| format!("invalid summary response: {error}"))?;

    normalize_project_summary_response(
        project.project_key.clone(),
        response,
        excerpts,
        misses,
        ui_base_url,
    )
    .ok_or_else(|| "summary response contained no usable report items".into())
}

fn build_project_summary_prompt(
    report_date: NaiveDate,
    project: &ProjectDayData,
    excerpts: &[ExcerptCandidate],
    misses: &[MissCandidate],
) -> String {
    let excerpt_lines = if excerpts.is_empty() {
        "- none".to_string()
    } else {
        excerpts
            .iter()
            .map(|candidate| {
                format!(
                    "{} | {} | {} | {}",
                    candidate.id,
                    candidate.role,
                    excerpt_tags(candidate),
                    candidate.text
                )
            })
            .collect::<Vec<_>>()
            .join("\n")
    };

    let miss_lines = if misses.is_empty() {
        "- none".to_string()
    } else {
        misses
            .iter()
            .map(|candidate| match candidate.assistant_text.as_deref() {
                Some(assistant_text) => format!(
                    concat!("{} | assistant: {}\n", "   correction: {}"),
                    candidate.id, assistant_text, candidate.correction_text
                ),
                None => format!(
                    "{} | correction: {}",
                    candidate.id, candidate.correction_text
                ),
            })
            .collect::<Vec<_>>()
            .join("\n")
    };

    format!(
        concat!(
            "Generate a concise daily coding report for one project.\n\n",
            "Date: {report_date}\n",
            "Project: {project}\n\n",
            "Evidence excerpts from that day (each line is ID | role | tags | text):\n",
            "{excerpt_lines}\n\n",
            "Tag guide:\n",
            "- topic = issue/request/workstream context, usually best for Worked on\n",
            "- outcome = completed change, verified result, or concrete delivered decision, best for Accomplished\n",
            "- correction = user pushback or correction, usually not an accomplishment by itself\n\n",
            "Potential LLM miss windows from that day (assistant statement followed by user correction):\n",
            "{miss_lines}\n\n",
            "Return ONLY valid JSON in this exact shape:\n",
            "{{\n",
            "  \"workedOn\": [\"...\"],\n",
            "  \"accomplishments\": [\n",
            "    {{ \"summary\": \"...\", \"excerptIds\": [\"E1\", \"E4\"] }}\n",
            "  ],\n",
            "  \"llmMisses\": [\n",
            "    {{ \"summary\": \"...\", \"lesson\": \"...\", \"missIds\": [\"M1\"], \"excerptIds\": [\"E2\"] }}\n",
            "  ]\n",
            "}}\n\n",
            "Rules:\n",
            "- Use only the evidence above\n",
            "- Keep it project-based, not session-based\n",
            "- Do not mention sessions, hosts, or counts\n",
            "- \"workedOn\" should contain 1 to 5 short bullets about what the project work focused on that day\n",
            "- Use excerpts tagged `topic` mainly for `workedOn`\n",
            "- \"accomplishments\" should contain 1 to 5 concrete outcomes, decisions, or completed steps that actually happened\n",
            "- Prefer excerpts tagged `outcome` for accomplishments\n",
            "- If there is no clear completed result, omit the accomplishment instead of restating an ask, question, or investigation\n",
            "- BAD accomplishments include wording like: explored, investigated, looked into, traced, let me, can we, why did, or user requests phrased as future work\n",
            "- Accomplishments MAY omit excerptIds when the evidence is diffuse or no single quote is strong enough\n",
            "- Prefer excerptIds only when they clearly support the accomplishment\n",
            "- When citing evidence, prefer the single most direct quote; add a second quote only when it adds distinct support\n",
            "- Avoid selecting near-duplicate quotes or generic delivery chatter like 'Yep — I added it' when a more direct quote is available\n",
            "- Do NOT treat exploratory assistant chatter like 'let me inspect', 'now let me see', or tool-use narration as accomplishments\n",
            "- \"llmMisses\" should contain only cases where the assistant clearly misunderstood scope, took the wrong direction, or needed user correction\n",
            "- For each LLM miss, include a short \"lesson\" that could improve prompts or skills in the future\n",
            "- Prefer missIds for llmMisses; excerptIds are optional supporting quotes\n",
            "- Do not invent quote text or IDs\n",
            "- Keep each item concise and factual\n"
        ),
        report_date = report_date,
        project = project.project_key,
        excerpt_lines = excerpt_lines,
        miss_lines = miss_lines,
    )
}

fn normalize_project_summary_response(
    project_key: String,
    response: ProjectSummaryResponse,
    excerpts: &[ExcerptCandidate],
    misses: &[MissCandidate],
    ui_base_url: &str,
) -> Option<RenderedProjectReport> {
    let excerpt_lookup = excerpts
        .iter()
        .map(|candidate| (candidate.id.as_str(), candidate))
        .collect::<HashMap<_, _>>();
    let miss_lookup = misses
        .iter()
        .map(|candidate| (candidate.id.as_str(), candidate))
        .collect::<HashMap<_, _>>();

    let mut worked_on = Vec::new();
    for item in response.worked_on {
        let Some(item) = normalize_report_line(&item) else {
            continue;
        };
        push_unique_case_insensitive(&mut worked_on, item);
        if worked_on.len() >= MAX_WORKED_ON_ITEMS {
            break;
        }
    }

    let mut accomplishments = Vec::new();
    for accomplishment in response.accomplishments {
        let Some(summary) = normalize_report_line(&accomplishment.summary) else {
            continue;
        };
        if accomplishments
            .iter()
            .any(|existing: &RenderedAccomplishment| {
                existing.summary.eq_ignore_ascii_case(&summary)
            })
        {
            continue;
        }

        let excerpts = excerpts_from_ids(&accomplishment.excerpt_ids, &excerpt_lookup, ui_base_url);
        accomplishments.push(RenderedAccomplishment { summary, excerpts });
        if accomplishments.len() >= MAX_ACCOMPLISHMENTS {
            break;
        }
    }

    let mut llm_misses = Vec::new();
    for miss in response.llm_misses {
        let Some(summary) = normalize_report_line(&miss.summary) else {
            continue;
        };
        if llm_misses
            .iter()
            .any(|existing: &RenderedMiss| existing.summary.eq_ignore_ascii_case(&summary))
        {
            continue;
        }

        let lesson = normalize_report_line(&miss.lesson);
        let mut evidence_lines = Vec::new();
        let mut seen_evidence = HashSet::new();

        for miss_id in miss.miss_ids {
            let miss_id = collapse_whitespace(&miss_id);
            let Some(candidate) = miss_lookup.get(miss_id.as_str()) else {
                continue;
            };
            if let Some(assistant_text) = candidate.assistant_text.as_deref() {
                let line = format!("LLM: {}", truncate_chars(assistant_text, MAX_EXCERPT_CHARS));
                if seen_evidence.insert(line.to_ascii_lowercase()) {
                    evidence_lines.push(FootnoteEvidence {
                        text: line,
                        ui_url: candidate
                            .assistant_link_target
                            .as_ref()
                            .map(|target| report_ui_message_url(ui_base_url, target)),
                    });
                }
            }
            let correction_line = format!(
                "Correction: {}",
                truncate_chars(&candidate.correction_text, MAX_EXCERPT_CHARS)
            );
            if seen_evidence.insert(correction_line.to_ascii_lowercase()) {
                evidence_lines.push(FootnoteEvidence {
                    text: correction_line,
                    ui_url: Some(report_ui_message_url(
                        ui_base_url,
                        &candidate.correction_link_target,
                    )),
                });
            }
            if evidence_lines.len() >= MAX_EVIDENCE_LINES_PER_MISS {
                break;
            }
        }

        if evidence_lines.len() < MAX_EVIDENCE_LINES_PER_MISS {
            for excerpt in excerpts_from_ids(&miss.excerpt_ids, &excerpt_lookup, ui_base_url) {
                let line = truncate_chars(&excerpt.text, MAX_EXCERPT_CHARS);
                if seen_evidence.insert(line.to_ascii_lowercase()) {
                    evidence_lines.push(FootnoteEvidence {
                        text: line,
                        ui_url: excerpt.ui_url,
                    });
                }
                if evidence_lines.len() >= MAX_EVIDENCE_LINES_PER_MISS {
                    break;
                }
            }
        }

        llm_misses.push(RenderedMiss {
            summary,
            lesson,
            evidence_lines,
        });
        if llm_misses.len() >= MAX_LLM_MISSES {
            break;
        }
    }

    if worked_on.is_empty() {
        for accomplishment in &accomplishments {
            push_unique_case_insensitive(&mut worked_on, accomplishment.summary.clone());
            if worked_on.len() >= MAX_WORKED_ON_ITEMS {
                break;
            }
        }
    }

    if worked_on.is_empty() {
        for excerpt in excerpts.iter().filter(|excerpt| excerpt.role == "user") {
            let Some(item) = normalize_report_line(&headline_from_excerpt(&excerpt.text)) else {
                continue;
            };
            push_unique_case_insensitive(&mut worked_on, item);
            if worked_on.len() >= MAX_WORKED_ON_ITEMS {
                break;
            }
        }
    }

    if worked_on.is_empty() && accomplishments.is_empty() && llm_misses.is_empty() {
        None
    } else {
        Some(RenderedProjectReport {
            project_key,
            worked_on,
            accomplishments,
            llm_misses,
        })
    }
}

fn excerpts_from_ids(
    excerpt_ids: &[String],
    excerpt_lookup: &HashMap<&str, &ExcerptCandidate>,
    ui_base_url: &str,
) -> Vec<FootnoteEvidence> {
    let mut excerpts = Vec::new();
    let mut seen_excerpt_ids = HashSet::new();
    let mut seen_canonical_texts: Vec<String> = Vec::new();

    for excerpt_id in excerpt_ids {
        let excerpt_id = collapse_whitespace(excerpt_id);
        if excerpt_id.is_empty() || !seen_excerpt_ids.insert(excerpt_id.clone()) {
            continue;
        }

        let Some(excerpt) = excerpt_lookup.get(excerpt_id.as_str()) else {
            continue;
        };
        let excerpt_text = truncate_chars(&excerpt.text, MAX_EXCERPT_CHARS);
        let canonical = canonical_footnote_text_from_text(&excerpt_text);
        if seen_canonical_texts
            .iter()
            .any(|existing| footnote_texts_are_redundant(existing, &canonical))
        {
            continue;
        }

        seen_canonical_texts.push(canonical);
        if excerpts
            .iter()
            .all(|existing: &FootnoteEvidence| !existing.text.eq_ignore_ascii_case(&excerpt_text))
        {
            excerpts.push(FootnoteEvidence {
                text: excerpt_text,
                ui_url: Some(report_ui_message_url(ui_base_url, &excerpt.link_target)),
            });
        }
        if excerpts.len() >= MAX_EXCERPTS_PER_ACCOMPLISHMENT {
            break;
        }
    }

    excerpts
}

fn heuristic_project_report(
    project: &ProjectDayData,
    excerpts: &[ExcerptCandidate],
    misses: &[MissCandidate],
    ui_base_url: &str,
) -> RenderedProjectReport {
    let mut worked_on = Vec::new();
    for excerpt in excerpts.iter().filter(|excerpt| excerpt.role == "user") {
        let Some(item) = normalize_report_line(&headline_from_excerpt(&excerpt.text)) else {
            continue;
        };
        push_unique_case_insensitive(&mut worked_on, item);
        if worked_on.len() >= MAX_WORKED_ON_ITEMS {
            break;
        }
    }

    let mut accomplishments = Vec::new();
    for excerpt in excerpts
        .iter()
        .filter(|excerpt| looks_like_outcome_statement(&excerpt.text))
    {
        let Some(summary) = normalize_report_line(&headline_from_excerpt(&excerpt.text)) else {
            continue;
        };
        if accomplishments
            .iter()
            .any(|existing: &RenderedAccomplishment| {
                existing.summary.eq_ignore_ascii_case(&summary)
            })
        {
            continue;
        }

        accomplishments.push(RenderedAccomplishment {
            summary,
            excerpts: vec![FootnoteEvidence {
                text: excerpt.text.clone(),
                ui_url: Some(report_ui_message_url(ui_base_url, &excerpt.link_target)),
            }],
        });
        if accomplishments.len() >= MAX_ACCOMPLISHMENTS {
            break;
        }
    }

    let mut llm_misses = Vec::new();
    for miss in misses {
        let Some(summary) = normalize_report_line(&headline_from_excerpt(&miss.correction_text))
        else {
            continue;
        };
        if llm_misses
            .iter()
            .any(|existing: &RenderedMiss| existing.summary.eq_ignore_ascii_case(&summary))
        {
            continue;
        }

        let lesson = normalize_report_line(&miss.correction_text);
        let mut evidence_lines = Vec::new();
        if let Some(assistant_text) = miss.assistant_text.as_deref() {
            evidence_lines.push(FootnoteEvidence {
                text: format!("LLM: {}", truncate_chars(assistant_text, MAX_EXCERPT_CHARS)),
                ui_url: miss
                    .assistant_link_target
                    .as_ref()
                    .map(|target| report_ui_message_url(ui_base_url, target)),
            });
        }
        evidence_lines.push(FootnoteEvidence {
            text: format!(
                "Correction: {}",
                truncate_chars(&miss.correction_text, MAX_EXCERPT_CHARS)
            ),
            ui_url: Some(report_ui_message_url(
                ui_base_url,
                &miss.correction_link_target,
            )),
        });

        llm_misses.push(RenderedMiss {
            summary,
            lesson,
            evidence_lines,
        });
        if llm_misses.len() >= MAX_LLM_MISSES {
            break;
        }
    }

    if worked_on.is_empty() {
        for accomplishment in &accomplishments {
            push_unique_case_insensitive(&mut worked_on, accomplishment.summary.clone());
            if worked_on.len() >= MAX_WORKED_ON_ITEMS {
                break;
            }
        }
    }

    if worked_on.is_empty() {
        push_unique_case_insensitive(&mut worked_on, project.project_key.clone());
    }

    RenderedProjectReport {
        project_key: project.project_key.clone(),
        worked_on,
        accomplishments,
        llm_misses,
    }
}

fn headline_from_excerpt(text: &str) -> String {
    let trimmed = text.trim();
    for delimiter in [". ", "? ", "! "] {
        if let Some((first, _)) = trimmed.split_once(delimiter)
            && first.chars().count() >= 20
        {
            return first.to_string();
        }
    }

    truncate_chars(trimmed, 110)
}

fn normalize_report_line(value: &str) -> Option<String> {
    let normalized = collapse_whitespace(value)
        .trim_start_matches("- ")
        .trim_matches('`')
        .trim_matches('"')
        .trim_matches('\'')
        .trim_end_matches(['.', '!', '?', ';', ':'])
        .trim()
        .to_string();

    if normalized.is_empty() {
        None
    } else {
        Some(normalized)
    }
}

fn render_day_report(report_date: NaiveDate, projects: &[RenderedProjectReport]) -> String {
    if projects.is_empty() {
        return format!(
            "# Daily report for {report_date}\n\nNo archived project activity found.\n"
        );
    }

    let mut lines = vec![format!("# Daily report for {report_date}"), String::new()];
    let mut next_footnote_index = 1usize;
    let mut footnotes = Vec::new();

    for (index, project) in projects.iter().enumerate() {
        if index > 0 {
            lines.push(String::new());
        }

        lines.push(format!("## {}", project.project_key));
        lines.push(String::new());

        if !project.worked_on.is_empty() {
            lines.push("Worked on:".to_string());
            for item in &project.worked_on {
                lines.push(format!("- {item}"));
            }
            lines.push(String::new());
        }

        if !project.accomplishments.is_empty() {
            lines.push("Accomplished:".to_string());
            for accomplishment in &project.accomplishments {
                let summary = with_footnote_refs(
                    &accomplishment.summary,
                    &accomplishment.excerpts,
                    &mut next_footnote_index,
                    &mut footnotes,
                );
                lines.push(format!("- {summary}"));
            }
            lines.push(String::new());
        }

        if !project.llm_misses.is_empty() {
            lines.push("LLM misses:".to_string());
            for miss in &project.llm_misses {
                let summary = with_footnote_refs(
                    &miss.summary,
                    &miss.evidence_lines,
                    &mut next_footnote_index,
                    &mut footnotes,
                );
                lines.push(format!("- {summary}"));
                if let Some(lesson) = miss.lesson.as_deref() {
                    lines.push(format!("  Lesson: {lesson}"));
                }
            }
        }
    }

    if !footnotes.is_empty() {
        lines.push(String::new());
        lines.extend(footnotes);
    }

    lines.push(String::new());
    lines.join("\n")
}

fn render_footnote_text(note: &FootnoteEvidence) -> Option<String> {
    let note_text = collapse_whitespace(&note.text);
    let (label, body) = split_footnote_label(&note_text);
    let body = best_footnote_text(body)?;
    let rendered = format!("{label}{body}");

    match note.ui_url.as_deref() {
        Some(ui_url) => Some(format!("{rendered} ([ui]({ui_url}))")),
        None => Some(rendered),
    }
}

fn split_footnote_label(text: &str) -> (&'static str, &str) {
    if let Some(rest) = text.strip_prefix("LLM: ") {
        ("LLM: ", rest)
    } else if let Some(rest) = text.strip_prefix("Correction: ") {
        ("Correction: ", rest)
    } else {
        ("", text)
    }
}

fn best_footnote_text(text: &str) -> Option<String> {
    let text = collapse_whitespace(text).trim().to_string();
    if text.is_empty() {
        return None;
    }

    let mut candidates = vec![text.clone()];
    for marker in [
        "What changed:",
        "Changed:",
        "Change:",
        "What it does:",
        "Updated:",
        "Created:",
        "Cause:",
    ] {
        if let Some((before, after)) = text.split_once(marker) {
            candidates.push(before.to_string());
            candidates.push(after.to_string());
        }
    }

    let mut best: Option<(i32, String)> = None;
    for candidate in candidates {
        let Some(candidate) = clean_footnote_candidate(&candidate) else {
            continue;
        };
        for variant in [candidate.clone(), headline_from_excerpt(&candidate)] {
            let Some(variant) = normalize_report_line(&variant) else {
                continue;
            };
            let score = footnote_candidate_score(&variant);
            match &best {
                Some((best_score, best_text))
                    if score < *best_score
                        || (score == *best_score
                            && variant.chars().count() >= best_text.chars().count()) => {}
                _ => best = Some((score, variant)),
            }
        }
    }

    best.and_then(|(score, text)| {
        (score >= MIN_FOOTNOTE_SCORE).then(|| truncate_chars(&text, MAX_FOOTNOTE_CHARS))
    })
}

fn clean_footnote_candidate(text: &str) -> Option<String> {
    let mut text = collapse_whitespace(text)
        .trim()
        .trim_start_matches("- ")
        .trim()
        .to_string();
    if text.is_empty() {
        return None;
    }

    for prefix in [
        "Yep — ",
        "Yes — ",
        "Yeah — ",
        "Done. ",
        "Updated. ",
        "Added. ",
        "Implemented. ",
        "Confirmed. ",
        "Verified. ",
    ] {
        if let Some(stripped) = strip_prefix_ignore_ascii_case(&text, prefix) {
            text = stripped.trim().to_string();
            break;
        }
    }

    for lead in [
        "I added it.",
        "I fixed it.",
        "I updated it.",
        "It's fixed.",
        "It is fixed.",
        "It's done.",
        "It is done.",
    ] {
        if text.starts_with(lead)
            && let Some((_, rest)) = text.split_once('.')
        {
            text = rest.trim().trim_start_matches('-').trim().to_string();
            break;
        }
    }

    while let Some(stripped) = strip_leading_code_bullet(&text) {
        text = stripped.to_string();
    }
    while let Some(stripped) = strip_leading_path_prefix(&text) {
        text = stripped.to_string();
    }

    let text = text
        .trim()
        .trim_matches('"')
        .trim_matches('`')
        .trim()
        .to_string();
    if text.is_empty() { None } else { Some(text) }
}

fn strip_leading_code_bullet(text: &str) -> Option<&str> {
    let trimmed = text.trim_start();
    let bullet = trimmed.strip_prefix("- `")?;
    let end = bullet.find("` - ")?;
    Some(bullet[end + 4..].trim())
}

fn strip_leading_path_prefix(text: &str) -> Option<&str> {
    let trimmed = text.trim_start();
    let (head, tail) = trimmed.split_once(" - ")?;
    let head = head.trim().trim_matches('`').trim();
    if head.contains('/')
        || head.ends_with(".swift")
        || head.ends_with(".rs")
        || head.ends_with(".md")
    {
        Some(tail.trim())
    } else {
        None
    }
}

fn strip_prefix_ignore_ascii_case<'a>(text: &'a str, prefix: &str) -> Option<&'a str> {
    text.get(..prefix.len())
        .filter(|candidate| candidate.eq_ignore_ascii_case(prefix))?;
    Some(&text[prefix.len()..])
}

fn footnote_candidate_score(text: &str) -> i32 {
    let lower = text.to_ascii_lowercase();
    let mut score = 0;
    let len = i32::try_from(text.chars().count()).unwrap_or(i32::MAX);

    score += (60 - ((len - 90).abs() / 2)).clamp(0, 60);
    if looks_like_outcome_statement(text) {
        score += 35;
    }
    if looks_like_user_correction(text) {
        score += 20;
    }
    if lower.contains("what changed") || lower.contains("changed:") {
        score -= 15;
    }
    if lower.contains("cause:") {
        score -= 10;
    }
    if lower.starts_with("fixed in `") {
        score -= 20;
    }
    if lower.contains("tool call:") {
        score -= 40;
    }
    score -= i32::try_from(text.matches('`').count()).unwrap_or(0) * 3;

    score
}

fn canonical_footnote_text(text: &str) -> String {
    let (_, body) = split_footnote_label(text);
    collapse_whitespace(body).trim().to_ascii_lowercase()
}

fn canonical_footnote_text_from_text(text: &str) -> String {
    canonical_footnote_text(text)
}

fn footnote_texts_are_redundant(left: &str, right: &str) -> bool {
    left == right
        || (left.chars().count() >= 24
            && right.chars().count() >= 24
            && (left.contains(right) || right.contains(left)))
}

fn with_footnote_refs(
    text: &str,
    note_texts: &[FootnoteEvidence],
    next_footnote_index: &mut usize,
    footnotes: &mut Vec<String>,
) -> String {
    let mut line = text.to_string();
    let mut selected_canonicals: Vec<String> = Vec::new();

    for note in note_texts {
        let Some(note_text) = render_footnote_text(note) else {
            continue;
        };
        let canonical = canonical_footnote_text(&note.text);
        if canonical.is_empty()
            || selected_canonicals
                .iter()
                .any(|existing| footnote_texts_are_redundant(existing, &canonical))
        {
            continue;
        }

        selected_canonicals.push(canonical);
        let index = *next_footnote_index;
        *next_footnote_index += 1;
        line.push_str(&format!("[^{}]", index));
        footnotes.push(format!("[^{}]: {}", index, note_text));
    }

    line
}

fn parse_json_response<T: DeserializeOwned>(text: &str) -> Result<T, String> {
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return Err("empty response".to_string());
    }

    if let Ok(value) = serde_json::from_str::<T>(trimmed) {
        return Ok(value);
    }

    if let Some(stripped) = strip_markdown_fences(trimmed)
        && let Ok(value) = serde_json::from_str::<T>(&stripped)
    {
        return Ok(value);
    }

    if let Some(json_object) = extract_top_level_json_object(trimmed)
        && let Ok(value) = serde_json::from_str::<T>(json_object)
    {
        return Ok(value);
    }

    Err(truncate_chars(trimmed, 500))
}

fn strip_markdown_fences(text: &str) -> Option<String> {
    let stripped = text.strip_prefix("```json")?.trim();
    let stripped = stripped.strip_suffix("```")?.trim();
    Some(stripped.to_string())
}

fn extract_top_level_json_object(text: &str) -> Option<&str> {
    let start = text.find('{')?;
    let end = text.rfind('}')?;
    (start < end).then_some(&text[start..=end])
}

fn canonical_excerpt_text(text: &str) -> String {
    text.trim().to_ascii_lowercase()
}

fn push_unique_case_insensitive(values: &mut Vec<String>, value: String) {
    let canonical = value.to_ascii_lowercase();
    if values
        .iter()
        .all(|existing| existing.to_ascii_lowercase() != canonical)
    {
        values.push(value);
    }
}

fn truncate_chars(text: &str, max_chars: usize) -> String {
    if text.chars().count() <= max_chars {
        return text.to_string();
    }

    let truncated = text.chars().take(max_chars).collect::<String>();
    format!("{truncated}…")
}

fn report_ui_message_url(ui_base_url: &str, target: &MessageLinkTarget) -> String {
    format!(
        "{}/ui/session?host={}&id={}&message={}#{}",
        ui_base_url.trim_end_matches('/'),
        percent_encode_component(&target.host_location),
        percent_encode_component(&target.session_id),
        percent_encode_component(&target.message_key),
        message_anchor_id(&target.message_key),
    )
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

#[cfg(test)]
mod tests {
    use chrono::TimeZone;
    use serde_json::json;

    use super::*;

    #[test]
    fn report_timezone_defaults_to_los_angeles() {
        assert_eq!(
            resolve_report_timezone(None).unwrap(),
            "America/Los_Angeles"
        );
    }

    #[test]
    fn report_timezone_rejects_blank_override() {
        assert!(resolve_report_timezone(Some("   ")).is_err());
    }

    #[test]
    fn resolve_ui_base_url_accepts_relative_paths() {
        assert_eq!(resolve_ui_base_url(Some("/")).unwrap(), "");
        assert_eq!(resolve_ui_base_url(Some("/pimux/")).unwrap(), "/pimux");
    }

    #[test]
    fn normalizes_project_keys_across_mac_and_linux_home_paths() {
        assert_eq!(
            normalized_project_key(Some("/Users/nakajima/apps/pimux2000")),
            "~/apps/pimux2000"
        );
        assert_eq!(
            normalized_project_key(Some("/home/nakajima/apps/pimux2000")),
            "~/apps/pimux2000"
        );
        assert_eq!(normalized_project_key(Some("   ")), NO_WORKING_DIRECTORY);
    }

    #[test]
    fn extracts_text_blocks_without_tool_call_noise() {
        let message_json = json!({
            "created_at": "2026-04-08T00:00:00Z",
            "role": "assistant",
            "body": "Now let me inspect this\n\nTool call: read",
            "blocks": [
                { "type": "text", "text": "Now let me inspect this" },
                { "type": "toolCall", "toolCallName": "read", "text": "{\"path\":\"x\"}" }
            ]
        });

        assert_eq!(
            extract_archived_message_text(
                &message_json,
                "Now let me inspect this\n\nTool call: read"
            ),
            Some("Now let me inspect this".to_string())
        );
    }

    #[test]
    fn candidate_excerpts_skip_tool_calls_and_meta_assistant_text() {
        let project = ProjectDayData {
            project_key: "~/apps/pimux2000".to_string(),
            last_activity_at: Utc.timestamp_opt(3_000, 0).unwrap(),
            messages: vec![
                ArchivedMessage {
                    host_location: "dev@mac".to_string(),
                    session_id: "s1".to_string(),
                    message_key: "id:a1".to_string(),
                    project_cwd: Some("/Users/nakajima/apps/pimux2000".to_string()),
                    created_at: Utc.timestamp_opt(1_000, 0).unwrap(),
                    role: "assistant".to_string(),
                    text: Some("Now let me see how activeSessionIDs is built".to_string()),
                },
                ArchivedMessage {
                    host_location: "dev@mac".to_string(),
                    session_id: "s1".to_string(),
                    message_key: "id:u1".to_string(),
                    project_cwd: Some("/Users/nakajima/apps/pimux2000".to_string()),
                    created_at: Utc.timestamp_opt(2_000, 0).unwrap(),
                    role: "user".to_string(),
                    text: Some("it should be project-based, not session based".to_string()),
                },
            ],
        };

        let candidates = build_candidate_excerpts(&project);
        assert_eq!(candidates.len(), 1);
        assert_eq!(
            candidates[0].text,
            "it should be project-based, not session based"
        );
    }

    #[test]
    fn build_miss_candidates_pairs_assistant_with_user_correction() {
        let project = ProjectDayData {
            project_key: "~/apps/pimux2000".to_string(),
            last_activity_at: Utc.timestamp_opt(3_000, 0).unwrap(),
            messages: vec![
                ArchivedMessage {
                    host_location: "dev@mac".to_string(),
                    session_id: "s1".to_string(),
                    message_key: "id:a2".to_string(),
                    project_cwd: Some("/Users/nakajima/apps/pimux2000".to_string()),
                    created_at: Utc.timestamp_opt(1_000, 0).unwrap(),
                    role: "assistant".to_string(),
                    text: Some("I'd start with session-grouped output".to_string()),
                },
                ArchivedMessage {
                    host_location: "dev@mac".to_string(),
                    session_id: "s1".to_string(),
                    message_key: "id:u2".to_string(),
                    project_cwd: Some("/Users/nakajima/apps/pimux2000".to_string()),
                    created_at: Utc.timestamp_opt(2_000, 0).unwrap(),
                    role: "user".to_string(),
                    text: Some("it should be project-based, not session based".to_string()),
                },
            ],
        };

        let misses = build_miss_candidates(&project);
        assert_eq!(misses.len(), 1);
        assert_eq!(
            misses[0].assistant_text.as_deref(),
            Some("I'd start with session-grouped output")
        );
        assert_eq!(
            misses[0].correction_text,
            "it should be project-based, not session based"
        );
    }

    #[test]
    fn render_day_report_places_all_markdown_footnotes_at_document_bottom() {
        let rendered = render_day_report(
            NaiveDate::from_ymd_opt(2026, 4, 8).unwrap(),
            &[
                RenderedProjectReport {
                    project_key: "~/apps/pimux2000".to_string(),
                    worked_on: vec!["Added report command plumbing".to_string()],
                    accomplishments: vec![
                        RenderedAccomplishment {
                            summary: "Defined project-based daily report output".to_string(),
                            excerpts: vec![footnote(
                                "it should be project-based, not session based",
                            )],
                        },
                        RenderedAccomplishment {
                            summary: "Allowed accomplishment bullets without forced excerpts"
                                .to_string(),
                            excerpts: vec![],
                        },
                    ],
                    llm_misses: vec![RenderedMiss {
                        summary: "Mis-scoped the report as session-based".to_string(),
                        lesson: Some(
                            "Daily reports should default to project-level aggregation".to_string(),
                        ),
                        evidence_lines: vec![
                            footnote("LLM: I'd start with session-grouped output"),
                            footnote("Correction: it should be project-based, not session based"),
                        ],
                    }],
                },
                RenderedProjectReport {
                    project_key: "~/apps/Termsy".to_string(),
                    worked_on: vec!["Window focus behavior".to_string()],
                    accomplishments: vec![RenderedAccomplishment {
                        summary: "Fixed focus handoff for new windows".to_string(),
                        excerpts: vec![footnote(
                            "activate the app before ordering the window front",
                        )],
                    }],
                    llm_misses: vec![],
                },
            ],
        );

        assert!(rendered.contains("- Defined project-based daily report output[^1]"));
        assert!(rendered.contains("- Allowed accomplishment bullets without forced excerpts"));
        assert!(rendered.contains("- Mis-scoped the report as session-based[^2]"));
        assert!(rendered.contains("- Fixed focus handoff for new windows[^3]"));
        assert!(
            rendered
                .contains("  Lesson: Daily reports should default to project-level aggregation")
        );
        assert!(rendered.contains("[^1]: it should be project-based, not session based"));
        assert!(rendered.contains("[^3]: activate the app before ordering the window front"));

        let termsy_heading = rendered.find("## ~/apps/Termsy").unwrap();
        let first_footnote = rendered
            .find("[^1]: it should be project-based, not session based")
            .unwrap();
        assert!(termsy_heading < first_footnote);
    }

    #[test]
    fn footnote_rendering_prefers_concise_non_redundant_evidence() {
        let rendered = render_day_report(
            NaiveDate::from_ymd_opt(2026, 4, 8).unwrap(),
            &[RenderedProjectReport {
                project_key: "~/apps/Termsy".to_string(),
                worked_on: vec!["Input debugging".to_string()],
                accomplishments: vec![RenderedAccomplishment {
                    summary: "Added raw keypress logging".to_string(),
                    excerpts: vec![
                        footnote(
                            "Yep — I added it. Changed: - `TermsyMac/MacWindowSupport.swift` What it does: - Logs macOS `keyDown`, `keyUp`, and `flagsChanged` before dispatch",
                        ),
                        footnote(
                            "Yep — I added it. Changed: - `TermsyMac/MacWindowSupport.swift` What it does: - Logs macOS `keyDown`, `keyUp`, and `flagsChanged` before dispatch and keeps a little more detail",
                        ),
                    ],
                }],
                llm_misses: vec![RenderedMiss {
                    summary: "Footnotes were duplicated".to_string(),
                    lesson: Some("Deduplicate correction evidence".to_string()),
                    evidence_lines: vec![
                        footnote("Correction: all of the footnotes should be at the bottom"),
                        footnote("all of the footnotes should be at the bottom"),
                    ],
                }],
            }],
        );

        assert!(rendered.contains("- Added raw keypress logging[^1]"));
        assert!(
            rendered.contains(
                "[^1]: Logs macOS `keyDown`, `keyUp`, and `flagsChanged` before dispatch"
            )
        );
        assert!(rendered.contains("- Footnotes were duplicated[^2]"));
        assert!(
            rendered.contains("[^2]: Correction: all of the footnotes should be at the bottom")
        );
        assert!(!rendered.contains("[^3]: all of the footnotes should be at the bottom"));
    }

    #[test]
    fn report_ui_message_url_links_to_archive_message_view() {
        let url = report_ui_message_url(
            "http://127.0.0.1:3000",
            &MessageLinkTarget {
                host_location: "dev@mac".to_string(),
                session_id: "session-1".to_string(),
                message_key: "id:entry 1".to_string(),
            },
        );

        assert_eq!(
            url,
            format!(
                "http://127.0.0.1:3000/ui/session?host=dev%40mac&id=session-1&message=id%3Aentry%201#{}",
                message_anchor_id("id:entry 1")
            )
        );
    }

    #[test]
    fn parse_json_response_accepts_markdown_fenced_json() {
        let response = parse_json_response::<ProjectSummaryResponse>(
            "```json\n{\"workedOn\":[\"Added reporting\"],\"accomplishments\":[],\"llmMisses\":[]}\n```",
        )
        .unwrap();

        assert_eq!(response.worked_on, vec!["Added reporting"]);
    }

    fn footnote(text: &str) -> FootnoteEvidence {
        FootnoteEvidence {
            text: text.to_string(),
            ui_url: None,
        }
    }
}
