use std::path::PathBuf;

use clap::{Parser, Subcommand};

use crate::host::HostAuth;

mod agent;
mod host;
mod message;
mod report;
mod server;
mod session;

#[derive(Debug, Parser)]
#[command(name = "pimux")]
#[command(about = "pimux server and agent")]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Debug, Subcommand)]
enum Commands {
    /// Start the server
    Server,
    /// Start the agent
    Agent {
        /// Base URL of the pimux server, for example http://localhost:3000
        server_url: String,
        /// Override the reported host location, for example user@host
        #[arg(long, env = "PIMUX_HOST_LOCATION")]
        location: Option<String>,
        /// Override the host auth mode reported to the server
        #[arg(long, env = "PIMUX_HOST_AUTH", value_enum, default_value_t = HostAuth::None)]
        auth: HostAuth,
        /// Override pi's agent directory (defaults to PI_CODING_AGENT_DIR or ~/.pi/agent)
        #[arg(long, env = "PI_CODING_AGENT_DIR")]
        pi_agent_dir: Option<PathBuf>,
        /// Model to use when generating session titles via pi
        #[arg(long, env = "PIMUX_SUMMARY_MODEL", default_value = agent::DEFAULT_SUMMARY_MODEL)]
        summary_model: String,
    },
    /// List the local sessions the agent would discover
    List {
        /// Override pi's agent directory (defaults to PI_CODING_AGENT_DIR or ~/.pi/agent)
        #[arg(long, env = "PI_CODING_AGENT_DIR")]
        pi_agent_dir: Option<PathBuf>,
        /// Model to use when generating session titles via pi
        #[arg(long, env = "PIMUX_SUMMARY_MODEL", default_value = agent::DEFAULT_SUMMARY_MODEL)]
        summary_model: String,
    },
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let cli = Cli::parse();

    match cli.command {
        Commands::Server => server::start().await?,
        Commands::Agent {
            server_url,
            location,
            auth,
            pi_agent_dir,
            summary_model,
        } => {
            agent::start(agent::Config {
                server_url,
                location,
                auth,
                pi_agent_dir,
                summary_model,
            })
            .await?
        }
        Commands::List {
            pi_agent_dir,
            summary_model,
        } => {
            agent::list(agent::ListConfig {
                pi_agent_dir,
                summary_model,
            })
            .await?
        }
    }

    Ok(())
}
