use std::path::PathBuf;

use clap::{Args, Parser, Subcommand};

use crate::host::HostAuth;

mod agent;
mod channel;
mod host;
mod message;
mod report;
mod self_update;
mod server;
mod session;
mod transcript;

#[derive(Debug, Parser)]
#[command(name = "pimux")]
#[command(about = "pimux server and agent")]
#[command(version)]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Debug, Subcommand)]
enum Commands {
    /// Start the server or manage the server service
    Server {
        #[command(subcommand)]
        command: Option<ServerCommand>,
    },
    /// Agent commands
    Agent {
        #[command(subcommand)]
        command: AgentCommand,
    },
    /// Restart installed managed services
    Restart(RestartArgs),
    /// List the local sessions the agent would discover
    List {
        /// Override pi's agent directory (defaults to PI_CODING_AGENT_DIR or ~/.pi/agent)
        #[arg(long, env = "PI_CODING_AGENT_DIR")]
        pi_agent_dir: Option<PathBuf>,
        /// Model to use when generating session titles via pi
        #[arg(long, env = "PIMUX_SUMMARY_MODEL", default_value = agent::DEFAULT_SUMMARY_MODEL)]
        summary_model: String,
        /// Filter sessions to a local calendar day in the system timezone, for example 2026-03-27
        #[arg(long)]
        date: Option<String>,
    },
    /// Install the pimux live extension into pi's auto-discovered extensions directory
    InstallExtension {
        /// Override pi's agent directory (defaults to PI_CODING_AGENT_DIR or ~/.pi/agent)
        #[arg(long, env = "PI_CODING_AGENT_DIR")]
        pi_agent_dir: Option<PathBuf>,
        /// Overwrite an existing extension file if its contents differ
        #[arg(long)]
        force: bool,
    },
    /// Update this binary from the latest GitHub release
    Update(UpdateArgs),
}

#[derive(Debug, Subcommand)]
enum ServerCommand {
    /// Install the server as a per-user background service and start it
    Install(ServerInstallArgs),
    /// Uninstall the per-user background service
    Uninstall,
}

#[derive(Debug, Subcommand)]
enum AgentCommand {
    /// Run the agent in the foreground
    Run(AgentRunArgs),
    /// Install the agent as a per-user background service and install the live extension
    Install(AgentInstallArgs),
    /// Uninstall the per-user background service
    Uninstall,
    /// Show the current service status
    Status(AgentStatusArgs),
    /// Show recent service logs
    Logs(AgentLogsArgs),
}

#[derive(Debug, Args)]
struct ServerInstallArgs {
    /// Port for the installed server service. Defaults to 3000 unless PORT is already set.
    #[arg(long, env = "PORT")]
    port: Option<u16>,
}

#[derive(Debug, Args, Clone)]
struct AgentRunArgs {
    /// Base URL of the pimux server, for example http://localhost:3000. If the scheme is omitted, http:// is assumed.
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
}

#[derive(Debug, Args)]
struct AgentInstallArgs {
    #[command(flatten)]
    agent: AgentRunArgs,
    /// Overwrite an existing bundled pimux live extension if its contents differ
    #[arg(long)]
    force_extension: bool,
}

#[derive(Debug, Args)]
struct AgentStatusArgs {
    /// Override pi's agent directory when checking extension/socket paths
    #[arg(long, env = "PI_CODING_AGENT_DIR")]
    pi_agent_dir: Option<PathBuf>,
}

#[derive(Debug, Args)]
struct AgentLogsArgs {
    /// Number of recent lines to show
    #[arg(long, default_value_t = 100)]
    lines: usize,
    /// Follow logs continuously
    #[arg(long)]
    follow: bool,
}

#[derive(Debug, Args)]
struct RestartArgs {
    /// Restart the installed server service
    #[arg(long)]
    server: bool,
    /// Restart the installed agent service
    #[arg(long)]
    agent: bool,
}

#[derive(Debug, Args)]
struct UpdateArgs {
    /// Only check whether a newer GitHub release is available
    #[arg(long)]
    check: bool,
    /// Reinstall the latest release even if this version already matches
    #[arg(long)]
    force: bool,
}

impl AgentRunArgs {
    fn into_config(self) -> Result<agent::Config, Box<dyn std::error::Error + Send + Sync>> {
        let normalized = agent::normalize_server_url(&self.server_url)?;
        if normalized.inferred_http {
            eprintln!(
                "assuming http:// for server URL `{}` -> {}",
                self.server_url, normalized.url
            );
        }

        Ok(agent::Config {
            server_url: normalized.url,
            location: self.location,
            auth: self.auth,
            pi_agent_dir: self.pi_agent_dir,
            summary_model: self.summary_model,
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct RestartTargets {
    server: bool,
    agent: bool,
}

fn restart_targets(args: &RestartArgs) -> RestartTargets {
    if !args.server && !args.agent {
        return RestartTargets {
            server: true,
            agent: true,
        };
    }

    RestartTargets {
        server: args.server,
        agent: args.agent,
    }
}

fn restart_requested_services(
    args: RestartArgs,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let targets = restart_targets(&args);
    let mut failures = Vec::new();

    if targets.server {
        match server::restart_service_if_installed() {
            Ok(Some(kind)) => println!("restarted server service via {kind}"),
            Ok(None) => println!("server service is not installed"),
            Err(error) => failures.push(format!("server: {error}")),
        }
    }

    if targets.agent {
        match agent::restart_service_if_installed() {
            Ok(Some(kind)) => println!("restarted agent service via {kind}"),
            Ok(None) => println!("agent service is not installed"),
            Err(error) => failures.push(format!("agent: {error}")),
        }
    }

    if failures.is_empty() {
        Ok(())
    } else {
        Err(failures.join("\n").into())
    }
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let cli = Cli::parse();

    match cli.command {
        Commands::Server { command } => match command {
            None => server::start().await?,
            Some(ServerCommand::Install(args)) => {
                let result = server::install_service(server::ServiceConfig { port: args.port })?;
                println!(
                    "installed {} server service at {}",
                    result.kind,
                    result.path.display()
                );
            }
            Some(ServerCommand::Uninstall) => {
                let result = server::uninstall_service()?;
                if result.removed {
                    println!(
                        "uninstalled {} server service from {}",
                        result.kind,
                        result.path.display()
                    );
                } else {
                    println!(
                        "no {} server service file found at {}",
                        result.kind,
                        result.path.display()
                    );
                }
            }
        },
        Commands::Agent { command } => match command {
            AgentCommand::Run(args) => {
                agent::start(args.into_config()?).await?;
            }
            AgentCommand::Install(args) => {
                let extension_path = agent::install_extension(
                    args.agent.pi_agent_dir.clone(),
                    args.force_extension,
                )?;
                let result = agent::install_service(args.agent.into_config()?)?;
                println!(
                    "installed {} agent service at {}",
                    result.kind,
                    result.path.display()
                );
                println!(
                    "installed pimux live extension to {}",
                    extension_path.display()
                );
            }
            AgentCommand::Uninstall => {
                let result = agent::uninstall_service()?;
                if result.removed {
                    println!(
                        "uninstalled {} agent service from {}",
                        result.kind,
                        result.path.display()
                    );
                } else {
                    println!(
                        "no {} agent service file found at {}",
                        result.kind,
                        result.path.display()
                    );
                }
            }
            AgentCommand::Status(args) => {
                print!("{}", agent::service_status(args.pi_agent_dir)?);
            }
            AgentCommand::Logs(args) => {
                agent::service_logs(args.lines, args.follow)?;
            }
        },
        Commands::Restart(args) => {
            restart_requested_services(args)?;
        }
        Commands::List {
            pi_agent_dir,
            summary_model,
            date,
        } => {
            agent::list(agent::ListConfig {
                pi_agent_dir,
                summary_model,
                date,
            })
            .await?
        }
        Commands::InstallExtension {
            pi_agent_dir,
            force,
        } => {
            let path = agent::install_extension(pi_agent_dir, force)?;
            println!("installed pimux live extension to {}", path.display());
        }
        Commands::Update(args) => {
            self_update::run(self_update::Options {
                check: args.check,
                force: args.force,
            })
            .await?;
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{RestartArgs, RestartTargets, restart_targets};

    #[test]
    fn restart_defaults_to_both_services() {
        let targets = restart_targets(&RestartArgs {
            server: false,
            agent: false,
        });

        assert_eq!(
            targets,
            RestartTargets {
                server: true,
                agent: true,
            }
        );
    }

    #[test]
    fn restart_can_target_only_server() {
        let targets = restart_targets(&RestartArgs {
            server: true,
            agent: false,
        });

        assert_eq!(
            targets,
            RestartTargets {
                server: true,
                agent: false,
            }
        );
    }

    #[test]
    fn restart_can_target_only_agent() {
        let targets = restart_targets(&RestartArgs {
            server: false,
            agent: true,
        });

        assert_eq!(
            targets,
            RestartTargets {
                server: false,
                agent: true,
            }
        );
    }
}
