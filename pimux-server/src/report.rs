use serde::{Deserialize, Serialize};

use crate::{host::HostIdentity, session::ActiveSession};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReportPayload {
    pub host: HostIdentity,
    #[serde(rename = "active_sessions")]
    pub active_sessions: Vec<ActiveSession>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct VersionResponse {
    pub version: String,
}
