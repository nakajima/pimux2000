// Auto-generated: bundled pimux2000 server source files
// These are written to ~/.pimux2000/server/ on the remote host during install

import Foundation

struct ServerFile {
	let path: String
	let content: String
}

enum ServerFiles {
	static let all: [ServerFile] = [
		packageJSON,
		cli,
		index,
		install,
		rpc,
		sessions,
	]

	/// Pi extensions installed to ~/.pi/agent/extensions/ so all sessions register themselves
	static let extensions: [ServerFile] = [
		extReloadCoordinator,
		extActiveSessionRegistry,
		extPimux2000,
	]
}

extension ServerFiles {
	static let packageJSON = ServerFile(
		path: "package.json",
		content: #"""
{
  "name": "pimux2000-server",
  "version": "0.1.0",
  "type": "module",
  "bin": {
    "pimux2000": "./src/cli.ts"
  },
  "scripts": {
    "start": "bun run src/index.ts",
    "dev": "bun --watch run src/index.ts"
  }
}

"""#
	)
}

extension ServerFiles {
	static let cli = ServerFile(
		path: "src/cli.ts",
		content: #"""
#!/usr/bin/env bun

import { installServer, uninstallServer, restartServer } from "./install";

const args = process.argv.slice(2);
const command = args[0];

switch (command) {
  case "install-server": {
    const portArg = args.find((a) => a.startsWith("--port="));
    const port = portArg ? parseInt(portArg.split("=")[1], 10) : 7749;
    installServer(port);
    break;
  }

  case "uninstall-server":
    uninstallServer();
    break;

  case "restart-server":
    restartServer();
    break;

  case "serve": {
    // Run the server directly (foreground)
    await import("./index");
    break;
  }

  default:
    console.log(`pimux2000 - pi session server for iOS

Usage:
  pimux2000 install-server [--port=7749]   Install as launchd/systemd service
  pimux2000 uninstall-server               Remove service
  pimux2000 restart-server                 Restart the running service
  pimux2000 serve                          Run server in foreground
`);
    if (command && command !== "help" && command !== "--help") {
      console.error(`Unknown command: ${command}`);
      process.exit(1);
    }
}

"""#
	)
}

extension ServerFiles {
	static let index = ServerFile(
		path: "src/index.ts",
		content: #"""
import {
  listSessions,
  getMessages,
  getLastAssistantText,
  getState,
  watchRegistry,
  watchSessionFile,
  summarizeMissingSessions,
  type ChangeCallback,
} from "./sessions";
import { sendPrompt } from "./rpc";
import type { ServerWebSocket } from "bun";
import type { FSWatcher } from "fs";

// MARK: - Config

const PORT = parseInt(process.env.PIMUX2000_PORT ?? "7749", 10);

// MARK: - Types

interface ClientMessage {
  id?: string;
  type: string;
  sessionId?: string;
  sessionFile?: string;
  message?: string;
  cwd?: string;
}

interface WSData {
  sessionWatchers: Map<string, FSWatcher>;
}

// MARK: - Connected clients

const clients = new Set<ServerWebSocket<WSData>>();

// MARK: - Server

const server = Bun.serve<WSData>({
  port: PORT,

  fetch(req, server) {
    const url = new URL(req.url);

    // Health check endpoint
    if (url.pathname === "/health") {
      return new Response("ok");
    }

    const upgraded = server.upgrade(req, {
      data: { sessionWatchers: new Map() },
    });
    if (upgraded) return undefined;

    return new Response("Expected WebSocket", { status: 400 });
  },

  websocket: {
    open(ws) {
      clients.add(ws);
      console.log(
        `Client connected (${clients.size} total)`
      );
    },

    async message(ws, raw) {
      let msg: ClientMessage;
      try {
        msg = JSON.parse(typeof raw === "string" ? raw : raw.toString());
      } catch {
        ws.send(JSON.stringify({ type: "error", error: "Invalid JSON" }));
        return;
      }

      try {
        await handleMessage(ws, msg);
      } catch (err: unknown) {
        const error =
          err instanceof Error ? err.message : "Unknown error";
        ws.send(
          JSON.stringify({
            type: "error",
            id: msg.id,
            command: msg.type,
            error,
          })
        );
      }
    },

    close(ws) {
      clients.delete(ws);
      // Clean up session file watchers for this client
      for (const watcher of ws.data.sessionWatchers.values()) {
        watcher.close();
      }
      ws.data.sessionWatchers.clear();
      console.log(
        `Client disconnected (${clients.size} total)`
      );
    },
  },
});

// MARK: - Message handler

async function handleMessage(
  ws: ServerWebSocket<WSData>,
  msg: ClientMessage
) {
  switch (msg.type) {
    case "list_sessions": {
      const sessions = await listSessions();
      ws.send(
        JSON.stringify({
          type: "sessions",
          id: msg.id,
          data: sessions,
        })
      );

      // Generate summaries in background for sessions that lack one
      summarizeMissingSessions(sessions, () => {
        broadcastSessionsDebounced();
      });
      break;
    }

    case "get_messages": {
      if (!msg.sessionFile) {
        throw new Error("sessionFile required");
      }
      const messages = await getMessages(msg.sessionFile);
      ws.send(
        JSON.stringify({
          type: "messages",
          id: msg.id,
          sessionFile: msg.sessionFile,
          data: messages,
        })
      );

      // Set up a file watcher for this session if not already watching
      if (!ws.data.sessionWatchers.has(msg.sessionFile)) {
        const watcher = watchSessionFile(msg.sessionFile, async () => {
          try {
            const updated = await getMessages(msg.sessionFile!);
            ws.send(
              JSON.stringify({
                type: "messages_updated",
                sessionFile: msg.sessionFile,
                data: updated,
              })
            );
          } catch {
            // file may have been removed
          }
        });
        if (watcher) {
          ws.data.sessionWatchers.set(msg.sessionFile, watcher);
        }
      }
      break;
    }

    case "get_state": {
      if (!msg.sessionId) {
        throw new Error("sessionId required");
      }
      const state = await getState(msg.sessionId);
      ws.send(
        JSON.stringify({
          type: "state",
          id: msg.id,
          sessionId: msg.sessionId,
          data: state,
        })
      );
      break;
    }

    case "get_last_assistant_text": {
      if (!msg.sessionFile) {
        throw new Error("sessionFile required");
      }
      const text = await getLastAssistantText(msg.sessionFile);
      ws.send(
        JSON.stringify({
          type: "last_assistant_text",
          id: msg.id,
          sessionFile: msg.sessionFile,
          text,
        })
      );
      break;
    }

    case "prompt": {
      if (!msg.sessionFile) throw new Error("sessionFile required");
      if (!msg.message) throw new Error("message required");

      const result = await sendPrompt(
        msg.sessionFile,
        msg.message,
        msg.cwd
      );
      ws.send(
        JSON.stringify({
          type: "prompt_complete",
          id: msg.id,
          sessionFile: msg.sessionFile,
          events: result.events,
          responses: result.responses,
        })
      );
      break;
    }

    default:
      throw new Error(`Unknown message type: ${msg.type}`);
  }
}

// MARK: - Debounced session broadcast

let sessionsBroadcastDebounce: ReturnType<typeof setTimeout> | null = null;

function broadcastSessionsDebounced() {
  if (sessionsBroadcastDebounce) clearTimeout(sessionsBroadcastDebounce);
  sessionsBroadcastDebounce = setTimeout(async () => {
    try {
      const sessions = await listSessions();
      const payload = JSON.stringify({
        type: "sessions_updated",
        data: sessions,
      });
      for (const client of clients) {
        client.send(payload);
      }
    } catch {
      // ignore
    }
  }, 2000);
}

// MARK: - Registry watcher → broadcast session updates

let registryDebounce: ReturnType<typeof setTimeout> | null = null;

watchRegistry(() => {
  if (registryDebounce) clearTimeout(registryDebounce);
  registryDebounce = setTimeout(async () => {
    try {
      const sessions = await listSessions();
      const payload = JSON.stringify({
        type: "sessions_updated",
        data: sessions,
      });
      for (const client of clients) {
        client.send(payload);
      }
    } catch {
      // ignore
    }
  }, 300);
});

console.log(`pimux2000 server listening on ws://0.0.0.0:${PORT}`);

"""#
	)
}

extension ServerFiles {
	static let install = ServerFile(
		path: "src/install.ts",
		content: #"""
import { mkdirSync, writeFileSync, unlinkSync } from "fs";
import { join } from "path";
import { homedir, platform } from "os";
import { execSync } from "child_process";

const SERVICE_NAME = "pimux2000";
const isMac = platform() === "darwin";

function findBun(): string {
  if (process.execPath) {
    return process.execPath;
  }

  try {
    return execSync("which bun", { encoding: "utf-8" }).trim();
  } catch {
    console.error("Error: bun not found in PATH");
    process.exit(1);
  }
}

// MARK: - Install

export function installServer(port: number = 7749) {
  const bunPath = findBun();
  const serverEntry = join(import.meta.dir, "index.ts");

  if (isMac) {
    installLaunchd(bunPath, serverEntry, port);
  } else {
    installSystemd(bunPath, serverEntry, port);
  }
}

// MARK: - Uninstall

export function uninstallServer() {
  if (isMac) {
    uninstallLaunchd();
  } else {
    uninstallSystemd();
  }
}

// MARK: - Restart

export function restartServer() {
  if (isMac) {
    const label = `com.pimux2000.server`;
    try {
      execSync(`launchctl kickstart -k gui/$(id -u)/${label}`, {
        stdio: "inherit",
      });
      console.log(`${SERVICE_NAME} restarted`);
    } catch {
      console.error("Failed to restart. Is the service installed?");
    }
  } else {
    try {
      execSync(`systemctl --user restart ${SERVICE_NAME}`, {
        stdio: "inherit",
      });
      console.log(`${SERVICE_NAME} restarted`);
    } catch {
      console.error("Failed to restart. Is the service installed?");
    }
  }
}

// MARK: - macOS launchd

const LAUNCHD_LABEL = "com.pimux2000.server";

function launchdPlistPath(): string {
  return join(homedir(), "Library", "LaunchAgents", `${LAUNCHD_LABEL}.plist`);
}

function installLaunchd(bunPath: string, serverEntry: string, port: number) {
  const plistPath = launchdPlistPath();
  const logPath = join(homedir(), "Library", "Logs", `${SERVICE_NAME}.log`);

  // Capture the current PATH so pi/node/bun are all findable at runtime
  const currentPath = process.env.PATH ?? "/usr/bin:/bin:/usr/sbin:/sbin";

  const plist = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LAUNCHD_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${bunPath}</string>
    <string>run</string>
    <string>${serverEntry}</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PIMUX2000_PORT</key>
    <string>${port}</string>
    <key>PATH</key>
    <string>${currentPath}</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${logPath}</string>
  <key>StandardErrorPath</key>
  <string>${logPath}</string>
</dict>
</plist>
`;

  mkdirSync(join(homedir(), "Library", "LaunchAgents"), { recursive: true });
  writeFileSync(plistPath, plist);
  console.log(`Wrote ${plistPath}`);

  try {
    // Unload first in case it's already loaded
    execSync(`launchctl bootout gui/$(id -u)/${LAUNCHD_LABEL} 2>/dev/null`, {
      stdio: "ignore",
    });
  } catch {
    // may not be loaded
  }

  try {
    execSync(`launchctl bootstrap gui/$(id -u) ${plistPath}`, {
      stdio: "inherit",
    });
    console.log(`${SERVICE_NAME} service loaded and started`);
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error(`Failed to load service: ${msg}`);
    console.log(`You can manually load it with:`);
    console.log(`  launchctl bootstrap gui/$(id -u) ${plistPath}`);
  }
}

function uninstallLaunchd() {
  try {
    execSync(`launchctl bootout gui/$(id -u)/${LAUNCHD_LABEL}`, {
      stdio: "inherit",
    });
  } catch {
    // may not be loaded
  }

  const plistPath = launchdPlistPath();
  try {
    unlinkSync(plistPath);
    console.log(`Removed ${plistPath}`);
  } catch {
    // may not exist
  }

  console.log(`${SERVICE_NAME} service removed`);
}

// MARK: - Linux systemd

function systemdUnitPath(): string {
  return join(homedir(), ".config", "systemd", "user", `${SERVICE_NAME}.service`);
}

function installSystemd(bunPath: string, serverEntry: string, port: number) {
  const unitPath = systemdUnitPath();

  const unit = `[Unit]
Description=pimux2000 server
After=network.target

[Service]
Type=simple
ExecStart=${bunPath} run ${serverEntry}
Environment=PIMUX2000_PORT=${port}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
`;

  mkdirSync(join(homedir(), ".config", "systemd", "user"), { recursive: true });
  writeFileSync(unitPath, unit);
  console.log(`Wrote ${unitPath}`);

  try {
    execSync("systemctl --user daemon-reload", { stdio: "inherit" });
    execSync(`systemctl --user enable --now ${SERVICE_NAME}`, {
      stdio: "inherit",
    });
    console.log(`${SERVICE_NAME} service enabled and started`);
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error(`Failed to enable service: ${msg}`);
    console.log(`  systemctl --user enable --now ${SERVICE_NAME}`);
  }
}

function uninstallSystemd() {
  try {
    execSync(`systemctl --user disable --now ${SERVICE_NAME}`, {
      stdio: "inherit",
    });
  } catch {
    // may not be running
  }

  try {
    unlinkSync(systemdUnitPath());
    console.log(`Removed ${systemdUnitPath()}`);
  } catch {
    // may not exist
  }

  try {
    execSync("systemctl --user daemon-reload", { stdio: "inherit" });
  } catch {
    // best effort
  }

  console.log(`${SERVICE_NAME} service removed`);
}

"""#
	)
}

extension ServerFiles {
	static let rpc = ServerFile(
		path: "src/rpc.ts",
		content: #"""
import { execSync, spawn } from "child_process";
import { existsSync } from "fs";
import { join } from "path";
import { homedir } from "os";

function findPiCommand(): string {
  const explicit = process.env.PIMUX2000_PI?.trim();
  if (explicit) return explicit;

  try {
    const resolved = execSync("command -v pi", {
      encoding: "utf-8",
      shell: "/bin/sh",
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
    if (resolved) return resolved;
  } catch {
    // fall through to common locations
  }

  const candidates = [
    join(homedir(), ".bun", "bin", "pi"),
    "/opt/homebrew/bin/pi",
    "/usr/local/bin/pi",
  ];

  for (const candidate of candidates) {
    if (existsSync(candidate)) return candidate;
  }

  throw new Error(
    "pi command not found. Set PIMUX2000_PI or install pi in a standard location."
  );
}

// MARK: - Types

interface RPCCommand {
  id: string;
  type: string;
  [key: string]: unknown;
}

interface RPCResult {
  responses: Record<string, unknown>[];
  events: Record<string, unknown>[];
}

// MARK: - Run pi RPC commands

export async function runRPC(
  commands: RPCCommand[],
  cwd?: string
): Promise<RPCResult> {
  const input = commands.map((c) => JSON.stringify(c)).join("\n") + "\n";

  return new Promise((resolve, reject) => {
    const piCommand = findPiCommand();
    const proc = spawn(piCommand, ["--mode", "rpc"], {
      cwd: cwd ?? undefined,
      stdio: ["pipe", "pipe", "pipe"],
      env: { ...process.env },
    });

    let stdout = "";
    let stderr = "";

    proc.stdout.on("data", (data: Buffer) => {
      stdout += data.toString();
    });

    proc.stderr.on("data", (data: Buffer) => {
      stderr += data.toString();
    });

    proc.on("error", (err) => {
      reject(new Error(`Failed to spawn pi: ${err.message}`));
    });

    proc.on("close", (code) => {
      if (code !== 0) {
        reject(
          new Error(`pi exited with code ${code}: ${stderr.slice(0, 500)}`)
        );
        return;
      }

      const responses: Record<string, unknown>[] = [];
      const events: Record<string, unknown>[] = [];

      for (const line of stdout.split("\n")) {
        if (!line.trim()) continue;
        try {
          const obj = JSON.parse(line);
          if (obj.type === "response") {
            responses.push(obj);
          } else {
            events.push(obj);
          }
        } catch {
          // skip non-JSON lines
        }
      }

      resolve({ responses, events });
    });

    proc.stdin.write(input);
    proc.stdin.end();
  });
}

// MARK: - High-level: send prompt to a session

let rpcRequestCounter = 0;

function nextId(): string {
  return `srv-${++rpcRequestCounter}`;
}

export async function sendPrompt(
  sessionFile: string,
  message: string,
  cwd?: string
): Promise<RPCResult> {
  return runRPC(
    [
      { id: nextId(), type: "switch_session", sessionPath: sessionFile },
      { id: nextId(), type: "prompt", message },
    ],
    cwd
  );
}

"""#
	)
}

extension ServerFiles {
	static let sessions = ServerFile(
		path: "src/sessions.ts",
		content: #"""
import { readdir, readFile } from "fs/promises";
import { join } from "path";
import { homedir } from "os";
import { existsSync, watch, type FSWatcher } from "fs";
import { execSync, spawn } from "child_process";

// MARK: - Types

export interface RegistryEntry {
  pid: number;
  cwd: string;
  sessionFile: string;
  sessionId: string;
  sessionName?: string;
  model?: { provider: string; id: string };
  startedAt: string;
  lastSeenAt: string;
  mode: string;
  workSummary?: string;
  workSummaryUpdatedAt?: string;
  lastMessage?: string;
  lastMessageAt?: string;
  lastMessageRole?: string;
}

export interface SessionMessage {
  role: string;
  content: unknown[];
  toolName?: string;
  toolCallId?: string;
  timestamp?: number;
}

// MARK: - Paths

const REGISTRY_DIR = join(
  homedir(),
  ".pi",
  "agent",
  "runtime",
  "instances"
);

// MARK: - Read sessions from registry

export async function listSessions(): Promise<RegistryEntry[]> {
  let files: string[];
  try {
    files = await readdir(REGISTRY_DIR);
  } catch {
    return [];
  }

  const entries: RegistryEntry[] = [];
  for (const file of files.sort()) {
    if (!file.endsWith(".json") || file.includes("-messages")) continue;
    try {
      const raw = await readFile(join(REGISTRY_DIR, file), "utf-8");
      const entry: RegistryEntry = JSON.parse(raw);

      // Skip one-shot pi -p sessions (e.g. from summarization)
      if (entry.mode === "print") continue;

      // Use cached summary if registry doesn't have one
      if (!entry.workSummary && entry.sessionFile) {
        const cached = summaryCache.get(entry.sessionFile);
        if (cached) entry.workSummary = cached.summary;
      }

      entries.push(entry);
    } catch {
      // skip corrupt/unreadable files
    }
  }
  return entries;
}

// Kick off background summarization for sessions missing workSummary.
// Calls onComplete with the sessionFile and summary when each one finishes.
export function summarizeMissingSessions(
  entries: RegistryEntry[],
  onComplete: (sessionFile: string, summary: string) => void
): void {
  for (const entry of entries) {
    if (entry.workSummary || !entry.sessionFile) continue;
    const sessionFile = entry.sessionFile;

    // Already in-flight or cached
    if (summaryCache.has(sessionFile) || summarizeInFlight.has(sessionFile))
      continue;

    summarizeInFlight.add(sessionFile);
    deriveWorkSummary(sessionFile).then((summary) => {
      summarizeInFlight.delete(sessionFile);
      if (summary) onComplete(sessionFile, summary);
    });
  }
}

const summarizeInFlight = new Set<string>();

// MARK: - Derive a summary from the first user message in the session file

// MARK: - LLM-based summary generation

function findPiCommand(): string {
  const explicit = process.env.PIMUX2000_PI?.trim();
  if (explicit) return explicit;

  try {
    const resolved = execSync("command -v pi", {
      encoding: "utf-8",
      shell: "/bin/sh",
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
    if (resolved) return resolved;
  } catch {
    // fall through to common locations
  }

  const candidates = [
    join(homedir(), ".bun", "bin", "pi"),
    "/opt/homebrew/bin/pi",
    "/usr/local/bin/pi",
  ];

  for (const candidate of candidates) {
    if (existsSync(candidate)) return candidate;
  }

  throw new Error(
    "pi command not found. Set PIMUX2000_PI or install pi in a standard location."
  );
}

const summaryCache = new Map<
  string,
  { summary: string; messageCount: number }
>();

async function deriveWorkSummary(
  sessionFile: string
): Promise<string | undefined> {
  const messages = await getMessages(sessionFile);
  if (messages.length === 0) return undefined;

  const cached = summaryCache.get(sessionFile);
  if (cached && cached.messageCount === messages.length) {
    return cached.summary;
  }

  const summary = await summarizeWithPi(messages);
  if (summary) {
    summaryCache.set(sessionFile, { summary, messageCount: messages.length });
  }
  return summary;
}

async function summarizeWithPi(
  messages: SessionMessage[]
): Promise<string | undefined> {
  const recent = messages.slice(-20);
  const transcript = recent
    .map((m) => {
      const text = extractText(m.content);
      if (!text) return null;
      const truncated =
        text.length > 300 ? text.slice(0, 300) + "..." : text;
      return `${m.role}: ${truncated}`;
    })
    .filter(Boolean)
    .join("\n");

  if (!transcript.trim()) return undefined;

  const prompt = `Summarize what this coding session is working on in a single short phrase (under 60 chars). No quotes, no punctuation at the end, no emojis. Just the topic.\n\n${transcript}`;

  return new Promise((resolve) => {
    let resolved = false;
    const done = (value: string | undefined) => {
      if (resolved) return;
      resolved = true;
      resolve(value);
    };

    const piCommand = findPiCommand();
    const proc = spawn(
      piCommand,
      ["-p", "--no-session", "--model", "anthropic/claude-haiku-4-5", prompt],
      { stdio: ["ignore", "pipe", "pipe"] }
    );

    let stdout = "";
    proc.stdout.on("data", (d: Buffer) => {
      stdout += d.toString();
    });

    // pi -p prints the answer then may hang; give it 15s then take what we have
    const timeout = setTimeout(() => {
      const text = stdout.trim();
      if (text) done(text);
      else done(undefined);
      proc.kill();
    }, 15_000);

    proc.on("error", () => {
      clearTimeout(timeout);
      done(undefined);
    });
    proc.on("close", () => {
      clearTimeout(timeout);
      const text = stdout.trim();
      done(text || undefined);
    });
  });
}

function extractText(content: unknown): string | undefined {
  if (typeof content === "string") return content.trim() || undefined;
  if (!Array.isArray(content)) return undefined;
  const parts: string[] = [];
  for (const block of content as Record<string, unknown>[]) {
    if (block?.type === "text" && typeof block.text === "string") {
      const text = (block.text as string).trim();
      if (text) parts.push(text);
    }
  }
  return parts.join(" ") || undefined;
}

// MARK: - Read messages from JSONL session file

export async function getMessages(
  sessionFile: string
): Promise<SessionMessage[]> {
  let raw: string;
  try {
    raw = await readFile(sessionFile, "utf-8");
  } catch {
    return [];
  }

  const messages: SessionMessage[] = [];
  for (const line of raw.split("\n")) {
    if (!line) continue;
    try {
      const obj = JSON.parse(line);
      if (obj.type === "message" && obj.message) {
        messages.push(obj.message);
      }
    } catch {
      // skip malformed lines
    }
  }
  return messages;
}

// MARK: - Derive last assistant text

export async function getLastAssistantText(
  sessionFile: string
): Promise<string | null> {
  const messages = await getMessages(sessionFile);

  for (let i = messages.length - 1; i >= 0; i--) {
    const msg = messages[i];
    if (msg.role !== "assistant") continue;
    if (!Array.isArray(msg.content)) continue;

    const textParts: string[] = [];
    for (const block of msg.content) {
      if (
        typeof block === "object" &&
        block !== null &&
        "type" in block &&
        (block as any).type === "text" &&
        "text" in block
      ) {
        textParts.push((block as any).text);
      }
    }
    if (textParts.length > 0) return textParts.join("\n");
  }
  return null;
}

// MARK: - Get state from registry entry

export async function getState(
  sessionId: string
): Promise<RegistryEntry | null> {
  const sessions = await listSessions();
  return sessions.find((s) => s.sessionId === sessionId) ?? null;
}

// MARK: - Watch for changes

export type ChangeCallback = () => void;

export function watchRegistry(callback: ChangeCallback): FSWatcher | null {
  try {
    return watch(REGISTRY_DIR, { persistent: false }, () => callback());
  } catch {
    return null;
  }
}

export function watchSessionFile(
  sessionFile: string,
  callback: ChangeCallback
): FSWatcher | null {
  try {
    return watch(sessionFile, { persistent: false }, () => callback());
  } catch {
    return null;
  }
}

"""#
	)
}

// MARK: - Pi Extensions

extension ServerFiles {
	static let extReloadCoordinator = ServerFile(
		path: "reload-coordinator.ts",
		content: #"""
import { mkdir, readFile, readdir, rename, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { getAgentDir, type ExtensionAPI } from "@mariozechner/pi-coding-agent";

export interface ActiveSessionRecord {
	pid: number;
	cwd: string;
	sessionFile: string | null;
	sessionId: string;
	sessionName?: string;
	model?: {
		provider: string;
		id: string;
	};
	startedAt: string;
	lastSeenAt: string;
	mode: "interactive" | "rpc" | "json" | "print" | "unknown";
	workSummary?: string;
	workSummaryUpdatedAt?: string;
	lastMessage?: string;
	lastMessageAt?: string;
	lastMessageRole?: "user" | "assistant";
}

interface ReloadRequest {
	targetPid: number;
	requestedByPid?: number;
	requestedAt: string;
	reason?: string;
}

const RUNTIME_DIR = join(getAgentDir(), "runtime");
export const REGISTRY_DIR = join(RUNTIME_DIR, "instances");
export const RELOAD_REQUESTS_DIR = join(RUNTIME_DIR, "reload-requests");

function isProcessAlive(pid: number): boolean {
	try {
		process.kill(pid, 0);
		return true;
	} catch {
		return false;
	}
}

export function isActiveSessionRecord(value: unknown): value is ActiveSessionRecord {
	if (!value || typeof value !== "object") return false;
	const record = value as Partial<ActiveSessionRecord>;
	return (
		typeof record.pid === "number" &&
		Number.isFinite(record.pid) &&
		typeof record.cwd === "string" &&
		typeof record.sessionId === "string" &&
		typeof record.startedAt === "string" &&
		typeof record.lastSeenAt === "string" &&
		(record.mode === "interactive" || record.mode === "rpc" || record.mode === "json" || record.mode === "print" || record.mode === "unknown") &&
		(record.workSummary === undefined || typeof record.workSummary === "string") &&
		(record.workSummaryUpdatedAt === undefined || typeof record.workSummaryUpdatedAt === "string") &&
		(record.lastMessage === undefined || typeof record.lastMessage === "string") &&
		(record.lastMessageAt === undefined || typeof record.lastMessageAt === "string") &&
		(record.lastMessageRole === undefined || record.lastMessageRole === "user" || record.lastMessageRole === "assistant")
	);
}

async function writeJsonAtomic(path: string, value: unknown): Promise<void> {
	const tempPath = `${path}.${process.pid}.${Date.now()}.${Math.random().toString(36).slice(2)}.tmp`;
	await writeFile(tempPath, `${JSON.stringify(value, null, 2)}\n`, "utf8");
	await rename(tempPath, path);
}

export async function readRegistryEntries(): Promise<ActiveSessionRecord[]> {
	const files = await readdir(REGISTRY_DIR).catch(() => [] as string[]);
	const entries: ActiveSessionRecord[] = [];

	for (const file of files) {
		if (!file.endsWith(".json")) continue;
		const path = join(REGISTRY_DIR, file);
		try {
			const raw = await readFile(path, "utf8");
			const parsed = JSON.parse(raw) as unknown;
			if (!isActiveSessionRecord(parsed)) continue;
			if (!isProcessAlive(parsed.pid)) continue;
			entries.push(parsed);
		} catch {
			// Ignore malformed or concurrently rewritten registry entries.
		}
	}

	return entries.sort((a, b) => a.pid - b.pid);
}

export async function ensureReloadRequestsDir(): Promise<void> {
	await mkdir(RELOAD_REQUESTS_DIR, { recursive: true });
}

function reloadRequestPath(targetPid: number): string {
	return join(RELOAD_REQUESTS_DIR, `${targetPid}.json`);
}

export async function requestReload(targetPid: number, options?: { requestedByPid?: number; reason?: string }): Promise<void> {
	await ensureReloadRequestsDir();
	const request: ReloadRequest = {
		targetPid,
		requestedByPid: options?.requestedByPid,
		requestedAt: new Date().toISOString(),
		reason: options?.reason,
	};
	await writeJsonAtomic(reloadRequestPath(targetPid), request);
}

export async function requestReloadForOtherInteractiveSessions(currentPid: number, options?: {
	reason?: string;
}): Promise<{ requested: number; interactiveCount: number; skipped: string[] }> {
	const sessions = await readRegistryEntries();
	const interactiveSessions = sessions.filter((session) => session.mode === "interactive");
	const otherInteractiveSessions = interactiveSessions.filter((session) => session.pid !== currentPid);
	const skipped: string[] = [];
	let requested = 0;

	for (const session of otherInteractiveSessions) {
		try {
			await requestReload(session.pid, {
				requestedByPid: currentPid,
				reason: options?.reason,
			});
			requested += 1;
		} catch (error) {
			const message = error instanceof Error ? error.message : "failed to write reload request";
			skipped.push(`${session.pid}: ${message}`);
		}
	}

	return { requested, interactiveCount: interactiveSessions.length, skipped };
}

export async function consumeReloadRequest(targetPid: number): Promise<ReloadRequest | undefined> {
	const path = reloadRequestPath(targetPid);
	let raw: string;
	try {
		raw = await readFile(path, "utf8");
	} catch {
		return undefined;
	}

	try {
		const parsed = JSON.parse(raw) as Partial<ReloadRequest>;
		if (parsed.targetPid !== targetPid) return undefined;
		await rm(path, { force: true }).catch(() => undefined);
		return {
			targetPid,
			requestedAt: typeof parsed.requestedAt === "string" ? parsed.requestedAt : new Date().toISOString(),
			requestedByPid: typeof parsed.requestedByPid === "number" ? parsed.requestedByPid : undefined,
			reason: typeof parsed.reason === "string" ? parsed.reason : undefined,
		};
	} catch {
		await rm(path, { force: true }).catch(() => undefined);
		return undefined;
	}
}

export default function reloadCoordinatorExtension(_pi: ExtensionAPI) {
	// Shared helper module for other extensions. Intentionally no-op.
}

"""#
	)

	static let extActiveSessionRegistry = ServerFile(
		path: "active-session-registry.ts",
		content: #"""
import { mkdir, readdir, rename, rm, stat, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { type ExtensionAPI, type ExtensionContext } from "@mariozechner/pi-coding-agent";
import { consumeReloadRequest, ensureReloadRequestsDir, REGISTRY_DIR, type ActiveSessionRecord } from "./reload-coordinator";

type SessionBranchEntry = ReturnType<ExtensionContext["sessionManager"]["getEntries"]>[number] & {
	type: string;
	timestamp?: unknown;
	message?: {
		role?: string;
		content?: unknown;
		timestamp?: unknown;
	};
};

type MessageContentPart = {
	type?: string;
	text?: string;
};

const HEARTBEAT_MS = 15_000;
const RELOAD_POLL_MS = 2_000;
const STALE_GRACE_MS = 5 * 60_000;
const LAST_MESSAGE_MAX_CHARS = 280;

function detectMode(argv: string[]): ActiveSessionRecord["mode"] {
	for (let i = 0; i < argv.length; i++) {
		const arg = argv[i];
		if (arg === "-p" || arg === "--print") return "print";
		if (arg === "--mode") {
			const next = argv[i + 1];
			if (next === "rpc" || next === "json") return next;
		}
		if (arg === "--mode=rpc") return "rpc";
		if (arg === "--mode=json") return "json";
	}
	return process.stdout.isTTY ? "interactive" : "unknown";
}

function isProcessAlive(pid: number): boolean {
	try {
		process.kill(pid, 0);
		return true;
	} catch {
		return false;
	}
}

function extractTextParts(content: unknown): string[] {
	if (typeof content === "string") return [content];
	if (!Array.isArray(content)) return [];
	const parts: string[] = [];
	for (const part of content) {
		if (!part || typeof part !== "object") continue;
		const block = part as MessageContentPart;
		if (block.type === "text" && typeof block.text === "string") {
			const text = block.text.trim();
			if (text) parts.push(text);
		}
	}
	return parts;
}

function normalizeSnippet(text: string, maxLength: number): string {
	const normalized = text.replace(/\s+/g, " ").trim();
	if (!normalized) return "";
	if (normalized.length <= maxLength) return normalized;
	return `${normalized.slice(0, maxLength - 1).trimEnd()}…`;
}

function coerceTimestamp(value: unknown): string | undefined {
	if (typeof value === "string") {
		const trimmed = value.trim();
		return trimmed ? trimmed : undefined;
	}
	if (typeof value === "number" && Number.isFinite(value)) {
		return new Date(value).toISOString();
	}
	return undefined;
}

type LastMessageSnapshot = {
	text: string;
	at?: string;
	role: "user" | "assistant";
};

function deriveLastMessageFromBranch(ctx: ExtensionContext): LastMessageSnapshot | undefined {
	const branch = ctx.sessionManager.getBranch() as SessionBranchEntry[];
	for (let i = branch.length - 1; i >= 0; i--) {
		const entry = branch[i];
		if (!entry || entry.type !== "message" || !entry.message) continue;
		const role = entry.message.role;
		if (role !== "user" && role !== "assistant") continue;
		const text = normalizeSnippet(extractTextParts(entry.message.content).join("\n"), LAST_MESSAGE_MAX_CHARS);
		if (!text) continue;
		return {
			text,
			at: coerceTimestamp(entry.timestamp) ?? coerceTimestamp(entry.message.timestamp),
			role,
		};
	}
	return undefined;
}

async function ensureRegistryDir(): Promise<void> {
	await mkdir(REGISTRY_DIR, { recursive: true });
}

async function writeJsonAtomic(path: string, value: unknown): Promise<void> {
	const tempPath = `${path}.${process.pid}.${Date.now()}.${Math.random().toString(36).slice(2)}.tmp`;
	await writeFile(tempPath, `${JSON.stringify(value, null, 2)}\n`, "utf8");
	await rename(tempPath, path);
}

export default function activeSessionRegistryExtension(pi: ExtensionAPI) {
	const pid = process.pid;
	const startedAt = new Date().toISOString();
	const mode = detectMode(process.argv);
	const instanceFile = join(REGISTRY_DIR, `${pid}.json`);
	const messagesFile = join(REGISTRY_DIR, `${pid}-messages.json`);
	let heartbeat: NodeJS.Timeout | undefined;
	let reloadPoll: NodeJS.Timeout | undefined;
	let latestContext: ExtensionContext | undefined;
	let lastKnownModel: ActiveSessionRecord["model"];
	let latestLastMessage: string | undefined;
	let latestLastMessageAt: string | undefined;
	let latestLastMessageRole: ActiveSessionRecord["lastMessageRole"];
	let selfReloadQueued = false;
	let publishQueue: Promise<void> = Promise.resolve();

	function buildRecord(ctx: ExtensionContext): ActiveSessionRecord {
		return {
			pid,
			cwd: ctx.cwd,
			sessionFile: ctx.sessionManager.getSessionFile() ?? null,
			sessionId: ctx.sessionManager.getSessionId(),
			sessionName: pi.getSessionName() ?? undefined,
			model: ctx.model
				? { provider: ctx.model.provider, id: ctx.model.id }
				: lastKnownModel,
			startedAt,
			lastSeenAt: new Date().toISOString(),
			mode,
			lastMessage: latestLastMessage,
			lastMessageAt: latestLastMessageAt,
			lastMessageRole: latestLastMessageRole,
		};
	}

	async function publish(ctx: ExtensionContext): Promise<void> {
		const record = buildRecord(ctx);
		publishQueue = publishQueue
			.catch(() => undefined)
			.then(async () => {
				await ensureRegistryDir();
				await writeJsonAtomic(instanceFile, record);
			});
		return publishQueue;
	}

	async function cleanupStaleEntries(): Promise<void> {
		await ensureRegistryDir();
		const files = await readdir(REGISTRY_DIR).catch(() => [] as string[]);
		const now = Date.now();
		for (const file of files) {
			if (!file.endsWith(".json")) continue;
			const fullPath = join(REGISTRY_DIR, file);
			const baseName = file.endsWith("-messages.json") ? file.slice(0, -"-messages.json".length) : file.slice(0, -5);
			const otherPid = Number.parseInt(baseName, 10);
			if (!Number.isFinite(otherPid) || otherPid === pid) continue;
			if (isProcessAlive(otherPid)) continue;
			try {
				const info = await stat(fullPath);
				if (now - info.mtimeMs < STALE_GRACE_MS) continue;
				await rm(fullPath, { force: true });
			} catch {
				// Ignore races or permission issues.
			}
		}
	}

	async function removeInstanceFile(): Promise<void> {
		if (heartbeat) { clearInterval(heartbeat); heartbeat = undefined; }
		if (reloadPoll) { clearInterval(reloadPoll); reloadPoll = undefined; }
		await publishQueue.catch(() => undefined);
		await rm(instanceFile, { force: true }).catch(() => undefined);
		await rm(messagesFile, { force: true }).catch(() => undefined);
	}

	async function checkForQueuedReload(ctx: ExtensionContext): Promise<void> {
		if (selfReloadQueued || mode !== "interactive") return;
		const request = await consumeReloadRequest(pid);
		if (!request) return;
		selfReloadQueued = true;
		if (ctx.hasUI) {
			const source = request.requestedByPid ? ` from pid ${request.requestedByPid}` : "";
			ctx.ui.notify(`Queued /reload${source}.`, "info");
		}
		pi.sendUserMessage("/reload", { deliverAs: "followUp" });
	}

	function startHeartbeat(ctx: ExtensionContext): void {
		latestContext = ctx;
		if (!heartbeat) {
			heartbeat = setInterval(() => {
				if (latestContext) void publish(latestContext);
			}, HEARTBEAT_MS);
		}
		if (!reloadPoll) {
			reloadPoll = setInterval(() => {
				if (latestContext) void checkForQueuedReload(latestContext);
			}, RELOAD_POLL_MS);
		}
	}

	async function writeMessages(ctx: ExtensionContext): Promise<void> {
		const branch = ctx.sessionManager.getBranch() as SessionBranchEntry[];
		const messages: unknown[] = [];
		for (const entry of branch) {
			if (entry.type !== "message" || !entry.message) continue;
			messages.push(entry.message);
		}
		await ensureRegistryDir();
		await writeJsonAtomic(messagesFile, messages);
	}

	function updateLastMessage(ctx: ExtensionContext): void {
		latestContext = ctx;
		const lastMessage = deriveLastMessageFromBranch(ctx);
		latestLastMessage = lastMessage?.text;
		latestLastMessageAt = lastMessage?.at;
		latestLastMessageRole = lastMessage?.role;
	}

	pi.on("session_start", async (_event, ctx) => {
		latestContext = ctx;
		lastKnownModel = ctx.model
			? { provider: ctx.model.provider, id: ctx.model.id }
			: undefined;
		await cleanupStaleEntries();
		await ensureReloadRequestsDir();
		updateLastMessage(ctx);
		await publish(ctx);
		startHeartbeat(ctx);
		await checkForQueuedReload(ctx);
	});

	pi.on("session_switch", async (_event, ctx) => {
		latestContext = ctx;
		updateLastMessage(ctx);
		await publish(ctx);
		await checkForQueuedReload(ctx);
	});

	pi.on("session_fork", async (_event, ctx) => {
		latestContext = ctx;
		updateLastMessage(ctx);
		await publish(ctx);
		await checkForQueuedReload(ctx);
	});

	pi.on("model_select", async (event, ctx) => {
		latestContext = ctx;
		lastKnownModel = { provider: event.model.provider, id: event.model.id };
		await publish(ctx);
		await checkForQueuedReload(ctx);
	});

	pi.on("turn_end", async (_event, ctx) => {
		latestContext = ctx;
		updateLastMessage(ctx);
		await publish(ctx);
		await writeMessages(ctx);
		await checkForQueuedReload(ctx);
	});

	pi.on("agent_end", async (_event, ctx) => {
		latestContext = ctx;
		updateLastMessage(ctx);
		await publish(ctx);
		await writeMessages(ctx);
		await checkForQueuedReload(ctx);
	});

	pi.on("session_shutdown", async () => {
		await removeInstanceFile();
	});
}

"""#
	)

	static let extPimux2000 = ServerFile(
		path: "pimux2000.ts",
		content: #"""
import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import { REGISTRY_DIR, requestReloadForOtherInteractiveSessions } from "./reload-coordinator";

export default function pimux2000Extension(pi: ExtensionAPI) {
	pi.registerCommand("pimux2000", {
		description: "pimux2000 utilities: reload-all, sessions-path",
		handler: async (args, ctx) => {
			const subcommand = args.trim().split(/\s+/)[0];

			switch (subcommand) {
				case "reload-all": {
					const { requested, interactiveCount, skipped } = await requestReloadForOtherInteractiveSessions(process.pid, {
						reason: "reload-all",
					});

					const parts = ["Reloaded current session"];
					if (requested > 0) {
						parts.push(`queued /reload for ${requested} other active session${requested === 1 ? "" : "s"}`);
					}
					if (interactiveCount === 1) {
						parts.push("no other active interactive sessions found");
					}
					ctx.ui.notify(parts.join("; "), "info");
					if (skipped.length > 0) {
						ctx.ui.notify(`Skipped: ${skipped.slice(0, 4).join(", ")}${skipped.length > 4 ? ", …" : ""}`, "warning");
					}

					await ctx.reload();
					return;
				}

				case "sessions-path": {
					ctx.ui.notify(`Active session registry: ${REGISTRY_DIR}`, "info");
					return;
				}

				default:
					ctx.ui.notify(
						"Usage: /pimux2000 <subcommand>\n" +
						"  reload-all      Reload all active pi sessions\n" +
						"  sessions-path   Show the session registry directory",
						subcommand ? "warning" : "info"
					);
					return;
			}
		},
	});
}

"""#
	)
}
