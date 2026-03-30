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
	var onRefresh: (() async -> Void)? = nil
	var onRetry: (() -> Void)? = nil
	var onOpenMessageContext: ((MessageContextRoute) -> Void)? = nil

	func makeCoordinator() -> Coordinator {
		Coordinator(parent: self)
	}

	func makeUIView(context: Context) -> TranscriptTableView {
		let tableView = TranscriptTableView(frame: .zero, style: .plain)
		context.coordinator.attach(to: tableView)
		return tableView
	}

	func updateUIView(_ tableView: TranscriptTableView, context: Context) {
		context.coordinator.update(parent: self, tableView: tableView)
	}

	// MARK: - Coordinator

	final class Coordinator: NSObject, UITableViewDataSource, UITableViewDelegate {
		private static let initialWindowSize = 50
		private static let pageSize = 30
		private static let nearBottomThreshold: CGFloat = 24
		private static let loadOlderThreshold: CGFloat = 300

		private var parent: SessionTranscriptView
		private var currentSessionID: String
		private var allMessages: [TranscriptMessage] = []
		private var windowStart: Int = 0
		private var visibleMessages: [TranscriptMessage] = []
		private var visibleFingerprints: [String: UInt64] = [:]
		private var isPinnedToBottom = true
		private var lastForcePinToken = 0
		private var isAdjustingScroll = false
		private weak var refreshControl: UIRefreshControl?

		init(parent: SessionTranscriptView) {
			self.parent = parent
			self.currentSessionID = parent.sessionID
			super.init()
		}

		func attach(to tableView: TranscriptTableView) {
			tableView.dataSource = self
			tableView.delegate = self
			tableView.separatorStyle = .none
			tableView.backgroundColor = .clear
			tableView.rowHeight = UITableView.automaticDimension
			tableView.estimatedRowHeight = 80
			tableView.keyboardDismissMode = .interactive
			tableView.alwaysBounceVertical = true
			tableView.register(TranscriptRowCell.self, forCellReuseIdentifier: TranscriptRowCell.reuseIdentifier)
			tableView.scrollToBottomAction = { [weak self, weak tableView] in
				guard let self, let tableView else { return }
				self.scrollToBottom(tableView)
			}
			configureRefreshControl(for: tableView)
		}

		// MARK: Update

		func update(parent: SessionTranscriptView, tableView: TranscriptTableView) {
			if parent.sessionID != currentSessionID {
				resetForNewSession(parent: parent, tableView: tableView)
				return
			}

			self.parent = parent
			configureRefreshControl(for: tableView)
			updateEmptyState(on: tableView)

			let forcePinRequested = parent.forcePinToken != lastForcePinToken
			if forcePinRequested {
				lastForcePinToken = parent.forcePinToken
				isPinnedToBottom = true
			}

			let newAll = parent.messages
			let oldAll = allMessages
			allMessages = newAll

			guard !newAll.isEmpty else {
				if !visibleMessages.isEmpty {
					visibleMessages = []
					visibleFingerprints = [:]
					windowStart = 0
					UIView.performWithoutAnimation { tableView.reloadData() }
				}
				return
			}

			if oldAll.isEmpty {
				windowStart = max(0, newAll.count - Self.initialWindowSize)
				visibleMessages = Array(newAll[windowStart...])
				visibleFingerprints = buildFingerprintMap(visibleMessages)
				UIView.performWithoutAnimation { tableView.reloadData() }
				requestScrollToBottom(tableView)
				return
			}

			let oldVisibleIDs = visibleMessages.map(\.id)
			windowStart = min(windowStart, max(0, newAll.count - 1))
			let newVisible = Array(newAll[windowStart...])
			let newVisibleIDs = newVisible.map(\.id)

			if !oldVisibleIDs.isEmpty, newVisibleIDs.starts(with: oldVisibleIDs) {
				let appendCount = newVisibleIDs.count - oldVisibleIDs.count
				if appendCount > 0 {
					visibleMessages = newVisible
					visibleFingerprints = buildFingerprintMap(visibleMessages)
					let paths = (oldVisibleIDs.count..<newVisibleIDs.count).map { IndexPath(row: $0, section: 0) }
					UIView.performWithoutAnimation {
						tableView.insertRows(at: paths, with: .none)
					}
					if isPinnedToBottom || forcePinRequested {
						requestScrollToBottom(tableView)
					}
				} else {
					reloadChangedRows(old: visibleMessages, new: newVisible, tableView: tableView)
					if (isPinnedToBottom || forcePinRequested), hasLastRowContentChanged(old: visibleMessages, new: newVisible) {
						stickyScrollToBottom(tableView)
					}
				}
			} else {
				reloadPreservingPosition(newVisible: newVisible, tableView: tableView, forcePinRequested: forcePinRequested)
			}
		}

		private func resetForNewSession(parent: SessionTranscriptView, tableView: TranscriptTableView) {
			self.parent = parent
			currentSessionID = parent.sessionID
			allMessages = parent.messages
			windowStart = max(0, allMessages.count - Self.initialWindowSize)
			visibleMessages = allMessages.isEmpty ? [] : Array(allMessages[windowStart...])
			visibleFingerprints = buildFingerprintMap(visibleMessages)
			isPinnedToBottom = true
			lastForcePinToken = parent.forcePinToken
			isAdjustingScroll = false
			UIView.performWithoutAnimation { tableView.reloadData() }
			updateEmptyState(on: tableView)
			if !visibleMessages.isEmpty {
				requestScrollToBottom(tableView)
			}
		}

		// MARK: Diffing helpers

		private func buildFingerprintMap(_ messages: [TranscriptMessage]) -> [String: UInt64] {
			Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0.fingerprint) })
		}

		private func reloadChangedRows(old: [TranscriptMessage], new: [TranscriptMessage], tableView: UITableView) {
			var reloadPaths: [IndexPath] = []
			let newFP = buildFingerprintMap(new)
			for (index, msg) in old.enumerated() {
				if let newFingerprint = newFP[msg.id], newFingerprint != msg.fingerprint {
					reloadPaths.append(IndexPath(row: index, section: 0))
				}
			}
			guard !reloadPaths.isEmpty else { return }
			visibleMessages = new
			visibleFingerprints = newFP
			UIView.performWithoutAnimation {
				tableView.reloadRows(at: reloadPaths, with: .none)
			}
		}

		private func hasLastRowContentChanged(old: [TranscriptMessage], new: [TranscriptMessage]) -> Bool {
			guard let oldLast = old.last, let newLast = new.last else { return false }
			return oldLast.id == newLast.id && oldLast.fingerprint != newLast.fingerprint
		}

		private func reloadPreservingPosition(newVisible: [TranscriptMessage], tableView: TranscriptTableView, forcePinRequested: Bool) {
			let anchor = captureAnchor(in: tableView)
			visibleMessages = newVisible
			visibleFingerprints = buildFingerprintMap(newVisible)
			UIView.performWithoutAnimation { tableView.reloadData() }
			if isPinnedToBottom || forcePinRequested {
				requestScrollToBottom(tableView)
			} else if let anchor {
				restoreAnchor(anchor, in: tableView)
			}
		}

		// MARK: Scroll anchor

		private struct ScrollAnchor {
			let messageID: String
			let offsetFromTop: CGFloat
		}

		private func captureAnchor(in tableView: UITableView) -> ScrollAnchor? {
			guard let firstVisiblePath = tableView.indexPathsForVisibleRows?.first,
				visibleMessages.indices.contains(firstVisiblePath.row),
				let cell = tableView.cellForRow(at: firstVisiblePath) else {
				return nil
			}
			let offset = cell.frame.origin.y - tableView.contentOffset.y
			return ScrollAnchor(messageID: visibleMessages[firstVisiblePath.row].id, offsetFromTop: offset)
		}

		private func restoreAnchor(_ anchor: ScrollAnchor, in tableView: UITableView) {
			guard let index = visibleMessages.firstIndex(where: { $0.id == anchor.messageID }) else { return }
			tableView.layoutIfNeeded()
			let rect = tableView.rectForRow(at: IndexPath(row: index, section: 0))
			let targetOffset = rect.origin.y - anchor.offsetFromTop
			let maxOffset = tableView.contentSize.height - tableView.bounds.height + tableView.adjustedContentInset.bottom
			let minOffset = -tableView.adjustedContentInset.top
			tableView.contentOffset.y = min(maxOffset, max(minOffset, targetOffset))
		}

		// MARK: Prepend older messages

		private func loadOlderMessages(_ tableView: UITableView) {
			guard windowStart > 0 else { return }

			let oldStart = windowStart
			let newStart = max(0, oldStart - Self.pageSize)
			guard newStart < oldStart else { return }

			let oldContentHeight = tableView.contentSize.height
			let oldOffset = tableView.contentOffset

			windowStart = newStart
			let prependedMessages = Array(allMessages[newStart..<oldStart])
			visibleMessages = prependedMessages + visibleMessages
			visibleFingerprints = buildFingerprintMap(visibleMessages)

			let insertCount = oldStart - newStart
			let paths = (0..<insertCount).map { IndexPath(row: $0, section: 0) }

			isAdjustingScroll = true
			UIView.performWithoutAnimation {
				tableView.insertRows(at: paths, with: .none)
				tableView.layoutIfNeeded()
			}
			let heightDelta = tableView.contentSize.height - oldContentHeight
			tableView.contentOffset = CGPoint(x: oldOffset.x, y: oldOffset.y + heightDelta)
			isAdjustingScroll = false
		}

		// MARK: Scroll

		private func scrollToBottom(_ tableView: UITableView) {
			let lastRow = tableView.numberOfRows(inSection: 0) - 1
			guard lastRow >= 0 else { return }
			tableView.scrollToRow(at: IndexPath(row: lastRow, section: 0), at: .bottom, animated: false)
		}

		/// Keeps the viewport pinned to the bottom edge when the last
		/// row's content is growing (e.g. streaming blocks). Unlike
		/// `scrollToRow` this works even when we're already at the last
		/// row but its height increased after a reload.
		private func stickyScrollToBottom(_ tableView: UITableView) {
			let maxOffset = tableView.contentSize.height - tableView.bounds.height + tableView.adjustedContentInset.bottom
			guard maxOffset > -tableView.adjustedContentInset.top else { return }
			tableView.contentOffset = CGPoint(x: 0, y: maxOffset)
		}

		/// Scrolls to bottom immediately if layout is ready, otherwise
		/// defers to the next layoutSubviews pass where geometry is valid.
		private func requestScrollToBottom(_ tableView: TranscriptTableView) {
			if tableView.bounds.height > 0 && tableView.contentSize.height > 0 {
				scrollToBottom(tableView)
			}
			tableView.pendingScrollToBottom = true
			tableView.setNeedsLayout()
		}

		// MARK: UITableViewDataSource

		func numberOfSections(in tableView: UITableView) -> Int { 1 }

		func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
			visibleMessages.count
		}

		func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
			guard let cell = tableView.dequeueReusableCell(withIdentifier: TranscriptRowCell.reuseIdentifier, for: indexPath) as? TranscriptRowCell,
				visibleMessages.indices.contains(indexPath.row) else {
				return UITableViewCell()
			}
			cell.configure(message: visibleMessages[indexPath.row], context: renderContext)
			return cell
		}

		// MARK: UIScrollViewDelegate

		func scrollViewDidScroll(_ scrollView: UIScrollView) {
			guard !isAdjustingScroll else { return }

			if scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating {
				let bottomDistance = scrollView.contentSize.height - scrollView.contentOffset.y - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
				isPinnedToBottom = bottomDistance <= Self.nearBottomThreshold
			}

			if let tableView = scrollView as? UITableView,
				scrollView.contentOffset.y < Self.loadOlderThreshold,
				windowStart > 0 {
				loadOlderMessages(tableView)
			}
		}

		// MARK: Refresh control

		@objc
		private func refreshControlChanged() {
			guard let onRefresh = parent.onRefresh else {
				refreshControl?.endRefreshing()
				return
			}
			Task {
				await onRefresh()
				await MainActor.run { self.refreshControl?.endRefreshing() }
			}
		}

		private func configureRefreshControl(for tableView: UITableView) {
			guard parent.onRefresh != nil else {
				tableView.refreshControl = nil
				refreshControl = nil
				return
			}
			if refreshControl == nil {
				let control = UIRefreshControl()
				control.addTarget(self, action: #selector(refreshControlChanged), for: .valueChanged)
				tableView.refreshControl = control
				refreshControl = control
			}
		}

		// MARK: Empty state

		private func updateEmptyState(on tableView: UITableView) {
			if visibleMessages.isEmpty, let emptyState = parent.emptyState {
				if tableView.backgroundView == nil || !(tableView.backgroundView is TranscriptEmptyStateView) {
					tableView.backgroundView = TranscriptEmptyStateView(state: emptyState, onRetry: parent.onRetry)
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

private struct TranscriptRenderContext {
	let sessionID: String
	let serverURL: String?
	let onOpenMessageContext: ((MessageContextRoute) -> Void)?
}

// MARK: - Table view

final class TranscriptTableView: UITableView {
	var pendingScrollToBottom = false
	var scrollToBottomAction: (() -> Void)?

	override func layoutSubviews() {
		super.layoutSubviews()
		if pendingScrollToBottom, bounds.height > 0, contentSize.height > 0 {
			pendingScrollToBottom = false
			scrollToBottomAction?()
		}
	}
}

// MARK: - Cell

private final class TranscriptRowCell: UITableViewCell {
	static let reuseIdentifier = "TranscriptRowCell"

	private var hostedRowView: UIView?
	private var hostedConstraints: [NSLayoutConstraint] = []

	override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
		super.init(style: style, reuseIdentifier: reuseIdentifier)
		selectionStyle = .none
		backgroundColor = .clear
		contentView.backgroundColor = .clear
	}

	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override func prepareForReuse() {
		super.prepareForReuse()
		hostedRowView?.removeFromSuperview()
		hostedRowView = nil
		NSLayoutConstraint.deactivate(hostedConstraints)
		hostedConstraints.removeAll()
	}

	func configure(message: TranscriptMessage, context: TranscriptRenderContext) {
		hostedRowView?.removeFromSuperview()
		NSLayoutConstraint.deactivate(hostedConstraints)
		hostedConstraints.removeAll()

		let view = makeView(for: message, context: context)
		view.translatesAutoresizingMaskIntoConstraints = false
		contentView.addSubview(view)
		hostedConstraints = [
			view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
			view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
			view.topAnchor.constraint(equalTo: contentView.topAnchor),
			view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
		]
		NSLayoutConstraint.activate(hostedConstraints)
		hostedRowView = view
	}

	private func makeView(for message: TranscriptMessage, context: TranscriptRenderContext) -> UIView {
		switch message {
		case .confirmed(let messageInfo):
			return TranscriptInsetContainerView(
				content: TranscriptMessageRowView(messageInfo: messageInfo, sessionID: context.sessionID, serverURL: context.serverURL, onOpenMessageContext: context.onOpenMessageContext),
				verticalInset: TranscriptLayout.verticalInset
			)
		case .pending(let pendingMessage):
			return TranscriptInsetContainerView(
				content: TranscriptPendingMessageRowView(message: pendingMessage),
				verticalInset: TranscriptLayout.verticalInset
			)
		}
	}
}

// MARK: - Row views

private final class TranscriptInsetContainerView: UIView {
	init(content: UIView, verticalInset: CGFloat = TranscriptLayout.verticalInset) {
		super.init(frame: .zero)
		translatesAutoresizingMaskIntoConstraints = false
		backgroundColor = .clear
		content.translatesAutoresizingMaskIntoConstraints = false
		addSubview(content)
		NSLayoutConstraint.activate([
			content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: TranscriptLayout.horizontalInset),
			content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -TranscriptLayout.horizontalInset),
			content.topAnchor.constraint(equalTo: topAnchor, constant: verticalInset),
			content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -verticalInset),
		])
	}

	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
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

private final class TranscriptPendingMessageRowView: UIView {
	init(message: PendingLocalMessage) {
		super.init(frame: .zero)
		translatesAutoresizingMaskIntoConstraints = false

		let stack = UIStackView()
		stack.translatesAutoresizingMaskIntoConstraints = false
		stack.axis = .vertical
		stack.alignment = .fill
		stack.spacing = 6
		addSubview(stack)

		let header = UIStackView()
		header.translatesAutoresizingMaskIntoConstraints = false
		header.axis = .horizontal
		header.alignment = .center
		header.spacing = 6
		stack.addArrangedSubview(header)

		let icon = UIImageView(image: UIImage(systemName: "clock.fill"))
		icon.translatesAutoresizingMaskIntoConstraints = false
		icon.tintColor = .secondaryLabel
		header.addArrangedSubview(icon)
		header.addArrangedSubview(makeUppercaseLabel("You", color: .secondaryLabel))
		header.addArrangedSubview(makeLabel("· Pending", style: .caption1, color: .secondaryLabel))
		header.addArrangedSubview(UIView())

		let bodyLabel = makeMessageTextLabel(text: message.body, role: .user)
		bodyLabel.alpha = 0.55
		stack.addArrangedSubview(bodyLabel)

		NSLayoutConstraint.activate([
			stack.leadingAnchor.constraint(equalTo: leadingAnchor),
			stack.trailingAnchor.constraint(equalTo: trailingAnchor),
			stack.topAnchor.constraint(equalTo: topAnchor),
			stack.bottomAnchor.constraint(equalTo: bottomAnchor),
		])
	}

	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}
}

private final class TranscriptMessageRowView: UIView {
	init(messageInfo: MessageInfo, sessionID: String, serverURL: String?, onOpenMessageContext: ((MessageContextRoute) -> Void)?) {
		super.init(frame: .zero)
		translatesAutoresizingMaskIntoConstraints = false

		let root = UIStackView()
		root.translatesAutoresizingMaskIntoConstraints = false
		root.axis = .horizontal
		root.alignment = .top
		root.spacing = 12
		addSubview(root)

		let role = messageInfo.message.role
		let iconView = UIImageView(image: UIImage(systemName: roleIcon(for: role)))
		iconView.translatesAutoresizingMaskIntoConstraints = false
		iconView.tintColor = roleColor(for: role)
		iconView.setContentHuggingPriority(.required, for: .horizontal)
		iconView.setContentCompressionResistancePriority(.required, for: .horizontal)
		root.addArrangedSubview(iconView)
		NSLayoutConstraint.activate([
			iconView.widthAnchor.constraint(equalToConstant: 20),
			iconView.heightAnchor.constraint(equalToConstant: 20),
		])

		let bodyStack = UIStackView()
		bodyStack.translatesAutoresizingMaskIntoConstraints = false
		bodyStack.axis = .vertical
		bodyStack.alignment = .fill
		bodyStack.spacing = 6
		root.addArrangedSubview(bodyStack)

		let header = UIStackView()
		header.translatesAutoresizingMaskIntoConstraints = false
		header.axis = .horizontal
		header.alignment = .center
		header.spacing = 6
		bodyStack.addArrangedSubview(header)

		header.addArrangedSubview(makeUppercaseLabel(roleLabel(for: role), color: roleColor(for: role)))
		if let toolName = messageInfo.message.toolName {
			header.addArrangedSubview(makeLabel("· \(toolName)", style: .caption1, color: .secondaryLabel))
		}
		header.addArrangedSubview(UIView())

		let messageTitle = messageTitle(for: messageInfo.message)
		for block in messageInfo.contentBlocks {
			let view = makeBlockView(
				block: block,
				messageRole: role,
				messageTitle: messageTitle,
				attachmentURL: attachmentURL(for: block, sessionID: sessionID, serverURL: serverURL),
				onOpenMessageContext: onOpenMessageContext
			)
			bodyStack.addArrangedSubview(view)
		}

		NSLayoutConstraint.activate([
			root.leadingAnchor.constraint(equalTo: leadingAnchor),
			root.trailingAnchor.constraint(equalTo: trailingAnchor),
			root.topAnchor.constraint(equalTo: topAnchor),
			root.bottomAnchor.constraint(equalTo: bottomAnchor),
		])
	}

	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}
}

// MARK: - Block views

private func makeBlockView(
	block: MessageContentBlock,
	messageRole: Message.Role,
	messageTitle: String,
	attachmentURL: URL?,
	onOpenMessageContext: ((MessageContextRoute) -> Void)?
) -> UIView {
	switch block.type {
	case "text":
		guard let text = block.text, !text.isEmpty else { return UIView() }
		return makeTranscriptTextBlock(text: text, role: messageRole, title: messageTitle, color: .label, onOpenMessageContext: onOpenMessageContext)
	case "thinking":
		guard let text = block.text, !text.isEmpty else { return UIView() }
		let label = makeMessageTextLabel(text: text, role: messageRole, style: .callout)
		label.font = UIFontMetrics(forTextStyle: .callout).scaledFont(for: .italicSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .callout).pointSize))
		label.textColor = .secondaryLabel
		return label
	case "toolCall":
		return TranscriptToolCallBlockView(block: block, messageTitle: messageTitle, onOpenMessageContext: onOpenMessageContext)
	case "image":
		if let attachmentURL {
			return TranscriptImageBlockView(url: attachmentURL, mimeType: block.mimeType, attachmentID: block.attachmentID)
		}
		return TranscriptPillView(text: "Image", systemImage: "photo", foregroundColor: .secondaryLabel, backgroundColor: .secondarySystemFill)
	default:
		guard let text = block.text, !text.isEmpty else { return UIView() }
		return makeTranscriptTextBlock(text: text, role: messageRole, title: messageTitle, color: .secondaryLabel, onOpenMessageContext: onOpenMessageContext)
	}
}

private func makeTranscriptTextBlock(
	text: String,
	role: Message.Role,
	title: String,
	color: UIColor,
	onOpenMessageContext: ((MessageContextRoute) -> Void)?
) -> UIView {
	let collapsed = MessageMarkdownRenderer.shouldCollapsePreview(for: text, role: role)
	let stack = UIStackView()
	stack.translatesAutoresizingMaskIntoConstraints = false
	stack.axis = .vertical
	stack.alignment = .fill
	stack.spacing = 10

	let label = makeMessageTextLabel(text: collapsed ? MessageMarkdownRenderer.previewText(for: text) : text, role: role)
	label.textColor = color
	stack.addArrangedSubview(label)

	if collapsed, let onOpenMessageContext {
		let button = makeContextButton {
			onOpenMessageContext(MessageContextRoute(title: title, text: text, role: role))
		}
		stack.addArrangedSubview(button)
	}

	return stack
}

private final class TranscriptToolCallBlockView: UIView {
	init(block: MessageContentBlock, messageTitle: String, onOpenMessageContext: ((MessageContextRoute) -> Void)?) {
		super.init(frame: .zero)
		translatesAutoresizingMaskIntoConstraints = false

		let stack = UIStackView()
		stack.translatesAutoresizingMaskIntoConstraints = false
		stack.axis = .vertical
		stack.alignment = .fill
		stack.spacing = 8
		addSubview(stack)

		let pill = TranscriptPillView(text: block.toolCallName ?? "unknown tool", systemImage: "terminal.fill", foregroundColor: .systemTeal, backgroundColor: UIColor.systemTeal.withAlphaComponent(0.12))
		stack.addArrangedSubview(pill)

		if let text = block.text, !text.isEmpty {
			let collapsed = shouldCollapseCodeLikeContent(text)
			let details = TranscriptCodeBackgroundView(content: makeCodeLabel(text: collapsed ? MessageMarkdownRenderer.previewText(for: text) : text))
			stack.addArrangedSubview(details)

			if collapsed, let onOpenMessageContext {
				let title = "\(messageTitle) · \(block.toolCallName ?? "Tool Call")"
				stack.addArrangedSubview(makeContextButton {
					onOpenMessageContext(MessageContextRoute(title: title, text: text, role: .toolResult))
				})
			}
		}

		NSLayoutConstraint.activate([
			stack.leadingAnchor.constraint(equalTo: leadingAnchor),
			stack.trailingAnchor.constraint(equalTo: trailingAnchor),
			stack.topAnchor.constraint(equalTo: topAnchor),
			stack.bottomAnchor.constraint(equalTo: bottomAnchor),
		])
	}

	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}
}

private final class TranscriptPillView: UIView {
	init(text: String, systemImage: String, foregroundColor: UIColor, backgroundColor: UIColor) {
		super.init(frame: .zero)
		translatesAutoresizingMaskIntoConstraints = false

		let imageView = UIImageView(image: UIImage(systemName: systemImage))
		imageView.translatesAutoresizingMaskIntoConstraints = false
		imageView.tintColor = foregroundColor
		imageView.setContentHuggingPriority(.required, for: .horizontal)
		imageView.setContentCompressionResistancePriority(.required, for: .horizontal)

		let label = UILabel()
		label.translatesAutoresizingMaskIntoConstraints = false
		label.font = UIFont.preferredFont(forTextStyle: .caption1)
		label.adjustsFontForContentSizeCategory = true
		label.textColor = foregroundColor
		label.numberOfLines = 0
		label.text = text

		let stack = UIStackView(arrangedSubviews: [imageView, label])
		stack.translatesAutoresizingMaskIntoConstraints = false
		stack.axis = .horizontal
		stack.alignment = .center
		stack.spacing = 8

		layer.cornerRadius = 10
		self.backgroundColor = backgroundColor
		addSubview(stack)

		NSLayoutConstraint.activate([
			stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
			stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
			stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
			stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
		])
	}

	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}
}

private final class TranscriptCodeBackgroundView: UIView {
	init(content: UIView) {
		super.init(frame: .zero)
		translatesAutoresizingMaskIntoConstraints = false
		layer.cornerRadius = 8
		backgroundColor = UIColor.systemTeal.withAlphaComponent(0.08)
		content.translatesAutoresizingMaskIntoConstraints = false
		addSubview(content)
		NSLayoutConstraint.activate([
			content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
			content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
			content.topAnchor.constraint(equalTo: topAnchor, constant: 8),
			content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
		])
	}

	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}
}

private final class TranscriptImageBlockView: UIView {
	private static let imageCache = NSCache<NSURL, UIImage>()

	private let imageView = UIImageView()
	private let placeholderStack = UIStackView()
	private var task: URLSessionDataTask?

	init(url: URL, mimeType: String?, attachmentID: String?) {
		super.init(frame: .zero)
		translatesAutoresizingMaskIntoConstraints = false

		layer.cornerRadius = 10
		clipsToBounds = true
		backgroundColor = .secondarySystemFill

		imageView.translatesAutoresizingMaskIntoConstraints = false
		imageView.contentMode = .scaleAspectFit
		imageView.isHidden = true
		addSubview(imageView)

		placeholderStack.translatesAutoresizingMaskIntoConstraints = false
		placeholderStack.axis = .vertical
		placeholderStack.alignment = .leading
		placeholderStack.spacing = 6
		addSubview(placeholderStack)

		placeholderStack.addArrangedSubview(makeLabel("Loading image…", style: .callout, color: .secondaryLabel))
		if let mimeType, !mimeType.isEmpty {
			placeholderStack.addArrangedSubview(makeLabel(mimeType, style: .caption1, color: .secondaryLabel))
		}
		if let attachmentID, !attachmentID.isEmpty {
			placeholderStack.addArrangedSubview(makeLabel(attachmentID, style: .caption2, color: .tertiaryLabel))
		}

		NSLayoutConstraint.activate([
			widthAnchor.constraint(equalToConstant: TranscriptLayout.imageSize.width),
			heightAnchor.constraint(equalToConstant: TranscriptLayout.imageSize.height),
			imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
			imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
			imageView.topAnchor.constraint(equalTo: topAnchor),
			imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
			placeholderStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
			placeholderStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
			placeholderStack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
		])

		if let cachedImage = Self.imageCache.object(forKey: url as NSURL) {
			show(image: cachedImage)
		} else {
			load(url: url)
		}
	}

	deinit {
		task?.cancel()
	}

	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	private func load(url: URL) {
		task?.cancel()
		task = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
			guard let self, let data, let image = UIImage(data: data) else { return }
			Self.imageCache.setObject(image, forKey: url as NSURL)
			DispatchQueue.main.async {
				self.show(image: image)
			}
		}
		task?.resume()
	}

	private func show(image: UIImage) {
		imageView.image = image
		imageView.isHidden = false
		placeholderStack.isHidden = true
	}
}

// MARK: - Helper functions

private func makeContextButton(action: @escaping () -> Void) -> UIButton {
	let button = UIButton(type: .system)
	button.translatesAutoresizingMaskIntoConstraints = false
	button.contentHorizontalAlignment = .leading
	button.setTitle("View full context", for: .normal)
	button.addAction(UIAction { _ in action() }, for: .touchUpInside)
	return button
}

private func makeMessageTextLabel(text: String, role: Message.Role, style: UIFont.TextStyle = .body) -> UILabel {
	let label = UILabel()
	label.translatesAutoresizingMaskIntoConstraints = false
	label.numberOfLines = 0
	label.text = text
	label.font = messageFont(for: role, style: style)
	label.adjustsFontForContentSizeCategory = true
	label.textColor = .label
	return label
}

private func makeCodeLabel(text: String) -> UILabel {
	let label = UILabel()
	label.translatesAutoresizingMaskIntoConstraints = false
	label.numberOfLines = 0
	label.text = text
	label.font = UIFont.monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .regular)
	label.adjustsFontForContentSizeCategory = true
	label.textColor = .secondaryLabel
	return label
}

private func makeUppercaseLabel(_ text: String, color: UIColor) -> UILabel {
	let label = UILabel()
	label.translatesAutoresizingMaskIntoConstraints = false
	label.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(for: .systemFont(ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .semibold))
	label.adjustsFontForContentSizeCategory = true
	label.textColor = color
	label.text = text.uppercased()
	return label
}

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

private func messageFont(for role: Message.Role, style: UIFont.TextStyle) -> UIFont {
	switch role {
	case .toolResult, .bashExecution:
		return UIFont.monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: style).pointSize, weight: .regular)
	default:
		return UIFont.preferredFont(forTextStyle: style)
	}
}

private func shouldCollapseCodeLikeContent(_ text: String) -> Bool {
	let lineCount = text.components(separatedBy: .newlines).count
	return lineCount > 10 || text.count > 900
}

private func roleLabel(for role: Message.Role) -> String {
	switch role {
	case .user: return "You"
	case .assistant: return "Assistant"
	case .toolResult: return "Tool Result"
	case .bashExecution: return "Bash"
	case .custom: return "Custom"
	case .branchSummary: return "Branch Summary"
	case .compactionSummary: return "Summary"
	case .other(let value): return value
	}
}

private func roleIcon(for role: Message.Role) -> String {
	switch role {
	case .user: return "person.fill"
	case .assistant: return "sparkles"
	case .toolResult: return "wrench.fill"
	case .bashExecution: return "terminal.fill"
	case .custom: return "square.stack.3d.up.fill"
	case .branchSummary: return "arrow.triangle.branch"
	case .compactionSummary: return "archivebox.fill"
	case .other: return "ellipsis.circle"
	}
}

private func roleColor(for role: Message.Role) -> UIColor {
	switch role {
	case .user: return .systemBlue
	case .assistant: return .systemPurple
	case .toolResult: return .systemOrange
	case .bashExecution: return .systemTeal
	case .custom: return .systemIndigo
	case .branchSummary: return .systemGreen
	case .compactionSummary: return .systemBrown
	case .other: return .secondaryLabel
	}
}

private func messageTitle(for message: Message) -> String {
	if let toolName = message.toolName {
		return "\(roleLabel(for: message.role)) · \(toolName)"
	}
	return roleLabel(for: message.role)
}

private func attachmentURL(for block: MessageContentBlock, sessionID: String, serverURL: String?) -> URL? {
	guard block.type == "image",
		let attachmentID = block.attachmentID,
		!attachmentID.isEmpty,
		let serverURL
	else {
		return nil
	}

	do {
		let client = try PimuxServerClient(baseURL: serverURL)
		return client.attachmentURL(sessionID: sessionID, attachmentID: attachmentID)
	} catch {
		return nil
	}
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
					MessageContentBlock(id: 2, messageID: 2, type: "text", text: "Yes — the iOS transcript now uses a windowed UITableView with anchor-preserving prepend.", toolCallName: nil, position: 0),
					MessageContentBlock(id: 3, messageID: 2, type: "toolCall", text: "xcodebuild -scheme pimux2000 -destination 'platform=iOS Simulator,id=1234' test", toolCallName: "bash", position: 1),
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
