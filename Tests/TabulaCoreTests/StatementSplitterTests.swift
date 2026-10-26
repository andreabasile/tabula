import Testing
@testable import TabulaCore

struct StatementSplitterTests {
    @Test func splitsOnSemicolons() {
        let statements = StatementSplitter.split("SELECT 1; SELECT 2;\n\nSELECT 3")
        #expect(statements.map(\.text) == ["SELECT 1", "SELECT 2", "SELECT 3"])
    }

    @Test func ignoresSemicolonsInsideQuotesAndComments() {
        let script = """
            SELECT 'a;b', "we;ird" FROM t; -- trailing; comment
            /* block; comment */ SELECT 2
            """
        let statements = StatementSplitter.split(script)
        #expect(statements.count == 2)
        #expect(statements[0].text == #"SELECT 'a;b', "we;ird" FROM t"#)
    }

    @Test func respectsDollarQuotedBodies() {
        let script = "CREATE FUNCTION f() RETURNS int AS $body$ SELECT 1; $body$ LANGUAGE sql; SELECT $1"
        let statements = StatementSplitter.split(script)
        #expect(statements.count == 2)
        #expect(statements[1].text == "SELECT $1")
    }

    @Test func handlesEscapedQuotes() {
        #expect(StatementSplitter.split("SELECT 'it''s; fine'; SELECT 2").count == 2)
    }

    @Test func dropsCommentOnlyFragments() {
        #expect(StatementSplitter.split("SELECT 1; -- nothing else").map(\.text) == ["SELECT 1"])
    }

    @Test func findsStatementUnderCursor() {
        let script = "SELECT 1;\nSELECT 2;\nSELECT 3"
        let cursorInSecond = script.utf16.count - 12
        #expect(StatementSplitter.statement(in: script, at: cursorInSecond)?.text == "SELECT 2")
        #expect(StatementSplitter.statement(in: script, at: script.utf16.count)?.text == "SELECT 3")
    }

    @Test func cursorRightAfterSemicolonPicksThatStatement() {
        let script = "SELECT 1;"
        #expect(StatementSplitter.statement(in: script, at: 9)?.text == "SELECT 1")
    }

    @Test func cursorInGapBetweenStatementsPicksThePreviousOne() {
        let script = "SELECT 1;\n\n  -- note\n\nSELECT 2;"
        #expect(StatementSplitter.statement(in: script, at: 12)?.text == "SELECT 1")
        #expect(StatementSplitter.statement(in: script, at: 0)?.text == "SELECT 1")
    }

    @Test func regionStartFindsTheEnclosingCommentOrString() {
        let script = "SELECT 'a;b' /* long\ncomment */ FROM t"
        #expect(StatementSplitter.regionStart(containing: 9, in: script) == 7)
        #expect(StatementSplitter.regionStart(containing: 20, in: script) == 13)
        #expect(StatementSplitter.regionStart(containing: 34, in: script) == 34)
        #expect(StatementSplitter.regionStart(containing: 12, in: script) == 12)
    }

    @Test func rangesUseUTF16Offsets() {
        let script = "SELECT 'è🙂'; SELECT 2"
        let second = StatementSplitter.split(script)[1]
        let units = Array(script.utf16)[second.range]
        #expect(String(decoding: units, as: UTF16.self) == "SELECT 2")
    }
}

struct StatementClassifierTests {
    @Test func readOnlyStatements() {
        #expect(StatementClassifier.isReadOnly("select * from t"))
        #expect(StatementClassifier.isReadOnly("  -- note\n EXPLAIN SELECT 1"))
        #expect(StatementClassifier.isReadOnly("(SELECT 1) UNION (SELECT 2)"))
        #expect(StatementClassifier.isReadOnly("WITH x AS (SELECT 1) SELECT * FROM x"))
    }

    @Test func writeStatements() {
        #expect(!StatementClassifier.isReadOnly("UPDATE t SET a = 1"))
        #expect(!StatementClassifier.isReadOnly("WITH d AS (DELETE FROM t RETURNING *) SELECT * FROM d"))
        #expect(!StatementClassifier.isReadOnly("drop table t"))
    }

    @Test func safeModeAsksOnlyWhenNeeded() {
        #expect(!SafeMode.silent.requiresConfirmation(for: ["DELETE FROM t"]))
        #expect(SafeMode.alertAll.requiresConfirmation(for: ["SELECT 1"]))
        #expect(!SafeMode.alertWrites.requiresConfirmation(for: ["SELECT 1", "SHOW search_path"]))
        #expect(SafeMode.alertWrites.requiresConfirmation(for: ["SELECT 1", "DELETE FROM t"]))
    }
}
