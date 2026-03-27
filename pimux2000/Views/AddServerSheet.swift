import SwiftUI

struct AddServerSheet: View {
	@Environment(\.appDatabase) private var appDatabase
	@Environment(\.dismiss) private var dismiss
	@State private var sshTarget = ""
	@State private var installer: ServerInstaller?
	@State private var phase: Phase = .input

	enum Phase {
		case input
		case checking
		case installing
		case done
	}

	var body: some View {
		NavigationStack {
			Group {
				switch phase {
				case .input:
					inputView
				case .checking:
					checkingView
				case .installing, .done:
					installLogView
				}
			}
			.navigationTitle("Add Server")
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button("Cancel") { dismiss() }
						.disabled(phase == .checking || (phase == .installing && installer?.isRunning == true))
				}
			}
		}
	}

	// MARK: - Input

	private var inputView: some View {
		Form {
			Section {
				TextField("user@host", text: $sshTarget)
					.textInputAutocapitalization(.never)
					.autocorrectionDisabled()
			} footer: {
				Text("The SSH target for the remote machine. A pimux2000 server will be set up automatically if one isn't running.")
			}

			Section {
				Button("Connect") {
					Task { await connect() }
				}
				.disabled(sshTarget.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
			}
		}
	}

	// MARK: - Checking

	private var checkingView: some View {
		ContentUnavailableView {
			ProgressView()
		} description: {
			Text("Checking for running server...")
		}
	}

	// MARK: - Install log

	private var installLogView: some View {
		VStack(spacing: 0) {
			ScrollViewReader { proxy in
				ScrollView {
					LazyVStack(alignment: .leading, spacing: 4) {
						if let installer {
							ForEach(Array(installer.logLines.enumerated()), id: \.offset) { index, line in
								Text(line)
									.font(.system(.caption, design: .monospaced))
									.foregroundStyle(line.hasPrefix("Error:") ? .red : .primary)
									.id(index)
							}
						}
					}
					.padding()
				}
				.onChange(of: installer?.logLines.count) {
					if let count = installer?.logLines.count, count > 0 {
						withAnimation {
							proxy.scrollTo(count - 1, anchor: .bottom)
						}
					}
				}
			}

			Divider()

			if let installer {
				HStack {
					if installer.isComplete {
						Label("Server running", systemImage: "checkmark.circle.fill")
							.foregroundStyle(.green)
						Spacer()
						Button("Done") {
							Task { await saveAndDismiss() }
						}
						.buttonStyle(.borderedProminent)
					} else if installer.error != nil {
						Label("Failed", systemImage: "xmark.circle.fill")
							.foregroundStyle(.red)
						Spacer()
						Button("Retry") {
							Task { await installer.install() }
						}
						.buttonStyle(.bordered)
					} else {
						ProgressView()
							.controlSize(.small)
						Text("Installing...")
							.foregroundStyle(.secondary)
						Spacer()
					}
				}
				.padding()
			}
		}
	}

	// MARK: - Actions

	private func connect() async {
		let trimmed = sshTarget.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return }

		let inst = ServerInstaller(sshTarget: trimmed)
		self.installer = inst
		phase = .checking

		// Try connecting to existing server first
		if await inst.checkServerRunning() {
			// Server already running — just save the host
			do {
				try appDatabase?.addHost(sshTarget: trimmed)
				dismiss()
			} catch {
				inst.error = error.localizedDescription
				phase = .installing
			}
			return
		}

		// No server running — install it
		phase = .installing
		await inst.install()
		if inst.isComplete {
			phase = .done
		}
	}

	private func saveAndDismiss() async {
		let trimmed = sshTarget.trimmingCharacters(in: .whitespacesAndNewlines)
		try? appDatabase?.addHost(sshTarget: trimmed)
		dismiss()
	}
}

#Preview {
	AddServerSheet()
		.environment(\.appDatabase, AppDatabase.preview())
}
