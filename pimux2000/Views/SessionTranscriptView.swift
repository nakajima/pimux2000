import SwiftUI

// MARK: - Data types

enum TranscriptMessage: Identifiable {
	case confirmed(MessageInfo)
	case pending(PendingLocalMessage)

	var id: String {
		switch self {
		case let .confirmed(info):
			return info.id
		case let .pending(msg):
			return "pending-\(msg.id.uuidString)"
		}
	}

	var fingerprint: UInt64 {
		switch self {
		case let .confirmed(info):
			return info.contentFingerprint
		case let .pending(msg):
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
	case noServer
	case empty
}

// MARK: - iOS implementation

#if canImport(UIKit) && !os(macOS)
	import UIKit

	struct SessionTranscriptView: UIViewRepresentable {
		@Environment(\.pimuxServerClient) private var pimuxServerClient

		let messages: [TranscriptMessage]
		let sessionID: String
		let emptyState: TranscriptEmptyState?
		var forcePinToken: Int = 0
		var onRetry: (() -> Void)? = nil
		var onOpenMessageContext: ((MessageContextRoute) -> Void)? = nil
		var onScrollOffsetChanged: ((CGFloat) -> Void)? = nil
		var onReachOldestVisibleMessage: (() -> Void)? = nil

		func makeCoordinator() -> Coordinator {
			Coordinator(parent: self)
		}

		func makeUIView(context: Context) -> UITableView {
			let tableView = UITableView(frame: .zero, style: .plain)
			tableView.transform = CGAffineTransform(scaleX: 1, y: -1)
			tableView.delegate = context.coordinator
			tableView.separatorStyle = .none
			tableView.backgroundColor = .clear
			tableView.keyboardDismissMode = .interactive
			tableView.alwaysBounceVertical = true
			tableView.contentInset.top = 16
			tableView.showsVerticalScrollIndicator = true
			tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
			context.coordinator.configureDataSource(for: tableView)
			return tableView
		}

		func updateUIView(_ tableView: UITableView, context: Context) {
			context.coordinator.update(parent: self, tableView: tableView)
		}

		// MARK: - Coordinator

		final class Coordinator: NSObject, UITableViewDelegate {
			private var parent: SessionTranscriptView
			private var lastForcePinToken: Int = 0
			private var messagesByID: [String: TranscriptMessage] = [:]
			private var dataSource: UITableViewDiffableDataSource<Int, String>!

			/// In the flipped table, contentOffset.y ≈ 0 means the user is viewing the
			/// newest messages (visual bottom). A positive offset means scrolled toward
			/// older messages. We treat anything within ~2 lines as "near bottom".
			private var isNearBottom: Bool = true
			private static let nearBottomThreshold: CGFloat = 44

			/// Set when an apply is deferred because the user is mid-scroll gesture.
			/// Cleared after the deferred apply runs.
			private var needsDeferredApply: Bool = false
			private weak var deferredTableView: UITableView?

			/// Background task that pre-warms markdown caches for incoming messages.
			private var prewarmTask: Task<Void, Never>?

			/// Caches measured cell heights so the table can estimate off-screen row
			/// sizes without triggering full layout passes.
			private var measuredHeights: [String: CGFloat] = [:]

			init(parent: SessionTranscriptView) {
				self.parent = parent
				super.init()
			}

			func configureDataSource(for tableView: UITableView) {
				dataSource = UITableViewDiffableDataSource<Int, String>(tableView: tableView) {
					[weak self] tableView, indexPath, messageID in
					let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
					guard let self, let message = self.messagesByID[messageID] else { return cell }

					cell.transform = CGAffineTransform(scaleX: 1, y: -1)
					let ctx = self.renderContext
					cell.contentConfiguration = UIHostingConfiguration {
						TranscriptRowSwiftUIView(message: message, context: ctx)
							.environment(\.pimuxServerClient, self.parent.pimuxServerClient)
							.transaction { $0.animation = nil }
					}
					.margins(.all, 0)
					cell.backgroundColor = .clear
					cell.selectionStyle = .none
					return cell
				}
				dataSource.defaultRowAnimation = .none
			}

			func update(parent: SessionTranscriptView, tableView: UITableView) {
				let shouldForcePin = parent.forcePinToken != lastForcePinToken
				lastForcePinToken = parent.forcePinToken
				self.parent = parent
				let newMessages = parent.messages.reversed() as [TranscriptMessage]

				// Always keep the lookup fresh so the cell provider has current data
				// when cells scroll into view or are recycled.
				let oldFingerprints = messagesByID.mapValues(\.fingerprint)
				messagesByID = Dictionary(uniqueKeysWithValues: newMessages.map { ($0.id, $0) })

				// Pre-warm markdown caches for new or changed messages so cells
				// don't parse markdown on the main thread during scroll.
				let messagesToWarm = newMessages.filter { msg in
					guard let oldFP = oldFingerprints[msg.id] else { return true }
					return oldFP != msg.fingerprint
				}
				if !messagesToWarm.isEmpty {
					prewarmTask?.cancel()
					prewarmTask = Task {
						await TranscriptMarkdownPrewarmer.prewarm(messagesToWarm)
					}
				}

				let newItemIDs = newMessages.map(\.id)
				let structureChanged = dataSource.snapshot().itemIdentifiers != newItemIDs

				// Defer snapshot apply while the user is actively scrolling away from
				// the bottom. The cell provider reads from messagesByID, so cells pick
				// up fresh data naturally when they become visible.
				let isUserScrolling = tableView.isDragging || tableView.isDecelerating
				if isUserScrolling, !isNearBottom, !shouldForcePin {
					if structureChanged || hasContentChanges(newMessages, oldFingerprints: oldFingerprints) {
						needsDeferredApply = true
						deferredTableView = tableView
					}
					return
				}

				applySnapshot(
					newMessages: newMessages,
					newItemIDs: newItemIDs,
					oldFingerprints: oldFingerprints,
					structureChanged: structureChanged,
					shouldForcePin: shouldForcePin,
					tableView: tableView
				)
			}

			private func hasContentChanges(
				_ newMessages: [TranscriptMessage],
				oldFingerprints: [String: UInt64]
			) -> Bool {
				newMessages.contains { message in
					guard let oldFP = oldFingerprints[message.id] else { return false }
					return oldFP != message.fingerprint
				}
			}

			private func applySnapshot(
				newMessages: [TranscriptMessage],
				newItemIDs: [String],
				oldFingerprints: [String: UInt64],
				structureChanged: Bool,
				shouldForcePin: Bool,
				tableView: UITableView
			) {
				needsDeferredApply = false

				if structureChanged {
					// Structure changed (messages added/removed).
					var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
					snapshot.appendSections([0])
					snapshot.appendItems(newItemIDs, toSection: 0)

					let savedOffset = tableView.contentOffset
					dataSource.applySnapshotUsingReloadData(snapshot)
					if shouldForcePin, !newMessages.isEmpty {
						tableView.scrollToRow(at: IndexPath(row: 0, section: 0), at: .top, animated: false)
					} else {
						tableView.contentOffset = savedOffset
					}
				} else {
					// Same structure — reconfigure only changed items
					let changedIDs = newMessages.compactMap { message -> String? in
						guard let oldFP = oldFingerprints[message.id], oldFP != message.fingerprint else { return nil }
						return message.id
					}

					if !changedIDs.isEmpty {
						var snapshot = dataSource.snapshot()
						snapshot.reconfigureItems(changedIDs)

						if isNearBottom {
							// User is at the bottom — apply normally. Row 0 grows and
							// the view stays pinned via offset ≈ 0.
							dataSource.apply(snapshot, animatingDifferences: false)
						} else {
							// User is scrolled away — preserve their position. The growing
							// row 0 shifts all subsequent rows in table coords; restoring
							// the offset cancels that shift.
							let savedOffset = tableView.contentOffset
							dataSource.apply(snapshot, animatingDifferences: false)
							tableView.contentOffset = savedOffset
						}
					}

					if shouldForcePin, !newMessages.isEmpty {
						tableView.scrollToRow(
							at: IndexPath(row: 0, section: 0),
							at: .top,
							animated: changedIDs.isEmpty
						)
					}
				}

				updateEmptyState(on: tableView)
			}

			private func applyDeferredUpdateIfNeeded() {
				guard needsDeferredApply, let tableView = deferredTableView else { return }
				let messages = parent.messages.reversed() as [TranscriptMessage]
				let oldFingerprints = messagesByID.mapValues(\.fingerprint)
				let newItemIDs = messages.map(\.id)
				let structureChanged = dataSource.snapshot().itemIdentifiers != newItemIDs

				applySnapshot(
					newMessages: messages,
					newItemIDs: newItemIDs,
					oldFingerprints: oldFingerprints,
					structureChanged: structureChanged,
					shouldForcePin: false,
					tableView: tableView
				)
			}

			// MARK: UITableViewDelegate

			func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
				guard let tableView = scrollView as? UITableView else { return false }
				let itemCount = dataSource.snapshot().numberOfItems
				guard itemCount > 0 else { return false }
				tableView.scrollToRow(at: IndexPath(row: itemCount - 1, section: 0), at: .bottom, animated: true)
				return false
			}

			func scrollViewDidScroll(_ scrollView: UIScrollView) {
				let normalized = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
				isNearBottom = normalized < Self.nearBottomThreshold
				parent.onScrollOffsetChanged?(normalized)
			}

			func scrollViewDidEndDragging(_: UIScrollView, willDecelerate decelerate: Bool) {
				if !decelerate {
					applyDeferredUpdateIfNeeded()
				}
			}

			func scrollViewDidEndDecelerating(_: UIScrollView) {
				applyDeferredUpdateIfNeeded()
			}

			func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
				guard let messageID = dataSource.itemIdentifier(for: indexPath) else { return }
				measuredHeights[messageID] = cell.bounds.height
				if indexPath.row == dataSource.snapshot().numberOfItems - 1 {
					parent.onReachOldestVisibleMessage?()
				}
			}

			func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
				guard let messageID = dataSource.itemIdentifier(for: indexPath),
				      let cached = measuredHeights[messageID]
				else {
					// Rough estimate: header + a few lines of text.
					return 88
				}
				return cached
			}

			// MARK: Empty state

			private func updateEmptyState(on tableView: UITableView) {
				if messagesByID.isEmpty, let emptyState = parent.emptyState {
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
		let onOpenMessageContext: ((MessageContextRoute) -> Void)?
	}

	// MARK: - SwiftUI row view

	private struct TranscriptRowSwiftUIView: View {
		let message: TranscriptMessage
		let context: TranscriptRenderContext

		var body: some View {
			Group {
				switch message {
				case let .confirmed(messageInfo):
					TranscriptMessageView(
						messageInfo: messageInfo,
						sessionID: context.sessionID
					)
				case let .pending(pendingMessage):
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
			case let .error(message):
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
			case .noServer:
				icon.image = UIImage(systemName: "server.rack")
				stack.addArrangedSubview(makeLabel("No server configured", style: .body, color: .secondaryLabel, alignment: .center))
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

		@available(*, unavailable)
		required init?(coder _: NSCoder) {
			fatalError("init(coder:) has not been implemented")
		}
	}

	// MARK: - Markdown pre-warming

	enum TranscriptMarkdownPrewarmer {
		/// Pre-warms the block parse cache and attributed string cache for the given
		/// messages. Runs on the main actor in cooperative chunks so scroll events
		/// are not blocked. Yields between messages to keep the run loop responsive.
		static func prewarm(_ messages: [TranscriptMessage]) async {
			let font = chatUIFont()
			let captionFont = chatUIFont(style: .caption)

			for message in messages {
				guard !Task.isCancelled else { return }
				guard case let .confirmed(info) = message else { continue }
				let role = info.message.role

				for block in info.contentBlocks {
					guard block.type == "text", let text = block.text, !text.isEmpty else { continue }

					if MessageMarkdownRenderer.shouldCollapsePreview(for: text, role: role) {
						continue
					}

					let blockFont = (role == .toolResult || role == .bashExecution) ? captionFont : font

					if MessageMarkdownRenderer.usesInlineMarkdown(for: text, role: role) {
						_ = MarkdownAttributedStringBuilder.attributedString(for: text, role: role, font: blockFont)
					} else if role != .toolResult && role != .bashExecution {
						let blocks = MarkdownBlockParser.parse(text)
						for mdBlock in blocks {
							switch mdBlock {
							case let .paragraph(t):
								_ = MarkdownAttributedStringBuilder.inlineAttributedString(for: t, font: blockFont)
							case let .heading(level, t):
								let scale: CGFloat = switch level {
								case 1: 1.4; case 2: 1.25; case 3: 1.12; default: 1.05
								}
								let headingFont = UIFont.systemFont(ofSize: blockFont.pointSize * scale, weight: .semibold)
								_ = MarkdownAttributedStringBuilder.inlineAttributedString(for: t, font: headingFont)
							case let .blockQuote(t):
								_ = MarkdownAttributedStringBuilder.inlineAttributedString(for: t, font: blockFont, textColor: .secondaryLabel)
							case let .unorderedList(items):
								for item in items {
									_ = MarkdownAttributedStringBuilder.inlineAttributedString(for: item, font: blockFont)
								}
							case let .orderedList(items):
								for item in items {
									_ = MarkdownAttributedStringBuilder.inlineAttributedString(for: item.text, font: blockFont)
								}
							case .codeBlock, .thematicBreak:
								break
							}
						}
					}
				}

				// Yield between messages so the main run loop can process scroll
				// events, touch handling, and cell layout without blocking.
				await Task.yield()
			}
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

		NavigationStack {
			SessionTranscriptView(messages: messages, sessionID: "preview-session", emptyState: nil, onOpenMessageContext: { _ in })
				.background(.background)
		}
	}
#endif
