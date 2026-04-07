use std::collections::HashMap;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use crate::message::{ApiMessage, Message};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionMessagesResponse {
    pub session_id: String,
    pub messages: Vec<Message>,
    pub freshness: TranscriptFreshness,
    pub activity: SessionActivity,
    pub warnings: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ApiSessionMessagesResponse {
    pub session_id: String,
    pub messages: Vec<ApiMessage>,
    pub freshness: TranscriptFreshness,
    pub activity: SessionActivity,
    pub warnings: Vec<String>,
}

impl From<&SessionMessagesResponse> for ApiSessionMessagesResponse {
    fn from(response: &SessionMessagesResponse) -> Self {
        Self {
            session_id: response.session_id.clone(),
            messages: response.messages.iter().map(Message::to_api).collect(),
            freshness: response.freshness.clone(),
            activity: response.activity.clone(),
            warnings: response.warnings.clone(),
        }
    }
}

impl From<SessionMessagesResponse> for ApiSessionMessagesResponse {
    fn from(response: SessionMessagesResponse) -> Self {
        Self::from(&response)
    }
}

impl From<&ApiSessionMessagesResponse> for SessionMessagesResponse {
    fn from(response: &ApiSessionMessagesResponse) -> Self {
        Self {
            session_id: response.session_id.clone(),
            messages: response.messages.iter().map(Message::from).collect(),
            freshness: response.freshness.clone(),
            activity: response.activity.clone(),
            warnings: response.warnings.clone(),
        }
    }
}

impl From<ApiSessionMessagesResponse> for SessionMessagesResponse {
    fn from(response: ApiSessionMessagesResponse) -> Self {
        Self::from(&response)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TranscriptFreshness {
    pub state: TranscriptFreshnessState,
    pub source: TranscriptSource,
    pub as_of: DateTime<Utc>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TranscriptFreshnessState {
    Live,
    Persisted,
    LiveUnknown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TranscriptSource {
    Extension,
    Helper,
    File,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionActivity {
    pub active: bool,
    pub attached: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TranscriptFetchFulfillment {
    pub request_id: String,
    pub host_location: String,
    pub session: Option<SessionMessagesResponse>,
    pub error: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SessionUiWidgetPlacement {
    AboveEditor,
    BelowEditor,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionUiWidget {
    pub key: String,
    pub lines: Vec<String>,
    pub placement: SessionUiWidgetPlacement,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct SessionUiState {
    #[serde(default, skip_serializing_if = "HashMap::is_empty")]
    pub statuses: HashMap<String, String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub widgets: Vec<SessionUiWidget>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub editor_text: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub working_message: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub hidden_thinking_label: Option<String>,
}

impl SessionUiState {
    pub fn is_empty(&self) -> bool {
        self.statuses.is_empty()
            && self.widgets.is_empty()
            && self.title.is_none()
            && self.editor_text.is_none()
            && self.working_message.is_none()
            && self.hidden_thinking_label.is_none()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SessionUiDialogKind {
    Confirm,
    Select,
    Input,
    Editor,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SessionUiDialogMoveDirection {
    Up,
    Down,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionUiDialogState {
    pub id: String,
    pub kind: SessionUiDialogKind,
    pub title: String,
    pub message: String,
    pub options: Vec<String>,
    pub selected_index: usize,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub placeholder: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub value: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum SessionUiDialogAction {
    Move {
        direction: SessionUiDialogMoveDirection,
    },
    SelectIndex {
        index: usize,
    },
    SetValue {
        value: String,
    },
    Submit,
    Cancel,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionUiDialogActionRequest {
    pub dialog_id: String,
    pub action: SessionUiDialogAction,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SessionTerminalOnlyUiKind {
    CustomUi,
    DialogFallback,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionTerminalOnlyUiState {
    pub kind: SessionTerminalOnlyUiKind,
    pub reason: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum SessionStreamEvent {
    Snapshot {
        sequence: u64,
        session: ApiSessionMessagesResponse,
    },
    SessionState {
        sequence: u64,
        connected: bool,
        missing: bool,
        last_seen_at: Option<DateTime<Utc>>,
    },
    UiState {
        sequence: u64,
        state: SessionUiState,
    },
    UiDialogState {
        sequence: u64,
        state: Option<SessionUiDialogState>,
    },
    TerminalOnlyUiState {
        sequence: u64,
        state: Option<SessionTerminalOnlyUiState>,
    },
    Keepalive {
        sequence: u64,
        timestamp: DateTime<Utc>,
    },
}
