use std::{
    collections::VecDeque,
    env,
    fs::{self, File},
    io::{BufRead, BufReader},
    path::{Path, PathBuf},
    time::UNIX_EPOCH,
};

use chrono::{DateTime, TimeZone, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use walkdir::WalkDir;

use crate::session::ActiveSession;

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
            Err(error) => eprintln!(
                "skipping unreadable session file {}: {error}",
                entry.path().display()
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
        model: model.unwrap_or_else(|| "unknown".to_string()),
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
}
