import SwiftUI

struct SessionTranscriptDiffItem: Equatable {
	let id: String
	let version: UInt64
}

enum SessionTranscriptUpdatePlan: Equatable {
	case none
	case reloadAll
	case batch(deletions: [Int], insertions: [Int], reloads: [Int])
}

enum SessionTranscriptUpdatePlanner {
	static func plan(old: [SessionTranscriptDiffItem], new: [SessionTranscriptDiffItem]) -> SessionTranscriptUpdatePlan {
		guard old != new else { return .none }
		guard !old.isEmpty, !new.isEmpty else { return .reloadAll }
		guard hasUniqueIDs(old), hasUniqueIDs(new) else { return .reloadAll }

		let oldIndexByID = Dictionary(uniqueKeysWithValues: old.enumerated().map { ($1.id, $0) })
		let newIndexByID = Dictionary(uniqueKeysWithValues: new.enumerated().map { ($1.id, $0) })

		let oldSharedIDs = old.compactMap { newIndexByID[$0.id] == nil ? nil : $0.id }
		let newSharedIDs = new.compactMap { oldIndexByID[$0.id] == nil ? nil : $0.id }
		guard oldSharedIDs == newSharedIDs else { return .reloadAll }

		let deletions = old.enumerated().compactMap { newIndexByID[$1.id] == nil ? $0 : nil }
		let insertions = new.enumerated().compactMap { oldIndexByID[$1.id] == nil ? $0 : nil }
		let reloads = new.enumerated().compactMap { element -> Int? in
			let (index, item) = element
			guard let oldIndex = oldIndexByID[item.id] else { return nil }
			return old[oldIndex].version == item.version ? nil : index
		}

		guard !deletions.isEmpty || !insertions.isEmpty || !reloads.isEmpty else {
			return .none
		}

		return .batch(deletions: deletions, insertions: insertions, reloads: reloads)
	}

	private static func hasUniqueIDs(_ items: [SessionTranscriptDiffItem]) -> Bool {
		Set(items.map(\.id)).count == items.count
	}
}

enum TranscriptEmptyState: Equatable {
	case loading
	case error(String)
	case empty
}

enum SessionTranscriptRow: Identifiable {
	case status(String)
	case warning(id: String, text: String)
	case historyLoader(hiddenCount: Int)
	case confirmed(MessageInfo)
	case pending(PendingLocalMessage)
	case empty(TranscriptEmptyState)

	var id: String {
		switch self {
		case .status:
			return "transcript-status"
		case .warning(let id, _):
			return id
		case .historyLoader:
			return "transcript-history-loader"
		case .confirmed(let messageInfo):
			return messageInfo.id
		case .pending(let pendingMessage):
			return "pending-\(pendingMessage.id.uuidString)"
		case .empty:
			return "transcript-empty-state"
		}
	}

	var diffItem: SessionTranscriptDiffItem {
		SessionTranscriptDiffItem(id: id, version: version)
	}

	private var version: UInt64 {
		switch self {
		case .status(let text):
			return TranscriptFingerprint.make { fingerprint in
				fingerprint.combine("status")
				fingerprint.combine(text)
			}
		case .warning(_, let text):
			return TranscriptFingerprint.make { fingerprint in
				fingerprint.combine("warning")
				fingerprint.combine(text)
			}
		case .historyLoader(let hiddenCount):
			return TranscriptFingerprint.make { fingerprint in
				fingerprint.combine("historyLoader")
				fingerprint.combine(hiddenCount)
			}
		case .confirmed(let messageInfo):
			return messageInfo.contentFingerprint
		case .pending(let pendingMessage):
			return TranscriptFingerprint.make { fingerprint in
				fingerprint.combine("pending")
				fingerprint.combine(pendingMessage.normalizedBody)
			}
		case .empty(let state):
			return TranscriptFingerprint.make { fingerprint in
				fingerprint.combine("empty")
				switch state {
				case .loading:
					fingerprint.combine("loading")
				case .error(let message):
					fingerprint.combine("error")
					fingerprint.combine(message)
				case .empty:
					fingerprint.combine("idle")
				}
			}
		}
	}
}

struct SessionTranscriptPaginationState {
	let visibleRows: [SessionTranscriptRow]
	let visibleBodyStartIndex: Int
	let hiddenBodyRowCount: Int
}

enum SessionTranscriptPaginator {
	static let initialBodyRowCount = 60
	static let bodyPageSize = 60

	static func paginate(rows: [SessionTranscriptRow], visibleBodyStartIndex: Int?) -> SessionTranscriptPaginationState {
		let prefixCount = leadingAuxiliaryRowCount(in: rows)
		let prefixRows = Array(rows.prefix(prefixCount))
		let bodyRows = Array(rows.dropFirst(prefixCount))

		guard bodyRows.count > initialBodyRowCount else {
			return SessionTranscriptPaginationState(
				visibleRows: rows,
				visibleBodyStartIndex: 0,
				hiddenBodyRowCount: 0
			)
		}

		let initialStartIndex = max(0, bodyRows.count - initialBodyRowCount)
		let startIndex = min(max(visibleBodyStartIndex ?? initialStartIndex, 0), max(0, bodyRows.count - 1))
		var visibleRows = prefixRows
		if startIndex > 0 {
			visibleRows.append(.historyLoader(hiddenCount: startIndex))
		}
		visibleRows.append(contentsOf: bodyRows[startIndex...])

		return SessionTranscriptPaginationState(
			visibleRows: visibleRows,
			visibleBodyStartIndex: startIndex,
			hiddenBodyRowCount: startIndex
		)
	}

	static func expandedVisibleBodyStartIndex(from startIndex: Int) -> Int {
		max(0, startIndex - bodyPageSize)
	}

	private static func leadingAuxiliaryRowCount(in rows: [SessionTranscriptRow]) -> Int {
		rows.prefix { row in
			switch row {
			case .status, .warning:
				return true
			case .historyLoader, .confirmed, .pending, .empty:
				return false
			}
		}.count
	}
}

#if canImport(UIKit) && !os(macOS)
import UIKit

struct SessionTranscriptView: UIViewRepresentable {
	let rows: [SessionTranscriptRow]
	let sessionID: String
	let serverURL: String?
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

	final class Coordinator: NSObject, UITableViewDataSource, UITableViewDelegate {
		private var parent: SessionTranscriptView
		private var currentSessionID: String
		private var rows: [SessionTranscriptRow] = []
		private var diffItems: [SessionTranscriptDiffItem] = []
		private var visibleBodyStartIndex: Int?
		private var lastLaidOutBoundsHeight: Int = 0
		private var lastLaidOutContentHeight: Int = 0
		private var isPinnedToBottom = true
		private var lastForcePinToken = 0
		private var didFinishInitialSelectionTrace = false
		private var estimatedHeightRequestCount = 0
		private weak var refreshControl: UIRefreshControl?
		private weak var tableView: UITableView?

		init(parent: SessionTranscriptView) {
			self.parent = parent
			self.currentSessionID = parent.sessionID
			super.init()
		}

		func attach(to tableView: TranscriptTableView) {
			self.tableView = tableView
			tableView.dataSource = self
			tableView.delegate = self
			tableView.separatorStyle = .none
			tableView.backgroundColor = .clear
			tableView.rowHeight = UITableView.automaticDimension
			tableView.estimatedRowHeight = 180
			tableView.keyboardDismissMode = .interactive
			tableView.alwaysBounceVertical = true
			tableView.register(TranscriptRowCell.self, forCellReuseIdentifier: TranscriptRowCell.reuseIdentifier)
			tableView.onLayout = { [weak self, weak tableView] in
				guard let self, let tableView else { return }
				self.handleLayout(for: tableView)
			}
			configureRefreshControl(for: tableView)
		}

		func update(parent: SessionTranscriptView, tableView: TranscriptTableView) {
			if parent.sessionID != currentSessionID {
				resetState(for: parent)
			}

			let pagination = SessionTranscriptPaginator.paginate(rows: parent.rows, visibleBodyStartIndex: visibleBodyStartIndex)
			visibleBodyStartIndex = pagination.visibleBodyStartIndex
			let visibleRows = pagination.visibleRows
			let interval = SessionSelectionPerformanceTrace.beginInterval(
				name: "TranscriptUpdate",
				sessionID: parent.sessionID,
				message: "incomingRows=\(parent.rows.count) visibleRows=\(visibleRows.count) hiddenRows=\(pagination.hiddenBodyRowCount)"
			)
			defer {
				SessionSelectionPerformanceTrace.endInterval(
					interval,
					message: "rows=\(rows.count) hiddenRows=\(pagination.hiddenBodyRowCount) estimatedHeightRequests=\(estimatedHeightRequestCount)"
				)
			}

			self.parent = parent
			configureRefreshControl(for: tableView)

			let forcePinRequested = parent.forcePinToken != lastForcePinToken
			if forcePinRequested {
				lastForcePinToken = parent.forcePinToken
				isPinnedToBottom = true
			}

			let newDiffItems = visibleRows.map(\.diffItem)
			guard diffItems != newDiffItems || forcePinRequested else {
				if forcePinRequested {
					scrollToBottom(tableView)
				}
				return
			}

			let plan = SessionTranscriptUpdatePlanner.plan(old: diffItems, new: newDiffItems)
			apply(plan: plan, newRows: visibleRows, newDiffItems: newDiffItems, to: tableView, forcePinRequested: forcePinRequested)
		}

		private func resetState(for parent: SessionTranscriptView) {
			self.parent = parent
			currentSessionID = parent.sessionID
			rows = []
			diffItems = []
			visibleBodyStartIndex = nil
			lastLaidOutBoundsHeight = 0
			lastLaidOutContentHeight = 0
			isPinnedToBottom = true
			lastForcePinToken = parent.forcePinToken
			didFinishInitialSelectionTrace = false
			estimatedHeightRequestCount = 0
		}

		func numberOfSections(in tableView: UITableView) -> Int {
			1
		}

		func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
			rows.count
		}

		func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
			guard let cell = tableView.dequeueReusableCell(withIdentifier: TranscriptRowCell.reuseIdentifier, for: indexPath) as? TranscriptRowCell,
				rows.indices.contains(indexPath.row) else {
				return UITableViewCell()
			}

			cell.configure(
				row: rows[indexPath.row],
				context: renderContext
			)
			return cell
		}

		func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
			estimatedHeightForRow(at: indexPath, in: tableView)
		}

		func scrollViewDidScroll(_ scrollView: UIScrollView) {
			guard scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating else { return }
			isPinnedToBottom = bottomDistance(of: scrollView) <= TranscriptLayout.nearBottomThreshold
		}

		@objc
		private func refreshControlChanged() {
			guard let onRefresh = parent.onRefresh else {
				refreshControl?.endRefreshing()
				return
			}

			Task {
				await onRefresh()
				await MainActor.run {
					self.refreshControl?.endRefreshing()
				}
			}
		}

		private var renderContext: TranscriptRenderContext {
			TranscriptRenderContext(
				sessionID: parent.sessionID,
				serverURL: parent.serverURL,
				onRetry: parent.onRetry,
				onOpenMessageContext: parent.onOpenMessageContext,
				onLoadOlderMessages: { [weak self] in
					guard let self, let tableView = self.tableView else { return }
					self.loadOlderMessages(on: tableView)
				}
			)
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

		private func loadOlderMessages(on tableView: UITableView) {
			let pagination = SessionTranscriptPaginator.paginate(rows: parent.rows, visibleBodyStartIndex: visibleBodyStartIndex)
			guard pagination.hiddenBodyRowCount > 0 else { return }
			let hiddenBefore = pagination.hiddenBodyRowCount
			visibleBodyStartIndex = SessionTranscriptPaginator.expandedVisibleBodyStartIndex(from: pagination.visibleBodyStartIndex)
			let expandedPagination = SessionTranscriptPaginator.paginate(rows: parent.rows, visibleBodyStartIndex: visibleBodyStartIndex)
			visibleBodyStartIndex = expandedPagination.visibleBodyStartIndex
			let newRows = expandedPagination.visibleRows
			let newDiffItems = newRows.map(\.diffItem)
			let plan = SessionTranscriptUpdatePlanner.plan(old: diffItems, new: newDiffItems)

			SessionSelectionPerformanceTrace.emitEvent(
				sessionID: parent.sessionID,
				name: "TranscriptLoadOlder",
				message: "hiddenBefore=\(hiddenBefore) hiddenAfter=\(expandedPagination.hiddenBodyRowCount) visibleRows=\(newRows.count)"
			)

			apply(plan: plan, newRows: newRows, newDiffItems: newDiffItems, to: tableView, forcePinRequested: false)
		}

		private func handleLayout(for tableView: UITableView) {
			let boundsHeight = roundedKey(for: tableView.bounds.height)
			let contentHeight = roundedKey(for: tableView.contentSize.height)
			let layoutChanged = boundsHeight != lastLaidOutBoundsHeight || contentHeight != lastLaidOutContentHeight
			lastLaidOutBoundsHeight = boundsHeight
			lastLaidOutContentHeight = contentHeight

			if !didFinishInitialSelectionTrace,
				tableView.window != nil,
				tableView.bounds.height > 0,
				(tableView.contentSize.height > 0 || !rows.isEmpty)
			{
				didFinishInitialSelectionTrace = true
				SessionSelectionPerformanceTrace.emitEvent(
					sessionID: parent.sessionID,
					name: "TranscriptFirstLayout",
					message: "rows=\(rows.count) contentHeight=\(contentHeight) estimatedHeightRequests=\(estimatedHeightRequestCount)"
				)
				SessionSelectionPerformanceTrace.endSelection(
					sessionID: parent.sessionID,
					reason: "first_layout rows=\(rows.count)"
				)
			}

			guard layoutChanged, isPinnedToBottom, !isUserInteracting(tableView) else { return }
			scrollToBottom(tableView)
		}

		private func apply(
			plan: SessionTranscriptUpdatePlan,
			newRows: [SessionTranscriptRow],
			newDiffItems: [SessionTranscriptDiffItem],
			to tableView: UITableView,
			forcePinRequested: Bool
		) {
			switch plan {
			case .none:
				rows = newRows
				diffItems = newDiffItems
				if forcePinRequested {
					scrollToBottom(tableView)
				}
			case .reloadAll:
				applyFullReload(with: newRows, diffItems: newDiffItems, to: tableView, forcePinRequested: forcePinRequested)
			case .batch(let deletions, let insertions, let reloads):
				let shouldPreserveBottom = isPinnedToBottom || forcePinRequested
				let preservedBottomDistance = shouldPreserveBottom ? bottomDistance(of: tableView) : nil
				rows = newRows
				diffItems = newDiffItems

				let deletePaths = deletions.map { IndexPath(row: $0, section: 0) }
				let insertPaths = insertions.map { IndexPath(row: $0, section: 0) }
				let reloadPaths = reloads.map { IndexPath(row: $0, section: 0) }

				UIView.performWithoutAnimation {
					tableView.performBatchUpdates {
						if !deletePaths.isEmpty {
							tableView.deleteRows(at: deletePaths, with: .none)
						}
						if !insertPaths.isEmpty {
							tableView.insertRows(at: insertPaths, with: .none)
						}
						if !reloadPaths.isEmpty {
							tableView.reloadRows(at: reloadPaths, with: .none)
						}
					} completion: { _ in
						self.scheduleScrollRestore(on: tableView, preservedBottomDistance: preservedBottomDistance, forcePinRequested: forcePinRequested)
					}
				}
			}
		}

		private func applyFullReload(
			with newRows: [SessionTranscriptRow],
			diffItems newDiffItems: [SessionTranscriptDiffItem],
			to tableView: UITableView,
			forcePinRequested: Bool
		) {
			let shouldPreserveBottom = isPinnedToBottom || forcePinRequested
			let preservedBottomDistance = shouldPreserveBottom ? bottomDistance(of: tableView) : nil
			rows = newRows
			diffItems = newDiffItems

			UIView.performWithoutAnimation {
				tableView.reloadData()
			}

			scheduleScrollRestore(on: tableView, preservedBottomDistance: preservedBottomDistance, forcePinRequested: forcePinRequested)
		}

		private func scheduleScrollRestore(on tableView: UITableView, preservedBottomDistance: CGFloat?, forcePinRequested: Bool) {
			DispatchQueue.main.async { [weak self, weak tableView] in
				guard let self, let tableView else { return }
				self.restoreScrollPosition(on: tableView, preservedBottomDistance: preservedBottomDistance, forcePinRequested: forcePinRequested)
			}
		}

		private func restoreScrollPosition(on tableView: UITableView, preservedBottomDistance: CGFloat?, forcePinRequested: Bool) {
			if forcePinRequested || isPinnedToBottom {
				scrollToBottom(tableView)
				DispatchQueue.main.async { [weak self, weak tableView] in
					guard let self, let tableView else { return }
					guard forcePinRequested || self.isPinnedToBottom else { return }
					self.scrollToBottom(tableView)
				}
				return
			}

			guard let preservedBottomDistance else { return }
			setBottomDistance(preservedBottomDistance, on: tableView)
		}

		private func scrollToBottom(_ tableView: UITableView) {
			setBottomDistance(0, on: tableView)
		}

		private func setBottomDistance(_ distance: CGFloat, on tableView: UITableView) {
			let topOffset = -tableView.adjustedContentInset.top
			let maxOffset = max(topOffset, tableView.contentSize.height - tableView.bounds.height + tableView.adjustedContentInset.bottom)
			let targetOffset = min(maxOffset, max(topOffset, maxOffset - distance))
			tableView.setContentOffset(CGPoint(x: 0, y: targetOffset), animated: false)
		}

		private func bottomDistance(of scrollView: UIScrollView) -> CGFloat {
			let topOffset = -scrollView.adjustedContentInset.top
			let maxOffset = max(topOffset, scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom)
			return max(0, maxOffset - scrollView.contentOffset.y)
		}

		private func estimatedHeightForRow(at indexPath: IndexPath, in tableView: UITableView) -> CGFloat {
			estimatedHeightRequestCount += 1
			guard rows.indices.contains(indexPath.row) else { return 1 }
			let width = max(tableView.bounds.width, 1)
			let row = rows[indexPath.row]
			return roughEstimatedHeight(for: row, width: width)
		}

		private func roughEstimatedHeight(for row: SessionTranscriptRow, width: CGFloat) -> CGFloat {
			switch row {
			case .status(let text):
				return roughEstimatedPillHeight(text: text, width: width)
			case .warning(_, let text):
				return roughEstimatedPillHeight(text: text, width: width)
			case .historyLoader:
				return 52
			case .pending(let pendingMessage):
				let textHeight = roughEstimatedLabelHeight(
					for: pendingMessage.body,
					width: max(120, width - 2 * TranscriptLayout.horizontalInset),
					font: messageFont(for: .user, style: .body)
				)
				return ceil(TranscriptLayout.verticalInset * 2 + 26 + 6 + textHeight)
			case .empty(let state):
				switch state {
				case .loading:
					return 140
				case .error(let message):
					let textHeight = roughEstimatedLabelHeight(
						for: message,
						width: max(120, width - 2 * TranscriptLayout.horizontalInset - 40),
						font: UIFont.preferredFont(forTextStyle: .body)
					)
					return ceil(140 + textHeight)
				case .empty:
					return 120
				}
			case .confirmed(let messageInfo):
				return roughEstimatedMessageHeight(for: messageInfo, width: width)
			}
		}

		private func roughEstimatedPillHeight(text: String, width: CGFloat) -> CGFloat {
			let textHeight = roughEstimatedLabelHeight(
				for: text,
				width: max(120, width - 2 * TranscriptLayout.horizontalInset - 20 - 20 - 8),
				font: UIFont.preferredFont(forTextStyle: .caption1)
			)
			return ceil(TranscriptLayout.verticalInset * 2 + textHeight + 16)
		}

		private func roughEstimatedMessageHeight(for messageInfo: MessageInfo, width: CGFloat) -> CGFloat {
			let role = messageInfo.message.role
			let contentWidth = max(120, width - 2 * TranscriptLayout.horizontalInset - 20 - 12)
			var total = TranscriptLayout.verticalInset * 2 + 22
			let blocks = messageInfo.contentBlocks
			for index in blocks.indices {
				if index > 0 {
					total += 6
				}
				total += roughEstimatedBlockHeight(for: blocks[index], role: role, width: contentWidth, title: messageTitle(for: messageInfo.message))
			}
			return ceil(max(total, 52))
		}

		private func roughEstimatedBlockHeight(for block: MessageContentBlock, role: Message.Role, width: CGFloat, title: String) -> CGFloat {
			switch block.type {
			case "text":
				guard let text = block.text, !text.isEmpty else { return 0 }
				let displayText = MessageMarkdownRenderer.shouldCollapsePreview(for: text, role: role)
					? MessageMarkdownRenderer.previewText(for: text)
					: text
				let textHeight = roughEstimatedLabelHeight(for: displayText, width: width, font: messageFont(for: role, style: .body))
				let contextButtonHeight: CGFloat = MessageMarkdownRenderer.shouldCollapsePreview(for: text, role: role) ? 30 : 0
				return ceil(textHeight + contextButtonHeight)
			case "thinking":
				guard let text = block.text, !text.isEmpty else { return 0 }
				return ceil(roughEstimatedLabelHeight(for: text, width: width, font: UIFont.preferredFont(forTextStyle: .callout)))
			case "toolCall":
				var total: CGFloat = 32
				if let text = block.text, !text.isEmpty {
					let collapsed = shouldCollapseCodeLikeContent(text)
					let displayText = collapsed ? MessageMarkdownRenderer.previewText(for: text) : text
					let textHeight = roughEstimatedLabelHeight(
						for: displayText,
						width: max(80, width - 20),
						font: UIFont.monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .regular)
					)
					total += 8 + textHeight + 16
					if collapsed {
						total += 30
					}
				}
				return ceil(total)
			case "image":
				return TranscriptLayout.imageSize.height
			default:
				guard let text = block.text, !text.isEmpty else { return 0 }
				return ceil(roughEstimatedLabelHeight(for: text, width: width, font: UIFont.preferredFont(forTextStyle: .body)))
			}
		}

		private func roughEstimatedLabelHeight(for text: String, width: CGFloat, font: UIFont) -> CGFloat {
			guard !text.isEmpty else { return font.lineHeight }
			let rect = (text as NSString).boundingRect(
				with: CGSize(width: max(1, width), height: .greatestFiniteMagnitude),
				options: [.usesLineFragmentOrigin, .usesFontLeading],
				attributes: [.font: font],
				context: nil
			)
			return max(font.lineHeight, ceil(rect.height))
		}

		private func isUserInteracting(_ scrollView: UIScrollView) -> Bool {
			scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating
		}

		private func roundedKey(for value: CGFloat) -> Int {
			Int(value.rounded())
		}
	}
}

private enum TranscriptLayout {
	static let horizontalInset: CGFloat = 16
	static let verticalInset: CGFloat = 8
	static let verticalSpacing: CGFloat = 8
	static let messageBlockSpacing: CGFloat = 10
	static let imageSize = CGSize(width: 320, height: 240)
	static let nearBottomThreshold: CGFloat = 24
}

private struct TranscriptRenderContext {
	let sessionID: String
	let serverURL: String?
	let onRetry: (() -> Void)?
	let onOpenMessageContext: ((MessageContextRoute) -> Void)?
	let onLoadOlderMessages: (() -> Void)?
}

final class TranscriptTableView: UITableView {
	var onLayout: (() -> Void)?

	override func layoutSubviews() {
		super.layoutSubviews()
		onLayout?()
	}
}

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

	func configure(row: SessionTranscriptRow, context: TranscriptRenderContext) {
		hostedRowView?.removeFromSuperview()
		NSLayoutConstraint.deactivate(hostedConstraints)
		hostedConstraints.removeAll()

		let view = makeView(for: row, context: context)
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

	private func makeView(for row: SessionTranscriptRow, context: TranscriptRenderContext) -> UIView {
		switch row {
		case .status(let text):
			return TranscriptInsetContainerView(content: TranscriptPillView(text: text, systemImage: "dot.radiowaves.left.and.right", foregroundColor: .secondaryLabel, backgroundColor: UIColor.secondarySystemFill))
		case .warning(_, let text):
			return TranscriptInsetContainerView(content: TranscriptPillView(text: text, systemImage: "exclamationmark.triangle.fill", foregroundColor: .systemYellow, backgroundColor: UIColor.systemYellow.withAlphaComponent(0.12)))
		case .historyLoader(let hiddenCount):
			return TranscriptInsetContainerView(content: TranscriptHistoryLoaderRowView(hiddenCount: hiddenCount, onLoadOlderMessages: context.onLoadOlderMessages), verticalInset: TranscriptLayout.verticalInset)
		case .confirmed(let messageInfo):
			return TranscriptInsetContainerView(content: TranscriptMessageRowView(messageInfo: messageInfo, sessionID: context.sessionID, serverURL: context.serverURL, onOpenMessageContext: context.onOpenMessageContext), verticalInset: TranscriptLayout.verticalInset)
		case .pending(let pendingMessage):
			return TranscriptInsetContainerView(content: TranscriptPendingMessageRowView(message: pendingMessage), verticalInset: TranscriptLayout.verticalInset)
		case .empty(let state):
			return TranscriptInsetContainerView(content: TranscriptEmptyStateRowView(state: state, onRetry: context.onRetry), verticalInset: 24)
		}
	}
}

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

private final class TranscriptHistoryLoaderRowView: UIView {
	init(hiddenCount: Int, onLoadOlderMessages: (() -> Void)?) {
		super.init(frame: .zero)
		translatesAutoresizingMaskIntoConstraints = false

		let button = UIButton(type: .system)
		button.translatesAutoresizingMaskIntoConstraints = false
		button.setTitle(historyButtonTitle(hiddenCount: hiddenCount), for: .normal)
		button.titleLabel?.font = UIFont.preferredFont(forTextStyle: .footnote)
		button.titleLabel?.adjustsFontForContentSizeCategory = true
		button.backgroundColor = .secondarySystemFill
		button.layer.cornerRadius = 10
		button.contentEdgeInsets = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
		button.contentHorizontalAlignment = .center
		button.isEnabled = onLoadOlderMessages != nil
		if let onLoadOlderMessages {
			button.addAction(UIAction { _ in onLoadOlderMessages() }, for: .touchUpInside)
		}
		addSubview(button)

		NSLayoutConstraint.activate([
			button.leadingAnchor.constraint(equalTo: leadingAnchor),
			button.trailingAnchor.constraint(equalTo: trailingAnchor),
			button.topAnchor.constraint(equalTo: topAnchor),
			button.bottomAnchor.constraint(equalTo: bottomAnchor),
			button.heightAnchor.constraint(greaterThanOrEqualToConstant: 36),
		])
	}

	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	private func historyButtonTitle(hiddenCount: Int) -> String {
		hiddenCount == 1 ? "Show 1 earlier message" : "Show \(hiddenCount) earlier messages"
	}
}

private final class TranscriptEmptyStateRowView: UIView {
	init(state: TranscriptEmptyState, onRetry: (() -> Void)?) {
		super.init(frame: .zero)
		translatesAutoresizingMaskIntoConstraints = false

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
			stack.addArrangedSubview(makeLabel("Couldn’t Load Messages", style: .headline, color: .label, alignment: .center))
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
			stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
			stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
			stack.centerXAnchor.constraint(equalTo: centerXAnchor),
			stack.topAnchor.constraint(equalTo: topAnchor),
			stack.bottomAnchor.constraint(equalTo: bottomAnchor),
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

#Preview("iOS transcript") {
	let rows: [SessionTranscriptRow] = [
		.status("Live transcript • attached • source: live"),
		.warning(id: "warning", text: "Fell back to a persisted snapshot for a moment."),
		.confirmed(
			MessageInfo(
				message: Message(id: 1, piSessionID: 1, role: .user, toolName: nil, position: 0, createdAt: Date()),
				contentBlocks: [
					MessageContentBlock(id: 1, messageID: 1, type: "text", text: "Can you make the transcript stable on iOS?", toolCallName: nil, position: 0)
				]
			)
		),
		.confirmed(
			MessageInfo(
				message: Message(id: 2, piSessionID: 1, role: .assistant, toolName: nil, position: 1, createdAt: Date()),
				contentBlocks: [
					MessageContentBlock(id: 2, messageID: 2, type: "text", text: "Yes — the iOS transcript now uses UIKit rows instead of hosted SwiftUI rows, so sizing stays deterministic.", toolCallName: nil, position: 0),
					MessageContentBlock(id: 3, messageID: 2, type: "toolCall", text: "xcodebuild -scheme pimux2000 -destination 'platform=iOS Simulator,id=1234' test", toolCallName: "bash", position: 1)
				]
			)
		),
		.pending(PendingLocalMessage(body: "Please keep it boring and stable.", confirmedUserMessageBaseline: 1)),
	]

	return NavigationStack {
		SessionTranscriptView(rows: rows, sessionID: "preview-session", serverURL: nil, onOpenMessageContext: { _ in })
			.background(.background)
	}
}
#endif
