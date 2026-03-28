import type { ExtensionAPI, ExtensionContext } from "@mariozechner/pi-coding-agent";
import { createConnection, type Socket } from "node:net";
import { homedir } from "node:os";
import { join } from "node:path";

const LIVE_PROTOCOL_VERSION = 1;
const PARTIAL_UPDATE_THROTTLE_MS = 150;
const SOCKET_RECONNECT_DELAY_MS = 500;

type PimuxRole =
	| "user"
	| "assistant"
	| "toolResult"
	| "bashExecution"
	| "custom"
	| "branchSummary"
	| "compactionSummary"
	| "other";

type PimuxMessageBlockType = "text" | "thinking" | "toolCall" | "other";

interface PimuxMessageBlock {
	type: PimuxMessageBlockType;
	text?: string;
	toolCallName?: string;
}

interface PimuxMessage {
	created_at: string;
	role: PimuxRole;
	body: string;
	blocks?: PimuxMessageBlock[];
}

interface PimuxSessionMetadata {
	createdAt: string;
	cwd: string;
	summary: string;
	model: string;
}

type BridgeToAgentMessage =
	| { type: "hello"; protocolVersion: number }
	| { type: "sessionAttached"; sessionId: string; metadata: PimuxSessionMetadata }
	| { type: "sessionSnapshot"; sessionId: string; messages: PimuxMessage[]; metadata: PimuxSessionMetadata }
	| { type: "sessionAppend"; sessionId: string; messages: PimuxMessage[]; metadata: PimuxSessionMetadata }
	| { type: "assistantPartial"; sessionId: string; message: PimuxMessage }
	| { type: "sessionDetached"; sessionId: string }
	| { type: "sendUserMessageResult"; requestId: string; sessionId: string; error?: string };

type AgentToBridgeMessage = {
	type: "sendUserMessage";
	requestId: string;
	sessionId: string;
	body: string;
};

interface PendingPartial {
	message: PimuxMessage;
	timer: ReturnType<typeof setTimeout>;
}

interface BridgeStateSnapshot {
	currentSessionId?: string;
	latestSnapshotMessages: PimuxMessage[];
	latestMetadata?: PimuxSessionMetadata;
}

const MAX_PENDING_PAYLOADS = 256;

class LiveBridgeClient {
	private readonly socketPath: string;
	private readonly onCommand: (command: AgentToBridgeMessage) => void;
	private readonly getStateSnapshot: () => BridgeStateSnapshot;
	private socket?: Socket;
	private activeSocketId = 0;
	private connecting = false;
	private connected = false;
	private closed = false;
	private reconnectTimer?: ReturnType<typeof setTimeout>;
	private pendingPayloads: string[] = [];
	private incomingBuffer = "";

	constructor(
		socketPath: string,
		onCommand: (command: AgentToBridgeMessage) => void,
		getStateSnapshot: () => BridgeStateSnapshot
	) {
		this.socketPath = socketPath;
		this.onCommand = onCommand;
		this.getStateSnapshot = getStateSnapshot;
		this.ensureConnected();
	}

	send(message: BridgeToAgentMessage) {
		if (this.closed) return;

		const payload = `${JSON.stringify(message)}\n`;
		if (this.connected && this.socket && !this.socket.destroyed) {
			this.socket.write(payload);
			return;
		}

		if (this.pendingPayloads.length < MAX_PENDING_PAYLOADS) {
			this.pendingPayloads.push(payload);
		}
		this.ensureConnected();
	}

	close() {
		this.closed = true;
		if (this.reconnectTimer) {
			clearTimeout(this.reconnectTimer);
			this.reconnectTimer = undefined;
		}
		if (this.socket && !this.socket.destroyed) {
			this.socket.destroy();
		}
		this.socket = undefined;
		this.connected = false;
		this.connecting = false;
		this.pendingPayloads = [];
	}

	private ensureConnected() {
		if (this.closed || this.connected || this.connecting) return;
		this.connecting = true;

		const socketId = ++this.activeSocketId;
		const socket = createConnection(this.socketPath);
		this.socket = socket;

		socket.on("connect", () => {
			if (socketId !== this.activeSocketId) return;
			this.connecting = false;
			this.connected = true;
			this.incomingBuffer = "";
			this.writeNow({ type: "hello", protocolVersion: LIVE_PROTOCOL_VERSION });
			this.flushPendingPayloads();
			this.resyncCurrentSession();
		});

		socket.on("data", (chunk) => {
			if (socketId !== this.activeSocketId) return;
			this.incomingBuffer += chunk.toString("utf8");
			this.drainIncomingBuffer();
		});

		socket.on("error", () => {
			// close always fires after error; reconnect is handled there.
		});

		socket.on("close", () => {
			if (socketId !== this.activeSocketId) return;
			this.connected = false;
			this.connecting = false;
			this.socket = undefined;
			this.scheduleReconnect();
		});
	}

	private writeNow(message: BridgeToAgentMessage) {
		if (this.closed) return;
		if (!this.connected || !this.socket || this.socket.destroyed) {
			if (this.pendingPayloads.length < MAX_PENDING_PAYLOADS) {
				this.pendingPayloads.push(`${JSON.stringify(message)}\n`);
			}
			this.ensureConnected();
			return;
		}

		this.socket.write(`${JSON.stringify(message)}\n`);
	}

	private flushPendingPayloads() {
		if (!this.connected || !this.socket || this.socket.destroyed) return;
		while (this.pendingPayloads.length > 0) {
			const payload = this.pendingPayloads.shift();
			if (!payload) continue;
			this.socket.write(payload);
		}
	}

	private resyncCurrentSession() {
		const state = this.getStateSnapshot();
		if (!state.currentSessionId || !state.latestMetadata) return;
		this.writeNow({
			type: "sessionAttached",
			sessionId: state.currentSessionId,
			metadata: state.latestMetadata,
		});
		this.writeNow({
			type: "sessionSnapshot",
			sessionId: state.currentSessionId,
			messages: state.latestSnapshotMessages,
			metadata: state.latestMetadata,
		});
	}

	private drainIncomingBuffer() {
		while (true) {
			const newlineIndex = this.incomingBuffer.indexOf("\n");
			if (newlineIndex === -1) return;

			let line = this.incomingBuffer.slice(0, newlineIndex);
			this.incomingBuffer = this.incomingBuffer.slice(newlineIndex + 1);
			if (line.endsWith("\r")) line = line.slice(0, -1);
			line = line.trim();
			if (!line) continue;

			try {
				const command = JSON.parse(line) as AgentToBridgeMessage;
				if (command.type !== "sendUserMessage") continue;
				this.onCommand(command);
			} catch {
				// Ignore malformed agent-side commands.
			}
		}
	}

	private scheduleReconnect() {
		if (this.closed) return;
		if (this.reconnectTimer) return;
		this.reconnectTimer = setTimeout(() => {
			this.reconnectTimer = undefined;
			if (!this.closed) this.ensureConnected();
		}, SOCKET_RECONNECT_DELAY_MS);
	}
}

export default function (pi: ExtensionAPI) {
	const state: {
		currentSessionId?: string;
		latestSnapshotMessages: PimuxMessage[];
		latestMetadata?: PimuxSessionMetadata;
		isAgentBusy: boolean;
	} = {
		currentSessionId: undefined,
		latestSnapshotMessages: [],
		latestMetadata: undefined,
		isAgentBusy: false,
	};

	const pendingPartials = new Map<string, PendingPartial>();
	let bridge!: LiveBridgeClient;

	function bridgeStateSnapshot(): BridgeStateSnapshot {
		return {
			currentSessionId: state.currentSessionId,
			latestSnapshotMessages: state.latestSnapshotMessages,
			latestMetadata: state.latestMetadata,
		};
	}

	function respondToSendRequest(requestId: string, sessionId: string, error?: string) {
		bridge.send({ type: "sendUserMessageResult", requestId, sessionId, error });
	}

	function handleBridgeCommand(command: AgentToBridgeMessage) {
		if (command.type !== "sendUserMessage") return;

		if (!state.currentSessionId || command.sessionId !== state.currentSessionId) {
			respondToSendRequest(
				command.requestId,
				command.sessionId,
				`session ${command.sessionId} is not currently attached in this pi runtime`
			);
			return;
		}

		const body = command.body.trim();
		if (!body) {
			respondToSendRequest(command.requestId, command.sessionId, "message body must not be empty");
			return;
		}

		if (state.isAgentBusy) {
			pi.sendUserMessage(body, { deliverAs: "followUp" });
		} else {
			pi.sendUserMessage(body);
		}

		respondToSendRequest(command.requestId, command.sessionId);
	}

	bridge = new LiveBridgeClient(resolveSocketPath(), handleBridgeCommand, bridgeStateSnapshot);

	pi.on("session_start", async (_event, ctx) => {
		await attachCurrentSession(ctx);
	});

	pi.on("session_switch", async (_event, ctx) => {
		await attachCurrentSession(ctx);
	});

	pi.on("session_fork", async (_event, ctx) => {
		await attachCurrentSession(ctx);
	});

	pi.on("session_tree", async (_event, ctx) => {
		publishSnapshot(ctx);
	});

	pi.on("session_compact", async (_event, ctx) => {
		publishSnapshot(ctx);
	});

	pi.on("model_select", async (_event, ctx) => {
		if (state.currentSessionId === ctx.sessionManager.getSessionId()) {
			publishSnapshot(ctx);
		}
	});

	pi.on("agent_start", async () => {
		state.isAgentBusy = true;
	});

	pi.on("agent_end", async () => {
		state.isAgentBusy = false;
	});

	pi.on("message_update", async (event, ctx) => {
		const sessionId = ctx.sessionManager.getSessionId();
		if (!sessionId || sessionId !== state.currentSessionId) return;

		const message = agentMessageToPimuxMessage(event.message);
		if (!message || message.role !== "assistant") return;

		schedulePartial(sessionId, message);
	});

	pi.on("message_end", async (event, ctx) => {
		const sessionId = ctx.sessionManager.getSessionId();
		if (!sessionId || sessionId !== state.currentSessionId) return;

		const message = agentMessageToPimuxMessage(event.message);
		if (!message) return;

		if (message.role === "assistant") {
			cancelPendingPartial(sessionId);
		}

		state.latestSnapshotMessages = [...state.latestSnapshotMessages, message];
		state.latestMetadata = buildSessionMetadata(ctx, state.latestSnapshotMessages);
		bridge.send({
			type: "sessionAppend",
			sessionId,
			messages: [message],
			metadata: state.latestMetadata,
		});
	});

	pi.on("session_shutdown", async () => {
		for (const sessionId of pendingPartials.keys()) {
			cancelPendingPartial(sessionId);
		}

		if (state.currentSessionId) {
			bridge.send({ type: "sessionDetached", sessionId: state.currentSessionId });
			state.currentSessionId = undefined;
			state.latestSnapshotMessages = [];
			state.latestMetadata = undefined;
		}

		bridge.close();
	});

	function schedulePartial(sessionId: string, message: PimuxMessage) {
		const pending = pendingPartials.get(sessionId);
		if (pending) {
			pending.message = message;
			return;
		}

		const timer = setTimeout(() => {
			const latest = pendingPartials.get(sessionId);
			if (!latest) return;
			pendingPartials.delete(sessionId);
			bridge.send({
				type: "assistantPartial",
				sessionId,
				message: latest.message,
			});
		}, PARTIAL_UPDATE_THROTTLE_MS);

		pendingPartials.set(sessionId, { message, timer });
	}

	function cancelPendingPartial(sessionId: string) {
		const pending = pendingPartials.get(sessionId);
		if (!pending) return;
		clearTimeout(pending.timer);
		pendingPartials.delete(sessionId);
	}

	async function attachCurrentSession(ctx: ExtensionContext) {
		const nextSessionId = ctx.sessionManager.getSessionId();
		if (!nextSessionId) return;

		if (state.currentSessionId && state.currentSessionId !== nextSessionId) {
			cancelPendingPartial(state.currentSessionId);
			bridge.send({ type: "sessionDetached", sessionId: state.currentSessionId });
		}

		state.currentSessionId = nextSessionId;
		state.latestSnapshotMessages = buildSnapshotMessages(ctx);
		state.latestMetadata = buildSessionMetadata(ctx, state.latestSnapshotMessages);
		bridge.send({
			type: "sessionAttached",
			sessionId: nextSessionId,
			metadata: state.latestMetadata,
		});
		bridge.send({
			type: "sessionSnapshot",
			sessionId: nextSessionId,
			messages: state.latestSnapshotMessages,
			metadata: state.latestMetadata,
		});
	}

	function publishSnapshot(ctx: ExtensionContext) {
		const sessionId = ctx.sessionManager.getSessionId();
		if (!sessionId) return;

		state.currentSessionId = sessionId;
		state.latestSnapshotMessages = buildSnapshotMessages(ctx);
		state.latestMetadata = buildSessionMetadata(ctx, state.latestSnapshotMessages);
		cancelPendingPartial(sessionId);
		bridge.send({
			type: "sessionSnapshot",
			sessionId,
			messages: state.latestSnapshotMessages,
			metadata: state.latestMetadata,
		});
	}
}

function buildSessionMetadata(ctx: ExtensionContext, messages: PimuxMessage[]): PimuxSessionMetadata {
	const header = ctx.sessionManager.getHeader();
	const sessionId = ctx.sessionManager.getSessionId();
	const namedSummary = normalizeDisplayText(ctx.sessionManager.getSessionName());
	const fallbackSummary = summarizeMessages(messages) || sessionId;
	const model = ctx.model ? `${ctx.model.provider}/${ctx.model.id}` : "unknown";

	return {
		createdAt: toIsoString(header?.timestamp ?? messages[0]?.created_at ?? new Date().toISOString()),
		cwd: ctx.sessionManager.getCwd(),
		summary: namedSummary || fallbackSummary,
		model,
	};
}

function summarizeMessages(messages: PimuxMessage[]): string | undefined {
	const firstUser = messages.find((message) => message.role === "user");
	const source = firstUser?.body || messages.find((message) => message.body)?.body;
	if (!source) return undefined;
	const collapsed = collapseWhitespace(source);
	if (!collapsed) return undefined;
	return truncateChars(collapsed, 120);
}

function buildSnapshotMessages(ctx: ExtensionContext): PimuxMessage[] {
	const branch = ctx.sessionManager.getBranch();
	return branch
		.map((entry: any) => entryToPimuxMessage(entry))
		.filter((message): message is PimuxMessage => Boolean(message));
}

function entryToPimuxMessage(entry: any): PimuxMessage | undefined {
	switch (entry?.type) {
		case "message":
			return agentMessageToPimuxMessage(entry.message, entry.timestamp);
		case "custom_message": {
			const text = flattenTextContent(entry.content);
			if (!text) return undefined;
			return pimuxMessageFromText(toIsoString(entry.timestamp), "custom", text);
		}
		case "branch_summary": {
			const text = collapseWhitespace(entry.summary);
			if (!text) return undefined;
			return pimuxMessageFromText(toIsoString(entry.timestamp), "branchSummary", text);
		}
		case "compaction": {
			const text = collapseWhitespace(entry.summary);
			if (!text) return undefined;
			return pimuxMessageFromText(toIsoString(entry.timestamp), "compactionSummary", text);
		}
		default:
			return undefined;
	}
}

function agentMessageToPimuxMessage(message: any, fallbackTimestamp?: string): PimuxMessage | undefined {
	if (!message?.role) return undefined;

	switch (message.role) {
		case "user":
			return pimuxMessageFromBlocks(
				timestampToIso(message.timestamp, fallbackTimestamp),
				"user",
				contentToBlocks(message.content, false)
			);
		case "assistant":
			return pimuxMessageFromBlocks(
				timestampToIso(message.timestamp, fallbackTimestamp),
				"assistant",
				contentToBlocks(message.content, true)
			);
		case "toolResult":
			return pimuxMessageFromBlocks(
				timestampToIso(message.timestamp, fallbackTimestamp),
				"toolResult",
				contentToBlocks(message.content, false)
			);
		case "bashExecution": {
			const text = flattenBashExecution(message);
			if (!text) return undefined;
			return pimuxMessageFromText(timestampToIso(message.timestamp, fallbackTimestamp), "bashExecution", text);
		}
		case "custom": {
			const text = flattenTextContent(message.content);
			if (!text) return undefined;
			return pimuxMessageFromText(timestampToIso(message.timestamp, fallbackTimestamp), "custom", text);
		}
		case "branchSummary": {
			const text = collapseWhitespace(message.summary);
			if (!text) return undefined;
			return pimuxMessageFromText(timestampToIso(message.timestamp, fallbackTimestamp), "branchSummary", text);
		}
		case "compactionSummary": {
			const text = collapseWhitespace(message.summary);
			if (!text) return undefined;
			return pimuxMessageFromText(timestampToIso(message.timestamp, fallbackTimestamp), "compactionSummary", text);
		}
		default: {
			const text = flattenTextContent(message.content) ?? collapseWhitespace(message.summary) ?? "";
			if (!text) return undefined;
			return pimuxMessageFromText(timestampToIso(message.timestamp, fallbackTimestamp), "other", text);
		}
	}
}

function pimuxMessageFromText(created_at: string, role: PimuxRole, text: string): PimuxMessage | undefined {
	const normalized = normalizeDisplayText(text);
	if (!normalized) return undefined;
	return {
		created_at,
		role,
		body: normalized,
		blocks: [{ type: "text", text: normalized }],
	};
}

function pimuxMessageFromBlocks(created_at: string, role: PimuxRole, blocks: PimuxMessageBlock[]): PimuxMessage | undefined {
	const normalizedBlocks = blocks
		.map(normalizeBlock)
		.filter((block): block is PimuxMessageBlock => Boolean(block));
	if (normalizedBlocks.length === 0) return undefined;

	return {
		created_at,
		role,
		body: bodyFromBlocks(role, normalizedBlocks),
		blocks: normalizedBlocks,
	};
}

function normalizeBlock(block: PimuxMessageBlock | undefined): PimuxMessageBlock | undefined {
	if (!block) return undefined;

	switch (block.type) {
		case "text":
		case "thinking":
		case "other": {
			const text = normalizeDisplayText(block.text);
			if (!text) return undefined;
			return { type: block.type, text };
		}
		case "toolCall": {
			const toolCallName = collapseWhitespace(block.toolCallName);
			if (!toolCallName) return undefined;
			return { type: "toolCall", toolCallName };
		}
		default:
			return undefined;
	}
}

function bodyFromBlocks(role: PimuxRole, blocks: PimuxMessageBlock[]): string {
	return blocks
		.flatMap((block) => {
			if (block.type === "text" && block.text) return [block.text];
			if (role === "assistant" && block.type === "toolCall" && block.toolCallName) {
				return [`Tool call: ${block.toolCallName}`];
			}
			return [];
		})
		.join("\n\n");
}

function contentToBlocks(content: any, includeToolCalls: boolean): PimuxMessageBlock[] {
	if (typeof content === "string") {
		const text = normalizeDisplayText(content);
		return text ? [{ type: "text", text }] : [];
	}

	if (!Array.isArray(content)) return [];

	return content
		.map((block) => {
			switch (block?.type) {
				case "text": {
					const text = normalizeDisplayText(block.text);
					return text ? ({ type: "text", text } satisfies PimuxMessageBlock) : undefined;
				}
				case "thinking": {
					const text = normalizeDisplayText(block.thinking);
					return text ? ({ type: "thinking", text } satisfies PimuxMessageBlock) : undefined;
				}
				case "toolCall": {
					if (!includeToolCalls || typeof block.name !== "string") return undefined;
					const toolCallName = collapseWhitespace(block.name);
					return toolCallName
						? ({ type: "toolCall", toolCallName } satisfies PimuxMessageBlock)
						: undefined;
				}
				default:
					return undefined;
			}
		})
		.filter((block): block is PimuxMessageBlock => Boolean(block));
}

function flattenTextContent(content: any): string | undefined {
	const text = contentToBlocks(content, false)
		.filter((block) => block.type === "text")
		.map((block) => block.text)
		.filter((text): text is string => Boolean(text))
		.join("\n\n");
	return text || undefined;
}

function flattenBashExecution(message: any): string | undefined {
	const parts: string[] = [];

	if (typeof message.command === "string") {
		const command = normalizeDisplayText(message.command);
		if (command) parts.push(`$ ${command}`);
	}

	if (typeof message.output === "string") {
		const output = normalizeDisplayText(message.output);
		if (output) parts.push(output);
	}

	const body = parts.join("\n\n");
	return body || undefined;
}

function timestampToIso(timestamp: unknown, fallbackTimestamp?: string): string {
	if (typeof timestamp === "number") {
		return new Date(timestamp).toISOString();
	}

	if (typeof fallbackTimestamp === "string") {
		return toIsoString(fallbackTimestamp);
	}

	return new Date().toISOString();
}

function toIsoString(timestamp: unknown): string {
	if (typeof timestamp === "string") {
		return new Date(timestamp).toISOString();
	}
	if (typeof timestamp === "number") {
		return new Date(timestamp).toISOString();
	}
	return new Date().toISOString();
}

function normalizeDisplayText(value: unknown): string {
	if (typeof value !== "string") return "";
	const normalized = value.replace(/\r\n?/g, "\n").replace(/^\n+|\n+$/g, "");
	return normalized.trim().length > 0 ? normalized : "";
}

function collapseWhitespace(value: unknown): string {
	if (typeof value !== "string") return "";
	return value.split(/\s+/).filter(Boolean).join(" ");
}

function truncateChars(value: string, maxChars: number): string {
	const chars = Array.from(value);
	if (chars.length <= maxChars) return value;
	return `${chars.slice(0, maxChars).join("")}…`;
}

function resolveSocketPath(): string {
	const agentDir = process.env.PI_CODING_AGENT_DIR || join(homedir(), ".pi", "agent");
	return join(agentDir, "pimux", "live.sock");
}
