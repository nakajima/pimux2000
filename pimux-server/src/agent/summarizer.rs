use std::{
    collections::HashMap,
    env, fs, io,
    path::{Path, PathBuf},
    sync::Arc,
    time::{Duration, Instant},
};

use serde::{Deserialize, Serialize};
use tokio::{process::Command, sync::Semaphore, task::JoinSet};

use crate::session::ActiveSession;

use super::discovery::{DiscoveredSession, SessionFingerprint};

pub const DEFAULT_SUMMARY_MODEL: &str = "anthropic/claude-haiku-4-5";

const PROVIDER_SUMMARY_MODELS: &[(&str, &str)] = &[
    ("anthropic", "anthropic/claude-haiku-4-5"),
    ("openai-codex", "openai-codex/gpt-5.4-mini"),
    ("openai", "openai/gpt-4o-mini"),
    ("google", "google/gemini-2.0-flash"),
];

const SUMMARY_RETRY_BACKOFF: Duration = Duration::from_secs(30);
const SUMMARY_LLM_CONCURRENCY: usize = 4;
const MAX_LLM_SUMMARY_LEN: usize = 80;

#[derive(Debug, Clone)]
pub struct Config {
    pub model: String,
    pub pi_agent_dir: PathBuf,
}

pub fn resolve_summary_model(pi_agent_dir: &Path, requested_model: &str) -> String {
    let Some(provider) = extract_provider(requested_model) else {
        return requested_model.to_string();
    };

    if has_provider_auth(pi_agent_dir, provider) {
        return requested_model.to_string();
    }

    for &(fallback_provider, fallback_model) in PROVIDER_SUMMARY_MODELS {
        if fallback_provider == provider {
            continue;
        }
        if has_provider_auth(pi_agent_dir, fallback_provider) {
            eprintln!("no {provider} auth found; using {fallback_model} for session summaries",);
            return fallback_model.to_string();
        }
    }

    eprintln!(
        "no auth found for any known provider; session summaries will fall back to heuristics"
    );
    requested_model.to_string()
}

pub fn resolve_summary_model_or_default(
    pi_agent_dir: &Path,
    requested_model: Option<&str>,
) -> String {
    let requested_model = requested_model
        .map(str::trim)
        .filter(|value| !value.is_empty());

    match requested_model {
        Some(requested_model) => resolve_summary_model(pi_agent_dir, requested_model),
        None => default_provider_summary_model(pi_agent_dir)
            .map(|model| resolve_summary_model(pi_agent_dir, model))
            .unwrap_or_else(|| resolve_summary_model(pi_agent_dir, DEFAULT_SUMMARY_MODEL)),
    }
}

#[derive(Debug, Clone, Default, Deserialize)]
struct PiSettings {
    #[serde(default, rename = "defaultProvider")]
    default_provider: Option<String>,
}

fn default_provider_summary_model(pi_agent_dir: &Path) -> Option<&'static str> {
    let settings = load_pi_settings(pi_agent_dir)?;
    let provider = settings.default_provider?.trim().to_string();
    if provider.is_empty() {
        return None;
    }

    PROVIDER_SUMMARY_MODELS
        .iter()
        .find_map(|(candidate, model)| {
            if *candidate == provider {
                Some(*model)
            } else {
                None
            }
        })
}

fn load_pi_settings(pi_agent_dir: &Path) -> Option<PiSettings> {
    let settings_path = pi_agent_dir.join("settings.json");
    let contents = fs::read_to_string(settings_path).ok()?;
    serde_json::from_str(&contents).ok()
}

fn extract_provider(model: &str) -> Option<&str> {
    let provider = model.split('/').next()?;
    if provider.is_empty() || !model.contains('/') {
        return None;
    }
    Some(provider)
}

fn has_provider_auth(pi_agent_dir: &Path, provider: &str) -> bool {
    let env_vars: &[&str] = match provider {
        "anthropic" => &["ANTHROPIC_OAUTH_TOKEN", "ANTHROPIC_API_KEY"],
        "openai" | "openai-codex" => &["OPENAI_API_KEY"],
        "google" => &["GEMINI_API_KEY"],
        "groq" => &["GROQ_API_KEY"],
        "xai" => &["XAI_API_KEY"],
        "openrouter" => &["OPENROUTER_API_KEY"],
        "cerebras" => &["CEREBRAS_API_KEY"],
        "mistral" => &["MISTRAL_API_KEY"],
        _ => &[],
    };

    for var in env_vars {
        if env::var(var).ok().filter(|v| !v.is_empty()).is_some() {
            return true;
        }
    }

    let auth_path = pi_agent_dir.join("auth.json");
    if let Ok(contents) = fs::read_to_string(&auth_path) {
        if let Ok(data) = serde_json::from_str::<serde_json::Value>(&contents) {
            if let Some(obj) = data.as_object() {
                return obj.contains_key(provider);
            }
        }
    }

    false
}

pub struct SummaryCache {
    entries: HashMap<PathBuf, CachedSummary>,
    recent_failures: HashMap<PathBuf, FailedSummaryAttempt>,
    dirty: bool,
}

impl Default for SummaryCache {
    fn default() -> Self {
        Self {
            entries: HashMap::new(),
            recent_failures: HashMap::new(),
            dirty: false,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct CachedSummary {
    fingerprint: SessionFingerprint,
    summary: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum SummarySource {
    Explicit,
    Cached,
    Pi,
    CachedAfterError,
    HeuristicAfterError,
    Heuristic,
}

impl SummarySource {
    fn label(self) -> &'static str {
        match self {
            Self::Explicit => "explicit",
            Self::Cached => "cached",
            Self::Pi => "llm",
            Self::CachedAfterError => "cached-after-error",
            Self::HeuristicAfterError => "heuristic-after-error",
            Self::Heuristic => "heuristic",
        }
    }
}

#[derive(Debug, Clone)]
struct FailedSummaryAttempt {
    fingerprint: SessionFingerprint,
    retry_after: Instant,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
struct PersistedSummaryCache {
    entries: Vec<PersistedSummaryEntry>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct PersistedSummaryEntry {
    session_file: PathBuf,
    fingerprint: SessionFingerprint,
    summary: String,
}

struct PendingSummaryTask {
    index: usize,
    total: usize,
    discovered_session: DiscoveredSession,
    summary_input: String,
}

struct CompletedSummaryTask {
    index: usize,
    total: usize,
    discovered_session: DiscoveredSession,
    result: Result<String, SummaryError>,
    elapsed: Duration,
}

impl SummaryCache {
    pub fn load(pi_agent_dir: &Path) -> Self {
        let cache_path = cache_path(pi_agent_dir);
        let contents = match fs::read_to_string(&cache_path) {
            Ok(contents) => contents,
            Err(_) => return Self::default(),
        };

        let persisted = match serde_json::from_str::<PersistedSummaryCache>(&contents) {
            Ok(persisted) => persisted,
            Err(error) => {
                eprintln!(
                    "failed to parse summary cache {}: {error}",
                    cache_path.display()
                );
                return Self::default();
            }
        };

        let entries = persisted
            .entries
            .into_iter()
            .map(|entry| {
                (
                    entry.session_file,
                    CachedSummary {
                        fingerprint: entry.fingerprint,
                        summary: entry.summary,
                    },
                )
            })
            .collect();

        Self {
            entries,
            recent_failures: HashMap::new(),
            dirty: false,
        }
    }

    fn mark_dirty(&mut self) {
        self.dirty = true;
    }

    fn clear_failure(&mut self, session_file: &Path) {
        self.recent_failures.remove(session_file);
    }

    fn record_failure(&mut self, session_file: &Path, fingerprint: SessionFingerprint) {
        self.recent_failures.insert(
            session_file.to_path_buf(),
            FailedSummaryAttempt {
                fingerprint,
                retry_after: Instant::now() + SUMMARY_RETRY_BACKOFF,
            },
        );
    }

    fn should_skip_retry(&self, session_file: &Path, fingerprint: &SessionFingerprint) -> bool {
        self.recent_failures
            .get(session_file)
            .map(|failure| {
                &failure.fingerprint == fingerprint && Instant::now() < failure.retry_after
            })
            .unwrap_or(false)
    }

    fn persisted_summary_for(&self, session_file: &Path) -> Option<String> {
        self.entries
            .get(session_file)
            .map(|entry| entry.summary.clone())
    }

    fn successful_summary_for(
        &self,
        session_file: &Path,
        fingerprint: &SessionFingerprint,
    ) -> Option<String> {
        self.entries
            .get(session_file)
            .and_then(|entry| (&entry.fingerprint == fingerprint).then(|| entry.summary.clone()))
    }

    fn store_success(
        &mut self,
        session_file: PathBuf,
        fingerprint: SessionFingerprint,
        summary: String,
    ) {
        self.entries.insert(
            session_file.clone(),
            CachedSummary {
                fingerprint,
                summary,
            },
        );
        self.clear_failure(&session_file);
        self.mark_dirty();
    }

    fn persist_best_effort(&mut self, pi_agent_dir: &Path) {
        if !self.dirty {
            return;
        }

        if let Err(error) = self.persist(pi_agent_dir) {
            eprintln!(
                "failed to persist summary cache {}: {error}",
                cache_path(pi_agent_dir).display()
            );
        }
    }

    fn persist(
        &mut self,
        pi_agent_dir: &Path,
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        let cache_path = cache_path(pi_agent_dir);
        if let Some(parent) = cache_path.parent() {
            fs::create_dir_all(parent)?;
        }

        let persisted = PersistedSummaryCache {
            entries: self
                .entries
                .iter()
                .map(|(session_file, entry)| PersistedSummaryEntry {
                    session_file: session_file.clone(),
                    fingerprint: entry.fingerprint.clone(),
                    summary: entry.summary.clone(),
                })
                .collect(),
        };

        fs::write(&cache_path, serde_json::to_vec_pretty(&persisted)?)?;
        self.dirty = false;
        Ok(())
    }
}

pub async fn apply_summaries(
    discovered_sessions: Vec<DiscoveredSession>,
    config: &Config,
    cache: &mut SummaryCache,
) -> Vec<ActiveSession> {
    apply_summaries_inner(discovered_sessions, config, cache, false).await
}

pub async fn apply_summaries_with_stderr_progress(
    discovered_sessions: Vec<DiscoveredSession>,
    config: &Config,
    cache: &mut SummaryCache,
) -> Vec<ActiveSession> {
    apply_summaries_inner(discovered_sessions, config, cache, true).await
}

pub fn apply_summaries_cached_only(
    discovered_sessions: Vec<DiscoveredSession>,
    cache: &SummaryCache,
) -> Vec<ActiveSession> {
    discovered_sessions
        .into_iter()
        .map(|session| {
            let summary = resolve_summary_without_llm(&session, cache)
                .map(|(summary, _)| summary)
                .unwrap_or_else(|| {
                    cache
                        .persisted_summary_for(&session.session_file)
                        .unwrap_or_else(|| session.heuristic_summary.clone())
                });
            session.into_active_session(summary)
        })
        .collect()
}

pub async fn resummarize_session(
    discovered_session: &DiscoveredSession,
    config: &Config,
) -> String {
    let Some(summary_input) = discovered_session.summary_input.as_deref() else {
        return discovered_session.heuristic_summary.clone();
    };

    match summarize_via_pi(discovered_session, summary_input, config).await {
        Ok(summary) => summary,
        Err(error) => {
            log_summary_error(discovered_session, &error);
            discovered_session.heuristic_summary.clone()
        }
    }
}

async fn apply_summaries_inner(
    discovered_sessions: Vec<DiscoveredSession>,
    config: &Config,
    cache: &mut SummaryCache,
    stderr_progress: bool,
) -> Vec<ActiveSession> {
    let total = discovered_sessions.len();
    if stderr_progress {
        eprintln!(
            "resolving summaries for {total} session{} using {}...",
            if total == 1 { "" } else { "s" },
            config.model,
        );
    }

    let mut sessions = vec![None; total];
    let mut pending_tasks = Vec::new();

    for (index, discovered_session) in discovered_sessions.into_iter().enumerate() {
        if let Some((summary, source)) = resolve_summary_without_llm(&discovered_session, cache) {
            if stderr_progress {
                eprintln!(
                    "[{}/{}] done in 0.0s via {}: {}",
                    index + 1,
                    total,
                    source.label(),
                    summary,
                );
            }
            sessions[index] = Some(discovered_session.into_active_session(summary));
            continue;
        }

        let summary_input = discovered_session
            .summary_input
            .clone()
            .expect("missing summary input for llm summary task");

        if stderr_progress {
            eprintln!(
                "[{}/{}] summarizing {} ({})",
                index + 1,
                total,
                discovered_session.id,
                discovered_session.cwd,
            );
        }

        pending_tasks.push(PendingSummaryTask {
            index,
            total,
            discovered_session,
            summary_input,
        });
    }

    if stderr_progress {
        let immediate = total.saturating_sub(pending_tasks.len());
        eprintln!(
            "{} session{} ready immediately; {} require llm summaries (parallelism = {})",
            immediate,
            if immediate == 1 { "" } else { "s" },
            pending_tasks.len(),
            SUMMARY_LLM_CONCURRENCY.min(pending_tasks.len().max(1)),
        );
    }

    let semaphore = Arc::new(Semaphore::new(SUMMARY_LLM_CONCURRENCY.max(1)));
    let mut join_set = JoinSet::new();

    for task in pending_tasks {
        let semaphore = semaphore.clone();
        let config = config.clone();
        join_set.spawn(async move {
            let _permit = semaphore
                .acquire_owned()
                .await
                .expect("summary semaphore was closed unexpectedly");
            let started_at = Instant::now();
            let result =
                summarize_via_pi(&task.discovered_session, &task.summary_input, &config).await;
            CompletedSummaryTask {
                index: task.index,
                total: task.total,
                discovered_session: task.discovered_session,
                result,
                elapsed: started_at.elapsed(),
            }
        });
    }

    while let Some(joined) = join_set.join_next().await {
        let task = joined.expect("summary task panicked unexpectedly");
        let (summary, source) = match task.result {
            Ok(summary) => {
                cache.store_success(
                    task.discovered_session.session_file.clone(),
                    task.discovered_session.fingerprint.clone(),
                    summary.clone(),
                );
                (summary, SummarySource::Pi)
            }
            Err(error) => {
                cache.record_failure(
                    &task.discovered_session.session_file,
                    task.discovered_session.fingerprint.clone(),
                );
                log_summary_error(&task.discovered_session, &error);
                match cache.persisted_summary_for(&task.discovered_session.session_file) {
                    Some(summary) => (summary, SummarySource::CachedAfterError),
                    None => (
                        task.discovered_session.heuristic_summary.clone(),
                        SummarySource::HeuristicAfterError,
                    ),
                }
            }
        };

        if stderr_progress {
            eprintln!(
                "[{}/{}] done in {:.1}s via {}: {}",
                task.index + 1,
                task.total,
                task.elapsed.as_secs_f32(),
                source.label(),
                summary,
            );
        }

        sessions[task.index] = Some(task.discovered_session.into_active_session(summary));
    }

    cache.persist_best_effort(&config.pi_agent_dir);
    sessions
        .into_iter()
        .map(|session| session.expect("missing summary result"))
        .collect()
}

fn resolve_summary_without_llm(
    discovered_session: &DiscoveredSession,
    cache: &SummaryCache,
) -> Option<(String, SummarySource)> {
    if let Some(explicit_summary) = discovered_session.explicit_summary.as_deref() {
        return Some((
            normalize_existing_summary(explicit_summary)
                .unwrap_or_else(|| discovered_session.heuristic_summary.clone()),
            SummarySource::Explicit,
        ));
    }

    if let Some(summary) = cache.successful_summary_for(
        &discovered_session.session_file,
        &discovered_session.fingerprint,
    ) {
        return Some((summary, SummarySource::Cached));
    }

    if cache.should_skip_retry(
        &discovered_session.session_file,
        &discovered_session.fingerprint,
    ) {
        return Some(
            match cache.persisted_summary_for(&discovered_session.session_file) {
                Some(summary) => (summary, SummarySource::CachedAfterError),
                None => (
                    discovered_session.heuristic_summary.clone(),
                    SummarySource::HeuristicAfterError,
                ),
            },
        );
    }

    if discovered_session.summary_input.is_none() {
        return Some((
            discovered_session.heuristic_summary.clone(),
            SummarySource::Heuristic,
        ));
    }

    None
}

async fn summarize_via_pi(
    discovered_session: &DiscoveredSession,
    summary_input: &str,
    config: &Config,
) -> Result<String, SummaryError> {
    let prompt = build_summary_prompt(discovered_session, summary_input);
    trace_summary_prompt(discovered_session, config, &prompt);
    let mut command = Command::new(super::resolve_pi_executable(&config.pi_agent_dir));
    command
        .arg("-p")
        .arg("--no-session")
        .arg("--no-extensions")
        .arg("--no-skills")
        .arg("--thinking")
        .arg("off")
        .arg("--model")
        .arg(&config.model)
        .arg(prompt)
        .env("PI_SKIP_VERSION_CHECK", "1")
        .env("PI_CODING_AGENT_DIR", &config.pi_agent_dir)
        .current_dir(summary_working_dir(discovered_session, config))
        .kill_on_drop(true);

    let output = command.output().await.map_err(SummaryError::from_io)?;

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

fn log_summary_error(discovered_session: &DiscoveredSession, error: &SummaryError) {
    eprintln!(
        "llm summary failed for session {} ({}): {}",
        discovered_session.id,
        discovered_session.session_file.display(),
        error.message(),
    );
}

fn trace_summary_prompt(discovered_session: &DiscoveredSession, config: &Config, prompt: &str) {
    if !trace_logging_enabled() {
        return;
    }

    let command_preview = summary_command_preview(discovered_session, config, prompt);
    eprintln!(
        concat!(
            "trace: llm summary prompt for session {} ({}) using {}\n",
            "----- prompt begin -----\n",
            "{}\n",
            "----- prompt end -----\n",
            "trace: run manually with:\n",
            "{}"
        ),
        discovered_session.id,
        discovered_session.session_file.display(),
        config.model,
        prompt,
        command_preview,
    );
}

fn summary_command_preview(
    discovered_session: &DiscoveredSession,
    config: &Config,
    prompt: &str,
) -> String {
    let working_dir = summary_working_dir(discovered_session, config);
    let pi_executable = super::resolve_pi_executable(&config.pi_agent_dir);
    format!(
        "( cd {} && PI_SKIP_VERSION_CHECK=1 PI_CODING_AGENT_DIR={} {} -p --no-session --no-extensions --no-skills --thinking off --model {} {} )",
        shell_escape(&working_dir.display().to_string()),
        shell_escape(&config.pi_agent_dir.display().to_string()),
        shell_escape(&pi_executable.display().to_string()),
        shell_escape(&config.model),
        shell_escape(prompt),
    )
}

fn summary_working_dir(discovered_session: &DiscoveredSession, config: &Config) -> PathBuf {
    let cwd = PathBuf::from(&discovered_session.cwd);
    if cwd.exists() {
        cwd
    } else {
        config.pi_agent_dir.clone()
    }
}

fn shell_escape(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\"'\"'"))
}

fn trace_logging_enabled() -> bool {
    env::var("RUST_LOG")
        .ok()
        .map(|value| {
            value.split(',').any(|directive| {
                let directive = directive.trim().to_ascii_lowercase();
                directive == "trace" || directive.ends_with("=trace")
            })
        })
        .unwrap_or(false)
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

fn cache_path(pi_agent_dir: &Path) -> PathBuf {
    pi_agent_dir.join("pimux").join("summary-cache.json")
}

enum SummaryError {
    PiUnavailable(String),
    Configuration(String),
    Invocation(String),
}

impl SummaryError {
    fn message(&self) -> &str {
        match self {
            Self::PiUnavailable(message)
            | Self::Configuration(message)
            | Self::Invocation(message) => message,
        }
    }

    fn from_io(error: io::Error) -> Self {
        if error.kind() == io::ErrorKind::NotFound {
            return Self::PiUnavailable(
                "pimux could not find the `pi` CLI in the agent bin dir, bun install dir, or PATH"
                    .to_string(),
            );
        }

        Self::Invocation(error.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalizes_llm_summary() {
        assert_eq!(
            normalize_llm_summary("\n- \"Ship iOS transcript polling.\"\n\n"),
            Some("Ship iOS transcript polling".to_string())
        );
    }

    #[test]
    fn extract_provider_from_model() {
        assert_eq!(
            extract_provider("anthropic/claude-haiku-4-5"),
            Some("anthropic")
        );
        assert_eq!(extract_provider("openai/gpt-4o-mini"), Some("openai"));
        assert_eq!(
            extract_provider("openrouter/anthropic/claude-3.5-haiku"),
            Some("openrouter")
        );
        assert_eq!(extract_provider("bare-model"), None);
        assert_eq!(extract_provider(""), None);
    }

    #[test]
    fn resolve_model_keeps_requested_when_auth_present() {
        let dir = tempdir_with_auth("resolve_keep", &["anthropic"]);
        assert_eq!(
            resolve_summary_model(&dir, "anthropic/claude-haiku-4-5"),
            "anthropic/claude-haiku-4-5"
        );
    }

    #[test]
    fn resolve_model_falls_back_when_no_auth() {
        let dir = tempdir_with_auth("resolve_fallback", &["openai"]);
        assert_eq!(
            resolve_summary_model(&dir, "anthropic/claude-haiku-4-5"),
            "openai/gpt-4o-mini"
        );
    }

    #[test]
    fn resolve_model_falls_back_to_openai_codex_when_available() {
        let dir = tempdir_with_auth("resolve_fallback_codex", &["openai-codex"]);
        assert_eq!(
            resolve_summary_model(&dir, "anthropic/claude-haiku-4-5"),
            "openai-codex/gpt-5.4-mini"
        );
    }

    #[test]
    fn resolve_model_returns_requested_when_no_auth_at_all() {
        let dir = tempdir_with_auth("resolve_none", &[]);
        assert_eq!(
            resolve_summary_model(&dir, "anthropic/claude-haiku-4-5"),
            "anthropic/claude-haiku-4-5"
        );
    }

    #[test]
    fn resolve_model_or_default_uses_default_provider_summary_model() {
        let dir = tempdir_with_auth_and_settings(
            "resolve_default_provider",
            &["openai-codex"],
            Some("openai-codex"),
        );
        assert_eq!(
            resolve_summary_model_or_default(&dir, None),
            "openai-codex/gpt-5.4-mini"
        );
    }

    #[test]
    fn resolve_model_or_default_falls_back_from_default_provider_when_needed() {
        let dir = tempdir_with_auth_and_settings(
            "resolve_default_provider_fallback",
            &["openai-codex"],
            Some("anthropic"),
        );
        assert_eq!(
            resolve_summary_model_or_default(&dir, None),
            "openai-codex/gpt-5.4-mini"
        );
    }

    #[test]
    fn resolve_model_or_default_prefers_explicit_override() {
        let dir = tempdir_with_auth_and_settings(
            "resolve_explicit_override",
            &["anthropic", "openai-codex"],
            Some("openai-codex"),
        );
        assert_eq!(
            resolve_summary_model_or_default(&dir, Some("anthropic/claude-haiku-4-5")),
            "anthropic/claude-haiku-4-5"
        );
    }

    #[test]
    fn resolve_model_or_default_keeps_legacy_default_without_settings() {
        let dir = tempdir_with_auth("resolve_default_legacy", &["anthropic"]);
        assert_eq!(
            resolve_summary_model_or_default(&dir, None),
            "anthropic/claude-haiku-4-5"
        );
    }

    fn tempdir_with_auth(name: &str, providers: &[&str]) -> PathBuf {
        tempdir_with_auth_and_settings(name, providers, None)
    }

    fn tempdir_with_auth_and_settings(
        name: &str,
        providers: &[&str],
        default_provider: Option<&str>,
    ) -> PathBuf {
        let dir = env::temp_dir().join(format!("pimux-test-{name}-{}", std::process::id()));
        let _ = fs::create_dir_all(&dir);
        let mut auth = serde_json::Map::new();
        for provider in providers {
            let mut entry = serde_json::Map::new();
            entry.insert(
                "type".to_string(),
                serde_json::Value::String("api_key".to_string()),
            );
            entry.insert(
                "key".to_string(),
                serde_json::Value::String("sk-test".to_string()),
            );
            auth.insert(provider.to_string(), serde_json::Value::Object(entry));
        }
        fs::write(
            dir.join("auth.json"),
            serde_json::to_vec_pretty(&auth).unwrap(),
        )
        .unwrap();

        if let Some(default_provider) = default_provider {
            fs::write(
                dir.join("settings.json"),
                serde_json::to_vec_pretty(&serde_json::json!({
                    "defaultProvider": default_provider,
                    "defaultModel": "ignored-for-summary-tests"
                }))
                .unwrap(),
            )
            .unwrap();
        }

        dir
    }

    #[test]
    fn skips_recent_retry_for_same_fingerprint() {
        let mut cache = SummaryCache::default();
        let fingerprint = SessionFingerprint {
            file_size: 1,
            modified_at_millis: 2,
        };
        let session_file = PathBuf::from("/tmp/session.jsonl");
        cache.record_failure(&session_file, fingerprint.clone());

        assert!(cache.should_skip_retry(&session_file, &fingerprint));
    }
}
