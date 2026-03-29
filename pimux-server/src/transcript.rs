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
    Keepalive {
        sequence: u64,
        timestamp: DateTime<Utc>,
    },
}
