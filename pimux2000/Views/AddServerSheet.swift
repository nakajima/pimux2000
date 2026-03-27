import SwiftUI

struct AddServerSheet: View {
	@Environment(\.appDatabase) private var appDatabase
	@Environment(\.dismiss) private var dismiss
	@State private var sshTarget = ""
	@State private var sshPassword = ""
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
					#if os(iOS)
					.textInputAutocapitalization(.never)
					#endif
					.autocorrectionDisabled()

				SecureField("Password (optional)", text: $sshPassword)
					.textContentType(.password)
			} footer: {
				Text("The SSH target for the remote machine. If you enter a password, it will be used for SSH during install/update and not stored. If left blank, the app will try SSH without a password first.")
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
				Group {
					if installer.isComplete {
						HStack {
							Label("Server running", systemImage: "checkmark.circle.fill")
								.foregroundStyle(.green)
							Spacer()
							Button("Done") {
								Task { await saveAndDismiss() }
							}
							.buttonStyle(.borderedProminent)
						}
					} else if installer.error != nil {
						VStack(alignment: .leading, spacing: 12) {
							HStack {
								Label("Failed", systemImage: "xmark.circle.fill")
									.foregroundStyle(.red)
								Spacer()
								Button("Retry") {
									Task { await connect() }
								}
								.buttonStyle(.bordered)
							}

							SecureField("SSH password", text: $sshPassword)
								.textContentType(.password)
							Text("If the SSH server requires a password, enter it and retry. The password is not stored.")
								.font(.caption)
								.foregroundStyle(.secondary)
						}
					} else {
						HStack {
							ProgressView()
								.controlSize(.small)
							Text("Installing...")
								.foregroundStyle(.secondary)
							Spacer()
						}
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

		let password = sshPassword.isEmpty ? nil : sshPassword
		let inst = ServerInstaller(sshTarget: trimmed, sshPassword: password)
		self.installer = inst
		phase = .checking

		let serverAlreadyRunning = await inst.checkServerRunning()

		phase = .installing
		await inst.install(updatingExistingServer: serverAlreadyRunning)
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
