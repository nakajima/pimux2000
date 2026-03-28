import type { ExtensionAPI, ExtensionContext } from "@mariozechner/pi-coding-agent";
import { createConnection } from "node:net";
import { homedir } from "node:os";
import { join } from "node:path";

const PARTIAL_UPDATE_THROTTLE_MS = 150;
const SOCKET_WRITE_TIMEOUT_MS = 1_000;

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

type LiveSessionEvent =
	| { type: "sessionAttached"; sessionId: string }
	| { type: "sessionSnapshot"; sessionId: string; messages: PimuxMessage[] }
	| { type: "sessionAppend"; sessionId: string; messages: PimuxMessage[] }
	| { type: "assistantPartial"; sessionId: string; message: PimuxMessage }
	| { type: "sessionDetached"; sessionId: string };

interface PendingPartial {
	message: PimuxMessage;
	timer: ReturnType<typeof setTimeout>;
}

class SocketEventSender {
	private readonly socketPath: string;
	private queue: Promise<void> = Promise.resolve();

	constructor(socketPath: string) {
		this.socketPath = socketPath;
	}

	send(event: LiveSessionEvent): Promise<void> {
		this.queue = this.queue.then(() => this.writeEvent(event)).catch(() => {});
		return this.queue;
	}

	private writeEvent(event: LiveSessionEvent): Promise<void> {
		return new Promise((resolve) => {
			const socket = createConnection(this.socketPath);
			let settled = false;

			const finish = () => {
				if (settled) return;
				settled = true;
				socket.destroy();
				resolve();
			};

			socket.on("connect", () => {
				socket.end(`${JSON.stringify(event)}\n`);
			});
			socket.on("close", finish);
			socket.on("error", finish);
			setTimeout(finish, SOCKET_WRITE_TIMEOUT_MS);
		});
	}
}

export default function (pi: ExtensionAPI) {
	const sender = new SocketEventSender(resolveSocketPath());
	let currentSessionId: string | undefined;
	const pendingPartials = new Map<string, PendingPartial>();

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
		currentSessionId = ctx.sessionManager.getSessionId();
		await publishSnapshot(ctx);
	});

	pi.on("session_compact", async (_event, ctx) => {
		currentSessionId = ctx.sessionManager.getSessionId();
		await publishSnapshot(ctx);
	});

	pi.on("message_update", async (event, ctx) => {
		const sessionId = ctx.sessionManager.getSessionId();
		if (!sessionId) return;

		currentSessionId = sessionId;
		const message = agentMessageToPimuxMessage(event.message);
		if (!message || message.role !== "assistant") return;

		schedulePartial(sessionId, message);
	});

	pi.on("message_end", async (event, ctx) => {
		const sessionId = ctx.sessionManager.getSessionId();
		if (!sessionId) return;

		currentSessionId = sessionId;
		const message = agentMessageToPimuxMessage(event.message);
		if (!message) return;

		if (message.role === "assistant") {
			cancelPendingPartial(sessionId);
		}

		await sender.send({
			type: "sessionAppend",
			sessionId,
			messages: [message],
		});
	});

	pi.on("session_shutdown", async () => {
		for (const sessionId of pendingPartials.keys()) {
			cancelPendingPartial(sessionId);
		}

		if (currentSessionId) {
			await sender.send({ type: "sessionDetached", sessionId: currentSessionId });
			currentSessionId = undefined;
		}
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
			void sender.send({
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

		if (currentSessionId && currentSessionId !== nextSessionId) {
			cancelPendingPartial(currentSessionId);
			await sender.send({ type: "sessionDetached", sessionId: currentSessionId });
		}

		currentSessionId = nextSessionId;
		await sender.send({ type: "sessionAttached", sessionId: nextSessionId });
		await publishSnapshot(ctx);
	}

	async function publishSnapshot(ctx: ExtensionContext) {
		const sessionId = ctx.sessionManager.getSessionId();
		if (!sessionId) return;

		cancelPendingPartial(sessionId);
		await sender.send({
			type: "sessionSnapshot",
			sessionId,
			messages: buildSnapshotMessages(ctx),
		});
	}
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

function resolveSocketPath(): string {
	const agentDir = process.env.PI_CODING_AGENT_DIR || join(homedir(), ".pi", "agent");
	return join(agentDir, "pimux", "live.sock");
}
