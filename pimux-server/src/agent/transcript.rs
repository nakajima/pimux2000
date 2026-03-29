use std::{
    collections::HashMap,
    fs::File,
    io::{BufRead, BufReader},
};

use chrono::{DateTime, TimeZone, Utc};
use serde_json::Value;

use crate::{
    message::{
        Message, MessageContentBlock, MessageContentBlockKind, Role, collapse_whitespace,
        normalized_display_text, truncate_text,
    },
    transcript::{
        SessionActivity, SessionMessagesResponse, TranscriptFreshness, TranscriptFreshnessState,
        TranscriptSource,
    },
};

use super::discovery::DiscoveredSession;

type BoxError = Box<dyn std::error::Error + Send + Sync>;

const MAX_MESSAGE_BODY_CHARS: usize = 8_000;
const PERSISTED_WARNING: &str = "This transcript was reconstructed from persisted session state and may not include in-memory live updates.";

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
        Some("custom_message") => Message::from_text(
            parse_entry_timestamp(entry)?,
            Role::Custom,
            truncate_text(
                &flatten_text_content(entry.get("content"))?,
                MAX_MESSAGE_BODY_CHARS,
            ),
        ),
        Some("branch_summary") => Message::from_text(
            parse_entry_timestamp(entry)?,
            Role::BranchSummary,
            truncate_text(
                &collapse_whitespace(entry.get("summary").and_then(Value::as_str)?),
                MAX_MESSAGE_BODY_CHARS,
            ),
        ),
        Some("compaction") => Message::from_text(
            parse_entry_timestamp(entry)?,
            Role::CompactionSummary,
            truncate_text(
                &collapse_whitespace(entry.get("summary").and_then(Value::as_str)?),
                MAX_MESSAGE_BODY_CHARS,
            ),
        ),
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

    match role {
        Role::User | Role::ToolResult | Role::Custom | Role::Other => Message::from_blocks(
            created_at,
            role,
            content_blocks(message.get("content"), false),
        ),
        Role::Assistant => Message::from_blocks(
            created_at,
            role,
            content_blocks(message.get("content"), true),
        ),
        Role::BranchSummary => Message::from_text(
            created_at,
            role,
            truncate_text(
                &collapse_whitespace(message.get("summary").and_then(Value::as_str)?),
                MAX_MESSAGE_BODY_CHARS,
            ),
        ),
        Role::CompactionSummary => Message::from_text(
            created_at,
            role,
            truncate_text(
                &collapse_whitespace(message.get("summary").and_then(Value::as_str)?),
                MAX_MESSAGE_BODY_CHARS,
            ),
        ),
        Role::BashExecution => flatten_bash_execution_message(created_at, message),
    }
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

fn content_blocks(content: Option<&Value>, include_tool_calls: bool) -> Vec<MessageContentBlock> {
    let Some(content) = content else {
        return Vec::new();
    };

    match content {
        Value::String(text) => MessageContentBlock::text(text).into_iter().collect(),
        Value::Array(blocks) => blocks
            .iter()
            .filter_map(|block| match block.get("type").and_then(Value::as_str) {
                Some("text") => block
                    .get("text")
                    .and_then(Value::as_str)
                    .and_then(MessageContentBlock::text),
                Some("thinking") => block
                    .get("thinking")
                    .and_then(Value::as_str)
                    .and_then(MessageContentBlock::thinking),
                Some("toolCall") if include_tool_calls => block
                    .get("name")
                    .and_then(Value::as_str)
                    .and_then(MessageContentBlock::tool_call),
                Some("image") => Some(MessageContentBlock::image(
                    block.get("mimeType").and_then(Value::as_str),
                    block.get("data").and_then(Value::as_str),
                )),
                _ => None,
            })
            .collect(),
        _ => Vec::new(),
    }
}

fn flatten_text_content(content: Option<&Value>) -> Option<String> {
    let blocks = content_blocks(content, false);
    let parts = blocks
        .iter()
        .filter(|block| block.kind == MessageContentBlockKind::Text)
        .filter_map(|block| block.text.clone())
        .collect::<Vec<_>>();
    if parts.is_empty() {
        None
    } else {
        Some(parts.join("\n\n"))
    }
}

fn flatten_bash_execution_message(created_at: DateTime<Utc>, message: &Value) -> Option<Message> {
    Message::from_text(
        created_at,
        Role::BashExecution,
        flatten_bash_execution(message),
    )
}

fn flatten_bash_execution(message: &Value) -> String {
    let mut parts = Vec::new();

    if let Some(command) = message.get("command").and_then(Value::as_str)
        && let Some(command) = normalized_display_text(command)
    {
        parts.push(format!("$ {command}"));
    }

    if let Some(output) = message.get("output").and_then(Value::as_str)
        && let Some(output) = normalized_display_text(output)
    {
        parts.push(output);
    }

    if parts.is_empty() {
        return "bash execution".to_string();
    }

    truncate_text(&parts.join("\n\n"), MAX_MESSAGE_BODY_CHARS)
}

#[derive(Debug, Clone)]
struct ParsedEntry {
    id: String,
    parent_id: Option<String>,
    value: Value,
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::{content_blocks, flatten_bash_execution};
    use crate::message::MessageContentBlockKind;

    #[test]
    fn content_blocks_preserve_multiline_text() {
        let content = json!([
            {
                "type": "text",
                "text": "first line\nsecond line"
            }
        ]);

        let blocks = content_blocks(Some(&content), false);
        assert_eq!(blocks.len(), 1);
        assert_eq!(blocks[0].kind, MessageContentBlockKind::Text);
        assert_eq!(blocks[0].text.as_deref(), Some("first line\nsecond line"));
    }

    #[test]
    fn content_blocks_include_thinking_and_tool_calls() {
        let content = json!([
            {
                "type": "thinking",
                "thinking": "considering"
            },
            {
                "type": "toolCall",
                "name": "bash"
            }
        ]);

        let blocks = content_blocks(Some(&content), true);
        assert_eq!(blocks.len(), 2);
        assert_eq!(blocks[0].kind, MessageContentBlockKind::Thinking);
        assert_eq!(blocks[0].text.as_deref(), Some("considering"));
        assert_eq!(blocks[1].kind, MessageContentBlockKind::ToolCall);
        assert_eq!(blocks[1].tool_call_name.as_deref(), Some("bash"));
    }

    #[test]
    fn content_blocks_preserve_images() {
        let content = json!([
            {
                "type": "image",
                "mimeType": "image/png",
                "data": "ZmFrZQ=="
            }
        ]);

        let blocks = content_blocks(Some(&content), false);
        assert_eq!(blocks.len(), 1);
        assert_eq!(blocks[0].kind, MessageContentBlockKind::Image);
        assert_eq!(blocks[0].mime_type.as_deref(), Some("image/png"));
        assert_eq!(blocks[0].data.as_deref(), Some("ZmFrZQ=="));
    }

    #[test]
    fn flatten_bash_execution_preserves_multiline_output() {
        let message = json!({
            "command": "printf 'hi\\nthere'",
            "output": "hi\nthere\n"
        });

        let flattened = flatten_bash_execution(&message);
        assert_eq!(flattened, "$ printf 'hi\\nthere'\n\nhi\nthere");
    }
}
