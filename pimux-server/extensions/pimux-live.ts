import { complete } from "@mariozechner/pi-ai";
import {
	AgentSession,
	ExtensionEditorComponent,
	ExtensionInputComponent,
	ExtensionRunner,
	ExtensionSelectorComponent,
	type ExtensionAPI,
	type ExtensionCommandContext,
	type ExtensionContext,
} from "@mariozechner/pi-coding-agent";
import { setKeybindings, setKittyProtocolActive } from "@mariozechner/pi-tui";
import { execFile } from "node:child_process";
import { createConnection, type Socket } from "node:net";
import { homedir } from "node:os";
import { join } from "node:path";

const LIVE_PROTOCOL_VERSION = 8;
const PARTIAL_UPDATE_THROTTLE_MS = 150;
const SOCKET_RECONNECT_DELAY_MS = 500;
const RESUMMARIZE_EDGE_ENTRY_COUNT = 5;
const RESUMMARIZE_ENTRY_MAX_CHARS = 400;
const RESUMMARIZE_TITLE_MAX_CHARS = 80;

type PimuxRole =
	| "user"
	| "assistant"
	| "toolResult"
	| "bashExecution"
	| "custom"
	| "branchSummary"
	| "compactionSummary"
	| "other";

type PimuxMessageBlockType = "text" | "thinking" | "toolCall" | "image" | "other";

interface PimuxMessageBlock {
	type: PimuxMessageBlockType;
	text?: string;
	toolCallName?: string;
	mimeType?: string;
	data?: string;
}

interface PimuxMessage {
	created_at: string;
	role: PimuxRole;
	body: string;
	toolName?: string;
	blocks?: PimuxMessageBlock[];
	messageId?: string;
}

interface PimuxSessionContextUsage {
	usedTokens?: number;
	maxTokens?: number;
}

interface PimuxSessionMetadata {
	createdAt: string;
	cwd: string;
	summary: string;
	model: string;
	contextUsage?: PimuxSessionContextUsage;
}

type PimuxUiWidgetPlacement = "aboveEditor" | "belowEditor";

interface PimuxUiWidget {
	key: string;
	lines: string[];
	placement: PimuxUiWidgetPlacement;
}

interface PimuxUiState {
	statuses?: Record<string, string>;
	widgets?: PimuxUiWidget[];
	title?: string;
	editorText?: string;
	workingMessage?: string;
	hiddenThinkingLabel?: string;
}

interface RuntimeUiState {
	statuses: Map<string, string>;
	widgets: Map<string, PimuxUiWidget>;
	title?: string;
	editorText?: string;
	workingMessage?: string;
	hiddenThinkingLabel?: string;
}

type PimuxUiDialogKind = "confirm" | "select" | "input" | "editor";
type PimuxTerminalOnlyUiKind = "customUi" | "dialogFallback";

type PimuxUiDialogMoveDirection = "up" | "down";

interface PimuxUiDialogState {
	id: string;
	kind: PimuxUiDialogKind;
	title: string;
	message: string;
	options: string[];
	selectedIndex: number;
	placeholder?: string;
	value?: string;
}

type PimuxUiDialogAction =
	| { type: "move"; direction: PimuxUiDialogMoveDirection }
	| { type: "selectIndex"; index: number }
	| { type: "setValue"; value: string }
	| { type: "submit" }
	| { type: "cancel" };

type PimuxBuiltinCommandAction =
	| { type: "setSessionName"; name: string }
	| { type: "compact"; customInstructions?: string }
	| { type: "reload" };

interface PimuxTerminalOnlyUiState {
	kind: PimuxTerminalOnlyUiKind;
	reason: string;
}

type UiDialogOptions = { signal?: AbortSignal; timeout?: number };

type MirroredDialogTui = {
	terminal: { kittyProtocolActive: boolean };
	requestRender: () => void;
};

interface RuntimeSelectorDialog<
	Result,
	Kind extends Extract<PimuxUiDialogKind, "confirm" | "select">
> {
	sessionId: string;
	state: PimuxUiDialogState & { kind: Kind };
	selector?: ExtensionSelectorComponent;
	done?: (result: Result) => void;
	finished: boolean;
	result: Result;
}

interface RuntimeInputDialog {
	sessionId: string;
	state: PimuxUiDialogState & { kind: "input"; value: string };
	input?: ExtensionInputComponent;
	requestRender?: () => void;
	done?: (result: string | undefined) => void;
	finished: boolean;
	result: string | undefined;
}

interface RuntimeEditorDialog {
	sessionId: string;
	state: PimuxUiDialogState & { kind: "editor"; value: string };
	editor?: ExtensionEditorComponent;
	requestRender?: () => void;
	done?: (result: string | undefined) => void;
	finished: boolean;
	result: string | undefined;
}

type RuntimeConfirmDialog = RuntimeSelectorDialog<boolean, "confirm">;
type RuntimeSelectDialog = RuntimeSelectorDialog<string | undefined, "select">;
type RuntimeSelectorUiDialog = RuntimeConfirmDialog | RuntimeSelectDialog;
type RuntimeTextValueDialog = RuntimeInputDialog | RuntimeEditorDialog;
type RuntimeUiDialog = RuntimeSelectorUiDialog | RuntimeTextValueDialog;
type RuntimeUiDialogSelectorState = Pick<RuntimeSelectorUiDialog, "sessionId" | "state" | "selector">;

interface RuntimeTerminalOnlyUiState {
	sessionId: string;
	state: PimuxTerminalOnlyUiState;
}

type BoundCommandContextActions = {
	reload?: () => Promise<void>;
};

type BoundExtensionRunner = Pick<ExtensionRunner, "getCommand" | "createCommandContext">;
type BoundAgentSession = Pick<AgentSession, "prompt" | "sessionManager" | "extensionRunner">;

type PimuxLiveGlobalState = typeof globalThis & {
	__pimuxLiveBoundCommandContextActions?: BoundCommandContextActions;
	__pimuxLiveBoundExtensionRunner?: BoundExtensionRunner;
	__pimuxLiveCommandContextBindingsPatched?: boolean;
	__pimuxLiveAgentSession?: BoundAgentSession;
	__pimuxLiveAgentSessionBindingPatched?: boolean;
};

function pimuxLiveGlobalState(): PimuxLiveGlobalState {
	return globalThis as PimuxLiveGlobalState;
}

function currentBoundCommandContextActions() {
	return pimuxLiveGlobalState().__pimuxLiveBoundCommandContextActions;
}

function currentExtensionRunner() {
	return pimuxLiveGlobalState().__pimuxLiveBoundExtensionRunner;
}

function ensureCommandContextBindingsPatched() {
	const globalState = pimuxLiveGlobalState();
	if (globalState.__pimuxLiveCommandContextBindingsPatched) return;
	globalState.__pimuxLiveCommandContextBindingsPatched = true;

	const originalBindCommandContext = ExtensionRunner.prototype.bindCommandContext;
	ExtensionRunner.prototype.bindCommandContext = function (actions: BoundCommandContextActions | undefined) {
		globalState.__pimuxLiveBoundCommandContextActions = actions;
		globalState.__pimuxLiveBoundExtensionRunner = this as BoundExtensionRunner;
		return originalBindCommandContext.call(this, actions);
	};

	const originalGetRegisteredCommands = ExtensionRunner.prototype.getRegisteredCommands;
	ExtensionRunner.prototype.getRegisteredCommands = function (
		...args: Parameters<ExtensionRunner["getRegisteredCommands"]>
	) {
		globalState.__pimuxLiveBoundExtensionRunner = this as BoundExtensionRunner;
		return originalGetRegisteredCommands.apply(this, args);
	};
}

function currentAgentSession() {
	return pimuxLiveGlobalState().__pimuxLiveAgentSession;
}

function ensureAgentSessionBindingPatched() {
	const globalState = pimuxLiveGlobalState();
	if (globalState.__pimuxLiveAgentSessionBindingPatched) return;
	globalState.__pimuxLiveAgentSessionBindingPatched = true;

	const originalBindExtensions = AgentSession.prototype.bindExtensions;
	AgentSession.prototype.bindExtensions = async function (
		...args: Parameters<AgentSession["bindExtensions"]>
	) {
		globalState.__pimuxLiveAgentSession = this as BoundAgentSession;
		return await originalBindExtensions.apply(this, args);
	};

	const originalBindExtensionCore = (AgentSession.prototype as any)._bindExtensionCore;
	if (typeof originalBindExtensionCore === "function") {
		(AgentSession.prototype as any)._bindExtensionCore = function (...args: unknown[]) {
			globalState.__pimuxLiveAgentSession = this as BoundAgentSession;
			const [runner] = args;
			if (runner && typeof runner === "object") {
				globalState.__pimuxLiveBoundExtensionRunner = runner as BoundExtensionRunner;
			}
			return originalBindExtensionCore.apply(this, args);
		};
	}
}

function isConfirmDialog(dialog: RuntimeUiDialog): dialog is RuntimeConfirmDialog {
	return dialog.state.kind === "confirm";
}

function isSelectDialog(dialog: RuntimeUiDialog): dialog is RuntimeSelectDialog {
	return dialog.state.kind === "select";
}

function isInputDialog(dialog: RuntimeUiDialog): dialog is RuntimeInputDialog {
	return dialog.state.kind === "input";
}

function isEditorDialog(dialog: RuntimeUiDialog): dialog is RuntimeEditorDialog {
	return dialog.state.kind === "editor";
}

function isTextValueDialog(dialog: RuntimeUiDialog): dialog is RuntimeTextValueDialog {
	return dialog.state.kind === "input" || dialog.state.kind === "editor";
}

type BridgeToAgentMessage =
	| { type: "hello"; protocolVersion: number }
	| { type: "sessionAttached"; sessionId: string; metadata: PimuxSessionMetadata }
	| { type: "sessionSnapshot"; sessionId: string; messages: PimuxMessage[]; metadata: PimuxSessionMetadata }
	| { type: "sessionAppend"; sessionId: string; messages: PimuxMessage[]; metadata: PimuxSessionMetadata }
	| { type: "assistantPartial"; sessionId: string; message: PimuxMessage }
	| { type: "uiState"; sessionId: string; state: PimuxUiState }
	| { type: "uiDialogState"; sessionId: string; state: PimuxUiDialogState | null }
	| { type: "terminalOnlyUiState"; sessionId: string; state: PimuxTerminalOnlyUiState | null }
	| { type: "sessionDetached"; sessionId: string }
	| { type: "sendUserMessageResult"; requestId: string; sessionId: string; error?: string }
	| { type: "getCommandsResult"; requestId: string; sessionId: string; commands: PimuxSessionCommand[]; error?: string }
	| {
			type: "getCommandArgumentCompletionsResult";
			requestId: string;
			sessionId: string;
			completions: PimuxCommandCompletion[];
			error?: string;
	  }
	| { type: "uiDialogActionResult"; requestId: string; sessionId: string; error?: string }
	| { type: "builtinCommandResult"; requestId: string; sessionId: string; error?: string };

interface PimuxInputImage {
	type: "image";
	data: string;
	mimeType: string;
}

interface PimuxCommandCompletion {
	value: string;
	label: string;
	description?: string;
}

type AgentToBridgeMessage =
	| {
			type: "sendUserMessage";
			requestId: string;
			sessionId: string;
			body: string;
			images?: PimuxInputImage[];
	  }
	| {
			type: "getCommands";
			requestId: string;
			sessionId: string;
	  }
	| {
			type: "getCommandArgumentCompletions";
			requestId: string;
			sessionId: string;
			commandName: string;
			argumentPrefix: string;
	  }
	| {
			type: "uiDialogAction";
			requestId: string;
			sessionId: string;
			dialogId: string;
			action: PimuxUiDialogAction;
	  }
	| {
			type: "builtinCommand";
			requestId: string;
			sessionId: string;
			action: PimuxBuiltinCommandAction;
	  }
	| {
			type: "interruptSession";
			sessionId: string;
	  };

interface PimuxSessionCommand {
	name: string;
	description?: string;
	source: string;
}

interface PendingPartial {
	message: PimuxMessage;
	timer: ReturnType<typeof setTimeout>;
}

interface BridgeStateSnapshot {
	currentSessionId?: string;
	latestSnapshotMessages: PimuxMessage[];
	latestMetadata?: PimuxSessionMetadata;
	currentAssistantPartial?: PimuxMessage;
	currentUiState?: PimuxUiState;
	currentUiDialogState?: PimuxUiDialogState;
	currentTerminalOnlyUiState?: PimuxTerminalOnlyUiState;
}

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
		if (this.writeNow(message)) return;

		// Reconnects always resync the current session state, so avoid buffering
		// stale live payloads while the socket is down.
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

	private writeNow(message: BridgeToAgentMessage): boolean {
		if (this.closed) return false;
		if (!this.connected || !this.socket || this.socket.destroyed) {
			return false;
		}

		this.socket.write(`${JSON.stringify(message)}\n`);
		return true;
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
		if (state.currentAssistantPartial) {
			this.writeNow({
				type: "assistantPartial",
				sessionId: state.currentSessionId,
				message: state.currentAssistantPartial,
			});
		}
		if (state.currentUiState) {
			this.writeNow({
				type: "uiState",
				sessionId: state.currentSessionId,
				state: state.currentUiState,
			});
		}
		if (state.currentUiDialogState) {
			this.writeNow({
				type: "uiDialogState",
				sessionId: state.currentSessionId,
				state: state.currentUiDialogState,
			});
		}
		if (state.currentTerminalOnlyUiState) {
			this.writeNow({
				type: "terminalOnlyUiState",
				sessionId: state.currentSessionId,
				state: state.currentTerminalOnlyUiState,
			});
		}
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
	ensureCommandContextBindingsPatched();
	ensureAgentSessionBindingPatched();

	const state: {
		currentSessionId?: string;
		currentSessionContext?: ExtensionContext;
		latestSnapshotMessages: PimuxMessage[];
		latestMetadata?: PimuxSessionMetadata;
		currentAssistantPartial?: PimuxMessage;
		currentUiState: RuntimeUiState;
		currentUiDialog?: RuntimeUiDialog;
		currentTerminalOnlyUi?: RuntimeTerminalOnlyUiState;
		nextDialogId: number;
		isAgentBusy: boolean;
	} = {
		currentSessionId: undefined,
		currentSessionContext: undefined,
		latestSnapshotMessages: [],
		latestMetadata: undefined,
		currentAssistantPartial: undefined,
		currentUiState: createEmptyRuntimeUiState(),
		currentUiDialog: undefined,
		currentTerminalOnlyUi: undefined,
		nextDialogId: 1,
		isAgentBusy: false,
	};

	const pendingPartials = new Map<string, PendingPartial>();
	let bridge!: LiveBridgeClient;
	let uiPatched = false;

	pi.registerCommand("pimux-debug", {
		description:
			"Run pimux live UI debug helpers like test-confirm, test-select, test-input, test-editor, and test-custom-ui",
		handler: async (args, ctx) => {
			ensureUiPatched(ctx);
			await attachCurrentSession(ctx);

			const [subcommand, ...rest] = args
				.trim()
				.split(/\s+/)
				.filter(Boolean);

			switch (subcommand) {
				case "test-confirm": {
					const prompt =
						rest.join(" ") ||
						"Choose from either the Pi TUI or the iOS app. Does this confirm stay mirrored and resolve correctly?";
					const confirmed = await ctx.ui.confirm("Pimux Live Confirm Test", prompt);
					ctx.ui.notify(
						confirmed ? "pimux confirm test: confirmed" : "pimux confirm test: cancelled",
						"info"
					);
					return;
				}
				case "test-select": {
					const title =
						rest.join(" ") ||
						"Pick an option from either the Pi TUI or the iOS app. Does this select stay mirrored and resolve correctly?";
					const selection = await ctx.ui.select(title, ["Alpha", "Beta", "Gamma"]);
					ctx.ui.notify(
						selection ? `pimux select test: ${selection}` : "pimux select test: cancelled",
						"info"
					);
					return;
				}
				case "test-input": {
					const title = rest.join(" ") || "Type from either the Pi TUI or the iOS app.";
					const value = await ctx.ui.input("Pimux Live Input Test", title);
					ctx.ui.notify(
						value !== undefined ? `pimux input test: ${value}` : "pimux input test: cancelled",
						"info"
					);
					return;
				}
				case "test-editor": {
					const prefill =
						rest.join(" ") ||
						"Edit this text from either the Pi TUI or the iOS app.\n\nDoes this editor stay mirrored and resolve correctly?";
					const value = await ctx.ui.editor("Pimux Live Editor Test", prefill);
					ctx.ui.notify(
						value !== undefined ? `pimux editor test: ${value}` : "pimux editor test: cancelled",
						"info"
					);
					return;
				}
				case "test-custom-ui": {
					const title =
						rest.join(" ") ||
						"This command intentionally opens custom Pi terminal UI. iOS should show a terminal-only banner while the TUI stays interactive.";
					const result = await ctx.ui.custom<string | undefined>((tui, _theme, keybindings, done) => {
						configureMirroredTuiComponent(tui as MirroredDialogTui, keybindings);
						return new ExtensionSelectorComponent(
							title,
							["Finish in terminal", "Cancel"],
							(option) => done(option),
							() => done(undefined),
							{ tui }
						);
					});
					ctx.ui.notify(
						result ? `pimux custom ui test: ${result}` : "pimux custom ui test: cancelled",
						"info"
					);
					return;
				}
				default:
					ctx.ui.notify(
						"Usage: /pimux-debug test-confirm [prompt] or /pimux-debug test-select [title] or /pimux-debug test-input [placeholder] or /pimux-debug test-editor [prefill] or /pimux-debug test-custom-ui [title]",
						"info"
					);
					return;
			}
		},
	});


	pi.registerCommand("pimux", {
		description: "Pimux helpers (usage: /pimux resummarize | update-server)",
		handler: async (args, ctx) => {
			ensureUiPatched(ctx);
			await attachCurrentSession(ctx);

			const [subcommand] = args
				.trim()
				.split(/\s+/)
				.filter(Boolean);

			switch (subcommand) {
				case "resummarize":
					await handlePimuxResummarizeCommand(pi, ctx, publishSnapshot);
					return;
				case "update-server":
					await handlePimuxUpdateServerCommand(ctx);
					return;
				default:
					ctx.ui.notify("Usage: /pimux resummarize | update-server", "info");
					return;
			}
		},
	});

	function bridgeStateSnapshot(): BridgeStateSnapshot {
		const terminalOnlyUi = state.currentTerminalOnlyUi;
		return {
			currentSessionId: state.currentSessionId,
			latestSnapshotMessages: state.latestSnapshotMessages,
			latestMetadata: state.latestMetadata,
			currentAssistantPartial: state.currentAssistantPartial,
			currentUiState: serializeUiState(state.currentUiState),
			currentUiDialogState: state.currentUiDialog?.state,
			currentTerminalOnlyUiState:
				terminalOnlyUi && terminalOnlyUi.sessionId === state.currentSessionId
					? terminalOnlyUi.state
					: undefined,
		};
	}

	function sendCurrentUiState(sessionId: string | undefined = state.currentSessionId) {
		if (!sessionId) return;
		bridge.send({
			type: "uiState",
			sessionId,
			state: serializeUiState(state.currentUiState),
		});
	}

	function clearCurrentUiState(sessionId: string | undefined = state.currentSessionId) {
		if (sessionId) {
			bridge.send({ type: "uiState", sessionId, state: {} });
		}
		state.currentUiState = createEmptyRuntimeUiState();
	}

	function sendCurrentUiDialogState(sessionId: string | undefined = state.currentSessionId) {
		if (!sessionId) return;
		const dialog = state.currentUiDialog;
		bridge.send({
			type: "uiDialogState",
			sessionId,
			state: dialog && dialog.sessionId === sessionId ? dialog.state : null,
		});
	}

	function clearCurrentUiDialogState(sessionId: string | undefined = state.currentSessionId) {
		if (sessionId) {
			bridge.send({ type: "uiDialogState", sessionId, state: null });
		}
		if (!sessionId || state.currentUiDialog?.sessionId === sessionId) {
			state.currentUiDialog = undefined;
		}
	}

	function sendCurrentTerminalOnlyUiState(sessionId: string | undefined = state.currentSessionId) {
		if (!sessionId) return;
		const terminalOnlyUi = state.currentTerminalOnlyUi;
		bridge.send({
			type: "terminalOnlyUiState",
			sessionId,
			state:
				terminalOnlyUi && terminalOnlyUi.sessionId === sessionId ? terminalOnlyUi.state : null,
		});
	}

	function clearCurrentTerminalOnlyUiState(sessionId: string | undefined = state.currentSessionId) {
		if (sessionId) {
			bridge.send({ type: "terminalOnlyUiState", sessionId, state: null });
		}
		if (!sessionId || state.currentTerminalOnlyUi?.sessionId === sessionId) {
			state.currentTerminalOnlyUi = undefined;
		}
	}

	function activateTerminalOnlyUiState(
		sessionId: string,
		terminalOnlyUiState: PimuxTerminalOnlyUiState
	): RuntimeTerminalOnlyUiState {
		const runtimeState = {
			sessionId,
			state: terminalOnlyUiState,
		};
		state.currentTerminalOnlyUi = runtimeState;
		sendCurrentTerminalOnlyUiState(sessionId);
		return runtimeState;
	}

	function cleanupTerminalOnlyUiState(runtimeState: RuntimeTerminalOnlyUiState) {
		if (state.currentTerminalOnlyUi === runtimeState) {
			clearCurrentTerminalOnlyUiState(runtimeState.sessionId);
		}
	}

	async function runWithTerminalOnlyUiState<T>(
		sessionId: string | undefined,
		terminalOnlyUiState: PimuxTerminalOnlyUiState,
		operation: () => Promise<T>
	): Promise<T> {
		if (!sessionId) {
			return await operation();
		}

		const runtimeState = activateTerminalOnlyUiState(sessionId, terminalOnlyUiState);
		try {
			return await operation();
		} finally {
			cleanupTerminalOnlyUiState(runtimeState);
		}
	}

	function activateMirroredUiDialog<T extends RuntimeUiDialog>(dialog: T): T {
		state.currentUiDialog = dialog;
		sendCurrentUiDialogState(dialog.sessionId);
		return dialog;
	}

	function cleanupMirroredUiDialog(dialog: RuntimeUiDialog) {
		if (state.currentUiDialog === dialog && !dialog.finished) {
			clearCurrentUiDialogState(dialog.sessionId);
		}
	}

	function configureMirroredTuiComponent(
		tui: MirroredDialogTui,
		keybindings: Parameters<typeof setKeybindings>[0]
	) {
		setKeybindings(keybindings);
		setKittyProtocolActive(tui.terminal.kittyProtocolActive);
	}

	function setSelectorDialogSelectedIndex(
		dialog: RuntimeUiDialogSelectorState,
		nextIndex: number
	) {
		if (dialog.state.options.length === 0) return;
		const clampedIndex = Math.max(0, Math.min(dialog.state.options.length - 1, nextIndex));
		if (dialog.state.selectedIndex === clampedIndex) return;
		dialog.state.selectedIndex = clampedIndex;
		const selector = dialog.selector as any;
		if (selector) {
			selector.selectedIndex = clampedIndex;
			selector.updateList?.();
		}
		sendCurrentUiDialogState(dialog.sessionId);
	}

	function setTextValueDialogValue(
		dialog: RuntimeTextValueDialog,
		nextValue: string,
		options?: { updateComponent?: boolean }
	) {
		if (dialog.state.value === nextValue) return;
		dialog.state.value = nextValue;
		if (options?.updateComponent !== false) {
			if (isInputDialog(dialog)) {
				const input = dialog.input as any;
				input?.input?.setValue?.(nextValue);
			} else if (isEditorDialog(dialog)) {
				const editor = dialog.editor as any;
				editor?.editor?.setText?.(nextValue);
			}
			dialog.requestRender?.();
		}
		sendCurrentUiDialogState(dialog.sessionId);
	}

	function finishSelectorDialog(dialog: RuntimeConfirmDialog, result: boolean): void;
	function finishSelectorDialog(dialog: RuntimeSelectDialog, result: string | undefined): void;
	function finishSelectorDialog(
		dialog: RuntimeSelectorUiDialog,
		result: boolean | string | undefined
	) {
		if (dialog.finished) return;
		dialog.finished = true;
		(dialog as RuntimeUiDialog).result = result as any;
		if (state.currentUiDialog === dialog) {
			clearCurrentUiDialogState(dialog.sessionId);
		}
		const done = dialog.done as ((result: boolean | string | undefined) => void) | undefined;
		(dialog as RuntimeUiDialog).done = undefined as any;
		done?.(result);
	}

	function finishTextValueDialog(dialog: RuntimeTextValueDialog, result: string | undefined) {
		if (dialog.finished) return;
		dialog.finished = true;
		dialog.result = result;
		if (state.currentUiDialog === dialog) {
			clearCurrentUiDialogState(dialog.sessionId);
		}
		const done = dialog.done;
		dialog.done = undefined;
		done?.(dialog.result);
	}

	function finishCurrentConfirmDialog(
		dialog: RuntimeConfirmDialog,
		result: { confirmed?: boolean; cancelled?: boolean }
	) {
		finishSelectorDialog(dialog, result.cancelled ? false : result.confirmed === true);
	}

	function finishCurrentSelectDialog(
		dialog: RuntimeSelectDialog,
		result: { selected?: string; cancelled?: boolean }
	) {
		finishSelectorDialog(dialog, result.cancelled ? undefined : result.selected);
	}

	function finishCurrentInputDialog(
		dialog: RuntimeInputDialog,
		result: { value?: string; cancelled?: boolean }
	) {
		finishTextValueDialog(dialog, result.cancelled ? undefined : result.value);
	}

	function finishCurrentEditorDialog(
		dialog: RuntimeEditorDialog,
		result: { value?: string; cancelled?: boolean }
	) {
		finishTextValueDialog(dialog, result.cancelled ? undefined : result.value);
	}

	function submitCurrentUiDialog(dialog: RuntimeUiDialog) {
		if (isConfirmDialog(dialog)) {
			finishCurrentConfirmDialog(dialog, {
				confirmed: dialog.state.selectedIndex === 0,
				cancelled: false,
			});
			return;
		}
		if (isSelectDialog(dialog)) {
			finishCurrentSelectDialog(dialog, {
				selected: dialog.state.options[dialog.state.selectedIndex],
				cancelled: false,
			});
			return;
		}
		if (isInputDialog(dialog)) {
			finishCurrentInputDialog(dialog, {
				value: dialog.state.value,
				cancelled: false,
			});
			return;
		}
		if (isEditorDialog(dialog)) {
			finishCurrentEditorDialog(dialog, {
				value: dialog.state.value,
				cancelled: false,
			});
		}
	}

	function cancelUiDialog(dialog: RuntimeUiDialog) {
		if (isConfirmDialog(dialog)) {
			finishCurrentConfirmDialog(dialog, { cancelled: true });
			return;
		}
		if (isSelectDialog(dialog)) {
			finishCurrentSelectDialog(dialog, { cancelled: true });
			return;
		}
		if (isInputDialog(dialog)) {
			finishCurrentInputDialog(dialog, { cancelled: true });
			return;
		}
		if (isEditorDialog(dialog)) {
			finishCurrentEditorDialog(dialog, { cancelled: true });
		}
	}

	function attachSelectorDialogSelector<Result>(
		dialog: RuntimeSelectorDialog<Result, "confirm" | "select">,
		selector: ExtensionSelectorComponent,
		done: (result: Result) => void
	) {
		dialog.selector = selector;
		dialog.done = done;

		const selectorAny = selector as any;
		selectorAny.selectedIndex = dialog.state.selectedIndex;
		selectorAny.updateList?.();

		const originalHandleInput = selector.handleInput.bind(selector);
		selector.handleInput = ((keyData: string) => {
			const before =
				typeof selectorAny.selectedIndex === "number" ? selectorAny.selectedIndex : dialog.state.selectedIndex;
			originalHandleInput(keyData);
			const after = typeof selectorAny.selectedIndex === "number" ? selectorAny.selectedIndex : before;
			if (after !== before) {
				dialog.state.selectedIndex = after;
				sendCurrentUiDialogState(dialog.sessionId);
			}
		}) as typeof selector.handleInput;

		if (dialog.finished) {
			const result = dialog.result;
			dialog.done = undefined;
			done(result);
		}
	}

	function attachInputDialog(
		dialog: RuntimeInputDialog,
		inputComponent: ExtensionInputComponent,
		requestRender: () => void,
		done: (result: string | undefined) => void
	) {
		dialog.input = inputComponent;
		dialog.requestRender = requestRender;
		dialog.done = done;

		const inputAny = inputComponent as any;
		inputAny.input?.setValue?.(dialog.state.value);
		requestRender();

		const originalHandleInput = inputComponent.handleInput.bind(inputComponent);
		inputComponent.handleInput = ((keyData: string) => {
			const before = inputAny.input?.getValue?.() ?? dialog.state.value;
			originalHandleInput(keyData);
			const after = inputAny.input?.getValue?.() ?? before;
			if (after !== before) {
				dialog.state.value = after;
				sendCurrentUiDialogState(dialog.sessionId);
			}
		}) as typeof inputComponent.handleInput;

		if (dialog.finished) {
			const result = dialog.result;
			dialog.done = undefined;
			done(result);
		}
	}

	function attachEditorDialog(
		dialog: RuntimeEditorDialog,
		editorComponent: ExtensionEditorComponent,
		requestRender: () => void,
		done: (result: string | undefined) => void
	) {
		dialog.editor = editorComponent;
		dialog.requestRender = requestRender;
		dialog.done = done;

		const editorAny = editorComponent as any;
		editorAny.editor?.setText?.(dialog.state.value);
		requestRender();

		const originalHandleInput = editorComponent.handleInput.bind(editorComponent);
		editorComponent.handleInput = ((keyData: string) => {
			const before = editorAny.editor?.getExpandedText?.() ?? editorAny.editor?.getText?.() ?? dialog.state.value;
			originalHandleInput(keyData);
			const after = editorAny.editor?.getExpandedText?.() ?? editorAny.editor?.getText?.() ?? before;
			if (after !== before && !dialog.finished) {
				dialog.state.value = after;
				sendCurrentUiDialogState(dialog.sessionId);
			}
		}) as typeof editorComponent.handleInput;

		if (dialog.finished) {
			const result = dialog.result;
			dialog.done = undefined;
			done(result);
		}
	}

	function cancelCurrentUiDialog(sessionId: string | undefined = state.currentSessionId) {
		const dialog = state.currentUiDialog;
		if (!dialog) {
			clearCurrentUiDialogState(sessionId);
			return;
		}
		if (!sessionId || dialog.sessionId === sessionId) {
			cancelUiDialog(dialog);
		}
	}

	function respondToUiDialogActionRequest(requestId: string, sessionId: string, error?: string) {
		bridge.send({ type: "uiDialogActionResult", requestId, sessionId, error });
	}

	function handleUiDialogAction(
		requestId: string,
		sessionId: string,
		dialogId: string,
		action: PimuxUiDialogAction
	) {
		const dialog = state.currentUiDialog;
		if (!dialog || dialog.sessionId !== sessionId) {
			respondToUiDialogActionRequest(requestId, sessionId, `no active ui dialog for session ${sessionId}`);
			return;
		}
		if (dialog.state.id !== dialogId) {
			respondToUiDialogActionRequest(requestId, sessionId, `dialog ${dialogId} is not active for session ${sessionId}`);
			return;
		}

		switch (action.type) {
			case "move":
				if (!isConfirmDialog(dialog) && !isSelectDialog(dialog)) {
					respondToUiDialogActionRequest(requestId, sessionId, `dialog ${dialogId} does not support move`);
					return;
				}
				setSelectorDialogSelectedIndex(
					dialog,
					dialog.state.selectedIndex + (action.direction === "up" ? -1 : 1)
				);
				break;
			case "selectIndex":
				if (!isConfirmDialog(dialog) && !isSelectDialog(dialog)) {
					respondToUiDialogActionRequest(requestId, sessionId, `dialog ${dialogId} does not support selectIndex`);
					return;
				}
				setSelectorDialogSelectedIndex(dialog, action.index);
				break;
			case "setValue":
				if (!isTextValueDialog(dialog)) {
					respondToUiDialogActionRequest(requestId, sessionId, `dialog ${dialogId} does not support setValue`);
					return;
				}
				setTextValueDialogValue(dialog, action.value);
				break;
			case "submit":
				submitCurrentUiDialog(dialog);
				break;
			case "cancel":
				cancelUiDialog(dialog);
				break;
		}

		respondToUiDialogActionRequest(requestId, sessionId);
	}

	function ensureUiPatched(ctx: ExtensionContext) {
		if (uiPatched) return;
		uiPatched = true;

		const ui = ctx.ui;
		const originalCustom = ui.custom.bind(ui) as any;
		const originalSelect = ui.select.bind(ui);
		const originalInput = ui.input.bind(ui);
		const originalEditor = ui.editor.bind(ui);
		const originalConfirm = ui.confirm.bind(ui);
		const originalSetStatus = ui.setStatus.bind(ui);
		const originalSetWidget = ui.setWidget.bind(ui) as (key: string, content: unknown, options?: unknown) => void;
		const originalSetTitle = ui.setTitle.bind(ui);
		const originalSetEditorText = ui.setEditorText.bind(ui);
		const originalPasteToEditor = ui.pasteToEditor.bind(ui);
		const originalSetWorkingMessage = ui.setWorkingMessage.bind(ui);
		const originalSetHiddenThinkingLabel = ui.setHiddenThinkingLabel.bind(ui);

		ui.custom = ((...args: any[]) => {
			const sessionId = state.currentSessionId;
			return runWithTerminalOnlyUiState(
				sessionId,
				{
					kind: "customUi",
					reason:
						"This extension command opened custom terminal UI that pimux iOS can’t render yet. Finish it in the Pi terminal, or interrupt the session.",
				},
				async () => await originalCustom(...args)
			);
		}) as typeof ui.custom;

		ui.select = (async (title: string, options: string[], opts?: UiDialogOptions) => {
			const sessionId = state.currentSessionId;
			if (!sessionId || state.currentUiDialog || options.length === 0) {
				return originalSelect(title, options, opts);
			}
			if (opts?.signal?.aborted) {
				return undefined;
			}

			const dialog: RuntimeSelectDialog = {
				sessionId,
				state: {
					id: `select-${state.nextDialogId++}`,
					kind: "select",
					title,
					message: "",
					options: [...options],
					selectedIndex: 0,
				},
				selector: undefined,
				done: undefined,
				finished: false,
				result: undefined,
			};
			activateMirroredUiDialog(dialog);

			const onAbort = () => {
				finishCurrentSelectDialog(dialog, { cancelled: true });
			};
			opts?.signal?.addEventListener("abort", onAbort, { once: true });

			try {
				return await originalCustom((tui, _theme, keybindings, done) => {
					configureMirroredTuiComponent(tui as MirroredDialogTui, keybindings);

					const selector = new ExtensionSelectorComponent(
						title,
						dialog.state.options,
						(option) => {
							const selectedIndex = dialog.state.options.indexOf(option);
							if (selectedIndex !== -1) {
								setSelectorDialogSelectedIndex(dialog, selectedIndex);
							}
							finishCurrentSelectDialog(dialog, {
								selected: option,
								cancelled: false,
							});
						},
						() => {
							finishCurrentSelectDialog(dialog, { cancelled: true });
						},
						{ tui, timeout: opts?.timeout }
					);
					attachSelectorDialogSelector(dialog, selector, done);
					return selector;
				});
			} finally {
				opts?.signal?.removeEventListener("abort", onAbort);
				cleanupMirroredUiDialog(dialog);
			}
		}) as typeof ui.select;

		ui.input = (async (title: string, placeholder?: string, opts?: UiDialogOptions) => {
			const sessionId = state.currentSessionId;
			if (!sessionId || state.currentUiDialog) {
				return originalInput(title, placeholder, opts);
			}
			if (opts?.signal?.aborted) {
				return undefined;
			}

			const dialog: RuntimeInputDialog = {
				sessionId,
				state: {
					id: `input-${state.nextDialogId++}`,
					kind: "input",
					title,
					message: "",
					options: [],
					selectedIndex: 0,
					placeholder,
					value: "",
				},
				input: undefined,
				requestRender: undefined,
				done: undefined,
				finished: false,
				result: undefined,
			};
			activateMirroredUiDialog(dialog);

			const onAbort = () => {
				finishCurrentInputDialog(dialog, { cancelled: true });
			};
			opts?.signal?.addEventListener("abort", onAbort, { once: true });

			try {
				return await originalCustom((tui, _theme, keybindings, done) => {
					configureMirroredTuiComponent(tui as MirroredDialogTui, keybindings);

					const inputComponent = new ExtensionInputComponent(
						title,
						placeholder,
						(value) => {
							setTextValueDialogValue(dialog, value, { updateComponent: false });
							finishCurrentInputDialog(dialog, {
								value,
								cancelled: false,
							});
						},
						() => {
							finishCurrentInputDialog(dialog, { cancelled: true });
						},
						{ tui, timeout: opts?.timeout }
					);
					attachInputDialog(dialog, inputComponent, () => tui.requestRender(), done);
					return inputComponent;
				});
			} finally {
				opts?.signal?.removeEventListener("abort", onAbort);
				cleanupMirroredUiDialog(dialog);
			}
		}) as typeof ui.input;

		ui.editor = (async (title: string, prefill?: string) => {
			const sessionId = state.currentSessionId;
			if (!sessionId || state.currentUiDialog) {
				return originalEditor(title, prefill);
			}

			const dialog: RuntimeEditorDialog = {
				sessionId,
				state: {
					id: `editor-${state.nextDialogId++}`,
					kind: "editor",
					title,
					message: "",
					options: [],
					selectedIndex: 0,
					value: prefill ?? "",
				},
				editor: undefined,
				requestRender: undefined,
				done: undefined,
				finished: false,
				result: undefined,
			};
			activateMirroredUiDialog(dialog);

			try {
				return await originalCustom((tui, _theme, keybindings, done) => {
					configureMirroredTuiComponent(tui as MirroredDialogTui, keybindings);

					const editorComponent = new ExtensionEditorComponent(
						tui,
						keybindings,
						title,
						prefill,
						(value) => {
							setTextValueDialogValue(dialog, value, { updateComponent: false });
							finishCurrentEditorDialog(dialog, {
								value,
								cancelled: false,
							});
						},
						() => {
							finishCurrentEditorDialog(dialog, { cancelled: true });
						}
					);
					attachEditorDialog(dialog, editorComponent, () => tui.requestRender(), done);
					return editorComponent;
				});
			} finally {
				cleanupMirroredUiDialog(dialog);
			}
		}) as typeof ui.editor;

		ui.confirm = (async (title: string, message: string, opts?: UiDialogOptions) => {
			const sessionId = state.currentSessionId;
			if (!sessionId || state.currentUiDialog) {
				return originalConfirm(title, message, opts);
			}
			if (opts?.signal?.aborted) {
				return false;
			}

			const dialog: RuntimeConfirmDialog = {
				sessionId,
				state: {
					id: `confirm-${state.nextDialogId++}`,
					kind: "confirm",
					title,
					message,
					options: ["Yes", "No"],
					selectedIndex: 0,
				},
				selector: undefined,
				done: undefined,
				finished: false,
				result: false,
			};
			activateMirroredUiDialog(dialog);

			const onAbort = () => {
				finishCurrentConfirmDialog(dialog, { cancelled: true });
			};
			opts?.signal?.addEventListener("abort", onAbort, { once: true });

			try {
				return await originalCustom((tui, _theme, keybindings, done) => {
					configureMirroredTuiComponent(tui as MirroredDialogTui, keybindings);

					const selector = new ExtensionSelectorComponent(
						`${title}\n${message}`,
						dialog.state.options,
						(option) => {
							setSelectorDialogSelectedIndex(dialog, option === "Yes" ? 0 : 1);
							finishCurrentConfirmDialog(dialog, {
								confirmed: option === "Yes",
								cancelled: false,
							});
						},
						() => {
							finishCurrentConfirmDialog(dialog, { cancelled: true });
						},
						{ tui, timeout: opts?.timeout }
					);
					attachSelectorDialogSelector(dialog, selector, done);
					return selector;
				});
			} finally {
				opts?.signal?.removeEventListener("abort", onAbort);
				cleanupMirroredUiDialog(dialog);
			}
		}) as typeof ui.confirm;

		ui.setStatus = ((key: string, text: string | undefined) => {
			originalSetStatus(key, text);
			if (text === undefined) {
				state.currentUiState.statuses.delete(key);
			} else {
				state.currentUiState.statuses.set(key, text);
			}
			sendCurrentUiState();
		}) as typeof ui.setStatus;

		ui.setWidget = ((key: string, content: string[] | undefined, options?: { placement?: PimuxUiWidgetPlacement }) => {
			originalSetWidget(key, content, options);
			if (content === undefined) {
				state.currentUiState.widgets.delete(key);
				sendCurrentUiState();
				return;
			}
			if (!Array.isArray(content)) {
				return;
			}
			state.currentUiState.widgets.set(key, {
				key,
				lines: [...content],
				placement: options?.placement ?? "aboveEditor",
			});
			sendCurrentUiState();
		}) as typeof ui.setWidget;

		ui.setTitle = ((title: string) => {
			originalSetTitle(title);
			state.currentUiState.title = title;
			sendCurrentUiState();
		}) as typeof ui.setTitle;

		ui.setEditorText = ((text: string) => {
			originalSetEditorText(text);
			state.currentUiState.editorText = text;
			sendCurrentUiState();
		}) as typeof ui.setEditorText;

		ui.pasteToEditor = ((text: string) => {
			originalPasteToEditor(text);
			state.currentUiState.editorText = ui.getEditorText();
			sendCurrentUiState();
		}) as typeof ui.pasteToEditor;

		ui.setWorkingMessage = ((message?: string) => {
			originalSetWorkingMessage(message);
			state.currentUiState.workingMessage = message;
			sendCurrentUiState();
		}) as typeof ui.setWorkingMessage;

		ui.setHiddenThinkingLabel = ((label?: string) => {
			originalSetHiddenThinkingLabel(label);
			state.currentUiState.hiddenThinkingLabel = label;
			sendCurrentUiState();
		}) as typeof ui.setHiddenThinkingLabel;
	}

	function respondToSendRequest(requestId: string, sessionId: string, error?: string) {
		bridge.send({ type: "sendUserMessageResult", requestId, sessionId, error });
	}

	function respondToBuiltinCommandRequest(requestId: string, sessionId: string, error?: string) {
		bridge.send({ type: "builtinCommandResult", requestId, sessionId, error });
	}

	function respondToCommandArgumentCompletionsRequest(
		requestId: string,
		sessionId: string,
		completions: PimuxCommandCompletion[],
		error?: string
	) {
		bridge.send({
			type: "getCommandArgumentCompletionsResult",
			requestId,
			sessionId,
			completions,
			error,
		});
	}

	function userMessageContent(
		body: string,
		images: PimuxInputImage[]
	): string | Array<{ type: "text"; text: string } | PimuxInputImage> {
		if (images.length === 0) return body;

		const content: Array<{ type: "text"; text: string } | PimuxInputImage> = [];
		if (body) {
			content.push({ type: "text", text: body });
		}
		content.push(...images);
		return content;
	}

	function dispatchUserMessage(sessionId: string, body: string, images: PimuxInputImage[] = []): string | undefined {
		const extensionRunner = currentExtensionRunner();
		const agentSession = currentAgentSession();
		const activeSessionId =
			state.currentSessionContext?.sessionManager.getSessionId() ||
			agentSession?.sessionManager.getSessionId() ||
			state.currentSessionId;
		if (!activeSessionId || activeSessionId !== sessionId) {
			return `session ${sessionId} is not currently attached in this pi runtime`;
		}

		const trimmedBody = body.trim();
		const spaceIndex = trimmedBody.indexOf(" ");
		const commandName =
			trimmedBody.startsWith("/") && trimmedBody.length > 1
				? (spaceIndex === -1 ? trimmedBody.slice(1) : trimmedBody.slice(1, spaceIndex))
				: undefined;
		const extensionCommand = commandName ? extensionRunner?.getCommand(commandName) : undefined;
		if (extensionCommand) {
			const ctx = extensionRunner?.createCommandContext();
			if (!ctx) {
				return "no live pi command context is available";
			}

			const args = spaceIndex === -1 ? "" : trimmedBody.slice(spaceIndex + 1);
			void Promise.resolve(extensionCommand.handler(args, ctx)).catch((error: unknown) => {
				const message = error instanceof Error ? error.message : String(error);
				ctx.ui.notify(`Failed to execute /${commandName}: ${message}`, "error");
			});
			return;
		}

		if (agentSession && agentSession.sessionManager.getSessionId() === sessionId) {
			void agentSession
				.prompt(body, {
					images: images.length > 0 ? images : undefined,
					streamingBehavior: state.isAgentBusy ? "followUp" : undefined,
				})
				.catch((error: unknown) => {
					const message = error instanceof Error ? error.message : String(error);
					const ctx = state.currentSessionContext;
					if (ctx && ctx.sessionManager.getSessionId() === sessionId) {
						ctx.ui.notify(`Failed to submit input: ${message}`, "error");
						return;
					}
					console.error(`pimux live send failed for session ${sessionId}: ${message}`);
				});
			return;
		}

		if (trimmedBody.startsWith("/")) {
			return "no live pi agent session is available";
		}

		const content = userMessageContent(body, images);
		if (state.isAgentBusy) {
			pi.sendUserMessage(content, { deliverAs: "followUp" });
		} else {
			pi.sendUserMessage(content);
		}
	}

	function handleGetCommands(requestId: string, sessionId: string) {
		try {
			const slashCommands = pi.getCommands();
			const commands: PimuxSessionCommand[] = slashCommands.map((cmd) => ({
				name: cmd.name,
				description: cmd.description,
				source: cmd.source,
			}));
			bridge.send({ type: "getCommandsResult", requestId, sessionId, commands });
		} catch (error) {
			bridge.send({
				type: "getCommandsResult",
				requestId,
				sessionId,
				commands: [],
				error: error instanceof Error ? error.message : String(error),
			});
		}
	}

	function handleGetCommandArgumentCompletions(
		requestId: string,
		sessionId: string,
		commandName: string,
		argumentPrefix: string
	) {
		if (!state.currentSessionId || sessionId !== state.currentSessionId) {
			respondToCommandArgumentCompletionsRequest(
				requestId,
				sessionId,
				[],
				`session ${sessionId} is not currently attached in this pi runtime`
			);
			return;
		}

		try {
			const command =
				currentExtensionRunner()?.getCommand(commandName) ||
				currentAgentSession()?.extensionRunner?.getCommand(commandName);
			const completions = command?.getArgumentCompletions?.(argumentPrefix) ?? [];
			respondToCommandArgumentCompletionsRequest(
				requestId,
				sessionId,
				completions.map((item) => ({
					value: item.value,
					label: item.label,
					description: item.description,
				}))
			);
		} catch (error) {
			respondToCommandArgumentCompletionsRequest(
				requestId,
				sessionId,
				[],
				error instanceof Error ? error.message : String(error)
			);
		}
	}

	async function handleBuiltinCommand(
		requestId: string,
		sessionId: string,
		action: PimuxBuiltinCommandAction
	) {
		if (!state.currentSessionId || sessionId !== state.currentSessionId) {
			respondToBuiltinCommandRequest(
				requestId,
				sessionId,
				`session ${sessionId} is not currently attached in this pi runtime`
			);
			return;
		}

		const ctx = state.currentSessionContext;

		try {
			switch (action.type) {
				case "setSessionName": {
					if (!ctx) {
						respondToBuiltinCommandRequest(
							requestId,
							sessionId,
							`session ${sessionId} is not currently attached in this pi runtime`
						);
						return;
					}

					const name = action.name.trim();
					if (!name) {
						respondToBuiltinCommandRequest(requestId, sessionId, "session name must not be empty");
						return;
					}

					pi.setSessionName(name);
					publishSnapshot(ctx);
					ctx.ui.notify(`Session name set: ${name}`, "info");
					respondToBuiltinCommandRequest(requestId, sessionId);
					return;
				}
				case "compact": {
					if (!ctx) {
						respondToBuiltinCommandRequest(
							requestId,
							sessionId,
							`session ${sessionId} is not currently attached in this pi runtime`
						);
						return;
					}

					const messageCount = ctx.sessionManager
						.getEntries()
						.filter((entry) => entry.type === "message").length;
					if (messageCount < 2) {
						ctx.ui.notify("Nothing to compact (no messages yet)", "warning");
						respondToBuiltinCommandRequest(requestId, sessionId);
						return;
					}

					const customInstructions = action.customInstructions?.trim() || undefined;
					ctx.compact({ customInstructions });
					respondToBuiltinCommandRequest(requestId, sessionId);
					return;
				}
				case "reload": {
					const reload = currentBoundCommandContextActions()?.reload;
					if (!reload) {
						respondToBuiltinCommandRequest(
							requestId,
							sessionId,
							"reload is unavailable because the live pi command context is not initialized"
						);
						return;
					}

					await reload();
					respondToBuiltinCommandRequest(requestId, sessionId);
					return;
				}
			}
		} catch (error) {
			respondToBuiltinCommandRequest(
				requestId,
				sessionId,
				error instanceof Error ? error.message : String(error)
			);
		}
	}

	function handleBridgeCommand(command: AgentToBridgeMessage) {
		if (command.type === "getCommands") {
			handleGetCommands(command.requestId, command.sessionId);
			return;
		}

		if (command.type === "getCommandArgumentCompletions") {
			handleGetCommandArgumentCompletions(
				command.requestId,
				command.sessionId,
				command.commandName,
				command.argumentPrefix
			);
			return;
		}

		if (command.type === "uiDialogAction") {
			handleUiDialogAction(command.requestId, command.sessionId, command.dialogId, command.action);
			return;
		}

		if (command.type === "builtinCommand") {
			void handleBuiltinCommand(command.requestId, command.sessionId, command.action);
			return;
		}

		if (command.type === "interruptSession") {
			if (state.currentSessionId && command.sessionId === state.currentSessionId) {
				process.kill(process.pid, "SIGINT");
			}
			return;
		}

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
		const images = Array.isArray(command.images) ? command.images : [];
		if (!body && images.length === 0) {
			respondToSendRequest(command.requestId, command.sessionId, "message body or images must not both be empty");
			return;
		}

		const error = dispatchUserMessage(command.sessionId, body, images);
		respondToSendRequest(command.requestId, command.sessionId, error);
	}

	bridge = new LiveBridgeClient(resolveSocketPath(), handleBridgeCommand, bridgeStateSnapshot);

	pi.on("session_start", async (_event, ctx) => {
		ensureUiPatched(ctx);
		await attachCurrentSession(ctx);
	});

	pi.on("session_switch", async (_event, ctx) => {
		ensureUiPatched(ctx);
		await attachCurrentSession(ctx);
	});

	pi.on("session_fork", async (_event, ctx) => {
		ensureUiPatched(ctx);
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

		state.currentAssistantPartial = message;
		schedulePartial(sessionId, message);
	});

	pi.on("message_end", async (event, ctx) => {
		const sessionId = ctx.sessionManager.getSessionId();
		if (!sessionId || sessionId !== state.currentSessionId) return;

		const message = agentMessageToPimuxMessage(event.message);
		if (!message) return;

		if (message.role === "assistant") {
			cancelPendingPartial(sessionId);
			state.currentAssistantPartial = undefined;
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
			cancelCurrentUiDialog(state.currentSessionId);
			clearCurrentUiState(state.currentSessionId);
			clearCurrentTerminalOnlyUiState(state.currentSessionId);
			bridge.send({ type: "sessionDetached", sessionId: state.currentSessionId });
			state.currentSessionId = undefined;
			state.currentSessionContext = undefined;
			state.latestSnapshotMessages = [];
			state.latestMetadata = undefined;
			state.currentAssistantPartial = undefined;
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
			cancelCurrentUiDialog(state.currentSessionId);
			clearCurrentUiState(state.currentSessionId);
			clearCurrentTerminalOnlyUiState(state.currentSessionId);
			bridge.send({ type: "sessionDetached", sessionId: state.currentSessionId });
		}

		state.currentSessionId = nextSessionId;
		state.currentSessionContext = ctx;
		state.currentUiState = createEmptyRuntimeUiState();
		state.latestSnapshotMessages = buildSnapshotMessages(ctx);
		state.latestMetadata = buildSessionMetadata(ctx, state.latestSnapshotMessages);
		state.currentAssistantPartial = undefined;
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
		sendCurrentUiState(nextSessionId);
		sendCurrentUiDialogState(nextSessionId);
		sendCurrentTerminalOnlyUiState(nextSessionId);
	}

	function publishSnapshot(ctx: ExtensionContext) {
		const sessionId = ctx.sessionManager.getSessionId();
		if (!sessionId) return;

		state.currentSessionId = sessionId;
		state.currentSessionContext = ctx;
		state.latestSnapshotMessages = buildSnapshotMessages(ctx);
		state.latestMetadata = buildSessionMetadata(ctx, state.latestSnapshotMessages);
		state.currentAssistantPartial = undefined;
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
	const usage = ctx.getContextUsage();
	const contextUsage =
		usage && (typeof usage.tokens === "number" || typeof usage.contextWindow === "number")
			? {
					usedTokens: typeof usage.tokens === "number" ? usage.tokens : undefined,
					maxTokens: typeof usage.contextWindow === "number" ? usage.contextWindow : undefined,
				}
			: undefined;

	return {
		createdAt: toIsoString(header?.timestamp ?? messages[0]?.created_at ?? new Date().toISOString()),
		cwd: ctx.sessionManager.getCwd(),
		summary: namedSummary || fallbackSummary,
		model,
		contextUsage,
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

async function handlePimuxResummarizeCommand(
	pi: ExtensionAPI,
	ctx: ExtensionCommandContext,
	publishSnapshot: (ctx: ExtensionContext) => void
) {
	await ctx.waitForIdle();

	const messages = buildSnapshotMessages(ctx);
	const summaryInput = buildResummarizeInput(messages);
	if (!summaryInput) {
		ctx.ui.notify("No conversation text found to summarize", "warning");
		return;
	}

	const model = await resolveResummarizeModel(ctx);
	if (!model) {
		ctx.ui.notify("No model available to generate a session summary", "warning");
		return;
	}

	const auth = await ctx.modelRegistry.getApiKeyAndHeaders(model);
	if (!auth.ok) {
		ctx.ui.notify(auth.error, "warning");
		return;
	}
	if (!auth.apiKey) {
		ctx.ui.notify(`No API key available for ${model.provider}/${model.id}`, "warning");
		return;
	}

	ctx.ui.notify("Generating session summary…", "info");

	try {
		const response = await complete(
			model,
			{
				messages: [
					{
						role: "user",
						content: [
							{
								type: "text",
								text: buildResummarizePrompt(ctx.sessionManager.getCwd(), summaryInput),
							},
						],
						timestamp: Date.now(),
					},
				],
			},
			{
				apiKey: auth.apiKey,
				headers: auth.headers,
			}
		);

		const summary = normalizeResummarizedTitle(
			response.content
				.filter((block): block is { type: "text"; text: string } => block.type === "text")
				.map((block) => block.text)
				.join("\n")
		);
		if (!summary) {
			ctx.ui.notify("The model returned an empty session summary", "warning");
			return;
		}

		pi.setSessionName(summary);
		publishSnapshot(ctx);
		ctx.ui.notify(`Session summary updated: ${summary}`, "info");
	} catch (error) {
		ctx.ui.notify(
			`Failed to generate session summary: ${error instanceof Error ? error.message : String(error)}`,
			"error"
		);
	}
}

async function handlePimuxUpdateServerCommand(ctx: ExtensionCommandContext) {
	ctx.ui.notify("Checking for pimux updates…", "info");

	try {
		const result = await new Promise<{ stdout: string; stderr: string }>((resolve, reject) => {
			execFile("pimux", ["update"], { timeout: 60_000 }, (error, stdout, stderr) => {
				if (error) {
					reject(Object.assign(error, { stdout, stderr }));
				} else {
					resolve({ stdout, stderr });
				}
			});
		});

		const message = result.stdout.trim() || result.stderr.trim() || "pimux update completed";
		ctx.ui.notify(message, "info");
	} catch (error: any) {
		const message =
			error.stderr?.trim() || error.stdout?.trim() || error.message || String(error);
		ctx.ui.notify(`pimux update failed: ${message}`, "error");
	}
}

async function resolveResummarizeModel(ctx: ExtensionCommandContext) {
	const requested = process.env.PIMUX_SUMMARY_MODEL?.trim();
	if (requested) {
		const [provider, ...rest] = requested.split("/");
		const id = rest.join("/");
		if (provider && id) {
			const configured = ctx.modelRegistry.find(provider, id);
			if (configured) {
				return configured;
			}
		}
	}

	if (ctx.model) {
		return ctx.model;
	}

	ctx.modelRegistry.refresh();
	try {
		const available = await ctx.modelRegistry.getAvailable();
		return available[0];
	} catch {
		return undefined;
	}
}

function buildResummarizeInput(messages: PimuxMessage[]): string | undefined {
	const entries = messages
		.map((message, index) => {
			const role =
				message.role === "user"
					? "User"
					: message.role === "assistant"
						? "Assistant"
						: undefined;
			if (!role) return undefined;

			const text = extractResummarizeMessageText(message);
			if (!text) return undefined;

			return {
				index,
				text: `${role}: ${truncateChars(text, RESUMMARIZE_ENTRY_MAX_CHARS)}`,
			};
		})
		.filter(
			(entry): entry is { index: number; text: string } =>
				Boolean(entry?.text)
		);
	if (entries.length === 0) return undefined;

	const selected = [...entries.slice(0, RESUMMARIZE_EDGE_ENTRY_COUNT)];
	for (const entry of entries.slice(-RESUMMARIZE_EDGE_ENTRY_COUNT)) {
		if (!selected.some((existing) => existing.index === entry.index)) {
			selected.push(entry);
		}
	}

	return selected.map((entry) => entry.text).join("\n\n");
}

function extractResummarizeMessageText(message: PimuxMessage): string | undefined {
	const blockText = (message.blocks ?? [])
		.filter((block) => block.type === "text" && typeof block.text === "string")
		.map((block) => block.text ?? "")
		.join(" ");
	const collapsedBlocks = collapseWhitespace(blockText);
	if (collapsedBlocks) return collapsedBlocks;

	const collapsedBody = collapseWhitespace(message.body);
	return collapsedBody || undefined;
}

function buildResummarizePrompt(cwd: string, summaryInput: string): string {
	return [
		"Summarize what this coding session is currently about in a single short title.",
		"",
		"Rules:",
		"- Focus on the concrete coding task or topic",
		"- Prefer the current or latest task over earlier work",
		"- Ignore meta phrasing like 'Let's work this out together', 'keep planning', or 'start implementing'",
		"- Plain text only",
		"- No quotes",
		"- No markdown",
		"- No trailing punctuation",
		"- Keep it under 60 characters if possible",
		"",
		`Session cwd: ${cwd}`,
		"",
		"Recent conversation:",
		summaryInput,
		"",
		"Title:",
	].join("\n");
}

function normalizeResummarizedTitle(summary: string): string | undefined {
	const firstLine = summary
		.split(/\r?\n/)
		.map((line) => line.trim())
		.find(Boolean);
	if (!firstLine) return undefined;

	const normalized = collapseWhitespace(firstLine)
		.replace(/^-\s+/, "")
		.replace(/^['"`]+/, "")
		.replace(/['"`]+$/, "")
		.replace(/[.!?;:]+$/, "")
		.trim();
	if (!normalized) return undefined;

	return truncateChars(normalized, RESUMMARIZE_TITLE_MAX_CHARS);
}

function buildSnapshotMessages(ctx: ExtensionContext): PimuxMessage[] {
	const branch = ctx.sessionManager.getBranch();
	return branch
		.map((entry: any) => entryToPimuxMessage(entry))
		.filter((message): message is PimuxMessage => Boolean(message));
}

function entryToPimuxMessage(entry: any): PimuxMessage | undefined {
	const message = entryToPimuxMessageContent(entry);
	if (message && typeof entry?.id === "string") {
		message.messageId = entry.id;
	}
	return message;
}

function entryToPimuxMessageContent(entry: any): PimuxMessage | undefined {
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
				contentToBlocks(message.content, false),
				typeof message.toolName === "string" ? collapseWhitespace(message.toolName) : undefined
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

function pimuxMessageFromBlocks(
	created_at: string,
	role: PimuxRole,
	blocks: PimuxMessageBlock[],
	toolName?: string
): PimuxMessage | undefined {
	const normalizedBlocks = blocks
		.map(normalizeBlock)
		.filter((block): block is PimuxMessageBlock => Boolean(block));
	if (normalizedBlocks.length === 0) return undefined;

	return {
		created_at,
		role,
		body: bodyFromBlocks(role, normalizedBlocks),
		toolName: toolName || undefined,
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
			const text = normalizeDisplayText(block.text);
			return text ? { type: "toolCall", toolCallName, text } : { type: "toolCall", toolCallName };
		}
		case "image": {
			const mimeType = normalizeMimeType(block.mimeType);
			const data = normalizeImageData(block.data);
			if (!data) return mimeType ? { type: "image", mimeType } : { type: "image" };
			return mimeType ? { type: "image", mimeType, data } : { type: "image", data };
		}
		default:
			return undefined;
	}
}

function bodyFromBlocks(role: PimuxRole, blocks: PimuxMessageBlock[]): string {
	const parts = blocks.flatMap((block) => {
		if (block.type === "text" && block.text) return [block.text];
		if (role === "assistant" && block.type === "toolCall" && block.toolCallName) {
			return [`Tool call: ${block.toolCallName}`];
		}
		return [];
	});
	if (parts.length > 0) {
		return parts.join("\n\n");
	}

	const imageCount = blocks.filter((block) => block.type === "image").length;
	if (imageCount === 1) return "[Image]";
	if (imageCount > 1) return `[${imageCount} images]`;
	return "";
}

function toolCallSummary(toolName: string, args: any): string | undefined {
	if (!args || typeof args !== "object" || Array.isArray(args)) return undefined;

	switch (toolName) {
		case "read": {
			if (typeof args.path !== "string") return undefined;
			let summary = args.path;
			const options: string[] = [];
			if (typeof args.offset === "number") options.push(`offset=${args.offset}`);
			if (typeof args.limit === "number") options.push(`limit=${args.limit}`);
			if (options.length > 0) summary += ` (${options.join(", ")})`;
			return normalizeDisplayText(summary);
		}
		case "bash": {
			if (typeof args.command !== "string") return undefined;
			let summary = `$ ${args.command}`;
			if (typeof args.timeout === "number") summary += `\n\ntimeout: ${args.timeout}s`;
			return normalizeDisplayText(summary);
		}
		case "edit": {
			if (typeof args.path !== "string") return undefined;
			const lines = [args.path];
			if (Array.isArray(args.edits)) {
				lines.push(`${args.edits.length} ${args.edits.length === 1 ? "edit" : "edits"}`);
			} else if (typeof args.oldText === "string" || typeof args.newText === "string") {
				lines.push("single replacement");
			}
			return normalizeDisplayText(lines.join("\n\n"));
		}
		case "write": {
			if (typeof args.path !== "string") return undefined;
			const lines = [args.path];
			if (typeof args.content === "string") {
				lines.push(`${Math.max(args.content.split("\n").length, 1)} lines`);
			}
			return normalizeDisplayText(lines.join("\n\n"));
		}
		case "mcp": {
			const lines: string[] = [];
			for (const key of ["tool", "server", "connect", "describe", "search", "action"]) {
				if (typeof args[key] === "string" && args[key].trim()) {
					lines.push(`${key}: ${args[key].trim()}`);
				}
			}
			if (typeof args.args === "string" && args.args.trim()) {
				lines.push(`args: ${truncateSummary(args.args, 500)}`);
			}
			if (lines.length > 0) return lines.join("\n");
			return prettyJsonSummary(args);
		}
		case "multi_tool_use.parallel": {
			if (!Array.isArray(args.tool_uses)) return undefined;
			const count = args.tool_uses.length;
			return `${count} parallel ${count === 1 ? "tool call" : "tool calls"}`;
		}
		default:
			return prettyJsonSummary(args);
	}
}

function prettyJsonSummary(value: any): string | undefined {
	try {
		const pretty = JSON.stringify(value, null, 2);
		return normalizeDisplayText(truncateSummary(pretty, 2000));
	} catch {
		return undefined;
	}
}

function truncateSummary(value: string, maxChars: number): string {
	const chars = [...value];
	if (chars.length <= maxChars) return value;
	return `${chars.slice(0, maxChars).join("")}…`;
}

function contentToBlocks(content: any, includeToolCalls: boolean): PimuxMessageBlock[] {
	if (typeof content === "string") {
		const text = normalizeDisplayText(content);
		return text ? [{ type: "text", text }] : [];
	}

	if (!Array.isArray(content)) return [];

	return content
		.map((block): PimuxMessageBlock | undefined => {
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
					if (!toolCallName) return undefined;
					const text = toolCallSummary(toolCallName, block.arguments);
					return text
						? ({ type: "toolCall", toolCallName, text } satisfies PimuxMessageBlock)
						: ({ type: "toolCall", toolCallName } satisfies PimuxMessageBlock);
				}
				case "image": {
					const mimeType = normalizeMimeType(block.mimeType);
					const data = normalizeImageData(block.data);
					if (mimeType && data) return { type: "image", mimeType, data } satisfies PimuxMessageBlock;
					if (mimeType) return { type: "image", mimeType } satisfies PimuxMessageBlock;
					if (data) return { type: "image", data } satisfies PimuxMessageBlock;
					return { type: "image" } satisfies PimuxMessageBlock;
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

	const metadata: string[] = [];
	if (typeof message.exitCode === "number") metadata.push(`exit code: ${message.exitCode}`);
	if (message.cancelled === true) metadata.push("cancelled");
	if (message.truncated === true) metadata.push("truncated");
	if (typeof message.fullOutputPath === "string") {
		const path = normalizeDisplayText(message.fullOutputPath);
		if (path) metadata.push(`full output: ${path}`);
	}
	if (metadata.length > 0) parts.push(metadata.join("\n"));

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

function normalizeMimeType(value: unknown): string {
	if (typeof value !== "string") return "";
	return value.trim().toLowerCase();
}

function normalizeImageData(value: unknown): string {
	if (typeof value !== "string") return "";
	return value.replace(/\s+/g, "");
}

function truncateChars(value: string, maxChars: number): string {
	const chars = Array.from(value);
	if (chars.length <= maxChars) return value;
	return `${chars.slice(0, maxChars).join("")}…`;
}

function createEmptyRuntimeUiState(): RuntimeUiState {
	return {
		statuses: new Map(),
		widgets: new Map(),
		title: undefined,
		editorText: undefined,
		workingMessage: undefined,
		hiddenThinkingLabel: undefined,
	};
}

function serializeUiState(state: RuntimeUiState): PimuxUiState {
	const serialized: PimuxUiState = {};
	if (state.statuses.size > 0) {
		serialized.statuses = Object.fromEntries(state.statuses.entries());
	}
	if (state.widgets.size > 0) {
		serialized.widgets = Array.from(state.widgets.values()).sort((left, right) => left.key.localeCompare(right.key));
	}
	if (state.title !== undefined) serialized.title = state.title;
	if (state.editorText !== undefined) serialized.editorText = state.editorText;
	if (state.workingMessage !== undefined) serialized.workingMessage = state.workingMessage;
	if (state.hiddenThinkingLabel !== undefined) {
		serialized.hiddenThinkingLabel = state.hiddenThinkingLabel;
	}
	return serialized;
}

function resolveSocketPath(): string {
	const agentDir = process.env.PI_CODING_AGENT_DIR || join(homedir(), ".pi", "agent");
	return join(agentDir, "pimux", "live.sock");
}
