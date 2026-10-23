import Foundation
import Testing
@testable import TabulaCore

struct QueryLimitTests {
    @Test func appendsLimitToPlainSelect() {
        #expect(QueryLimit.apply(300, to: "select * from auth_user;") == "select * from auth_user\nLIMIT 300")
    }

    @Test func leavesQueriesThatLimitThemselves() {
        #expect(QueryLimit.apply(300, to: "SELECT * FROM t LIMIT 5") == "SELECT * FROM t LIMIT 5")
        #expect(QueryLimit.apply(300, to: "SELECT * FROM t FETCH FIRST 5 ROWS ONLY") == "SELECT * FROM t FETCH FIRST 5 ROWS ONLY")
    }

    @Test func limitInsideSubqueryDoesNotCount() {
        #expect(QueryLimit.apply(100, to: "SELECT * FROM (SELECT * FROM t LIMIT 5) x") == "SELECT * FROM (SELECT * FROM t LIMIT 5) x\nLIMIT 100")
    }

    @Test func neverTouchesWritesOrNoLimit() {
        #expect(QueryLimit.apply(100, to: "UPDATE t SET a = 1") == "UPDATE t SET a = 1")
        #expect(QueryLimit.apply(0, to: "SELECT 1") == "SELECT 1")
        #expect(QueryLimit.apply(100, to: "EXPLAIN SELECT 1") == "EXPLAIN SELECT 1")
    }
}

struct SQLBeautifierTests {
    @Test func putsClausesOnTheirOwnLines() {
        let formatted = SQLBeautifier.format("select id, name from users u join companies c on c.id = u.company_id where u.active = true and c.name like 'a, b' order by name")
        #expect(formatted == """
            SELECT
              id,
              name
            FROM users u
            JOIN companies c ON c.id = u.company_id
            WHERE u.active = TRUE
              AND c.name LIKE 'a, b'
            ORDER BY name
            """)
    }

    @Test func keepsFunctionCallsAndQuotedNamesIntact() {
        let formatted = SQLBeautifier.format(#"select count(*), "Weird Name" from t group by 2"#)
        #expect(formatted == """
            SELECT
              count(*),
              "Weird Name"
            FROM t
            GROUP BY 2
            """)
    }
}

struct ManagedSessionStreamTests {
    @Test func streamsThroughTheSession() async throws {
        let clock = TestClock()
        let opener = FakeOpener()
        let tokens = CachedTokenProvider(generator: CountingGenerator(clock: clock), now: clock.now)
        let session = ManagedSession(
            opener: opener,
            credentialsProvider: DSQLCredentialsProvider(settings: DSQLSettings(endpoint: "c.dsql.eu-west-1.on.aws"), tokens: tokens),
            lifetime: .dsql,
            now: clock.now
        )
        let received = RowCount()
        let summary = try await session.stream("SELECT 1") { received.add($0.rows.count) }
        #expect(summary.rowCount == 1)
        #expect(received.value == 1)
    }

    @Test func readsAreRetriedWhenTheConnectionDropsBeforeAnyRow() async throws {
        let clock = TestClock()
        let opener = FakeOpener(failFirstQueryWith: .connectionLost("gone"))
        let tokens = CachedTokenProvider(generator: CountingGenerator(clock: clock), now: clock.now)
        let session = ManagedSession(
            opener: opener,
            credentialsProvider: DSQLCredentialsProvider(settings: DSQLSettings(endpoint: "c.dsql.eu-west-1.on.aws"), tokens: tokens),
            lifetime: .dsql,
            now: clock.now
        )
        let summary = try await session.stream("SELECT 1") { _ in }
        #expect(summary.commandTag == "SELECT 1")
        #expect(await opener.opened.count == 2)
    }
}

final class RowCount: @unchecked Sendable {
    private let lock = NSLock()
    private var total = 0
    func add(_ count: Int) { lock.withLock { total += count } }
    var value: Int { lock.withLock { total } }
}
