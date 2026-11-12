import Testing
@testable import TabulaCore

struct ResultSortingTests {
    @Test func numbersCompareNumericallyWithNullsLast() {
        let values: [CellValue] = [.text("10"), .null, .text("9"), .text("-1.5")]
        let ascending = ResultSorting.sort(Array(values.indices), typeName: "int4", ascending: true) { values[$0] }
        #expect(ascending == [3, 2, 0, 1])
        let descending = ResultSorting.sort(Array(values.indices), typeName: "int4", ascending: false) { values[$0] }
        #expect(descending == [1, 0, 2, 3])
    }

    @Test func textUsesNaturalOrderAndKeepsTiesStable() {
        let values: [CellValue] = [.text("item10"), .text("b"), .text("item2"), .text("b")]
        let sorted = ResultSorting.sort(Array(values.indices), typeName: "text", ascending: true) { values[$0] }
        #expect(sorted == [1, 3, 2, 0])
    }

    @Test func sortsOnlyTheGivenSubset() {
        let values: [CellValue] = [.text("c"), .text("a"), .text("b")]
        #expect(ResultSorting.sort([0, 2], typeName: "text", ascending: true) { values[$0] } == [2, 0])
    }
}
