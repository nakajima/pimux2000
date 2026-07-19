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
        normalized_display_text, tool_call_summary, truncate_text,
    },
    transcript::{
        SessionActivity, SessionMessagesResponse, TranscriptFreshness, TranscriptFreshnessState,
        TranscriptSource,
    },
};

use super::discovery::{DiscoveredSession, SessionSource};

type BoxError = Box<dyn std::error::Error + Send + Sync>;

const MAX_MESSAGE_BODY_CHARS: usize = 8_000;
const PERSISTED_WARNING: &str = "This transcript was reconstructed from persisted session state and may not include in-memory live updates.";

pub fn build_persisted_snapshot(
    discovered_session: &DiscoveredSession,
) -> Result<SessionMessagesResponse, BoxError> {
    if discovered_session.source == SessionSource::Claude {
        return build_claude_snapshot(discovered_session);
    }

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
        if let Some(mut message) = entry_to_message(&entry.value) {
            message.message_id = Some(entry.id.clone());
            last_timestamp = message.created_at;
            messages.push(message);
        }
    }

    let (freshness_state, warnings) = match discovered_session.source {
        SessionSource::Pi => (
            TranscriptFreshnessState::LiveUnknown,
            vec![PERSISTED_WARNING.to_string()],
        ),
        SessionSource::Mi => (TranscriptFreshnessState::Persisted, Vec::new()),
        SessionSource::Claude => unreachable!("Claude sessions use their own transcript parser"),
    };

    Ok(SessionMessagesResponse {
        session_id: discovered_session.id.clone(),
        messages,
        freshness: TranscriptFreshness {
            state: freshness_state,
            source: TranscriptSource::File,
            as_of: last_timestamp,
        },
        activity: SessionActivity {
            active: false,
            attached: false,
        },
        warnings,
    })
}

fn build_claude_snapshot(
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
        if entry.get("isSidechain").and_then(Value::as_bool) == Some(true) {
            continue;
        }
        let Some(id) = entry.get("uuid").and_then(Value::as_str) else {
            continue;
        };

        leaf_id = Some(id.to_string());
        entries.push(ParsedEntry {
            id: id.to_string(),
            parent_id: entry
                .get("parentUuid")
                .and_then(Value::as_str)
                .map(str::to_string),
            value: entry,
        });
    }

    let branch = current_branch(entries, leaf_id)?;
    let mut parser = ClaudeEntryParser::default();
    let mut messages = Vec::new();
    let mut last_timestamp = discovered_session.activity_timestamp();

    for entry in branch {
        let mut entry_messages = parser.messages(&entry.value);
        let message_count = entry_messages.len();
        for (position, mut message) in entry_messages.drain(..).enumerate() {
            message.message_id = Some(if message_count == 1 {
                entry.id.clone()
            } else {
                format!("{}:{position}", entry.id)
            });
            last_timestamp = message.created_at;
            messages.push(message);
        }
    }

    Ok(SessionMessagesResponse {
        session_id: discovered_session.id.clone(),
        messages,
        freshness: TranscriptFreshness {
            state: TranscriptFreshnessState::Persisted,
            source: TranscriptSource::File,
            as_of: last_timestamp,
        },
        activity: SessionActivity {
            active: false,
            attached: false,
        },
        warnings: Vec::new(),
    })
}

#[derive(Default)]
struct ClaudeEntryParser {
    tool_names_by_call_id: HashMap<String, String>,
}

impl ClaudeEntryParser {
    fn messages(&mut self, entry: &Value) -> Vec<Message> {
        match entry.get("type").and_then(Value::as_str) {
            Some("assistant") => self.assistant_message(entry).into_iter().collect(),
            Some("user") => self.user_messages(entry),
            _ => Vec::new(),
        }
    }

    fn assistant_message(&mut self, entry: &Value) -> Option<Message> {
        let created_at = parse_entry_timestamp(entry)?;
        let content = entry.get("message")?.get("content")?;
        let mut blocks = Vec::new();

        match content {
            Value::String(text) => blocks.extend(MessageContentBlock::text(text)),
            Value::Array(content_blocks) => {
                for block in content_blocks {
                    match block.get("type").and_then(Value::as_str) {
                        Some("text") => blocks.extend(
                            block
                                .get("text")
                                .and_then(Value::as_str)
                                .and_then(MessageContentBlock::text),
                        ),
                        Some("thinking") => blocks.extend(
                            block
                                .get("thinking")
                                .and_then(Value::as_str)
                                .and_then(MessageContentBlock::thinking),
                        ),
                        Some("tool_use") => {
                            let Some(name) = block.get("name").and_then(Value::as_str) else {
                                continue;
                            };
                            let tool_call_id = block.get("id").and_then(Value::as_str);
                            if let Some(tool_call_id) = tool_call_id {
                                self.tool_names_by_call_id
                                    .insert(tool_call_id.to_string(), name.to_string());
                            }
                            let summary =
                                tool_call_summary(&name.to_ascii_lowercase(), block.get("input"));
                            blocks.extend(MessageContentBlock::tool_call_with_id(
                                tool_call_id,
                                name,
                                summary.as_deref(),
                            ));
                        }
                        Some("image") => blocks.extend(Self::image_block(block)),
                        _ => {}
                    }
                }
            }
            _ => {}
        }

        Message::from_blocks(created_at, Role::Assistant, blocks)
    }

    fn user_messages(&self, entry: &Value) -> Vec<Message> {
        if entry.get("isMeta").and_then(Value::as_bool) == Some(true) {
            return Vec::new();
        }

        let Some(created_at) = parse_entry_timestamp(entry) else {
            return Vec::new();
        };
        let Some(content) = entry
            .get("message")
            .and_then(|message| message.get("content"))
        else {
            return Vec::new();
        };

        match content {
            Value::String(text) => Message::from_text(created_at, Role::User, text)
                .into_iter()
                .collect(),
            Value::Array(content_blocks) => {
                let mut messages = Vec::new();
                let mut user_blocks = Vec::new();

                for block in content_blocks {
                    match block.get("type").and_then(Value::as_str) {
                        Some("text") => user_blocks.extend(
                            block
                                .get("text")
                                .and_then(Value::as_str)
                                .and_then(MessageContentBlock::text),
                        ),
                        Some("image") => user_blocks.extend(Self::image_block(block)),
                        Some("tool_result") => {
                            if let Some(message) = Message::from_blocks(
                                created_at,
                                Role::User,
                                std::mem::take(&mut user_blocks),
                            ) {
                                messages.push(message);
                            }
                            if let Some(message) = self.tool_result_message(created_at, block) {
                                messages.push(message);
                            }
                        }
                        _ => {}
                    }
                }

                if let Some(message) = Message::from_blocks(created_at, Role::User, user_blocks) {
                    messages.push(message);
                }
                messages
            }
            _ => Vec::new(),
        }
    }

    fn tool_result_message(&self, created_at: DateTime<Utc>, block: &Value) -> Option<Message> {
        let tool_call_id = block.get("tool_use_id").and_then(Value::as_str);
        let content = block.get("content")?;
        let mut result_blocks = Vec::new();

        match content {
            Value::String(text) => result_blocks.extend(MessageContentBlock::text(text)),
            Value::Array(content_blocks) => {
                for block in content_blocks {
                    match block.get("type").and_then(Value::as_str) {
                        Some("text") => result_blocks.extend(
                            block
                                .get("text")
                                .and_then(Value::as_str)
                                .and_then(MessageContentBlock::text),
                        ),
                        Some("image") => result_blocks.extend(Self::image_block(block)),
                        _ => {}
                    }
                }
            }
            _ => {}
        }

        let mut message = Message::from_blocks(created_at, Role::ToolResult, result_blocks)?;
        message.tool_call_id = tool_call_id.map(str::to_string);
        message.tool_name = tool_call_id
            .and_then(|tool_call_id| self.tool_names_by_call_id.get(tool_call_id).cloned());
        Some(message)
    }

    fn image_block(block: &Value) -> Option<MessageContentBlock> {
        let source = block.get("source").unwrap_or(block);
        let mime_type = source
            .get("media_type")
            .or_else(|| source.get("mimeType"))
            .and_then(Value::as_str)?;
        let data = source.get("data").and_then(Value::as_str)?;
        Some(MessageContentBlock::image(Some(mime_type), Some(data)))
    }
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
    let role = Role::from_raw(message.get("role").and_then(Value::as_str)?);
    let created_at = parse_message_timestamp(entry, message)?;

    let mut parsed = match role.clone() {
        Role::User | Role::ToolResult | Role::Custom | Role::Other(_) => Message::from_blocks(
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
    }?;

    parsed.tool_name = message_tool_name(message);
    parsed.tool_call_id = message_tool_call_id(message);
    Some(parsed)
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

fn message_tool_name(message: &Value) -> Option<String> {
    let tool_name = message.get("toolName").and_then(Value::as_str)?;
    let tool_name = collapse_whitespace(tool_name);
    if tool_name.is_empty() {
        None
    } else {
        Some(tool_name)
    }
}

fn message_tool_call_id(message: &Value) -> Option<String> {
    message
        .get("toolCallId")
        .and_then(Value::as_str)
        .and_then(normalized_display_text)
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
                Some("toolCall") if include_tool_calls => {
                    let name = block.get("name").and_then(Value::as_str)?;
                    let summary = tool_call_summary(name, block.get("arguments"));
                    match block.get("id").and_then(Value::as_str) {
                        Some(tool_call_id) => MessageContentBlock::tool_call_with_id(
                            Some(tool_call_id),
                            name,
                            summary.as_deref(),
                        ),
                        None => MessageContentBlock::tool_call(name, summary.as_deref()),
                    }
                }
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

    let mut metadata = Vec::new();
    if let Some(exit_code) = message.get("exitCode").and_then(Value::as_i64) {
        metadata.push(format!("exit code: {exit_code}"));
    }
    if message.get("cancelled").and_then(Value::as_bool) == Some(true) {
        metadata.push("cancelled".to_string());
    }
    if message.get("truncated").and_then(Value::as_bool) == Some(true) {
        metadata.push("truncated".to_string());
    }
    if let Some(path) = message.get("fullOutputPath").and_then(Value::as_str)
        && let Some(path) = normalized_display_text(path)
    {
        metadata.push(format!("full output: {path}"));
    }
    if !metadata.is_empty() {
        parts.push(metadata.join("\n"));
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
    use std::fs;

    use chrono::Utc;
    use serde_json::json;

    use super::{build_persisted_snapshot, content_blocks, flatten_bash_execution};
    use crate::{
        agent::discovery::{DiscoveredSession, SessionFingerprint, SessionSource},
        message::{MessageContentBlockKind, Role},
        transcript::TranscriptFreshnessState,
    };

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
                "id": "call-123",
                "name": "bash",
                "arguments": {
                    "command": "ls -la",
                    "timeout": 10
                }
            }
        ]);

        let blocks = content_blocks(Some(&content), true);
        assert_eq!(blocks.len(), 2);
        assert_eq!(blocks[0].kind, MessageContentBlockKind::Thinking);
        assert_eq!(blocks[0].text.as_deref(), Some("considering"));
        assert_eq!(blocks[1].kind, MessageContentBlockKind::ToolCall);
        assert_eq!(blocks[1].tool_call_name.as_deref(), Some("bash"));
        assert_eq!(blocks[1].tool_call_id.as_deref(), Some("call-123"));
        assert_eq!(blocks[1].text.as_deref(), Some("$ ls -la\n\ntimeout: 10s"));
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
            "output": "hi\nthere\n",
            "exitCode": 0,
            "truncated": true,
            "fullOutputPath": "/tmp/bash-output.txt"
        });

        let flattened = flatten_bash_execution(&message);
        assert_eq!(
            flattened,
            "$ printf 'hi\\nthere'\n\nhi\nthere\n\nexit code: 0\ntruncated\nfull output: /tmp/bash-output.txt"
        );
    }

    #[test]
    fn mi_persisted_snapshots_report_persisted_freshness_without_warnings() {
        let root = std::env::temp_dir().join(format!(
            "pimux-transcript-mi-{}-{}",
            std::process::id(),
            Utc::now().timestamp_nanos_opt().unwrap_or_default()
        ));
        fs::create_dir_all(&root).unwrap();
        let path = root.join("session.jsonl");
        fs::write(
            &path,
            [
                r#"{"type":"session","version":3,"id":"session-1","timestamp":"2026-04-08T00:00:00.000Z","cwd":"/tmp/project"}"#,
                r#"{"type":"message","id":"00000001","parentId":null,"timestamp":"2026-04-08T00:00:01.000Z","message":{"role":"user","content":"Hello","timestamp":1712534401000}}"#,
            ]
            .join("\n"),
        )
        .unwrap();

        let discovered_session = DiscoveredSession {
            source: SessionSource::Mi,
            session_file: path,
            fingerprint: SessionFingerprint {
                file_size: 1,
                modified_at_millis: 1,
            },
            id: "mi:session-1".to_string(),
            explicit_summary: None,
            heuristic_summary: "session-1".to_string(),
            summary_input: None,
            created_at: Utc::now(),
            updated_at: Utc::now(),
            last_user_message_at: Utc::now(),
            last_assistant_message_at: Utc::now(),
            cwd: "/tmp/project".to_string(),
            model: "unknown".to_string(),
            context_usage: None,
            supports_images: None,
        };

        let snapshot = build_persisted_snapshot(&discovered_session).unwrap();
        assert_eq!(
            snapshot.freshness.state,
            TranscriptFreshnessState::Persisted
        );
        assert!(snapshot.warnings.is_empty());

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn claude_snapshots_preserve_digest_text_and_tool_linkage() {
        let root = std::env::temp_dir().join(format!(
            "pimux-transcript-claude-{}-{}",
            std::process::id(),
            Utc::now().timestamp_nanos_opt().unwrap_or_default()
        ));
        fs::create_dir_all(&root).unwrap();
        let path = root.join("session.jsonl");
        fs::write(
            &path,
            [
                r#"{"type":"user","uuid":"user-1","parentUuid":null,"sessionId":"session-1","timestamp":"2026-04-08T00:00:01.000Z","cwd":"/tmp/project","isSidechain":false,"message":{"role":"user","content":"Implement the digest feature"}}"#,
                r#"{"type":"user","uuid":"alternate","parentUuid":"user-1","sessionId":"session-1","timestamp":"2026-04-08T00:00:02.000Z","cwd":"/tmp/project","isSidechain":false,"message":{"role":"user","content":"This branch should be excluded"}}"#,
                r#"{"type":"assistant","uuid":"assistant-thinking","parentUuid":"user-1","sessionId":"session-1","timestamp":"2026-04-08T00:00:03.000Z","cwd":"/tmp/project","isSidechain":false,"message":{"role":"assistant","content":[{"type":"thinking","thinking":"Inspecting the report flow"}]}}"#,
                r#"{"type":"assistant","uuid":"assistant-tool","parentUuid":"assistant-thinking","sessionId":"session-1","timestamp":"2026-04-08T00:00:04.000Z","cwd":"/tmp/project","isSidechain":false,"message":{"role":"assistant","content":[{"type":"tool_use","id":"tool-1","name":"Bash","input":{"command":"pwd"}}]}}"#,
                r#"{"type":"user","uuid":"tool-result","parentUuid":"assistant-tool","sessionId":"session-1","timestamp":"2026-04-08T00:00:05.000Z","cwd":"/tmp/project","isSidechain":false,"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tool-1","content":"/tmp/project"}]}}"#,
                r#"{"type":"assistant","uuid":"assistant-text","parentUuid":"tool-result","sessionId":"session-1","timestamp":"2026-04-08T00:00:06.000Z","cwd":"/tmp/project","isSidechain":false,"message":{"role":"assistant","content":[{"type":"text","text":"Implemented and verified the digest feature."}]}}"#,
                r#"{"type":"user","uuid":"meta","parentUuid":"assistant-text","sessionId":"session-1","timestamp":"2026-04-08T00:00:07.000Z","cwd":"/tmp/project","isMeta":true,"isSidechain":false,"message":{"role":"user","content":"local command metadata"}}"#,
            ]
            .join("\n"),
        )
        .unwrap();

        let discovered_session = DiscoveredSession {
            source: SessionSource::Claude,
            session_file: path,
            fingerprint: SessionFingerprint {
                file_size: 1,
                modified_at_millis: 1,
            },
            id: "claude:session-1".to_string(),
            explicit_summary: Some("Digest work".to_string()),
            heuristic_summary: "Implement the digest feature".to_string(),
            summary_input: None,
            created_at: Utc::now(),
            updated_at: Utc::now(),
            last_user_message_at: Utc::now(),
            last_assistant_message_at: Utc::now(),
            cwd: "/tmp/project".to_string(),
            model: "anthropic/claude-sonnet-4-6".to_string(),
            context_usage: None,
            supports_images: None,
        };

        let snapshot = build_persisted_snapshot(&discovered_session).unwrap();
        assert_eq!(snapshot.session_id, "claude:session-1");
        assert_eq!(
            snapshot.freshness.state,
            TranscriptFreshnessState::Persisted
        );
        assert!(snapshot.warnings.is_empty());
        assert_eq!(snapshot.messages.len(), 5);
        assert_eq!(snapshot.messages[0].role, Role::User);
        assert_eq!(snapshot.messages[0].body, "Implement the digest feature");
        assert_eq!(
            snapshot.messages[1].blocks[0].kind,
            MessageContentBlockKind::Thinking
        );
        assert_eq!(
            snapshot.messages[2].blocks[0].kind,
            MessageContentBlockKind::ToolCall
        );
        assert_eq!(
            snapshot.messages[2].blocks[0].tool_call_id.as_deref(),
            Some("tool-1")
        );
        assert_eq!(snapshot.messages[3].role, Role::ToolResult);
        assert_eq!(snapshot.messages[3].tool_name.as_deref(), Some("Bash"));
        assert_eq!(snapshot.messages[3].tool_call_id.as_deref(), Some("tool-1"));
        assert_eq!(snapshot.messages[4].role, Role::Assistant);
        assert_eq!(
            snapshot.messages[4].body,
            "Implemented and verified the digest feature."
        );
        assert!(snapshot.messages.iter().all(
            |message| !message.body.contains("excluded") && !message.body.contains("metadata")
        ));

        let _ = fs::remove_dir_all(root);
    }
}
