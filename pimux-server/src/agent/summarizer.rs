use std::{collections::HashMap, io, path::PathBuf};

use tokio::{
    process::Command,
    time::{Duration, timeout},
};

use crate::session::ActiveSession;

use super::discovery::{DiscoveredSession, SessionFingerprint};

pub const DEFAULT_SUMMARY_MODEL: &str = "anthropic/claude-haiku-4-5";
const SUMMARY_TIMEOUT: Duration = Duration::from_secs(20);
const MAX_LLM_SUMMARY_LEN: usize = 80;

#[derive(Debug, Clone)]
pub struct Config {
    pub model: String,
    pub pi_agent_dir: PathBuf,
}

pub struct SummaryCache {
    entries: HashMap<PathBuf, CachedSummary>,
    llm_disabled: bool,
}

impl Default for SummaryCache {
    fn default() -> Self {
        Self {
            entries: HashMap::new(),
            llm_disabled: false,
        }
    }
}

#[derive(Debug, Clone)]
struct CachedSummary {
    fingerprint: SessionFingerprint,
    summary: String,
}

pub async fn apply_summaries(
    discovered_sessions: Vec<DiscoveredSession>,
    config: &Config,
    cache: &mut SummaryCache,
) -> Vec<ActiveSession> {
    let mut sessions = Vec::with_capacity(discovered_sessions.len());

    for discovered_session in discovered_sessions {
        let summary = resolve_summary(&discovered_session, config, cache).await;
        sessions.push(discovered_session.into_active_session(summary));
    }

    sessions
}

async fn resolve_summary(
    discovered_session: &DiscoveredSession,
    config: &Config,
    cache: &mut SummaryCache,
) -> String {
    if let Some(explicit_summary) = discovered_session.explicit_summary.as_deref() {
        return normalize_existing_summary(explicit_summary)
            .unwrap_or_else(|| discovered_session.heuristic_summary.clone());
    }

    if let Some(cached_summary) = cache.entries.get(&discovered_session.session_file) {
        if cached_summary.fingerprint == discovered_session.fingerprint {
            return cached_summary.summary.clone();
        }
    }

    let summary = if cache.llm_disabled {
        discovered_session.heuristic_summary.clone()
    } else if let Some(summary_input) = discovered_session.summary_input.as_deref() {
        match summarize_via_pi(discovered_session, summary_input, config).await {
            Ok(summary) => summary,
            Err(SummaryError::PiUnavailable(error) | SummaryError::Configuration(error)) => {
                cache.llm_disabled = true;
                eprintln!("disabling llm summaries for this run: {error}");
                discovered_session.heuristic_summary.clone()
            }
            Err(SummaryError::Invocation(error)) => {
                eprintln!(
                    "llm summary failed for session {} ({}): {error}",
                    discovered_session.id,
                    discovered_session.session_file.display(),
                );
                discovered_session.heuristic_summary.clone()
            }
        }
    } else {
        discovered_session.heuristic_summary.clone()
    };

    cache.entries.insert(
        discovered_session.session_file.clone(),
        CachedSummary {
            fingerprint: discovered_session.fingerprint.clone(),
            summary: summary.clone(),
        },
    );

    summary
}

async fn summarize_via_pi(
    discovered_session: &DiscoveredSession,
    summary_input: &str,
    config: &Config,
) -> Result<String, SummaryError> {
    let prompt = build_summary_prompt(discovered_session, summary_input);
    let mut command = Command::new("pi");
    command
        .arg("-p")
        .arg("--no-session")
        .arg("--thinking")
        .arg("off")
        .arg("--model")
        .arg(&config.model)
        .arg(prompt)
        .env("PI_SKIP_VERSION_CHECK", "1")
        .env("PI_CODING_AGENT_DIR", &config.pi_agent_dir)
        .current_dir(&config.pi_agent_dir)
        .kill_on_drop(true);

    let output = timeout(SUMMARY_TIMEOUT, command.output())
        .await
        .map_err(|_| SummaryError::Invocation("timed out waiting for pi summary".to_string()))
        .and_then(|result| result.map_err(SummaryError::from_io))?;

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
        return Err(SummaryError::Configuration(details));
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    let summary = normalize_llm_summary(&stdout)
        .ok_or_else(|| SummaryError::Invocation("pi returned an empty summary".to_string()))?;

    Ok(summary)
}

fn build_summary_prompt(discovered_session: &DiscoveredSession, summary_input: &str) -> String {
    format!(
        concat!(
            "Summarize what this coding session is currently about in a single short title.\n\n",
            "Rules:\n",
            "- Focus on the concrete coding task or topic\n",
            "- Prefer the current or latest task over earlier work\n",
            "- Ignore meta phrasing like 'Let's work this out together', 'keep planning', or 'start implementing'\n",
            "- Plain text only\n",
            "- No quotes\n",
            "- No markdown\n",
            "- No trailing punctuation\n",
            "- Keep it under 60 characters if possible\n\n",
            "Session cwd: {cwd}\n\n",
            "Recent conversation:\n",
            "{summary_input}\n\n",
            "Title:"
        ),
        cwd = discovered_session.cwd,
        summary_input = summary_input,
    )
}

fn normalize_existing_summary(summary: &str) -> Option<String> {
    let normalized = collapse_whitespace(summary);
    if normalized.is_empty() {
        None
    } else {
        Some(normalized)
    }
}

fn normalize_llm_summary(summary: &str) -> Option<String> {
    let first_line = summary
        .lines()
        .map(str::trim)
        .find(|line| !line.is_empty())?;
    let normalized = collapse_whitespace(first_line)
        .trim_start_matches("- ")
        .trim_matches('`')
        .trim_matches('"')
        .trim_matches('\'')
        .trim_end_matches(['.', '!', '?', ';', ':'])
        .trim()
        .to_string();

    if normalized.is_empty() {
        return None;
    }

    Some(truncate_chars(&normalized, MAX_LLM_SUMMARY_LEN))
}

fn collapse_whitespace(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn truncate_chars(text: &str, max_chars: usize) -> String {
    if text.chars().count() <= max_chars {
        return text.to_string();
    }

    let truncated = text.chars().take(max_chars).collect::<String>();
    format!("{truncated}…")
}

enum SummaryError {
    PiUnavailable(String),
    Configuration(String),
    Invocation(String),
}

impl SummaryError {
    fn from_io(error: io::Error) -> Self {
        if error.kind() == io::ErrorKind::NotFound {
            return Self::PiUnavailable("`pi` was not found in PATH".to_string());
        }

        Self::Invocation(error.to_string())
    }
}
