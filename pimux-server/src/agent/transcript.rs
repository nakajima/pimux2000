use std::{
    collections::HashMap,
    fs::File,
    io::{BufRead, BufReader},
};

use chrono::{DateTime, TimeZone, Utc};
use serde_json::Value;

use crate::{
    message::{Message, Role},
    transcript::{
        SessionActivity, SessionMessagesBatchReport, SessionMessagesResponse, TranscriptFreshness,
        TranscriptFreshnessState, TranscriptSource,
    },
};

use super::discovery::DiscoveredSession;

type BoxError = Box<dyn std::error::Error + Send + Sync>;

const MAX_CACHED_TRANSCRIPTS: usize = 12;
const MAX_MESSAGE_BODY_CHARS: usize = 8_000;
const PERSISTED_WARNING: &str = "This transcript was reconstructed from persisted session state and may not include in-memory live updates.";

pub fn build_recent_transcript_report(
    host_location: &str,
    discovered_sessions: &[DiscoveredSession],
    live_overrides: &HashMap<String, SessionMessagesResponse>,
) -> Result<SessionMessagesBatchReport, BoxError> {
    let mut sessions = Vec::new();

    for discovered_session in discovered_sessions.iter().take(MAX_CACHED_TRANSCRIPTS) {
        if let Some(snapshot) = live_overrides.get(&discovered_session.id) {
            sessions.push(snapshot.clone());
            continue;
        }

        match build_persisted_snapshot(discovered_session) {
            Ok(snapshot) => sessions.push(snapshot),
            Err(error) => eprintln!(
                "skipping transcript snapshot for {} ({}): {error}",
                discovered_session.id,
                discovered_session.session_file.display(),
            ),
        }
    }

    Ok(SessionMessagesBatchReport {
        host_location: host_location.to_string(),
        sessions,
    })
}

pub fn build_persisted_snapshot(
    discovered_session: &DiscoveredSession,
) -> Result<SessionMessagesResponse, BoxError> {
    let file = File::open(&discovered_session.session_file)?;
    let reader = BufReader::new(file);
    let mut entries = Vec::new();
    let mut leaf_id = None;

    for line in reader.lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }

        let entry: Value = serde_json::from_str(&line)?;
        if entry.get("type").and_then(Value::as_str) == Some("session") {
            continue;
        }

        let Some(id) = entry.get("id").and_then(Value::as_str) else {
            continue;
        };

        leaf_id = Some(id.to_string());
        entries.push(ParsedEntry {
            id: id.to_string(),
            parent_id: entry
                .get("parentId")
                .and_then(Value::as_str)
                .map(str::to_string),
            value: entry,
        });
    }

    let branch = current_branch(entries, leaf_id)?;
    let mut messages = Vec::new();
    let mut last_timestamp = discovered_session.activity_timestamp();

    for entry in branch {
        if let Some(message) = entry_to_message(&entry.value) {
            last_timestamp = message.created_at;
            messages.push(message);
        }
    }

    Ok(SessionMessagesResponse {
        session_id: discovered_session.id.clone(),
        messages,
        freshness: TranscriptFreshness {
            state: TranscriptFreshnessState::LiveUnknown,
            source: TranscriptSource::File,
            as_of: last_timestamp,
        },
        activity: SessionActivity {
            active: false,
            attached: false,
        },
        warnings: vec![PERSISTED_WARNING.to_string()],
    })
}

fn current_branch(
    entries: Vec<ParsedEntry>,
    leaf_id: Option<String>,
) -> Result<Vec<ParsedEntry>, BoxError> {
    let mut by_id = HashMap::new();
    for (index, entry) in entries.iter().enumerate() {
        by_id.insert(entry.id.clone(), index);
    }

    let mut branch = Vec::new();
    let mut current = leaf_id;

    while let Some(id) = current {
        let Some(index) = by_id.get(&id).copied() else {
            return Err(format!("session branch references missing entry {id}").into());
        };

        let entry = entries[index].clone();
        current = entry.parent_id.clone();
        branch.push(entry);
    }

    branch.reverse();
    Ok(branch)
}

fn entry_to_message(entry: &Value) -> Option<Message> {
    match entry.get("type").and_then(Value::as_str) {
        Some("message") => nested_message_to_message(entry),
        Some("custom_message") => Some(Message {
            created_at: parse_entry_timestamp(entry)?,
            role: Role::Custom,
            body: flatten_content(entry.get("content"), false)?,
        }),
        Some("branch_summary") => Some(Message {
            created_at: parse_entry_timestamp(entry)?,
            role: Role::BranchSummary,
            body: truncate_body(collapse_whitespace(
                entry.get("summary").and_then(Value::as_str)?,
            )),
        }),
        Some("compaction") => Some(Message {
            created_at: parse_entry_timestamp(entry)?,
            role: Role::CompactionSummary,
            body: truncate_body(collapse_whitespace(
                entry.get("summary").and_then(Value::as_str)?,
            )),
        }),
        _ => None,
    }
}

fn nested_message_to_message(entry: &Value) -> Option<Message> {
    let message = entry.get("message")?;
    let role = match message.get("role").and_then(Value::as_str)? {
        "user" => Role::User,
        "assistant" => Role::Assistant,
        "toolResult" => Role::ToolResult,
        "bashExecution" => Role::BashExecution,
        "custom" => Role::Custom,
        "branchSummary" => Role::BranchSummary,
        "compactionSummary" => Role::CompactionSummary,
        _ => Role::Other,
    };
    let created_at = parse_message_timestamp(entry, message)?;
    let body = match role {
        Role::User | Role::ToolResult | Role::Custom | Role::Other => {
            flatten_content(message.get("content"), false)?
        }
        Role::Assistant => flatten_content(message.get("content"), true)?,
        Role::BranchSummary => truncate_body(collapse_whitespace(
            message.get("summary").and_then(Value::as_str)?,
        )),
        Role::CompactionSummary => truncate_body(collapse_whitespace(
            message.get("summary").and_then(Value::as_str)?,
        )),
        Role::BashExecution => flatten_bash_execution(message),
    };

    Some(Message {
        created_at,
        role,
        body,
    })
}

fn parse_message_timestamp(entry: &Value, message: &Value) -> Option<DateTime<Utc>> {
    message
        .get("timestamp")
        .and_then(parse_unix_millis)
        .or_else(|| parse_entry_timestamp(entry))
}

fn parse_entry_timestamp(entry: &Value) -> Option<DateTime<Utc>> {
    entry.get("timestamp")?.as_str().and_then(parse_rfc3339)
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

fn flatten_content(content: Option<&Value>, include_tool_calls: bool) -> Option<String> {
    let content = content?;
    let flattened = match content {
        Value::String(text) => collapse_whitespace(text),
        Value::Array(blocks) => {
            let mut parts = Vec::new();
            for block in blocks {
                match block.get("type").and_then(Value::as_str) {
                    Some("text") => {
                        if let Some(text) = block.get("text").and_then(Value::as_str) {
                            let text = collapse_whitespace(text);
                            if !text.is_empty() {
                                parts.push(text);
                            }
                        }
                    }
                    Some("toolCall") if include_tool_calls => {
                        if let Some(name) = block.get("name").and_then(Value::as_str) {
                            parts.push(format!("Tool call: {}", collapse_whitespace(name)));
                        }
                    }
                    _ => {}
                }
            }
            parts.join("\n\n")
        }
        _ => return None,
    };

    let flattened = flattened.trim();
    if flattened.is_empty() {
        None
    } else {
        Some(truncate_body(flattened.to_string()))
    }
}

fn flatten_bash_execution(message: &Value) -> String {
    let mut parts = Vec::new();

    if let Some(command) = message.get("command").and_then(Value::as_str) {
        let command = collapse_whitespace(command);
        if !command.is_empty() {
            parts.push(format!("$ {command}"));
        }
    }

    if let Some(output) = message.get("output").and_then(Value::as_str) {
        let output = output.trim();
        if !output.is_empty() {
            parts.push(output.to_string());
        }
    }

    if parts.is_empty() {
        return "bash execution".to_string();
    }

    truncate_body(parts.join("\n\n"))
}

fn collapse_whitespace(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn truncate_body(body: String) -> String {
    if body.chars().count() <= MAX_MESSAGE_BODY_CHARS {
        return body;
    }

    let truncated = body
        .chars()
        .take(MAX_MESSAGE_BODY_CHARS)
        .collect::<String>();
    format!("{truncated}…")
}

#[derive(Debug, Clone)]
struct ParsedEntry {
    id: String,
    parent_id: Option<String>,
    value: Value,
}
