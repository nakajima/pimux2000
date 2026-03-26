import Foundation
import GRDB
@testable import pimux2000
import Testing

@MainActor
struct AppDatabaseTests {
	@Test
	func addHostTrimsWhitespaceAndDeduplicates() async throws {
		let database = AppDatabase.preview()

		try database.addHost(sshTarget: "  root@pi  ")
		let firstHosts = try await database.dbQueue.read { db in
			try Host.fetchAll(db)
		}

		#expect(firstHosts.count == 1)
		#expect(firstHosts[0].sshTarget == "root@pi")
		let initialUpdatedAt = firstHosts[0].updatedAt

		try await Task.sleep(for: .milliseconds(20))
		try database.addHost(sshTarget: "root@pi")

		let secondHosts = try await database.dbQueue.read { db in
			try Host.fetchAll(db)
		}

		#expect(secondHosts.count == 1)
		#expect(secondHosts[0].updatedAt >= initialUpdatedAt)
	}

	@Test
	func deleteHostsRemovesRows() async throws {
		let database = AppDatabase.preview()

		try database.addHost(sshTarget: "root@one")
		try database.addHost(sshTarget: "root@two")

		let hosts = try await database.dbQueue.read { db in
			try Host.fetchAll(db)
		}
		let deletedID = try #require(hosts.first?.id)

		try database.deleteHosts(ids: [deletedID])

		let remainingHosts = try await database.dbQueue.read { db in
			try Host.fetchAll(db)
		}

		#expect(remainingHosts.count == 1)
		#expect(remainingHosts[0].sshTarget == "root@two")
	}
}
