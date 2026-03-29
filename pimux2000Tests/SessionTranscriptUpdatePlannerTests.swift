@testable import pimux2000
import Foundation
import Testing

struct SessionTranscriptUpdatePlannerTests {
	@Test
	func appendingRowsUsesBatchInsertions() {
		let plan = SessionTranscriptUpdatePlanner.plan(
			old: [item("a", 1)],
			new: [item("a", 1), item("b", 1)]
		)

		#expect(plan == .batch(deletions: [], insertions: [1], reloads: []))
	}

	@Test
	func changedVersionsReloadStableRows() {
		let plan = SessionTranscriptUpdatePlanner.plan(
			old: [item("a", 1), item("b", 1)],
			new: [item("a", 2), item("b", 1)]
		)

		#expect(plan == .batch(deletions: [], insertions: [], reloads: [0]))
	}

	@Test
	func replacingPendingWithConfirmedUsesDeleteAndInsert() {
		let plan = SessionTranscriptUpdatePlanner.plan(
			old: [item("confirmed-0", 1), item("pending-1", 1)],
			new: [item("confirmed-0", 1), item("confirmed-1", 1)]
		)

		#expect(plan == .batch(deletions: [1], insertions: [1], reloads: []))
	}

	@Test
	func reorderingSharedRowsFallsBackToReloadAll() {
		let plan = SessionTranscriptUpdatePlanner.plan(
			old: [item("a", 1), item("b", 1), item("c", 1)],
			new: [item("b", 1), item("a", 1), item("c", 1)]
		)

		#expect(plan == .reloadAll)
	}

	@Test
	func duplicateIDsFallBackToReloadAll() {
		let plan = SessionTranscriptUpdatePlanner.plan(
			old: [item("a", 1), item("a", 2)],
			new: [item("a", 2)]
		)

		#expect(plan == .reloadAll)
	}

	@Test
	func paginatorInitiallyShowsOnlyLatestBodyRows() {
		let rows = [SessionTranscriptRow.status("live"), .warning(id: "warning", text: "careful")]
			+ (0..<130).map(pendingRow)
		let pagination = SessionTranscriptPaginator.paginate(rows: rows, visibleBodyStartIndex: nil)

		#expect(pagination.visibleBodyStartIndex == 10)
		#expect(pagination.hiddenBodyRowCount == 10)
		#expect(pagination.visibleRows.count == 123)
		#expect(Array(pagination.visibleRows.prefix(3)).map(\.id) == ["transcript-status", "warning", "transcript-history-loader"])
		#expect(pagination.visibleRows[3].id == pendingRow(10).id)
		#expect(pagination.visibleRows.last?.id == pendingRow(129).id)
	}

	@Test
	func paginatorExpandsOlderRowsInPageSizedChunks() {
		let rows = (0..<250).map(pendingRow)
		let initial = SessionTranscriptPaginator.paginate(rows: rows, visibleBodyStartIndex: nil)
		let expandedStart = SessionTranscriptPaginator.expandedVisibleBodyStartIndex(from: initial.visibleBodyStartIndex)
		let expanded = SessionTranscriptPaginator.paginate(rows: rows, visibleBodyStartIndex: expandedStart)

		#expect(initial.visibleBodyStartIndex == 130)
		#expect(expanded.visibleBodyStartIndex == 10)
		#expect(expanded.hiddenBodyRowCount == 10)
		#expect(expanded.visibleRows.first?.id == "transcript-history-loader")
		#expect(expanded.visibleRows[1].id == pendingRow(10).id)
	}

	private func item(_ id: String, _ version: UInt64) -> SessionTranscriptDiffItem {
		SessionTranscriptDiffItem(id: id, version: version)
	}

	private func pendingRow(_ index: Int) -> SessionTranscriptRow {
		let uuid = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!
		return .pending(
			PendingLocalMessage(
				id: uuid,
				body: "message \(index)",
				confirmedUserMessageBaseline: index
			)
		)
	}
}
