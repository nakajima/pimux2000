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
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mime_type: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Message {
    pub created_at: DateTime<Utc>,
    pub role: Role,
    pub body: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub blocks: Vec<MessageContentBlock>,
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
    pub mime_type: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub attachment_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ApiMessage {
    pub created_at: DateTime<Utc>,
    pub role: Role,
    pub body: String,
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

        Some(Self {
            created_at,
            role,
            body: body_from_blocks(role, &blocks),
            blocks,
        })
    }

    pub fn to_api(&self) -> ApiMessage {
        ApiMessage {
            created_at: self.created_at,
            role: self.role,
            body: self.body.clone(),
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
            mime_type: None,
            data: None,
        })
    }

    pub fn thinking(text: impl AsRef<str>) -> Option<Self> {
        normalized_display_text(text.as_ref()).map(|text| Self {
            kind: MessageContentBlockKind::Thinking,
            text: Some(text),
            tool_call_name: None,
            mime_type: None,
            data: None,
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
            mime_type: None,
            data: None,
        })
    }

    pub fn image(mime_type: Option<&str>, data: Option<&str>) -> Self {
        Self {
            kind: MessageContentBlockKind::Image,
            text: None,
            tool_call_name: None,
            mime_type: mime_type.and_then(normalize_mime_type),
            data: data.and_then(normalize_image_data),
        }
    }

    pub fn attachment_id(&self) -> Option<String> {
        let mime_type = self.mime_type.as_deref()?;
        let data = self.data.as_deref()?;
        Some(image_attachment_id(mime_type, data))
    }
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
            mime_type: block.mime_type.clone(),
            attachment_id,
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
            block.mime_type = None;
            block.data = None;
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
            block.mime_type = None;
            block.data = None;
        }
        MessageContentBlockKind::Image => {
            block.text = None;
            block.tool_call_name = None;
            block.mime_type = block.mime_type.as_deref().and_then(normalize_mime_type);
            block.data = block.data.as_deref().and_then(normalize_image_data);
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
        normalize_image_data, normalize_mime_type,
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
}
