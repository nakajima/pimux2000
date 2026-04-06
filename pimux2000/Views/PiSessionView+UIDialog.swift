import SwiftUI

// MARK: - UI Dialog Management

extension PiSessionView {
	func moveUIDialogSelection(by delta: Int) async {
		guard delta != 0 else { return }
		guard !isUIDialogActionInFlight else { return }
		guard let dialog = currentUIDialog, dialog.isSelectorDialog, !dialog.options.isEmpty else { return }
		guard let pimuxServerClient else {
			uiDialogActionError = "No pimux server configured."
			return
		}

		let newIndex = max(0, min(dialog.selectedIndex + delta, dialog.options.count - 1))
		guard newIndex != dialog.selectedIndex else { return }

		currentUIDialog = dialog.settingSelectedIndex(newIndex)
		uiDialogActionError = nil

		do {
			try await pimuxServerClient.sendUIDialogAction(
				sessionID: session.sessionID,
				dialogID: dialog.id,
				action: PimuxSessionUIDialogAction.move(direction: delta < 0 ? "up" : "down")
			)
		} catch {
			currentUIDialog = dialog
			uiDialogActionError = error.localizedDescription
		}
	}

	func submitUIDialogSelection() async {
		guard let dialog = currentUIDialog, dialog.isSelectorDialog else { return }
		await chooseUIDialogOption(dialog.selectedIndex)
	}

	func chooseUIDialogOption(_ index: Int) async {
		guard let dialog = currentUIDialog, dialog.isSelectorDialog else { return }
		guard let pimuxServerClient else {
			uiDialogActionError = "No pimux server configured."
			return
		}

		isUIDialogActionInFlight = true
		uiDialogActionError = nil
		defer { isUIDialogActionInFlight = false }

		do {
			if dialog.selectedIndex != index {
				currentUIDialog = dialog.settingSelectedIndex(index)
				try await pimuxServerClient.sendUIDialogAction(
					sessionID: session.sessionID,
					dialogID: dialog.id,
					action: PimuxSessionUIDialogAction.selectIndex(index: index)
				)
			}
			try await pimuxServerClient.sendUIDialogAction(
				sessionID: session.sessionID,
				dialogID: dialog.id,
				action: PimuxSessionUIDialogAction.submit
			)
		} catch {
			uiDialogActionError = error.localizedDescription
		}
	}

	func updateUIDialogTextValue(_ value: String) {
		guard let dialog = currentUIDialog, dialog.isTextValueDialog else { return }
		guard dialog.resolvedTextValue != value else { return }
		currentUIDialog = dialog.settingTextValue(value)
		uiDialogActionError = nil
		uiDialogValueSyncTask?.cancel()

		guard let pimuxServerClient else {
			uiDialogActionError = "No pimux server configured."
			uiDialogValueSyncTask = nil
			return
		}

		let sessionID = session.sessionID
		let dialogID = dialog.id
		uiDialogValueSyncTask = Task {
			do {
				try await Task.sleep(for: .milliseconds(150))
				try await pimuxServerClient.sendUIDialogAction(
					sessionID: sessionID,
					dialogID: dialogID,
					action: PimuxSessionUIDialogAction.setValue(value: value)
				)
			} catch is CancellationError {
				return
			} catch {
				guard !Task.isCancelled else { return }
				await MainActor.run {
					if currentUIDialog?.id == dialogID {
						uiDialogActionError = error.localizedDescription
					}
				}
			}
		}
	}

	func submitUIDialogTextValue() async {
		guard let dialog = currentUIDialog, dialog.isTextValueDialog else { return }
		guard let pimuxServerClient else {
			uiDialogActionError = "No pimux server configured."
			return
		}

		uiDialogValueSyncTask?.cancel()
		uiDialogValueSyncTask = nil
		isUIDialogActionInFlight = true
		uiDialogActionError = nil
		defer { isUIDialogActionInFlight = false }

		do {
			try await pimuxServerClient.sendUIDialogAction(
				sessionID: session.sessionID,
				dialogID: dialog.id,
				action: PimuxSessionUIDialogAction.setValue(value: dialog.value ?? "")
			)
			try await pimuxServerClient.sendUIDialogAction(
				sessionID: session.sessionID,
				dialogID: dialog.id,
				action: PimuxSessionUIDialogAction.submit
			)
		} catch {
			uiDialogActionError = error.localizedDescription
		}
	}

	func applyIncomingUIDialogState(_ state: PimuxSessionUIDialogState?) {
		let previousDialog = currentUIDialog
		let shouldPreserveOptimisticTextValue =
			previousDialog?.id == state?.id
				&& previousDialog?.isTextValueDialog == true
				&& state?.isTextValueDialog == true
				&& (uiDialogValueSyncTask != nil || isUIDialogActionInFlight)

		if shouldPreserveOptimisticTextValue, let state, let previousDialog {
			currentUIDialog = state.settingTextValue(previousDialog.resolvedTextValue)
		} else {
			uiDialogValueSyncTask?.cancel()
			uiDialogValueSyncTask = nil
			currentUIDialog = state
		}

		if state == nil || state?.id != previousDialog?.id {
			isUIDialogActionInFlight = false
		}
		uiDialogActionError = nil
	}

	func uiDialogTextBinding(for dialog: PimuxSessionUIDialogState) -> Binding<String> {
		Binding(
			get: {
				guard let currentUIDialog, currentUIDialog.id == dialog.id else {
					return dialog.resolvedTextValue
				}
				return currentUIDialog.resolvedTextValue
			},
			set: { updateUIDialogTextValue($0) }
		)
	}

	func cancelUIDialog() async {
		guard let dialog = currentUIDialog else { return }
		guard let pimuxServerClient else {
			uiDialogActionError = "No pimux server configured."
			return
		}

		uiDialogValueSyncTask?.cancel()
		uiDialogValueSyncTask = nil
		isUIDialogActionInFlight = true
		uiDialogActionError = nil
		defer { isUIDialogActionInFlight = false }

		do {
			try await pimuxServerClient.sendUIDialogAction(
				sessionID: session.sessionID,
				dialogID: dialog.id,
				action: PimuxSessionUIDialogAction.cancel
			)
		} catch {
			uiDialogActionError = error.localizedDescription
		}
	}
}
