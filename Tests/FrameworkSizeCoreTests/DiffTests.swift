// DiffTests.swift — the verdict logic, which decides whether a build fails.

import XCTest
@testable import FrameworkSizeCore

final class DiffTests: XCTestCase {

    private func report(_ text: UInt64, architecture: String = "arm64", resources: UInt64 = 0) -> SizeReport {
        SizeReport(
            name: "MyKit", onDiskBytes: text,
            slices: [SliceSize(architecture: architecture, segments: [
                SegmentSize(name: "__TEXT", fileSize: text, vmSize: text)
            ])],
            resourceBytes: resources
        )
    }

    func testGrowthWithinLimitsIsOK() {
        let diff = Differ.compare(before: report(1000), after: report(1100),
                                  budget: 5000, tolerance: 500)
        XCTAssertEqual(diff.verdict, .ok)
        XCTAssertEqual(diff.delta, 100)
        XCTAssertEqual(diff.exitCode, 0)
    }

    func testShrinkingIsReportedAsImproved() {
        let diff = Differ.compare(before: report(1000), after: report(800))
        XCTAssertEqual(diff.verdict, .improved)
        XCTAssertEqual(diff.exitCode, 0)
    }

    func testExceedingBudgetFails() {
        let diff = Differ.compare(before: report(1000), after: report(6000), budget: 5000)
        XCTAssertEqual(diff.verdict, .overBudget)
        XCTAssertEqual(diff.exitCode, 1)
    }

    func testExceedingToleranceFails() {
        let diff = Differ.compare(before: report(1000), after: report(2000), tolerance: 500)
        XCTAssertEqual(diff.verdict, .overTolerance)
        XCTAssertEqual(diff.exitCode, 1)
    }

    /// Budget is the harder constraint, so it should win the label when both
    /// are breached — "you are over the ceiling" is more actionable than
    /// "this change was large".
    func testBudgetTakesPrecedenceOverTolerance() {
        let diff = Differ.compare(before: report(1000), after: report(9000),
                                  budget: 5000, tolerance: 500)
        XCTAssertEqual(diff.verdict, .overBudget)
    }

    func testNoLimitsNeverFails() {
        let diff = Differ.compare(before: report(1000), after: report(100_000))
        XCTAssertEqual(diff.verdict, .ok)
        XCTAssertEqual(diff.exitCode, 0)
    }

    /// Adding or removing an architecture is a real size change and has to be
    /// visible, not silently dropped for having no counterpart.
    func testArchitectureAddedShowsAsGrowth() {
        let before = report(1000, architecture: "arm64")
        let after = SizeReport(
            name: "MyKit", onDiskBytes: 0,
            slices: [
                SliceSize(architecture: "arm64", segments: [SegmentSize(name: "__TEXT", fileSize: 1000, vmSize: 1000)]),
                SliceSize(architecture: "x86_64", segments: [SegmentSize(name: "__TEXT", fileSize: 900, vmSize: 900)]),
            ],
            resourceBytes: 0
        )
        let diff = Differ.compare(before: before, after: after)
        let added = diff.slices.first { $0.architecture == "x86_64" }
        XCTAssertEqual(added?.before, 0)
        XCTAssertEqual(added?.after, 900)
        XCTAssertEqual(added?.delta, 900)
    }

    func testPercentChangeHandlesZeroBaseline() {
        let diff = Differ.compare(before: report(0), after: report(500))
        XCTAssertEqual(diff.percentChange, 0, "must not divide by zero")
    }

    // MARK: Markdown

    func testMarkdownStatesTheVerdict() {
        let over = Differ.compare(before: report(1000), after: report(6000), budget: 5000)
        XCTAssertTrue(Differ.markdown(over).contains("over budget"))

        let better = Differ.compare(before: report(1000), after: report(800))
        XCTAssertTrue(Differ.markdown(better).contains("smaller"))
    }

    func testMarkdownOmitsBreakdownWhenNothingMoved() {
        let unchanged = Differ.compare(before: report(1000), after: report(1000))
        // An unchanged table on every PR is noise people learn to scroll past.
        XCTAssertFalse(Differ.markdown(unchanged).contains("Breakdown by architecture"))
    }

    func testMarkdownExplainsWhatWasMeasured() {
        let diff = Differ.compare(before: report(1000), after: report(1100))
        let markdown = Differ.markdown(diff)
        XCTAssertTrue(markdown.contains("__LINKEDIT"))
        XCTAssertTrue(markdown.contains("thinning"))
    }
}
