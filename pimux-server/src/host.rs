use chrono::{DateTime, Utc};
use clap::ValueEnum;
use serde::{Deserialize, Serialize};

use crate::session::ActiveSession;

pub fn normalize_host_location(location: &str) -> String {
    let trimmed = location.trim();
    if trimmed.is_empty() {
        return String::new();
    }

    match trimmed.rsplit_once('@') {
        Some((user, host)) if !user.is_empty() => {
            let normalized_host = normalize_host_label(host);
            if normalized_host.is_empty() {
                trimmed.to_string()
            } else {
                format!("{user}@{normalized_host}")
            }
        }
        _ => {
            let normalized = normalize_host_label(trimmed);
            if normalized.is_empty() {
                trimmed.to_string()
            } else {
                normalized
            }
        }
    }
}

fn normalize_host_label(host: &str) -> String {
    let trimmed = host.trim().trim_end_matches('.');
    if trimmed.is_empty() {
        return String::new();
    }

    if trimmed.len() > ".local".len() && trimmed.to_ascii_lowercase().ends_with(".local") {
        trimmed[..trimmed.len() - ".local".len()].to_string()
    } else {
        trimmed.to_string()
    }
}

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

impl HostIdentity {
    pub fn normalized(&self) -> Self {
        Self {
            location: normalize_host_location(&self.location),
            auth: self.auth,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HostSessions {
    pub location: String,
    pub auth: HostAuth,
    pub connected: bool,
    pub missing: bool,
    pub last_seen_at: Option<DateTime<Utc>>,
    pub sessions: Vec<ActiveSession>,
}

#[cfg(test)]
mod tests {
    use super::{HostAuth, HostIdentity, normalize_host_location};

    #[test]
    fn normalize_host_location_strips_local_suffix() {
        assert_eq!(
            normalize_host_location("nakajima@macstudio.local"),
            "nakajima@macstudio"
        );
    }

    #[test]
    fn normalize_host_location_strips_local_suffix_case_insensitively() {
        assert_eq!(
            normalize_host_location("nakajima@Pats-Mac-Studio.LOCAL"),
            "nakajima@Pats-Mac-Studio"
        );
    }

    #[test]
    fn normalize_host_identity_preserves_auth() {
        let host = HostIdentity {
            location: "nakajima@macstudio.local".to_string(),
            auth: HostAuth::Pk,
        };

        let normalized = host.normalized();
        assert_eq!(normalized.location, "nakajima@macstudio");
        assert_eq!(normalized.auth, HostAuth::Pk);
    }
}
