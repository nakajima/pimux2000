import SwiftUI

// MARK: - Data types

enum TranscriptMessage: Identifiable {
	case confirmed(MessageInfo)
	case pending(PendingLocalMessage)

	var id: String {
		switch self {
		case .confirmed(let info):
			return info.id
		case .pending(let msg):
			return "pending-\(msg.id.uuidString)"
		}
	}

	var fingerprint: UInt64 {
		switch self {
		case .confirmed(let info):
			return info.contentFingerprint
		case .pending(let msg):
			return TranscriptFingerprint.make { fp in
				fp.combine("pending")
				fp.combine(msg.normalizedBody)
			}
		}
	}
}

enum TranscriptEmptyState: Equatable {
	case loading
	case error(String)
	case empty
}

// MARK: - iOS implementation

#if canImport(UIKit) && !os(macOS)
import UIKit

struct SessionTranscriptView: UIViewRepresentable {
	let messages: [TranscriptMessage]
	let sessionID: String
	let serverURL: String?
	let emptyState: TranscriptEmptyState?
	var forcePinToken: Int = 0
	var onRetry: (() -> Void)? = nil
	var onOpenMessageContext: ((MessageContextRoute) -> Void)? = nil
	var onScrollOffsetChanged: ((CGFloat) -> Void)? = nil

	func makeCoordinator() -> Coordinator {
		Coordinator(parent: self)
	}

	func makeUIView(context: Context) -> UITableView {
		let tableView = UITableView(frame: .zero, style: .plain)
		tableView.transform = CGAffineTransform(scaleX: 1, y: -1)
		tableView.dataSource = context.coordinator
		tableView.delegate = context.coordinator
		tableView.separatorStyle = .none
		tableView.backgroundColor = .clear
		tableView.keyboardDismissMode = .interactive
		tableView.alwaysBounceVertical = true
		tableView.contentInset.top = 16
		tableView.showsVerticalScrollIndicator = true
		tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
		return tableView
	}

	func updateUIView(_ tableView: UITableView, context: Context) {
		context.coordinator.update(parent: self, tableView: tableView)
	}

	// MARK: - Coordinator

	final class Coordinator: NSObject, UITableViewDataSource, UITableViewDelegate {
		private var parent: SessionTranscriptView
		private var messages: [TranscriptMessage] = []
		private var lastForcePinToken: Int = 0

		init(parent: SessionTranscriptView) {
			self.parent = parent
			super.init()
		}

		func update(parent: SessionTranscriptView, tableView: UITableView) {
			let shouldForcePin = parent.forcePinToken != lastForcePinToken
			lastForcePinToken = parent.forcePinToken
			self.parent = parent
			let newMessages = parent.messages.reversed() as [TranscriptMessage]

			if newMessages.map(\.id) != messages.map(\.id) ||
				newMessages.map(\.fingerprint) != messages.map(\.fingerprint) {
				let savedOffset = tableView.contentOffset
				messages = newMessages
				UIView.performWithoutAnimation {
					tableView.reloadData()
					if shouldForcePin {
						if !messages.isEmpty {
							tableView.scrollToRow(at: IndexPath(row: 0, section: 0), at: .bottom, animated: false)
						}
					} else {
						tableView.contentOffset = savedOffset
					}
				}
			} else if shouldForcePin, !messages.isEmpty {
				tableView.scrollToRow(at: IndexPath(row: 0, section: 0), at: .bottom, animated: true)
			}

			updateEmptyState(on: tableView)
		}

		// MARK: UITableViewDataSource

		func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
			messages.count
		}

		func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
			let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
			guard messages.indices.contains(indexPath.row) else { return cell }

			cell.transform = CGAffineTransform(scaleX: 1, y: -1)
			let message = messages[indexPath.row]
			let ctx = renderContext
			cell.contentConfiguration = UIHostingConfiguration {
				TranscriptRowSwiftUIView(message: message, context: ctx)
					.transaction { $0.animation = nil }
			}
			.margins(.all, 0)
			cell.backgroundColor = .clear
			cell.selectionStyle = .none
			return cell
		}

		// MARK: UITableViewDelegate

		func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
			guard let tableView = scrollView as? UITableView, !messages.isEmpty else { return false }
			let lastRow = IndexPath(row: messages.count - 1, section: 0)
			tableView.scrollToRow(at: lastRow, at: .bottom, animated: true)
			return false
		}

		func scrollViewDidScroll(_ scrollView: UIScrollView) {
			let normalized = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
			parent.onScrollOffsetChanged?(normalized)
		}

		// MARK: Empty state

		private func updateEmptyState(on tableView: UITableView) {
			if messages.isEmpty, let emptyState = parent.emptyState {
				if !(tableView.backgroundView is TranscriptEmptyStateView) {
					let view = TranscriptEmptyStateView(state: emptyState, onRetry: parent.onRetry)
					view.transform = CGAffineTransform(scaleX: 1, y: -1)
					tableView.backgroundView = view
				}
			} else {
				tableView.backgroundView = nil
			}
		}

		// MARK: Render context

		private var renderContext: TranscriptRenderContext {
			TranscriptRenderContext(
				sessionID: parent.sessionID,
				serverURL: parent.serverURL,
				onOpenMessageContext: parent.onOpenMessageContext
			)
		}
	}
}

// MARK: - Layout constants

private enum TranscriptLayout {
	static let horizontalInset: CGFloat = 16
	static let verticalInset: CGFloat = 8
	static let imageSize = CGSize(width: 320, height: 240)
}

// MARK: - Render context

struct TranscriptRenderContext {
	let sessionID: String
	let serverURL: String?
	let onOpenMessageContext: ((MessageContextRoute) -> Void)?
}

// MARK: - SwiftUI row view

private struct TranscriptRowSwiftUIView: View {
	let message: TranscriptMessage
	let context: TranscriptRenderContext

	var body: some View {
		Group {
			switch message {
			case .confirmed(let messageInfo):
				TranscriptMessageView(
					messageInfo: messageInfo,
					sessionID: context.sessionID,
					serverURL: context.serverURL
				)
			case .pending(let pendingMessage):
				PendingLocalMessageView(message: pendingMessage)
			}
		}
		.padding(.horizontal, TranscriptLayout.horizontalInset)
		.padding(.vertical, TranscriptLayout.verticalInset)
	}
}


private final class TranscriptEmptyStateView: UIView {
	init(state: TranscriptEmptyState, onRetry: (() -> Void)?) {
		super.init(frame: .zero)

		let stack = UIStackView()
		stack.translatesAutoresizingMaskIntoConstraints = false
		stack.axis = .vertical
		stack.alignment = .center
		stack.spacing = 12
		addSubview(stack)

		let icon = UIImageView()
		icon.translatesAutoresizingMaskIntoConstraints = false
		icon.tintColor = .secondaryLabel
		stack.addArrangedSubview(icon)

		switch state {
		case .loading:
			icon.image = UIImage(systemName: "ellipsis.circle")
			let spinner = UIActivityIndicatorView(style: .medium)
			spinner.startAnimating()
			stack.addArrangedSubview(spinner)
			stack.addArrangedSubview(makeLabel("Loading messages…", style: .body, color: .secondaryLabel, alignment: .center))
		case .error(let message):
			icon.image = UIImage(systemName: "exclamationmark.triangle")
			icon.tintColor = .systemOrange
			stack.addArrangedSubview(makeLabel("Couldn't Load Messages", style: .headline, color: .label, alignment: .center))
			stack.addArrangedSubview(makeLabel(message, style: .body, color: .secondaryLabel, alignment: .center))
			if let onRetry {
				let button = UIButton(type: .system)
				button.translatesAutoresizingMaskIntoConstraints = false
				button.setTitle("Retry", for: .normal)
				button.addAction(UIAction { _ in onRetry() }, for: .touchUpInside)
				stack.addArrangedSubview(button)
			}
		case .empty:
			icon.image = UIImage(systemName: "text.bubble")
			stack.addArrangedSubview(makeLabel("No messages yet", style: .body, color: .secondaryLabel, alignment: .center))
		}

		NSLayoutConstraint.activate([
			stack.centerXAnchor.constraint(equalTo: centerXAnchor),
			stack.centerYAnchor.constraint(equalTo: centerYAnchor),
			stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 20),
			stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),
		])
	}

	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}
}

// MARK: - Helpers for empty state view

private func makeLabel(_ text: String, style: UIFont.TextStyle, color: UIColor, alignment: NSTextAlignment = .natural) -> UILabel {
	let label = UILabel()
	label.translatesAutoresizingMaskIntoConstraints = false
	label.font = UIFont.preferredFont(forTextStyle: style)
	label.adjustsFontForContentSizeCategory = true
	label.textColor = color
	label.textAlignment = alignment
	label.numberOfLines = 0
	label.text = text
	return label
}

// MARK: - Preview

#Preview("iOS transcript") {
	let messages: [TranscriptMessage] = [
		.confirmed(
			MessageInfo(
				message: Message(id: 1, piSessionID: 1, role: .user, toolName: nil, position: 0, createdAt: Date()),
				contentBlocks: [
					MessageContentBlock(id: 1, messageID: 1, type: "text", text: "Can you make the transcript stable on iOS?", toolCallName: nil, position: 0),
				]
			)
		),
		.confirmed(
			MessageInfo(
				message: Message(id: 2, piSessionID: 1, role: .assistant, toolName: nil, position: 1, createdAt: Date()),
				contentBlocks: [
					MessageContentBlock(id: 2, messageID: 2, type: "text", text: "Yes \u{2014} the transcript now uses **UIHostingConfiguration** with the same SwiftUI views as macOS.", toolCallName: nil, position: 0),
					MessageContentBlock(id: 3, messageID: 2, type: "toolCall", text: "xcodebuild test", toolCallName: "bash", position: 1),
				]
			)
		),
		.pending(PendingLocalMessage(body: "Please keep it boring and stable.", confirmedUserMessageBaseline: 1)),
	]

	return NavigationStack {
		SessionTranscriptView(messages: messages, sessionID: "preview-session", serverURL: nil, emptyState: nil, onOpenMessageContext: { _ in })
			.background(.background)
	}
}
#endif
