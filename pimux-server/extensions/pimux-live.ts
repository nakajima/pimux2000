import type { ExtensionAPI, ExtensionContext } from "@mariozechner/pi-coding-agent";
import { createConnection } from "node:net";
import { homedir } from "node:os";
import { join } from "node:path";

const PARTIAL_UPDATE_THROTTLE_MS = 300;
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

interface PimuxMessage {
	created_at: string;
	role: PimuxRole;
	body: string;
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
			const body = flattenContent(entry.content, false);
			if (!body) return undefined;
			return {
				created_at: toIsoString(entry.timestamp),
				role: "custom",
				body,
			};
		}
		case "branch_summary": {
			const body = collapseWhitespace(entry.summary);
			if (!body) return undefined;
			return {
				created_at: toIsoString(entry.timestamp),
				role: "branchSummary",
				body,
			};
		}
		case "compaction": {
			const body = collapseWhitespace(entry.summary);
			if (!body) return undefined;
			return {
				created_at: toIsoString(entry.timestamp),
				role: "compactionSummary",
				body,
			};
		}
		default:
			return undefined;
	}
}

function agentMessageToPimuxMessage(message: any, fallbackTimestamp?: string): PimuxMessage | undefined {
	if (!message?.role) return undefined;

	switch (message.role) {
		case "user": {
			const body = flattenContent(message.content, false);
			if (!body) return undefined;
			return {
				created_at: timestampToIso(message.timestamp, fallbackTimestamp),
				role: "user",
				body,
			};
		}
		case "assistant": {
			const body = flattenContent(message.content, true);
			if (!body) return undefined;
			return {
				created_at: timestampToIso(message.timestamp, fallbackTimestamp),
				role: "assistant",
				body,
			};
		}
		case "toolResult": {
			const body = flattenContent(message.content, false);
			if (!body) return undefined;
			return {
				created_at: timestampToIso(message.timestamp, fallbackTimestamp),
				role: "toolResult",
				body,
			};
		}
		case "bashExecution": {
			const body = flattenBashExecution(message);
			if (!body) return undefined;
			return {
				created_at: timestampToIso(message.timestamp, fallbackTimestamp),
				role: "bashExecution",
				body,
			};
		}
		case "custom": {
			const body = flattenContent(message.content, false);
			if (!body) return undefined;
			return {
				created_at: timestampToIso(message.timestamp, fallbackTimestamp),
				role: "custom",
				body,
			};
		}
		case "branchSummary": {
			const body = collapseWhitespace(message.summary);
			if (!body) return undefined;
			return {
				created_at: timestampToIso(message.timestamp, fallbackTimestamp),
				role: "branchSummary",
				body,
			};
		}
		case "compactionSummary": {
			const body = collapseWhitespace(message.summary);
			if (!body) return undefined;
			return {
				created_at: timestampToIso(message.timestamp, fallbackTimestamp),
				role: "compactionSummary",
				body,
			};
		}
		default: {
			const body = flattenContent(message.content, false) ?? collapseWhitespace(message.summary) ?? "";
			if (!body) return undefined;
			return {
				created_at: timestampToIso(message.timestamp, fallbackTimestamp),
				role: "other",
				body,
			};
		}
	}
}

function flattenContent(content: any, includeToolCalls: boolean): string | undefined {
	if (typeof content === "string") {
		const collapsed = collapseWhitespace(content);
		return collapsed || undefined;
	}

	if (!Array.isArray(content)) return undefined;

	const parts: string[] = [];
	for (const block of content) {
		if (block?.type === "text" && typeof block.text === "string") {
			const text = collapseWhitespace(block.text);
			if (text) parts.push(text);
		}
		if (includeToolCalls && block?.type === "toolCall" && typeof block.name === "string") {
			parts.push(`Tool call: ${collapseWhitespace(block.name)}`);
		}
	}

	const flattened = parts.join("\n\n").trim();
	return flattened || undefined;
}

function flattenBashExecution(message: any): string | undefined {
	const parts: string[] = [];

	if (typeof message.command === "string") {
		const command = collapseWhitespace(message.command);
		if (command) parts.push(`$ ${command}`);
	}

	if (typeof message.output === "string") {
		const output = message.output.trim();
		if (output) parts.push(output);
	}

	const body = parts.join("\n\n").trim();
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

function collapseWhitespace(value: unknown): string {
	if (typeof value !== "string") return "";
	return value.split(/\s+/).filter(Boolean).join(" ");
}

function resolveSocketPath(): string {
	const agentDir = process.env.PI_CODING_AGENT_DIR || join(homedir(), ".pi", "agent");
	return join(agentDir, "pimux", "live.sock");
}
