use chrono::{DateTime, Utc};
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use serde_json::Value;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Role {
    User,
    Assistant,
    ToolResult,
    BashExecution,
    Custom,
    BranchSummary,
    CompactionSummary,
    Other(String),
}

impl Role {
    pub fn from_raw(raw: &str) -> Self {
        match raw {
            "user" => Self::User,
            "assistant" => Self::Assistant,
            "toolResult" => Self::ToolResult,
            "bashExecution" => Self::BashExecution,
            "custom" => Self::Custom,
            "branchSummary" => Self::BranchSummary,
            "compactionSummary" => Self::CompactionSummary,
            other => Self::Other(other.to_string()),
        }
    }

    pub fn raw_value(&self) -> &str {
        match self {
            Self::User => "user",
            Self::Assistant => "assistant",
            Self::ToolResult => "toolResult",
            Self::BashExecution => "bashExecution",
            Self::Custom => "custom",
            Self::BranchSummary => "branchSummary",
            Self::CompactionSummary => "compactionSummary",
            Self::Other(value) => value.as_str(),
        }
    }

    pub fn dedupe_value(&self) -> &str {
        match self {
            Self::Other(_) => "other",
            _ => self.raw_value(),
        }
    }

    pub fn is_assistant(&self) -> bool {
        matches!(self, Self::Assistant)
    }
}

impl Serialize for Role {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        serializer.serialize_str(self.raw_value())
    }
}

impl<'de> Deserialize<'de> for Role {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let raw = String::deserialize(deserializer)?;
        Ok(Self::from_raw(&raw))
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ImageContentKind {
    Image,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ImageContent {
    #[serde(rename = "type")]
    pub kind: ImageContentKind,
    pub data: String,
    pub mime_type: String,
}

impl ImageContent {
    pub fn new(mime_type: impl AsRef<str>, data: impl AsRef<str>) -> Self {
        Self {
            kind: ImageContentKind::Image,
            data: data.as_ref().to_string(),
            mime_type: mime_type.as_ref().to_string(),
        }
    }
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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool_call_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mime_type: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub attachment_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Message {
    pub created_at: DateTime<Utc>,
    pub role: Role,
    pub body: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none", rename = "toolCallId")]
    pub tool_call_id: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub blocks: Vec<MessageContentBlock>,
    #[serde(default, skip_serializing_if = "Option::is_none", rename = "messageId")]
    pub message_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ApiMessageContentBlock {
    #[serde(rename = "type")]
    pub kind: MessageContentBlockKind,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_call_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_call_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mime_type: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub attachment_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ApiMessage {
    #[serde(rename = "messageId", skip_serializing_if = "Option::is_none")]
    pub message_id: Option<String>,
    pub created_at: DateTime<Utc>,
    pub role: Role,
    pub body: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "toolCallId")]
    pub tool_call_id: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub blocks: Vec<ApiMessageContentBlock>,
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

        let body = body_from_blocks(&role, &blocks);

        Some(Self {
            created_at,
            role,
            body,
            tool_name: None,
            tool_call_id: None,
            blocks,
            message_id: None,
        })
    }

    pub fn to_api(&self) -> ApiMessage {
        ApiMessage {
            message_id: self.message_id.clone(),
            created_at: self.created_at,
            role: self.role.clone(),
            body: self.body.clone(),
            tool_name: self.tool_name.clone(),
            tool_call_id: self.tool_call_id.clone(),
            blocks: self
                .blocks
                .iter()
                .map(ApiMessageContentBlock::from)
                .collect(),
        }
    }
}

impl MessageContentBlock {
    pub fn text(text: impl AsRef<str>) -> Option<Self> {
        normalized_display_text(text.as_ref()).map(|text| Self {
            kind: MessageContentBlockKind::Text,
            text: Some(text),
            tool_call_name: None,
            tool_call_id: None,
            mime_type: None,
            data: None,
            attachment_id: None,
        })
    }

    pub fn thinking(text: impl AsRef<str>) -> Option<Self> {
        normalized_display_text(text.as_ref()).map(|text| Self {
            kind: MessageContentBlockKind::Thinking,
            text: Some(text),
            tool_call_name: None,
            tool_call_id: None,
            mime_type: None,
            data: None,
            attachment_id: None,
        })
    }

    pub fn tool_call(name: impl AsRef<str>, text: Option<&str>) -> Option<Self> {
        Self::tool_call_with_id(None, name, text)
    }

    pub fn tool_call_with_id(
        tool_call_id: Option<&str>,
        name: impl AsRef<str>,
        text: Option<&str>,
    ) -> Option<Self> {
        let name = collapse_whitespace(name.as_ref());
        if name.is_empty() {
            return None;
        }

        Some(Self {
            kind: MessageContentBlockKind::ToolCall,
            text: text.and_then(normalized_display_text),
            tool_call_name: Some(name),
            tool_call_id: tool_call_id.and_then(normalized_display_text),
            mime_type: None,
            data: None,
            attachment_id: None,
        })
    }

    pub fn image(mime_type: Option<&str>, data: Option<&str>) -> Self {
        Self {
            kind: MessageContentBlockKind::Image,
            text: None,
            tool_call_name: None,
            tool_call_id: None,
            mime_type: mime_type.and_then(normalize_mime_type),
            data: data.and_then(normalize_image_data),
            attachment_id: None,
        }
    }

    pub fn attachment_id(&self) -> Option<String> {
        if let Some(attachment_id) = self.attachment_id.as_deref()
            && !attachment_id.is_empty()
        {
            return Some(attachment_id.to_string());
        }

        let mime_type = self.mime_type.as_deref()?;
        let data = self.data.as_deref()?;
        Some(image_attachment_id(mime_type, data))
    }
}

pub fn strip_inline_image_data(message: &mut Message) {
    for block in &mut message.blocks {
        if block.kind != MessageContentBlockKind::Image {
            continue;
        }

        block.attachment_id = block.attachment_id();
        block.data = None;
    }
}

pub fn attachment_payload(messages: &[Message], attachment_id: &str) -> Option<(String, String)> {
    messages.iter().find_map(|message| {
        message.blocks.iter().find_map(|block| {
            let mime_type = block.mime_type.as_deref()?;
            let data = block.data.as_deref()?;
            let block_attachment_id = block.attachment_id()?;
            (block_attachment_id == attachment_id)
                .then_some((mime_type.to_string(), data.to_string()))
        })
    })
}

impl From<&MessageContentBlock> for ApiMessageContentBlock {
    fn from(block: &MessageContentBlock) -> Self {
        let attachment_id = match block.kind {
            MessageContentBlockKind::Image => block.attachment_id(),
            _ => None,
        };

        Self {
            kind: block.kind,
            text: block.text.clone(),
            tool_call_name: block.tool_call_name.clone(),
            tool_call_id: block.tool_call_id.clone(),
            mime_type: block.mime_type.clone(),
            attachment_id,
        }
    }
}

impl From<&ApiMessageContentBlock> for MessageContentBlock {
    fn from(block: &ApiMessageContentBlock) -> Self {
        Self {
            kind: block.kind,
            text: block.text.clone(),
            tool_call_name: block.tool_call_name.clone(),
            tool_call_id: block.tool_call_id.clone(),
            mime_type: block.mime_type.clone(),
            data: None,
            attachment_id: block.attachment_id.clone(),
        }
    }
}

impl From<&ApiMessage> for Message {
    fn from(message: &ApiMessage) -> Self {
        Self {
            created_at: message.created_at,
            role: message.role.clone(),
            body: message.body.clone(),
            tool_name: message.tool_name.clone(),
            tool_call_id: message.tool_call_id.clone(),
            blocks: message
                .blocks
                .iter()
                .map(MessageContentBlock::from)
                .collect(),
            message_id: message.message_id.clone(),
        }
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

pub fn normalize_mime_type(value: &str) -> Option<String> {
    let normalized = value.trim().to_ascii_lowercase();
    if normalized.is_empty() {
        None
    } else {
        Some(normalized)
    }
}

pub fn normalize_image_data(value: &str) -> Option<String> {
    let normalized = value
        .chars()
        .filter(|char| !char.is_whitespace())
        .collect::<String>();
    if normalized.is_empty() {
        None
    } else {
        Some(normalized)
    }
}

pub fn image_attachment_id(mime_type: &str, data: &str) -> String {
    const FNV_OFFSET: u64 = 0xcbf29ce484222325;
    const FNV_PRIME: u64 = 0x0000_0100_0000_01b3;

    let mut hash = FNV_OFFSET;
    for byte in mime_type.as_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(FNV_PRIME);
    }
    hash ^= 0xff;
    hash = hash.wrapping_mul(FNV_PRIME);
    for byte in data.as_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(FNV_PRIME);
    }

    format!("img-{hash:016x}")
}

pub fn truncate_text(text: &str, max_chars: usize) -> String {
    if text.chars().count() <= max_chars {
        return text.to_string();
    }

    let truncated = text.chars().take(max_chars).collect::<String>();
    format!("{truncated}…")
}

pub fn tool_call_summary(name: &str, arguments: Option<&Value>) -> Option<String> {
    let arguments = arguments?;

    match name {
        "read" => {
            let path = arguments.get("path").and_then(Value::as_str)?;
            let path = normalized_display_text(path)?;
            let mut summary = path;
            let mut options = Vec::new();
            if let Some(offset) = display_number(arguments.get("offset")) {
                options.push(format!("offset={offset}"));
            }
            if let Some(limit) = display_number(arguments.get("limit")) {
                options.push(format!("limit={limit}"));
            }
            if !options.is_empty() {
                summary.push_str(&format!(" ({})", options.join(", ")));
            }
            Some(summary)
        }
        "bash" => {
            let command = arguments.get("command").and_then(Value::as_str)?;
            let command = normalized_display_text(command)?;
            let mut summary = format!("$ {command}");
            if let Some(timeout) = display_number(arguments.get("timeout")) {
                summary.push_str(&format!("\n\ntimeout: {timeout}s"));
            }
            Some(summary)
        }
        "edit" => {
            let path = arguments.get("path").and_then(Value::as_str)?;
            let path = normalized_display_text(path)?;
            let mut lines = vec![path];
            if let Some(edits) = arguments.get("edits").and_then(Value::as_array) {
                let count = edits.len();
                let label = if count == 1 { "edit" } else { "edits" };
                lines.push(format!("{count} {label}"));
            } else if arguments.get("oldText").is_some() || arguments.get("newText").is_some() {
                lines.push("single replacement".to_string());
            }
            Some(lines.join("\n\n"))
        }
        "write" => {
            let path = arguments.get("path").and_then(Value::as_str)?;
            let path = normalized_display_text(path)?;
            let mut lines = vec![path];
            if let Some(content) = arguments.get("content").and_then(Value::as_str) {
                let line_count = content.lines().count().max(1);
                lines.push(format!("{line_count} lines"));
            }
            Some(lines.join("\n\n"))
        }
        "mcp" => {
            let mut lines = Vec::new();
            for key in ["tool", "server", "connect", "describe", "search", "action"] {
                if let Some(value) = arguments.get(key).and_then(Value::as_str)
                    && let Some(value) = normalized_display_text(value)
                {
                    lines.push(format!("{key}: {value}"));
                }
            }
            if let Some(args) = arguments.get("args")
                && !args.is_null()
            {
                lines.push(format!(
                    "args: {}",
                    truncate_text(&value_to_summary(args), 500)
                ));
            }
            if lines.is_empty() {
                pretty_json_summary(arguments)
            } else {
                Some(lines.join("\n"))
            }
        }
        "multi_tool_use.parallel" => {
            let count = arguments
                .get("tool_uses")
                .and_then(Value::as_array)
                .map(Vec::len)?;
            let label = if count == 1 {
                "tool call"
            } else {
                "tool calls"
            };
            Some(format!("{count} parallel {label}"))
        }
        _ => pretty_json_summary(arguments),
    }
}

fn display_number(value: Option<&Value>) -> Option<String> {
    let value = value?;
    if let Some(number) = value.as_i64() {
        return Some(number.to_string());
    }
    if let Some(number) = value.as_u64() {
        return Some(number.to_string());
    }
    if let Some(number) = value.as_f64() {
        return Some(number.to_string());
    }
    None
}

fn pretty_json_summary(value: &Value) -> Option<String> {
    let pretty = serde_json::to_string_pretty(value).ok()?;
    normalized_display_text(&truncate_text(&pretty, 2_000))
}

fn value_to_summary(value: &Value) -> String {
    match value {
        Value::String(text) => text.clone(),
        _ => serde_json::to_string(value).unwrap_or_else(|_| value.to_string()),
    }
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
            block.tool_call_id = None;
            block.mime_type = None;
            block.data = None;
            block.attachment_id = None;
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
            block.text = block.text.as_deref().and_then(normalized_display_text);
            block.tool_call_id = block.tool_call_id.as_deref().and_then(normalized_display_text);
            block.mime_type = None;
            block.data = None;
            block.attachment_id = None;
        }
        MessageContentBlockKind::Image => {
            block.text = None;
            block.tool_call_name = None;
            block.tool_call_id = None;
            block.mime_type = block.mime_type.as_deref().and_then(normalize_mime_type);
            block.data = block.data.as_deref().and_then(normalize_image_data);
            block.attachment_id = block
                .attachment_id
                .as_deref()
                .and_then(normalized_display_text)
                .or_else(
                    || match (block.mime_type.as_deref(), block.data.as_deref()) {
                        (Some(mime_type), Some(data)) => Some(image_attachment_id(mime_type, data)),
                        _ => None,
                    },
                );
        }
    }

    Some(block)
}

fn body_from_blocks(role: &Role, blocks: &[MessageContentBlock]) -> String {
    let parts = blocks
        .iter()
        .filter_map(|block| match block.kind {
            MessageContentBlockKind::Text => block.text.clone(),
            MessageContentBlockKind::ToolCall if role.is_assistant() => block
                .tool_call_name
                .as_ref()
                .map(|name| format!("Tool call: {name}")),
            _ => None,
        })
        .collect::<Vec<_>>();

    if !parts.is_empty() {
        return parts.join("\n\n");
    }

    let image_count = blocks
        .iter()
        .filter(|block| block.kind == MessageContentBlockKind::Image)
        .count();
    match image_count {
        0 => String::new(),
        1 => "[Image]".to_string(),
        count => format!("[{count} images]"),
    }
}

#[cfg(test)]
mod tests {
    use chrono::Utc;

    use super::{
        Message, MessageContentBlock, MessageContentBlockKind, Role, image_attachment_id,
        normalize_image_data, normalize_mime_type, strip_inline_image_data,
    };

    #[test]
    fn normalizes_image_mime_type() {
        assert_eq!(
            normalize_mime_type(" Image/PNG "),
            Some("image/png".to_string())
        );
        assert_eq!(normalize_mime_type("   "), None);
    }

    #[test]
    fn normalizes_image_data() {
        assert_eq!(
            normalize_image_data(" Zm Fr\nZQ== "),
            Some("ZmFrZQ==".to_string())
        );
        assert_eq!(normalize_image_data(" \n \t "), None);
    }

    #[test]
    fn image_attachment_ids_are_stable() {
        assert_eq!(
            image_attachment_id("image/png", "ZmFrZQ=="),
            image_attachment_id("image/png", "ZmFrZQ==")
        );
        assert_ne!(
            image_attachment_id("image/png", "ZmFrZQ=="),
            image_attachment_id("image/jpeg", "ZmFrZQ==")
        );
    }

    #[test]
    fn image_only_messages_get_body_placeholder() {
        let message = Message::from_blocks(
            Utc::now(),
            Role::User,
            vec![MessageContentBlock::image(
                Some("image/png"),
                Some("ZmFrZQ=="),
            )],
        )
        .unwrap();

        assert_eq!(message.body, "[Image]");
        assert_eq!(message.blocks[0].kind, MessageContentBlockKind::Image);
        assert_eq!(message.blocks[0].mime_type.as_deref(), Some("image/png"));
        assert_eq!(message.blocks[0].data.as_deref(), Some("ZmFrZQ=="));
        assert!(message.blocks[0].attachment_id().is_some());
    }

    #[test]
    fn text_and_image_messages_keep_text_body() {
        let message = Message::from_blocks(
            Utc::now(),
            Role::User,
            vec![
                MessageContentBlock::text("describe this").unwrap(),
                MessageContentBlock::image(Some("image/png"), Some("ZmFrZQ==")),
            ],
        )
        .unwrap();

        assert_eq!(message.body, "describe this");
    }

    #[test]
    fn api_messages_expose_attachment_ids_without_image_data() {
        let message = Message::from_blocks(
            Utc::now(),
            Role::User,
            vec![MessageContentBlock::image(
                Some("image/png"),
                Some("ZmFrZQ=="),
            )],
        )
        .unwrap();

        let api = message.to_api();
        assert_eq!(api.blocks.len(), 1);
        assert_eq!(api.blocks[0].kind, MessageContentBlockKind::Image);
        assert_eq!(api.blocks[0].mime_type.as_deref(), Some("image/png"));
        assert!(api.blocks[0].attachment_id.is_some());
    }

    #[test]
    fn preserves_unknown_role_raw_value_through_json() {
        let role = Role::Other("planning-mode-state".to_string());
        let encoded = serde_json::to_string(&role).unwrap();
        let decoded = serde_json::from_str::<Role>(&encoded).unwrap();

        assert_eq!(encoded, "\"planning-mode-state\"");
        assert_eq!(decoded, role);
        assert_eq!(decoded.raw_value(), "planning-mode-state");
    }

    #[test]
    fn tool_call_blocks_preserve_tool_call_id_for_api() {
        let message = Message::from_blocks(
            Utc::now(),
            Role::Assistant,
            vec![MessageContentBlock::tool_call_with_id(
                Some("call-123"),
                "read",
                Some("foo.txt"),
            )
            .unwrap()],
        )
        .unwrap();

        let api = message.to_api();
        assert_eq!(api.blocks[0].tool_call_id.as_deref(), Some("call-123"));
    }

    #[test]
    fn stripping_inline_image_data_preserves_attachment_id_for_api() {
        let mut message = Message::from_blocks(
            Utc::now(),
            Role::Assistant,
            vec![MessageContentBlock::image(
                Some("image/png"),
                Some("ZmFrZQ=="),
            )],
        )
        .unwrap();
        let expected_attachment_id = message.blocks[0].attachment_id();

        strip_inline_image_data(&mut message);

        assert_eq!(message.blocks[0].data, None);
        assert_eq!(message.blocks[0].attachment_id(), expected_attachment_id);

        let api = message.to_api();
        assert_eq!(api.blocks[0].attachment_id, expected_attachment_id);
    }
}
