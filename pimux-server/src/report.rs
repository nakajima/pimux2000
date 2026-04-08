use std::{
    collections::{HashMap, HashSet},
    env,
    error::Error as StdError,
    path::PathBuf,
};

use chrono::{DateTime, Local, NaiveDate, Utc};
use serde::{Deserialize, Serialize, de::DeserializeOwned};
use tokio::process::Command;
use tokio_postgres::{Client, NoTls};
use tracing::warn;

use crate::{
    agent,
    host::HostIdentity,
    message::collapse_whitespace,
    session::{ActiveSession, parse_local_date_filter, utc_range_for_local_date},
};

type BoxError = Box<dyn StdError + Send + Sync>;

pub const POSTGRES_BACKUP_URL_ENV: &str = "PIMUX_BACKUP_POSTGRES_URL";
const NO_WORKING_DIRECTORY: &str = "No working directory";
const MAX_CANDIDATE_EXCERPTS: usize = 24;
const MIN_STRICT_EXCERPTS: usize = 8;
const MAX_EXCERPT_CHARS: usize = 220;
const MAX_WORKED_ON_ITEMS: usize = 5;
const MAX_ACCOMPLISHMENTS: usize = 5;
const MAX_EXCERPTS_PER_ACCOMPLISHMENT: usize = 2;

#[derive(Debug, Clone)]
pub struct DayConfig {
    pub date: Option<String>,
    pub pi_agent_dir: Option<PathBuf>,
    pub summary_model: String,
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
    session_summary: Option<String>,
    project_cwd: Option<String>,
    created_at: DateTime<Utc>,
    role: String,
    body: String,
}

#[derive(Debug, Clone)]
struct ProjectDayData {
    project_key: String,
    session_summaries: Vec<String>,
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
}

#[derive(Debug, Clone, Default, Deserialize)]
struct ProjectSummaryResponse {
    #[serde(default, rename = "workedOn")]
    worked_on: Vec<String>,
    #[serde(default)]
    accomplishments: Vec<ProjectSummaryAccomplishment>,
}

#[derive(Debug, Clone, Default, Deserialize)]
struct ProjectSummaryAccomplishment {
    #[serde(default)]
    summary: String,
    #[serde(default, rename = "excerptIds")]
    excerpt_ids: Vec<String>,
}

#[derive(Debug, Clone)]
struct RenderedProjectReport {
    project_key: String,
    worked_on: Vec<String>,
    accomplishments: Vec<RenderedAccomplishment>,
}

#[derive(Debug, Clone)]
struct RenderedAccomplishment {
    summary: String,
    excerpts: Vec<String>,
}

pub async fn day(config: DayConfig) -> Result<(), BoxError> {
    let report_date = resolve_report_date(config.date.as_deref())?;
    let (start, end) = utc_range_for_local_date(report_date)?;
    let Some(postgres_url) = postgres_url_from_env() else {
        return Err(format!("{POSTGRES_BACKUP_URL_ENV} is not set").into());
    };

    let pi_agent_dir = agent::resolve_pi_agent_dir(config.pi_agent_dir)?;
    let summary_model = agent::resolve_summary_model(&pi_agent_dir, &config.summary_model);

    eprintln!(
        "loading archived activity for {} from {}...",
        report_date, POSTGRES_BACKUP_URL_ENV
    );
    let client = connect_postgres(&postgres_url).await?;
    let messages = load_archived_messages(&client, start, end).await?;

    if messages.is_empty() {
        println!("# Daily report for {report_date}\n\nNo archived project activity found.");
        return Ok(());
    }

    let mut projects = group_messages_by_project(messages);
    projects.sort_by(|left, right| {
        right
            .last_activity_at
            .cmp(&left.last_activity_at)
            .then_with(|| left.project_key.cmp(&right.project_key))
    });

    eprintln!(
        "generating report for {} project(s) using {}...",
        projects.len(),
        summary_model
    );

    let mut rendered_projects = Vec::with_capacity(projects.len());
    for (index, project) in projects.iter().enumerate() {
        eprintln!(
            "[{}/{}] summarizing {}",
            index + 1,
            projects.len(),
            project.project_key
        );

        let candidates = build_candidate_excerpts(project);
        let rendered = match summarize_project_day_via_pi(
            report_date,
            project,
            &candidates,
            &pi_agent_dir,
            &summary_model,
        )
        .await
        {
            Ok(rendered) => rendered,
            Err(error) => {
                eprintln!(
                    "report summary failed for project {}: {error}",
                    project.project_key
                );
                heuristic_project_report(project, &candidates)
            }
        };
        rendered_projects.push(rendered);
    }

    print!("{}", render_day_report(report_date, &rendered_projects));
    Ok(())
}

fn resolve_report_date(value: Option<&str>) -> Result<NaiveDate, BoxError> {
    match value {
        Some(value) => Ok(parse_local_date_filter(value)?),
        None => Ok(Local::now().date_naive()),
    }
}

fn postgres_url_from_env() -> Option<String> {
    env::var(POSTGRES_BACKUP_URL_ENV)
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
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
                "SELECT s.summary AS summary, s.cwd AS cwd, m.created_at AS created_at, ",
                "m.role AS role, m.body AS body ",
                "FROM messages m ",
                "JOIN sessions s ON s.host_location = m.host_location AND s.session_id = m.session_id ",
                "WHERE m.created_at >= $1 AND m.created_at < $2 ",
                "ORDER BY m.created_at ASC, m.ordinal ASC, m.session_id ASC"
            ),
            &[&start, &end],
        )
        .await?;

    Ok(rows
        .into_iter()
        .map(|row| ArchivedMessage {
            session_summary: row.get("summary"),
            project_cwd: row.get("cwd"),
            created_at: row.get("created_at"),
            role: row.get("role"),
            body: row.get("body"),
        })
        .collect())
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
                    session_summaries: Vec::new(),
                    messages: Vec::new(),
                    last_activity_at: message.created_at,
                });
                index
            }
        };

        let project = &mut projects[index];
        project.last_activity_at = project.last_activity_at.max(message.created_at);
        if let Some(summary) = message
            .session_summary
            .as_deref()
            .and_then(normalize_report_line)
        {
            push_unique_case_insensitive(&mut project.session_summaries, summary);
        }
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
    candidates.truncate(MAX_CANDIDATE_EXCERPTS);
    candidates.sort_by(|left, right| {
        left.created_at
            .cmp(&right.created_at)
            .then_with(|| left.text.cmp(&right.text))
    });

    for (index, candidate) in candidates.iter_mut().enumerate() {
        candidate.id = format!("E{}", index + 1);
    }

    candidates
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
        let Some(text) = candidate_excerpt_text(&message.role, &message.body, strict) else {
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
        });
    }

    candidates
}

fn candidate_excerpt_text(role: &str, body: &str, strict: bool) -> Option<String> {
    if !matches!(role, "user" | "assistant" | "custom" | "other") {
        return None;
    }

    let text = collapse_whitespace(body);
    if text.is_empty() || text == "[Image]" || text.starts_with("Tool call: ") {
        return None;
    }

    if strict {
        if text.chars().count() < 16 || is_low_signal_excerpt(&text) {
            return None;
        }
    } else if text.chars().count() < 6 {
        return None;
    }

    Some(truncate_chars(&text, MAX_EXCERPT_CHARS))
}

fn is_low_signal_excerpt(text: &str) -> bool {
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
        "user" => 40,
        "assistant" => 35,
        "custom" => 20,
        "other" => 15,
        _ => 0,
    };

    let length = i32::try_from(text.chars().count()).unwrap_or(i32::MAX);
    let ideal_length = 96;
    let length_score = (30 - ((length - ideal_length).abs() / 4)).clamp(0, 30);
    let punctuation_bonus = if text.contains('?') || text.contains(':') {
        4
    } else {
        0
    };

    role_score + length_score + punctuation_bonus
}

async fn summarize_project_day_via_pi(
    report_date: NaiveDate,
    project: &ProjectDayData,
    candidates: &[ExcerptCandidate],
    pi_agent_dir: &PathBuf,
    summary_model: &str,
) -> Result<RenderedProjectReport, BoxError> {
    if candidates.is_empty() {
        return Err("no usable excerpts found for project".into());
    }

    let prompt = build_project_summary_prompt(report_date, project, candidates);
    let mut command = Command::new("pi");
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

    normalize_project_summary_response(project.project_key.clone(), response, candidates)
        .ok_or_else(|| "summary response contained no usable report items".into())
}

fn build_project_summary_prompt(
    report_date: NaiveDate,
    project: &ProjectDayData,
    candidates: &[ExcerptCandidate],
) -> String {
    let session_summary_hints = if project.session_summaries.is_empty() {
        "- none".to_string()
    } else {
        project
            .session_summaries
            .iter()
            .take(8)
            .map(|summary| format!("- {summary}"))
            .collect::<Vec<_>>()
            .join("\n")
    };

    let candidate_lines = candidates
        .iter()
        .map(|candidate| format!("{} | {} | {}", candidate.id, candidate.role, candidate.text))
        .collect::<Vec<_>>()
        .join("\n");

    format!(
        concat!(
            "Generate a concise daily coding report for one project.\n\n",
            "Date: {report_date}\n",
            "Project: {project}\n\n",
            "Session summary hints (deduplicated, optional context only):\n",
            "{session_summary_hints}\n\n",
            "Candidate excerpts from that day:\n",
            "{candidate_lines}\n\n",
            "Return ONLY valid JSON in this exact shape:\n",
            "{{\n",
            "  \"workedOn\": [\"...\"],\n",
            "  \"accomplishments\": [\n",
            "    {{ \"summary\": \"...\", \"excerptIds\": [\"E1\", \"E4\"] }}\n",
            "  ]\n",
            "}}\n\n",
            "Rules:\n",
            "- Use only the evidence above\n",
            "- Keep it project-based, not session-based\n",
            "- Do not mention sessions, hosts, or counts\n",
            "- \"workedOn\" should contain 1 to 5 short bullets about what the project work focused on that day\n",
            "- \"accomplishments\" should contain 1 to 5 concrete outcomes, decisions, or completed steps\n",
            "- Each accomplishment must cite 1 or 2 excerpt IDs that directly support it\n",
            "- Do not invent quote text or excerpt IDs\n",
            "- Prefer concrete coding work and decisions over generic planning chatter\n",
            "- Keep each item concise and factual\n"
        ),
        report_date = report_date,
        project = project.project_key,
        session_summary_hints = session_summary_hints,
        candidate_lines = candidate_lines,
    )
}

fn normalize_project_summary_response(
    project_key: String,
    response: ProjectSummaryResponse,
    candidates: &[ExcerptCandidate],
) -> Option<RenderedProjectReport> {
    let excerpt_lookup = candidates
        .iter()
        .map(|candidate| (candidate.id.as_str(), candidate.text.as_str()))
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

        let mut excerpts = Vec::new();
        let mut seen_excerpt_ids = HashSet::new();
        for excerpt_id in accomplishment.excerpt_ids {
            let excerpt_id = collapse_whitespace(&excerpt_id);
            if excerpt_id.is_empty() || !seen_excerpt_ids.insert(excerpt_id.clone()) {
                continue;
            }

            let Some(excerpt) = excerpt_lookup.get(excerpt_id.as_str()) else {
                continue;
            };
            push_unique_case_insensitive(&mut excerpts, truncate_chars(excerpt, MAX_EXCERPT_CHARS));
            if excerpts.len() >= MAX_EXCERPTS_PER_ACCOMPLISHMENT {
                break;
            }
        }

        if excerpts.is_empty()
            || accomplishments
                .iter()
                .any(|existing: &RenderedAccomplishment| {
                    existing.summary.eq_ignore_ascii_case(&summary)
                })
        {
            continue;
        }

        accomplishments.push(RenderedAccomplishment { summary, excerpts });
        if accomplishments.len() >= MAX_ACCOMPLISHMENTS {
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

    if worked_on.is_empty() && accomplishments.is_empty() {
        None
    } else {
        Some(RenderedProjectReport {
            project_key,
            worked_on,
            accomplishments,
        })
    }
}

fn heuristic_project_report(
    project: &ProjectDayData,
    candidates: &[ExcerptCandidate],
) -> RenderedProjectReport {
    let mut worked_on = Vec::new();
    for summary in &project.session_summaries {
        push_unique_case_insensitive(&mut worked_on, summary.clone());
        if worked_on.len() >= MAX_WORKED_ON_ITEMS {
            break;
        }
    }

    let mut accomplishments = Vec::new();
    let preferred_roles = ["assistant", "user", "custom", "other"];
    for preferred_role in preferred_roles {
        for candidate in candidates
            .iter()
            .filter(|candidate| candidate.role == preferred_role)
        {
            let Some(summary) = normalize_report_line(&headline_from_excerpt(&candidate.text))
            else {
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
                excerpts: vec![candidate.text.clone()],
            });
            if accomplishments.len() >= MAX_ACCOMPLISHMENTS {
                break;
            }
        }

        if accomplishments.len() >= MAX_ACCOMPLISHMENTS {
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
                lines.push(format!("- {}", accomplishment.summary));
                for excerpt in &accomplishment.excerpts {
                    lines.push(format!("  > “{}”", excerpt));
                }
            }
        }
    }

    lines.push(String::new());
    lines.join("\n")
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

#[cfg(test)]
mod tests {
    use chrono::TimeZone;

    use super::*;

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
    fn candidate_excerpts_skip_tool_calls_and_keep_human_text() {
        let project = ProjectDayData {
            project_key: "~/apps/pimux2000".to_string(),
            session_summaries: Vec::new(),
            last_activity_at: Utc.timestamp_opt(2_000, 0).unwrap(),
            messages: vec![
                ArchivedMessage {
                    session_summary: None,
                    project_cwd: Some("/Users/nakajima/apps/pimux2000".to_string()),
                    created_at: Utc.timestamp_opt(1_000, 0).unwrap(),
                    role: "assistant".to_string(),
                    body: "Tool call: read".to_string(),
                },
                ArchivedMessage {
                    session_summary: None,
                    project_cwd: Some("/Users/nakajima/apps/pimux2000".to_string()),
                    created_at: Utc.timestamp_opt(2_000, 0).unwrap(),
                    role: "user".to_string(),
                    body: "group by project, not session".to_string(),
                },
            ],
        };

        let candidates = build_candidate_excerpts(&project);
        assert_eq!(candidates.len(), 1);
        assert_eq!(candidates[0].text, "group by project, not session");
    }

    #[test]
    fn render_day_report_places_excerpts_under_each_accomplishment() {
        let rendered = render_day_report(
            NaiveDate::from_ymd_opt(2026, 4, 8).unwrap(),
            &[RenderedProjectReport {
                project_key: "~/apps/pimux2000".to_string(),
                worked_on: vec!["Added report command plumbing".to_string()],
                accomplishments: vec![RenderedAccomplishment {
                    summary: "Defined project-based daily report output".to_string(),
                    excerpts: vec![
                        "it should be project-based, not session based".to_string(),
                        "the excerpts should be per accomplishment".to_string(),
                    ],
                }],
            }],
        );

        assert!(rendered.contains("Accomplished:\n- Defined project-based daily report output"));
        assert!(rendered.contains("  > “it should be project-based, not session based”"));
        assert!(rendered.contains("  > “the excerpts should be per accomplishment”"));
    }

    #[test]
    fn parse_json_response_accepts_markdown_fenced_json() {
        let response = parse_json_response::<ProjectSummaryResponse>(
            "```json\n{\"workedOn\":[\"Added reporting\"],\"accomplishments\":[]}\n```",
        )
        .unwrap();

        assert_eq!(response.worked_on, vec!["Added reporting"]);
    }
}
