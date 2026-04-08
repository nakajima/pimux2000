use std::{
    collections::VecDeque,
    env,
    fmt::Write as _,
    fs::{self, OpenOptions},
    io::{BufRead, BufReader},
    path::{Path, PathBuf},
    process::{Command, Stdio},
};

use crate::host::HostAuth;

use super::{Config, discovery, extension, live};

type BoxError = Box<dyn std::error::Error + Send + Sync>;
const SYSTEMD_UNIT_NAME: &str = "pimux-agent.service";
const LAUNCH_AGENT_LABEL: &str = "dev.pimux.agent";
const LAUNCH_AGENT_FILE_NAME: &str = "dev.pimux.agent.plist";
const DEFAULT_LOG_LINES: usize = 100;

pub struct InstallResult {
    pub kind: &'static str,
    pub path: PathBuf,
}

pub struct UninstallResult {
    pub kind: &'static str,
    pub path: PathBuf,
    pub removed: bool,
}

pub fn install(config: Config) -> Result<InstallResult, BoxError> {
    match env::consts::OS {
        "linux" => install_systemd_user_service(&config),
        "macos" => install_launch_agent(&config),
        other => Err(format!("agent service install is not supported on {other}").into()),
    }
}

pub fn uninstall() -> Result<UninstallResult, BoxError> {
    match env::consts::OS {
        "linux" => uninstall_systemd_user_service(),
        "macos" => uninstall_launch_agent(),
        other => Err(format!("agent service uninstall is not supported on {other}").into()),
    }
}

pub fn status(pi_agent_dir: Option<PathBuf>) -> Result<String, BoxError> {
    let pi_agent_dir = discovery::resolve_pi_agent_dir(pi_agent_dir)?;
    match env::consts::OS {
        "linux" => systemd_user_status(&pi_agent_dir),
        "macos" => launch_agent_status(&pi_agent_dir),
        other => Err(format!("agent service status is not supported on {other}").into()),
    }
}

pub fn logs(lines: usize, follow: bool) -> Result<(), BoxError> {
    let lines = lines.max(1);
    match env::consts::OS {
        "linux" => show_systemd_logs(lines, follow),
        "macos" => show_launch_agent_logs(lines, follow),
        other => Err(format!("agent service logs are not supported on {other}").into()),
    }
}

pub fn restart_if_installed() -> Result<Option<&'static str>, BoxError> {
    match env::consts::OS {
        "linux" => restart_systemd_user_service_if_installed(),
        "macos" => restart_launch_agent_if_installed(),
        other => Err(format!("agent service restart is not supported on {other}").into()),
    }
}

fn install_systemd_user_service(config: &Config) -> Result<InstallResult, BoxError> {
    let unit_path = systemd_unit_path()?;
    let executable = current_executable()?;
    let args = agent_run_args(config);
    let path_env = env::var("PATH").ok();
    let unit = render_systemd_unit(&executable, &args, path_env.as_deref());

    write_file(&unit_path, &unit)?;
    run_command("systemctl", &["--user", "daemon-reload"])?;
    run_command(
        "systemctl",
        &["--user", "enable", "--now", SYSTEMD_UNIT_NAME],
    )?;
    run_command("systemctl", &["--user", "restart", SYSTEMD_UNIT_NAME])?;

    Ok(InstallResult {
        kind: "systemd --user",
        path: unit_path,
    })
}

fn uninstall_systemd_user_service() -> Result<UninstallResult, BoxError> {
    let unit_path = systemd_unit_path()?;

    let _ = run_command(
        "systemctl",
        &["--user", "disable", "--now", SYSTEMD_UNIT_NAME],
    );

    let removed = remove_file_if_exists(&unit_path)?;
    let _ = run_command("systemctl", &["--user", "daemon-reload"]);

    Ok(UninstallResult {
        kind: "systemd --user",
        path: unit_path,
        removed,
    })
}

fn restart_systemd_user_service_if_installed() -> Result<Option<&'static str>, BoxError> {
    let unit_path = systemd_unit_path()?;
    if !unit_path.exists() {
        return Ok(None);
    }

    run_command("systemctl", &["--user", "daemon-reload"])?;
    run_command("systemctl", &["--user", "restart", SYSTEMD_UNIT_NAME])?;
    Ok(Some("systemd --user"))
}

fn install_launch_agent(config: &Config) -> Result<InstallResult, BoxError> {
    let plist_path = launch_agent_path()?;
    let executable = current_executable()?;
    let args = agent_run_args(config);
    let path_env = env::var("PATH").ok();
    let stdout_log = launch_agent_log_path("out")?;
    let stderr_log = launch_agent_log_path("err")?;
    let plist = render_launch_agent_plist(
        &executable,
        &args,
        path_env.as_deref(),
        &stdout_log,
        &stderr_log,
    );

    touch_file(&stdout_log)?;
    touch_file(&stderr_log)?;
    write_file(&plist_path, &plist)?;

    let domain = launchctl_domain()?;
    let _ = run_command(
        "launchctl",
        &["bootout", &format!("{domain}/{LAUNCH_AGENT_LABEL}")],
    );
    run_command(
        "launchctl",
        &["bootstrap", &domain, &plist_path.display().to_string()],
    )?;
    run_command(
        "launchctl",
        &["kickstart", "-k", &format!("{domain}/{LAUNCH_AGENT_LABEL}")],
    )?;

    Ok(InstallResult {
        kind: "launchctl",
        path: plist_path,
    })
}

fn uninstall_launch_agent() -> Result<UninstallResult, BoxError> {
    let plist_path = launch_agent_path()?;
    let domain = launchctl_domain()?;

    let _ = run_command(
        "launchctl",
        &["bootout", &format!("{domain}/{LAUNCH_AGENT_LABEL}")],
    );
    let removed = remove_file_if_exists(&plist_path)?;

    Ok(UninstallResult {
        kind: "launchctl",
        path: plist_path,
        removed,
    })
}

fn restart_launch_agent_if_installed() -> Result<Option<&'static str>, BoxError> {
    let plist_path = launch_agent_path()?;
    if !plist_path.exists() {
        return Ok(None);
    }

    let domain = launchctl_domain()?;
    let label = format!("{domain}/{LAUNCH_AGENT_LABEL}");
    if command_succeeds("launchctl", &["print", &label]) {
        run_command("launchctl", &["kickstart", "-k", &label])?;
    } else {
        run_command(
            "launchctl",
            &["bootstrap", &domain, &plist_path.display().to_string()],
        )?;
        run_command("launchctl", &["kickstart", "-k", &label])?;
    }

    Ok(Some("launchctl"))
}

fn systemd_user_status(pi_agent_dir: &Path) -> Result<String, BoxError> {
    let unit_path = systemd_unit_path()?;
    let extension_status = extension::status(Some(pi_agent_dir.to_path_buf()))?;
    let socket_path = live::socket_path(pi_agent_dir);
    let enabled = command_summary("systemctl", &["--user", "is-enabled", SYSTEMD_UNIT_NAME]);
    let active = command_summary("systemctl", &["--user", "is-active", SYSTEMD_UNIT_NAME]);

    let mut output = String::new();
    writeln!(output, "service manager: systemd --user")?;
    writeln!(output, "agent version: {}", env!("CARGO_PKG_VERSION"))?;
    writeln!(
        output,
        "unit file: {} ({})",
        unit_path.display(),
        file_state(&unit_path)
    )?;
    writeln!(output, "enabled: {enabled}")?;
    writeln!(output, "active: {active}")?;
    writeln!(
        output,
        "extension: {} ({})",
        extension_status.path.display(),
        extension_status.state
    )?;
    writeln!(output, "live socket: {}", socket_path.display())?;
    writeln!(
        output,
        "logs: journalctl --user-unit {} -n {} --no-pager",
        SYSTEMD_UNIT_NAME, DEFAULT_LOG_LINES
    )?;

    Ok(output)
}

fn launch_agent_status(pi_agent_dir: &Path) -> Result<String, BoxError> {
    let plist_path = launch_agent_path()?;
    let stdout_log = launch_agent_log_path("out")?;
    let stderr_log = launch_agent_log_path("err")?;
    let extension_status = extension::status(Some(pi_agent_dir.to_path_buf()))?;
    let socket_path = live::socket_path(pi_agent_dir);
    let loaded = match launchctl_domain() {
        Ok(domain) => bool_summary(command_succeeds(
            "launchctl",
            &["print", &format!("{domain}/{LAUNCH_AGENT_LABEL}")],
        )),
        Err(error) => format!("unknown ({error})"),
    };

    let mut output = String::new();
    writeln!(output, "service manager: launchctl")?;
    writeln!(output, "agent version: {}", env!("CARGO_PKG_VERSION"))?;
    writeln!(output, "label: {LAUNCH_AGENT_LABEL}")?;
    writeln!(
        output,
        "plist: {} ({})",
        plist_path.display(),
        file_state(&plist_path)
    )?;
    writeln!(output, "loaded: {loaded}")?;
    writeln!(
        output,
        "stdout log: {} ({})",
        stdout_log.display(),
        file_state(&stdout_log)
    )?;
    writeln!(
        output,
        "stderr log: {} ({})",
        stderr_log.display(),
        file_state(&stderr_log)
    )?;
    writeln!(
        output,
        "extension: {} ({})",
        extension_status.path.display(),
        extension_status.state
    )?;
    writeln!(output, "live socket: {}", socket_path.display())?;

    Ok(output)
}

fn show_systemd_logs(lines: usize, follow: bool) -> Result<(), BoxError> {
    let lines = lines.to_string();
    let mut command = Command::new("journalctl");
    command.args([
        "--user-unit",
        SYSTEMD_UNIT_NAME,
        "-n",
        lines.as_str(),
        "--no-pager",
    ]);
    if follow {
        command.arg("-f");
    }

    run_interactive(command, "journalctl")
}

fn show_launch_agent_logs(lines: usize, follow: bool) -> Result<(), BoxError> {
    let stdout_log = launch_agent_log_path("out")?;
    let stderr_log = launch_agent_log_path("err")?;

    if follow {
        touch_file(&stdout_log)?;
        touch_file(&stderr_log)?;
        let lines = lines.to_string();
        let mut command = Command::new("tail");
        command
            .arg("-n")
            .arg(lines)
            .arg("-f")
            .arg(&stdout_log)
            .arg(&stderr_log);
        return run_interactive(command, "tail");
    }

    print_log_tail("stdout", &stdout_log, lines)?;
    println!();
    print_log_tail("stderr", &stderr_log, lines)?;
    Ok(())
}

fn print_log_tail(label: &str, path: &Path, lines: usize) -> Result<(), BoxError> {
    println!("==> {} ({}) <==", label, path.display());

    if !path.exists() {
        println!("(missing)");
        return Ok(());
    }

    let file = fs::File::open(path)?;
    let reader = BufReader::new(file);
    let mut buffer = VecDeque::with_capacity(lines.max(1));

    for line in reader.lines() {
        let line = line?;
        if buffer.len() == lines {
            buffer.pop_front();
        }
        buffer.push_back(line);
    }

    if buffer.is_empty() {
        println!("(empty)");
    } else {
        for line in buffer {
            println!("{line}");
        }
    }

    Ok(())
}

fn run_interactive(mut command: Command, name: &str) -> Result<(), BoxError> {
    let status = command
        .stdin(Stdio::inherit())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit())
        .status()?;

    if status.success() {
        Ok(())
    } else {
        Err(format!("{name} exited with status {status}").into())
    }
}

fn agent_run_args(config: &Config) -> Vec<String> {
    let mut args = vec![
        "agent".to_string(),
        "run".to_string(),
        config.server_url.clone(),
        "--auth".to_string(),
        host_auth_arg(config.auth).to_string(),
        "--summary-model".to_string(),
        config.summary_model.clone(),
    ];

    if let Some(location) = &config.location {
        args.push("--location".to_string());
        args.push(location.clone());
    }

    if let Some(pi_agent_dir) = &config.pi_agent_dir {
        args.push("--pi-agent-dir".to_string());
        args.push(absolutize_path(pi_agent_dir).display().to_string());
    }

    args
}

fn host_auth_arg(auth: HostAuth) -> &'static str {
    match auth {
        HostAuth::None => "none",
        HostAuth::Pk => "pk",
    }
}

fn current_executable() -> Result<PathBuf, BoxError> {
    Ok(env::current_exe()?)
}

fn systemd_unit_path() -> Result<PathBuf, BoxError> {
    Ok(home_dir()?
        .join(".config")
        .join("systemd")
        .join("user")
        .join(SYSTEMD_UNIT_NAME))
}

fn launch_agent_path() -> Result<PathBuf, BoxError> {
    Ok(home_dir()?
        .join("Library")
        .join("LaunchAgents")
        .join(LAUNCH_AGENT_FILE_NAME))
}

fn launch_agent_log_path(suffix: &str) -> Result<PathBuf, BoxError> {
    Ok(home_dir()?
        .join("Library")
        .join("Logs")
        .join(format!("pimux-agent.{suffix}.log")))
}

fn launchctl_domain() -> Result<String, BoxError> {
    let uid = env::var("SUDO_UID")
        .ok()
        .filter(|v| !v.is_empty())
        .unwrap_or_else(|| run_command("id", &["-u"]).unwrap_or_default());
    Ok(format!("gui/{}", uid.trim()))
}

fn home_dir() -> Result<PathBuf, BoxError> {
    Ok(PathBuf::from(env::var("HOME")?))
}

fn write_file(path: &Path, contents: &str) -> Result<(), BoxError> {
    ensure_parent_dir(path)?;
    fs::write(path, contents)?;
    Ok(())
}

fn touch_file(path: &Path) -> Result<(), BoxError> {
    ensure_parent_dir(path)?;
    OpenOptions::new().create(true).append(true).open(path)?;
    Ok(())
}

fn ensure_parent_dir(path: &Path) -> Result<(), BoxError> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }

    Ok(())
}

fn remove_file_if_exists(path: &Path) -> Result<bool, BoxError> {
    if path.exists() {
        fs::remove_file(path)?;
        Ok(true)
    } else {
        Ok(false)
    }
}

fn absolutize_path(path: &Path) -> PathBuf {
    if path.is_absolute() {
        path.to_path_buf()
    } else {
        env::current_dir()
            .unwrap_or_else(|_| PathBuf::from("."))
            .join(path)
    }
}

fn render_systemd_unit(executable: &Path, args: &[String], path_env: Option<&str>) -> String {
    let exec_start = std::iter::once(executable.display().to_string())
        .chain(args.iter().cloned())
        .map(|arg| quote_systemd_arg(&arg))
        .collect::<Vec<_>>()
        .join(" ");

    let mut lines = vec![
        "[Unit]".to_string(),
        "Description=pimux agent".to_string(),
        String::new(),
        "[Service]".to_string(),
        "Type=simple".to_string(),
        format!("ExecStart={exec_start}"),
        "Restart=always".to_string(),
        "RestartSec=2".to_string(),
    ];

    if let Some(path_env) = path_env {
        lines.push(format!(
            "Environment=PATH={}",
            quote_systemd_env_value(path_env)
        ));
    }

    lines.push(String::new());
    lines.push("[Install]".to_string());
    lines.push("WantedBy=default.target".to_string());
    lines.push(String::new());

    lines.join("\n")
}

fn render_launch_agent_plist(
    executable: &Path,
    args: &[String],
    path_env: Option<&str>,
    stdout_log: &Path,
    stderr_log: &Path,
) -> String {
    let mut program_args = Vec::new();
    program_args.push(plist_string(&executable.display().to_string()));
    for arg in args {
        program_args.push(plist_string(arg));
    }

    let mut environment = String::new();
    if let Some(path_env) = path_env {
        environment.push_str("\n\t<key>EnvironmentVariables</key>\n\t<dict>");
        environment.push_str("\n\t\t<key>PATH</key>");
        environment.push_str(&format!("\n\t\t{}", plist_string(path_env)));
        environment.push_str("\n\t</dict>");
    }

    format!(
        concat!(
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n",
            "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n",
            "<plist version=\"1.0\">\n",
            "<dict>\n",
            "\t<key>Label</key>\n",
            "\t<string>{label}</string>\n",
            "\t<key>ProgramArguments</key>\n",
            "\t<array>\n",
            "{program_args}\n",
            "\t</array>{environment}\n",
            "\t<key>RunAtLoad</key>\n",
            "\t<true/>\n",
            "\t<key>KeepAlive</key>\n",
            "\t<true/>\n",
            "\t<key>StandardOutPath</key>\n",
            "\t<string>{stdout_log}</string>\n",
            "\t<key>StandardErrorPath</key>\n",
            "\t<string>{stderr_log}</string>\n",
            "</dict>\n",
            "</plist>\n"
        ),
        label = xml_escape(LAUNCH_AGENT_LABEL),
        program_args = program_args.join("\n"),
        environment = environment,
        stdout_log = xml_escape(&stdout_log.display().to_string()),
        stderr_log = xml_escape(&stderr_log.display().to_string()),
    )
}

fn quote_systemd_arg(value: &str) -> String {
    format!(
        "\"{}\"",
        value
            .replace('%', "%%")
            .replace('\\', "\\\\")
            .replace('"', "\\\"")
    )
}

fn quote_systemd_env_value(value: &str) -> String {
    quote_systemd_arg(value)
}

fn plist_string(value: &str) -> String {
    format!("\t\t<string>{}</string>", xml_escape(value))
}

fn xml_escape(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&apos;")
}

fn file_state(path: &Path) -> &'static str {
    if path.exists() { "present" } else { "missing" }
}

fn bool_summary(value: bool) -> String {
    if value {
        "yes".to_string()
    } else {
        "no".to_string()
    }
}

fn command_summary(command: &str, args: &[&str]) -> String {
    match Command::new(command).args(args).output() {
        Ok(output) => command_output_summary(output.stdout, output.stderr),
        Err(error) => format!("unavailable ({error})"),
    }
}

fn command_succeeds(command: &str, args: &[&str]) -> bool {
    Command::new(command)
        .args(args)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|status| status.success())
        .unwrap_or(false)
}

fn command_output_summary(stdout: Vec<u8>, stderr: Vec<u8>) -> String {
    let stdout = String::from_utf8_lossy(&stdout).trim().to_string();
    let stderr = String::from_utf8_lossy(&stderr).trim().to_string();

    if !stdout.is_empty() {
        stdout
    } else if !stderr.is_empty() {
        stderr
    } else {
        "unknown".to_string()
    }
}

fn run_command(command: &str, args: &[&str]) -> Result<String, BoxError> {
    let output = Command::new(command).args(args).output()?;
    if output.status.success() {
        let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
        return Ok(stdout);
    }

    let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
    let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
    let details = if !stderr.is_empty() {
        stderr
    } else if !stdout.is_empty() {
        stdout
    } else {
        format!("{command} exited with status {}", output.status)
    };

    Err(format!("{command} {}: {details}", args.join(" ")).into())
}

#[cfg(test)]
mod tests {
    use std::path::Path;

    use crate::{agent::DEFAULT_SUMMARY_MODEL, host::HostAuth};

    use super::*;

    fn sample_config() -> Config {
        Config {
            server_url: "http://127.0.0.1:3000".to_string(),
            location: Some("dev@mac".to_string()),
            auth: HostAuth::Pk,
            pi_agent_dir: Some(PathBuf::from("/tmp/pi agent")),
            summary_model: DEFAULT_SUMMARY_MODEL.to_string(),
        }
    }

    #[test]
    fn builds_agent_run_args() {
        let args = agent_run_args(&sample_config());
        assert_eq!(
            args,
            vec![
                "agent",
                "run",
                "http://127.0.0.1:3000",
                "--auth",
                "pk",
                "--summary-model",
                crate::agent::DEFAULT_SUMMARY_MODEL,
                "--location",
                "dev@mac",
                "--pi-agent-dir",
                "/tmp/pi agent",
            ]
        );
    }

    #[test]
    fn renders_systemd_unit() {
        let args = agent_run_args(&sample_config());
        let unit = render_systemd_unit(Path::new("/tmp/pimux"), &args, Some("/usr/bin:/opt/bin"));

        assert!(
            unit.contains("ExecStart=\"/tmp/pimux\" \"agent\" \"run\" \"http://127.0.0.1:3000\"")
        );
        assert!(unit.contains("Environment=PATH=\"/usr/bin:/opt/bin\""));
        assert!(unit.contains("WantedBy=default.target"));
    }

    #[test]
    fn renders_launch_agent_plist() {
        let args = agent_run_args(&sample_config());
        let plist = render_launch_agent_plist(
            Path::new("/tmp/pimux"),
            &args,
            Some("/usr/bin:/opt/bin"),
            Path::new("/tmp/out.log"),
            Path::new("/tmp/err.log"),
        );

        assert!(plist.contains("<string>dev.pimux.agent</string>"));
        assert!(plist.contains("<string>/tmp/pimux</string>"));
        assert!(plist.contains("<string>agent</string>"));
        assert!(plist.contains("<key>EnvironmentVariables</key>"));
        assert!(plist.contains("<string>/tmp/out.log</string>"));
        assert!(plist.contains("<string>/tmp/err.log</string>"));
    }
}
