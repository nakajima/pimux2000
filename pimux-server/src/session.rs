use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ActiveSession {
    pub id: String,
    pub summary: String,
    pub created_at: DateTime<Utc>,
    pub last_user_message_at: DateTime<Utc>,
    pub last_assistant_message_at: DateTime<Utc>,
    pub cwd: String,
    pub model: String,
}
