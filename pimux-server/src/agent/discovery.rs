use std::{
    collections::{HashMap, VecDeque},
    env,
    fs::{self, File},
    io::{BufRead, BufReader},
    path::{Path, PathBuf},
    process::Command,
    sync::OnceLock,
    time::UNIX_EPOCH,
};

use chrono::{DateTime, TimeZone, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use tracing::warn;
use walkdir::WalkDir;

use crate::session::{ActiveSession, SessionContextUsage};

type BoxError = Box<dyn std::error::Error + Send + Sync>;

const MAX_SUMMARY_LEN: usize = 120;
const MAX_SUMMARY_TRANSCRIPT_EDGE_ENTRIES: usize = 5;
const MAX_TRANSCRIPT_ENTRY_CHARS: usize = 400;

#[derive(Debug, Clone)]
pub struct DiscoveredSession {
    pub session_file: PathBuf,
    pub fingerprint: SessionFingerprint,
    pub id: String,
    pub explicit_summary: Option<String>,
    pub heuristic_summary: String,
    pub summary_input: Option<String>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    pub last_user_message_at: DateTime<Utc>,
    pub last_assistant_message_at: DateTime<Utc>,
    pub cwd: String,
    pub model: String,
    pub context_usage: Option<SessionContextUsage>,
    pub supports_images: Option<bool>,
}

impl DiscoveredSession {
    pub fn activity_timestamp(&self) -> DateTime<Utc> {
        self.last_user_message_at
            .max(self.last_assistant_message_at)
    }

    pub fn into_active_session(self, summary: String) -> ActiveSession {
        ActiveSession {
            id: self.id,
            summary,
            created_at: self.created_at,
            updated_at: self.updated_at,
            last_user_message_at: self.last_user_message_at,
            last_assistant_message_at: self.last_assistant_message_at,
            cwd: self.cwd,
            model: self.model,
            context_usage: self.context_usage,
            supports_images: self.supports_images,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionFingerprint {
    pub file_size: u64,
    pub modified_at_millis: u128,
}

pub fn resolve_pi_agent_dir(override_dir: Option<PathBuf>) -> Result<PathBuf, BoxError> {
    if let Some(path) = override_dir {
        return Ok(path);
    }

    if let Ok(path) = env::var("PI_CODING_AGENT_DIR") {
        return Ok(PathBuf::from(path));
    }

    let home = env::var("HOME")?;
    Ok(PathBuf::from(home).join(".pi").join("agent"))
}

pub fn session_root(pi_agent_dir: &Path) -> PathBuf {
    pi_agent_dir.join("sessions")
}

pub fn discover_sessions(pi_agent_dir: &Path) -> Result<Vec<DiscoveredSession>, BoxError> {
    let session_root = session_root(pi_agent_dir);
    if !session_root.exists() {
        return Ok(Vec::new());
    }

    let mut sessions = Vec::new();

    for entry in WalkDir::new(&session_root)
        .into_iter()
        .filter_map(Result::ok)
    {
        if !entry.file_type().is_file() {
            continue;
        }

        if entry.path().extension().and_then(|ext| ext.to_str()) != Some("jsonl") {
            continue;
        }

        match parse_session_file(entry.path()) {
            Ok(session) => sessions.push(session),
            Err(error) => warn!(
                path = %entry.path().display(),
                %error,
                "skipping unreadable session file"
            ),
        }
    }

    sessions.sort_by(|left, right| {
        right
            .activity_timestamp()
            .cmp(&left.activity_timestamp())
            .then_with(|| left.id.cmp(&right.id))
    });

    Ok(sessions)
}

fn parse_session_file(path: &Path) -> Result<DiscoveredSession, BoxError> {
    let file = File::open(path)?;
    let reader = BufReader::new(file);
    let metadata = fs::metadata(path)?;

    let mut header: Option<SessionHeader> = None;
    let mut session_name: Option<String> = None;
    let mut first_user_summary: Option<String> = None;
    let mut last_user_message_at: Option<DateTime<Utc>> = None;
    let mut last_assistant_message_at: Option<DateTime<Utc>> = None;
    let mut last_assistant_usage_total_tokens: Option<u64> = None;
    let mut model: Option<String> = None;
    let mut transcript_entries = SummaryTranscriptCollector::default();

    for line in reader.lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }

        let entry: Value = serde_json::from_str(&line)?;
        match entry.get("type").and_then(Value::as_str) {
            Some("session") => {
                header = Some(parse_session_header(&entry)?);
            }
            Some("session_info") => {
                if let Some(name) = entry.get("name").and_then(Value::as_str) {
                    let trimmed = collapse_whitespace(name);
                    if !trimmed.is_empty() {
                        session_name = Some(trimmed);
                    }
                }
            }
            Some("model_change") => {
                if let (Some(provider), Some(model_id)) = (
                    entry.get("provider").and_then(Value::as_str),
                    entry.get("modelId").and_then(Value::as_str),
                ) {
                    model = Some(format_model(provider, model_id));
                }
            }
            Some("message") => {
                let Some(message) = entry.get("message") else {
                    continue;
                };

                match message.get("role").and_then(Value::as_str) {
                    Some("user") => {
                        if first_user_summary.is_none() {
                            first_user_summary = extract_summary(message.get("content"));
                        }
                        last_user_message_at =
                            parse_message_timestamp(&entry, message).or(last_user_message_at);
                        if let Some(transcript_entry) = extract_transcript_entry("User", message) {
                            transcript_entries.push(transcript_entry);
                        }
                    }
                    Some("assistant") => {
                        last_assistant_message_at =
                            parse_message_timestamp(&entry, message).or(last_assistant_message_at);
                        last_assistant_usage_total_tokens = extract_usage_total_tokens(message)
                            .or(last_assistant_usage_total_tokens);

                        if let (Some(provider), Some(model_name)) = (
                            message.get("provider").and_then(Value::as_str),
                            message.get("model").and_then(Value::as_str),
                        ) {
                            model = Some(format_model(provider, model_name));
                        } else if let Some(model_name) =
                            message.get("model").and_then(Value::as_str)
                        {
                            model = Some(model_name.to_string());
                        }

                        if let Some(transcript_entry) =
                            extract_transcript_entry("Assistant", message)
                        {
                            transcript_entries.push(transcript_entry);
                        }
                    }
                    _ => {}
                }
            }
            _ => {}
        }
    }

    let header = header.ok_or_else(|| format!("missing session header in {}", path.display()))?;
    let heuristic_summary = first_user_summary
        .clone()
        .unwrap_or_else(|| header.id.clone());
    let updated_at = metadata
        .modified()
        .ok()
        .map(DateTime::<Utc>::from)
        .unwrap_or(header.created_at);
    let summary_input = transcript_entries.into_summary_input();
    let model = model.unwrap_or_else(|| "unknown".to_string());
    let context_usage = match (
        last_assistant_usage_total_tokens,
        model_context_window_tokens(&model),
    ) {
        (None, None) => None,
        (used_tokens, max_tokens) => Some(SessionContextUsage {
            used_tokens,
            max_tokens,
        }),
    };

    Ok(DiscoveredSession {
        session_file: path.to_path_buf(),
        fingerprint: session_fingerprint(&metadata),
        id: header.id,
        explicit_summary: session_name,
        heuristic_summary,
        summary_input,
        created_at: header.created_at,
        updated_at,
        last_user_message_at: last_user_message_at.unwrap_or(header.created_at),
        last_assistant_message_at: last_assistant_message_at.unwrap_or(header.created_at),
        cwd: header.cwd,
        model: model.clone(),
        context_usage,
        supports_images: model_supports_images(&model),
    })
}

fn session_fingerprint(metadata: &fs::Metadata) -> SessionFingerprint {
    let modified_at_millis = metadata
        .modified()
        .ok()
        .and_then(|timestamp| timestamp.duration_since(UNIX_EPOCH).ok())
        .map(|duration| duration.as_millis())
        .unwrap_or_default();

    SessionFingerprint {
        file_size: metadata.len(),
        modified_at_millis,
    }
}

fn parse_session_header(entry: &Value) -> Result<SessionHeader, BoxError> {
    let id = entry
        .get("id")
        .and_then(Value::as_str)
        .ok_or("session header missing id")?
        .to_string();
    let cwd = entry
        .get("cwd")
        .and_then(Value::as_str)
        .ok_or("session header missing cwd")?
        .to_string();
    let created_at = entry
        .get("timestamp")
        .and_then(Value::as_str)
        .and_then(parse_rfc3339)
        .ok_or("session header missing timestamp")?;

    Ok(SessionHeader {
        id,
        created_at,
        cwd,
    })
}

fn parse_message_timestamp(entry: &Value, message: &Value) -> Option<DateTime<Utc>> {
    message
        .get("timestamp")
        .and_then(parse_unix_millis)
        .or_else(|| {
            entry
                .get("timestamp")
                .and_then(Value::as_str)
                .and_then(parse_rfc3339)
        })
}

fn parse_unix_millis(value: &Value) -> Option<DateTime<Utc>> {
    let millis = if let Some(value) = value.as_i64() {
        value
    } else {
        let unsigned = value.as_u64()?;
        i64::try_from(unsigned).ok()?
    };

    Utc.timestamp_millis_opt(millis).single()
}

fn parse_rfc3339(value: &str) -> Option<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(value)
        .ok()
        .map(|timestamp| timestamp.with_timezone(&Utc))
}

fn extract_usage_total_tokens(message: &Value) -> Option<u64> {
    let usage = message.get("usage")?;
    usage.get("totalTokens").and_then(positive_u64).or_else(|| {
        let input = usage.get("input").and_then(positive_u64).unwrap_or(0);
        let output = usage.get("output").and_then(positive_u64).unwrap_or(0);
        let cache_read = usage.get("cacheRead").and_then(positive_u64).unwrap_or(0);
        let cache_write = usage.get("cacheWrite").and_then(positive_u64).unwrap_or(0);
        let total = input + output + cache_read + cache_write;
        (total > 0).then_some(total)
    })
}

fn positive_u64(value: &Value) -> Option<u64> {
    value
        .as_u64()
        .or_else(|| value.as_i64().and_then(|number| u64::try_from(number).ok()))
}

#[derive(Debug, Clone)]
struct ModelCapabilities {
    context_window: u64,
    supports_images: bool,
}

fn model_context_window_tokens(model: &str) -> Option<u64> {
    model_capabilities(model).map(|cap| cap.context_window)
}

fn model_supports_images(model: &str) -> Option<bool> {
    model_capabilities(model).map(|cap| cap.supports_images)
}

fn model_capabilities(model: &str) -> Option<ModelCapabilities> {
    static CAPABILITIES: OnceLock<HashMap<String, ModelCapabilities>> = OnceLock::new();

    CAPABILITIES
        .get_or_init(|| match load_model_capabilities() {
            Ok(caps) => caps,
            Err(error) => {
                warn!(%error, "failed to load pi model capabilities");
                HashMap::new()
            }
        })
        .get(model)
        .cloned()
}

fn load_model_capabilities() -> Result<HashMap<String, ModelCapabilities>, BoxError> {
    let output = Command::new("pi").arg("--list-models").output()?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        let message = if stderr.is_empty() {
            format!("pi --list-models exited with status {}", output.status)
        } else {
            format!("pi --list-models failed: {stderr}")
        };
        return Err(message.into());
    }

    let stdout = String::from_utf8(output.stdout)?;
    Ok(parse_model_capabilities(&stdout))
}

fn parse_model_capabilities(output: &str) -> HashMap<String, ModelCapabilities> {
    let mut capabilities = HashMap::new();

    for line in output.lines() {
        let columns = line.split_whitespace().collect::<Vec<_>>();
        if columns.len() < 3 || columns[0] == "provider" {
            continue;
        }

        let Some(context_window) = parse_token_count(columns[2]) else {
            continue;
        };

        let supports_images = columns.get(5).map_or(false, |col| *col == "yes");
        let key = format!("{}/{}", columns[0], columns[1]);
        capabilities.insert(
            key,
            ModelCapabilities {
                context_window,
                supports_images,
            },
        );
    }

    capabilities
}

fn parse_model_context_windows(output: &str) -> HashMap<String, u64> {
    parse_model_capabilities(output)
        .into_iter()
        .map(|(key, cap)| (key, cap.context_window))
        .collect()
}

fn parse_token_count(value: &str) -> Option<u64> {
    let value = value.trim();
    if value.is_empty() {
        return None;
    }

    let (number, multiplier) = match value.chars().last()? {
        'K' | 'k' => (&value[..value.len() - 1], 1_000_f64),
        'M' | 'm' => (&value[..value.len() - 1], 1_000_000_f64),
        _ => (value, 1_f64),
    };

    let parsed = number.parse::<f64>().ok()?;
    Some((parsed * multiplier).round() as u64)
}

fn extract_summary(content: Option<&Value>) -> Option<String> {
    let text = extract_message_text(content)?;
    Some(truncate_chars(&text, MAX_SUMMARY_LEN))
}

fn extract_transcript_entry(role: &str, message: &Value) -> Option<String> {
    let text = extract_message_text(message.get("content"))?;
    let combined = truncate_chars(&collapse_whitespace(&text), MAX_TRANSCRIPT_ENTRY_CHARS);
    Some(format!("{role}: {combined}"))
}

fn extract_message_text(content: Option<&Value>) -> Option<String> {
    let content = content?;
    let text = match content {
        Value::String(text) => text.clone(),
        Value::Array(blocks) => blocks
            .iter()
            .filter_map(|block| match block.get("type").and_then(Value::as_str) {
                Some("text") => block.get("text").and_then(Value::as_str),
                _ => None,
            })
            .collect::<Vec<_>>()
            .join(" "),
        _ => return None,
    };

    let collapsed = collapse_whitespace(&text);
    if collapsed.is_empty() {
        None
    } else {
        Some(collapsed)
    }
}

#[derive(Clone)]
struct IndexedTranscriptEntry {
    index: usize,
    text: String,
}

#[derive(Default)]
struct SummaryTranscriptCollector {
    next_index: usize,
    first_entries: Vec<IndexedTranscriptEntry>,
    last_entries: VecDeque<IndexedTranscriptEntry>,
}

impl SummaryTranscriptCollector {
    fn push(&mut self, entry: String) {
        let indexed = IndexedTranscriptEntry {
            index: self.next_index,
            text: entry,
        };
        self.next_index += 1;

        if self.first_entries.len() < MAX_SUMMARY_TRANSCRIPT_EDGE_ENTRIES {
            self.first_entries.push(indexed.clone());
        }

        self.last_entries.push_back(indexed);
        while self.last_entries.len() > MAX_SUMMARY_TRANSCRIPT_EDGE_ENTRIES {
            self.last_entries.pop_front();
        }
    }

    fn into_summary_input(self) -> Option<String> {
        if self.next_index == 0 {
            return None;
        }

        let mut entries = self.first_entries;
        for entry in self.last_entries {
            if entries.iter().any(|existing| existing.index == entry.index) {
                continue;
            }
            entries.push(entry);
        }

        Some(
            entries
                .into_iter()
                .map(|entry| entry.text)
                .collect::<Vec<_>>()
                .join("\n\n"),
        )
    }
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

fn format_model(provider: &str, model: &str) -> String {
    format!("{provider}/{model}")
}

struct SessionHeader {
    id: String,
    created_at: DateTime<Utc>,
    cwd: String,
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn extract_transcript_entry_ignores_tool_calls() {
        let message = json!({
            "content": [
                { "type": "toolCall", "name": "bash" },
                { "type": "toolCall", "name": "read" }
            ]
        });

        assert_eq!(extract_transcript_entry("Assistant", &message), None);
    }

    #[test]
    fn summary_transcript_collector_keeps_first_and_last_five_entries() {
        let mut collector = SummaryTranscriptCollector::default();
        for index in 0..12 {
            collector.push(format!("Entry {index}"));
        }

        let summary_input = collector.into_summary_input().unwrap();
        assert_eq!(
            summary_input,
            [
                "Entry 0", "Entry 1", "Entry 2", "Entry 3", "Entry 4", "Entry 7", "Entry 8",
                "Entry 9", "Entry 10", "Entry 11",
            ]
            .join("\n\n")
        );
    }

    #[test]
    fn summary_transcript_collector_deduplicates_overlap() {
        let mut collector = SummaryTranscriptCollector::default();
        for index in 0..3 {
            collector.push(format!("Entry {index}"));
        }

        let summary_input = collector.into_summary_input().unwrap();
        assert_eq!(
            summary_input,
            ["Entry 0", "Entry 1", "Entry 2"].join("\n\n")
        );
    }

    #[test]
    fn extract_usage_total_tokens_prefers_explicit_total() {
        let message = json!({
            "usage": {
                "input": 10,
                "output": 20,
                "cacheRead": 30,
                "cacheWrite": 40,
                "totalTokens": 1234
            }
        });

        assert_eq!(extract_usage_total_tokens(&message), Some(1234));
    }

    #[test]
    fn extract_usage_total_tokens_falls_back_to_usage_sum() {
        let message = json!({
            "usage": {
                "input": 10,
                "output": 20,
                "cacheRead": 30,
                "cacheWrite": 40
            }
        });

        assert_eq!(extract_usage_total_tokens(&message), Some(100));
    }

    #[test]
    fn parse_model_context_windows_reads_token_suffixes() {
        let output = [
            "provider      model              context  max-out  thinking  images",
            "anthropic     claude-opus-4-6    1M       128K     yes       yes",
            "openai-codex  gpt-5.4            272K     128K     yes       yes",
            "anthropic     claude-haiku-4-5   200K     64K      yes       yes",
        ]
        .join("\n");

        let context_windows = parse_model_context_windows(&output);
        assert_eq!(
            context_windows.get("anthropic/claude-opus-4-6"),
            Some(&1_000_000)
        );
        assert_eq!(context_windows.get("openai-codex/gpt-5.4"), Some(&272_000));
        assert_eq!(
            context_windows.get("anthropic/claude-haiku-4-5"),
            Some(&200_000)
        );
    }

    #[test]
    fn parse_model_capabilities_extracts_image_support() {
        let output = [
            "provider      model              context  max-out  thinking  images",
            "anthropic     claude-opus-4-6    1M       128K     yes       yes",
            "openai-codex  gpt-5.4            272K     128K     yes       no",
            "anthropic     claude-haiku-4-5   200K     64K      yes       yes",
        ]
        .join("\n");

        let caps = parse_model_capabilities(&output);
        assert!(
            caps.get("anthropic/claude-opus-4-6")
                .unwrap()
                .supports_images
        );
        assert!(!caps.get("openai-codex/gpt-5.4").unwrap().supports_images);
        assert!(
            caps.get("anthropic/claude-haiku-4-5")
                .unwrap()
                .supports_images
        );
    }
}
