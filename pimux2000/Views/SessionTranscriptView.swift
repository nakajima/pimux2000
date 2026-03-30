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

	func makeUIView(context: Context) -> TranscriptCollectionView {
		var listConfig = UICollectionLayoutListConfiguration(appearance: .plain)
		listConfig.showsSeparators = false
		listConfig.backgroundColor = .clear
		let layout = UICollectionViewCompositionalLayout.list(using: listConfig)

		let collectionView = TranscriptCollectionView(frame: .zero, collectionViewLayout: layout)
		context.coordinator.attach(to: collectionView)
		return collectionView
	}

	func updateUIView(_ collectionView: TranscriptCollectionView, context: Context) {
		context.coordinator.update(parent: self, collectionView: collectionView)
	}

	// MARK: - Coordinator

	final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegate {
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
		private var lastForcePinToken = 0
		private var isAdjustingScroll = false
		private weak var refreshControl: UIRefreshControl?

		init(parent: SessionTranscriptView) {
			self.parent = parent
			self.currentSessionID = parent.sessionID
			super.init()
		}

		func attach(to collectionView: TranscriptCollectionView) {
			collectionView.dataSource = self
			collectionView.delegate = self
			collectionView.backgroundColor = .clear
			collectionView.keyboardDismissMode = .interactive
			collectionView.alwaysBounceVertical = true
			collectionView.register(TranscriptCell.self, forCellWithReuseIdentifier: "cell")
			configureRefreshControl(for: collectionView)
		}

		// MARK: Update

		func update(parent: SessionTranscriptView, collectionView: TranscriptCollectionView) {
			if parent.sessionID != currentSessionID {
				resetForNewSession(parent: parent, collectionView: collectionView)
				return
			}

			self.parent = parent
			configureRefreshControl(for: collectionView)
			updateEmptyState(on: collectionView)

			let forcePinRequested = parent.forcePinToken != lastForcePinToken
			if forcePinRequested {
				lastForcePinToken = parent.forcePinToken
				collectionView.isPinnedToBottom = true
			}

			let newAll = parent.messages
			let oldAll = allMessages
			allMessages = newAll

			guard !newAll.isEmpty else {
				if !visibleMessages.isEmpty {
					visibleMessages = []
					visibleFingerprints = [:]
					windowStart = 0
					UIView.performWithoutAnimation {
						collectionView.reloadData()
						collectionView.layoutIfNeeded()
					}
				}
				return
			}

			if oldAll.isEmpty {
				windowStart = max(0, newAll.count - Self.initialWindowSize)
				visibleMessages = Array(newAll[windowStart...])
				visibleFingerprints = buildFingerprintMap(visibleMessages)
				UIView.performWithoutAnimation {
					collectionView.reloadData()
					collectionView.layoutIfNeeded()
				}
				collectionView.isPinnedToBottom = true
				collectionView.scrollToBottom()
				collectionView.animateScrolling = true
				return
			}

			let oldVisibleIDs = visibleMessages.map(\.id)
			windowStart = min(windowStart, max(0, newAll.count - 1))
			let newVisible = Array(newAll[windowStart...])
			let newVisibleIDs = newVisible.map(\.id)

			if !oldVisibleIDs.isEmpty, newVisibleIDs.starts(with: oldVisibleIDs) {
				let appendCount = newVisibleIDs.count - oldVisibleIDs.count
				if appendCount > 0 {
					let paths = (oldVisibleIDs.count..<newVisibleIDs.count).map { IndexPath(item: $0, section: 0) }
					UIView.performWithoutAnimation {
						collectionView.performBatchUpdates {
							self.visibleMessages = newVisible
							self.visibleFingerprints = self.buildFingerprintMap(newVisible)
							collectionView.insertItems(at: paths)
						}
						collectionView.layoutIfNeeded()
					}
					if collectionView.isPinnedToBottom {
						collectionView.scrollToBottom(animated: true)
					}
				} else {
					reloadChangedItems(old: visibleMessages, new: newVisible, collectionView: collectionView)
				}
			} else {
				reloadPreservingPosition(newVisible: newVisible, collectionView: collectionView, forcePinRequested: forcePinRequested)
			}
		}

		private func resetForNewSession(parent: SessionTranscriptView, collectionView: TranscriptCollectionView) {
			self.parent = parent
			currentSessionID = parent.sessionID
			allMessages = parent.messages
			windowStart = max(0, allMessages.count - Self.initialWindowSize)
			visibleMessages = allMessages.isEmpty ? [] : Array(allMessages[windowStart...])
			visibleFingerprints = buildFingerprintMap(visibleMessages)
			collectionView.animateScrolling = false
			collectionView.isPinnedToBottom = true
			lastForcePinToken = parent.forcePinToken
			isAdjustingScroll = false
			UIView.performWithoutAnimation {
				collectionView.reloadData()
				collectionView.layoutIfNeeded()
			}
			collectionView.scrollToBottom()
			collectionView.animateScrolling = true
			updateEmptyState(on: collectionView)
		}

		// MARK: Diffing helpers

		private func buildFingerprintMap(_ messages: [TranscriptMessage]) -> [String: UInt64] {
			Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0.fingerprint) })
		}

		private func reloadChangedItems(old: [TranscriptMessage], new: [TranscriptMessage], collectionView: UICollectionView) {
			var reloadPaths: [IndexPath] = []
			let newFP = buildFingerprintMap(new)
			for (index, msg) in old.enumerated() {
				if let newFingerprint = newFP[msg.id], newFingerprint != msg.fingerprint {
					reloadPaths.append(IndexPath(item: index, section: 0))
				}
			}
			guard !reloadPaths.isEmpty else { return }
			visibleMessages = new
			visibleFingerprints = newFP
			UIView.performWithoutAnimation {
				collectionView.reloadItems(at: reloadPaths)
			}
		}

		private func reloadPreservingPosition(newVisible: [TranscriptMessage], collectionView: TranscriptCollectionView, forcePinRequested: Bool) {
			let anchor = captureAnchor(in: collectionView)
			visibleMessages = newVisible
			visibleFingerprints = buildFingerprintMap(newVisible)
			UIView.performWithoutAnimation {
				collectionView.reloadData()
				collectionView.layoutIfNeeded()
			}
			if collectionView.isPinnedToBottom || forcePinRequested {
				collectionView.isPinnedToBottom = true
				collectionView.scrollToBottom(animated: collectionView.animateScrolling)
			} else if let anchor {
				restoreAnchor(anchor, in: collectionView)
			}
		}

		// MARK: Scroll anchor

		private struct ScrollAnchor {
			let messageID: String
			let offsetFromTop: CGFloat
		}

		private func captureAnchor(in collectionView: UICollectionView) -> ScrollAnchor? {
			guard let firstVisiblePath = collectionView.indexPathsForVisibleItems.sorted().first,
				visibleMessages.indices.contains(firstVisiblePath.item),
				let cell = collectionView.cellForItem(at: firstVisiblePath) else {
				return nil
			}
			let offset = cell.frame.origin.y - collectionView.contentOffset.y
			return ScrollAnchor(messageID: visibleMessages[firstVisiblePath.item].id, offsetFromTop: offset)
		}

		private func restoreAnchor(_ anchor: ScrollAnchor, in collectionView: UICollectionView) {
			guard let index = visibleMessages.firstIndex(where: { $0.id == anchor.messageID }) else { return }
			collectionView.layoutIfNeeded()
			guard let frame = collectionView.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame else { return }
			let targetOffset = frame.origin.y - anchor.offsetFromTop
			let maxOffset = collectionView.contentSize.height - collectionView.bounds.height + collectionView.adjustedContentInset.bottom
			let minOffset = -collectionView.adjustedContentInset.top
			collectionView.contentOffset.y = min(maxOffset, max(minOffset, targetOffset))
		}

		// MARK: Prepend older messages

		private func loadOlderMessages(_ collectionView: UICollectionView) {
			guard windowStart > 0 else { return }
			let newStart = max(0, windowStart - Self.pageSize)
			guard newStart < windowStart else { return }

			let anchor = captureAnchor(in: collectionView)
			isAdjustingScroll = true
			windowStart = newStart
			visibleMessages = Array(allMessages[windowStart...])
			visibleFingerprints = buildFingerprintMap(visibleMessages)
			UIView.performWithoutAnimation {
				collectionView.reloadData()
				collectionView.layoutIfNeeded()
			}
			if let anchor {
				restoreAnchor(anchor, in: collectionView)
			}
			isAdjustingScroll = false
		}

		// MARK: UICollectionViewDataSource

		func numberOfSections(in collectionView: UICollectionView) -> Int { 1 }

		func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
			visibleMessages.count
		}

		func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
			let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "cell", for: indexPath)
			guard visibleMessages.indices.contains(indexPath.item) else { return cell }

			let message = visibleMessages[indexPath.item]
			let ctx = renderContext
			cell.contentConfiguration = UIHostingConfiguration {
				TranscriptRowSwiftUIView(message: message, context: ctx)
					.transaction { $0.animation = nil }
			}
			.margins(.all, 0)
			cell.backgroundColor = .clear
			return cell
		}

		// MARK: UIScrollViewDelegate

		func scrollViewDidScroll(_ scrollView: UIScrollView) {
			guard !isAdjustingScroll else { return }

			if let cv = scrollView as? TranscriptCollectionView,
				scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating {
				let bottomDistance = scrollView.contentSize.height - scrollView.contentOffset.y - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
				cv.isPinnedToBottom = bottomDistance <= Self.nearBottomThreshold
			}

			if let collectionView = scrollView as? UICollectionView,
				scrollView.contentOffset.y < Self.loadOlderThreshold,
				windowStart > 0 {
				loadOlderMessages(collectionView)
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

		private func configureRefreshControl(for collectionView: UICollectionView) {
			guard parent.onRefresh != nil else {
				collectionView.refreshControl = nil
				refreshControl = nil
				return
			}
			if refreshControl == nil {
				let control = UIRefreshControl()
				control.addTarget(self, action: #selector(refreshControlChanged), for: .valueChanged)
				collectionView.refreshControl = control
				refreshControl = control
			}
		}

		// MARK: Empty state

		private func updateEmptyState(on collectionView: UICollectionView) {
			if visibleMessages.isEmpty, let emptyState = parent.emptyState {
				if collectionView.backgroundView == nil || !(collectionView.backgroundView is TranscriptEmptyStateView) {
					collectionView.backgroundView = TranscriptEmptyStateView(state: emptyState, onRetry: parent.onRetry)
				}
			} else {
				collectionView.backgroundView = nil
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

// MARK: - Cell subclass

private final class TranscriptCell: UICollectionViewCell {
	override func apply(_ layoutAttributes: UICollectionViewLayoutAttributes) {
		UIView.performWithoutAnimation {
			super.apply(layoutAttributes)
		}
	}
}

// MARK: - Collection view

final class TranscriptCollectionView: UICollectionView {
	var isPinnedToBottom = true
	var animateScrolling = false
	private var lastContentSize: CGSize = .zero

	override func layoutSubviews() {
		super.layoutSubviews()
		updateBottomAlignment()
		let contentSizeChanged = contentSize != lastContentSize
		lastContentSize = contentSize
		if isPinnedToBottom, contentSizeChanged,
		   bounds.height > 0, contentSize.height > 0,
		   !isDecelerating, !isDragging, !isTracking {
			let maxOffset = contentSize.height - bounds.height + adjustedContentInset.bottom
			if maxOffset > -adjustedContentInset.top {
				if animateScrolling {
					UIView.animate(withDuration: 0.2, delay: 0, options: [.allowUserInteraction, .curveEaseOut]) {
						self.contentOffset = CGPoint(x: 0, y: maxOffset)
					}
				} else {
					contentOffset = CGPoint(x: 0, y: maxOffset)
				}
			}
		}
	}

	func scrollToBottom(animated: Bool = false) {
		guard bounds.height > 0, contentSize.height > 0 else { return }
		let maxOffset = contentSize.height - bounds.height + adjustedContentInset.bottom
		guard maxOffset > -adjustedContentInset.top else { return }
		if animated {
			UIView.animate(withDuration: 0.2, delay: 0, options: [.allowUserInteraction, .curveEaseOut]) {
				self.contentOffset = CGPoint(x: 0, y: maxOffset)
			}
		} else {
			contentOffset = CGPoint(x: 0, y: maxOffset)
		}
	}

	private func updateBottomAlignment() {
		let baseTop = adjustedContentInset.top - contentInset.top
		let baseBottom = adjustedContentInset.bottom - contentInset.bottom
		let available = bounds.height - baseTop - baseBottom
		let desired = max(0, available - contentSize.height)
		if abs(contentInset.top - desired) > 0.5 {
			contentInset.top = desired
		}
	}
}

// MARK: - SwiftUI row view

private struct TranscriptRowSwiftUIView: View {
	let message: TranscriptMessage
	let context: TranscriptRenderContext

	var body: some View {
		Group {
			switch message {
			case .confirmed(let messageInfo):
				MessageView(
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
