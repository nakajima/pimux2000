use serde::{Deserialize, Serialize};

use crate::{
    host::HostIdentity, message::ImageContent, session::ActiveSession,
    transcript::SessionMessagesResponse,
};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum AgentToServerMessage {
    Hello {
        host: HostIdentity,
    },
    HostSnapshot {
        sessions: Vec<ActiveSession>,
    },
    LiveSessionUpdate {
        session: SessionMessagesResponse,
        active_session: Option<ActiveSession>,
    },
    FetchTranscriptResult {
        request_id: String,
        session: Option<SessionMessagesResponse>,
        error: Option<String>,
    },
    SendMessageResult {
        request_id: String,
        error: Option<String>,
    },
    Ping,
    Pong,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum ServerToAgentMessage {
    FetchTranscript {
        request_id: String,
        session_id: String,
    },
    SendMessage {
        request_id: String,
        session_id: String,
        body: String,
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        images: Vec<ImageContent>,
    },
    Ping,
    Pong,
}
