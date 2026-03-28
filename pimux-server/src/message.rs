use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Role {
    User,
    Assistant,
    ToolResult,
    BashExecution,
    Custom,
    BranchSummary,
    CompactionSummary,
    Other,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum MessageContentBlockKind {
    Text,
    Thinking,
    ToolCall,
    Image,
    Other,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MessageContentBlock {
    #[serde(rename = "type")]
    pub kind: MessageContentBlockKind,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_call_name: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Message {
    pub created_at: DateTime<Utc>,
    pub role: Role,
    pub body: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub blocks: Vec<MessageContentBlock>,
}

impl Message {
    pub fn from_text(created_at: DateTime<Utc>, role: Role, text: impl AsRef<str>) -> Option<Self> {
        let block = MessageContentBlock::text(text.as_ref())?;
        Self::from_blocks(created_at, role, vec![block])
    }

    pub fn from_blocks(
        created_at: DateTime<Utc>,
        role: Role,
        blocks: Vec<MessageContentBlock>,
    ) -> Option<Self> {
        let blocks = blocks
            .into_iter()
            .filter_map(normalize_block)
            .collect::<Vec<_>>();
        if blocks.is_empty() {
            return None;
        }

        Some(Self {
            created_at,
            role,
            body: body_from_blocks(role, &blocks),
            blocks,
        })
    }
}

impl MessageContentBlock {
    pub fn text(text: impl AsRef<str>) -> Option<Self> {
        normalized_display_text(text.as_ref()).map(|text| Self {
            kind: MessageContentBlockKind::Text,
            text: Some(text),
            tool_call_name: None,
        })
    }

    pub fn thinking(text: impl AsRef<str>) -> Option<Self> {
        normalized_display_text(text.as_ref()).map(|text| Self {
            kind: MessageContentBlockKind::Thinking,
            text: Some(text),
            tool_call_name: None,
        })
    }

    pub fn tool_call(name: impl AsRef<str>) -> Option<Self> {
        let name = collapse_whitespace(name.as_ref());
        if name.is_empty() {
            return None;
        }

        Some(Self {
            kind: MessageContentBlockKind::ToolCall,
            text: None,
            tool_call_name: Some(name),
        })
    }
}

pub fn normalized_display_text(text: &str) -> Option<String> {
    let normalized = normalize_line_endings(text);
    let trimmed = normalized.trim_matches('\n');
    if trimmed.trim().is_empty() {
        None
    } else {
        Some(trimmed.to_string())
    }
}

pub fn normalize_line_endings(text: &str) -> String {
    text.replace("\r\n", "\n").replace('\r', "\n")
}

pub fn collapse_whitespace(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

pub fn truncate_text(text: &str, max_chars: usize) -> String {
    if text.chars().count() <= max_chars {
        return text.to_string();
    }

    let truncated = text.chars().take(max_chars).collect::<String>();
    format!("{truncated}…")
}

fn normalize_block(mut block: MessageContentBlock) -> Option<MessageContentBlock> {
    match block.kind {
        MessageContentBlockKind::Text
        | MessageContentBlockKind::Thinking
        | MessageContentBlockKind::Other => {
            block.text = block.text.as_deref().and_then(normalized_display_text);
            if block.text.is_none() {
                return None;
            }
            block.tool_call_name = None;
        }
        MessageContentBlockKind::ToolCall => {
            block.tool_call_name = block.tool_call_name.as_deref().map(collapse_whitespace);
            if block
                .tool_call_name
                .as_deref()
                .unwrap_or_default()
                .is_empty()
            {
                return None;
            }
            block.text = None;
        }
        MessageContentBlockKind::Image => {
            block.text = None;
            block.tool_call_name = None;
        }
    }

    Some(block)
}

fn body_from_blocks(role: Role, blocks: &[MessageContentBlock]) -> String {
    let parts = blocks
        .iter()
        .filter_map(|block| match block.kind {
            MessageContentBlockKind::Text => block.text.clone(),
            MessageContentBlockKind::ToolCall if role == Role::Assistant => block
                .tool_call_name
                .as_ref()
                .map(|name| format!("Tool call: {name}")),
            _ => None,
        })
        .collect::<Vec<_>>();

    parts.join("\n\n")
}
