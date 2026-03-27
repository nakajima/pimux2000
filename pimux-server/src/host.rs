use clap::ValueEnum;
use serde::{Deserialize, Serialize};

use crate::session::ActiveSession;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, ValueEnum)]
#[serde(rename_all = "lowercase")]
pub enum HostAuth {
    None,
    Pk,
}

impl Default for HostAuth {
    fn default() -> Self {
        Self::None
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HostIdentity {
    pub location: String,
    pub auth: HostAuth,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HostSessions {
    pub location: String,
    pub sessions: Vec<ActiveSession>,
}
