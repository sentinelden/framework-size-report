// MeasurerTests.swift — parsing and the arithmetic that decides the headline
// number. The headline number is the whole product, so it gets the most tests.

import XCTest
@testable import FrameworkSizeCore

final class MeasurerTests: XCTestCase {

    func testMeasuresRealFatBinary() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: "/bin/ls"))
        let report = try Measurer.measure(path: "/bin/ls")

        XCTAssertFalse(report.slices.isEmpty)
        XCTAssertGreaterThan(report.onDiskBytes, 0)
        for slice in report.slices {
            XCTAssertTrue(slice.segments.contains { $0.name == "__TEXT" },
                          "every Mach-O has a __TEXT segment")
            XCTAssertGreaterThan(slice.segment("__TEXT"), 0)
        }
    }

    func testOnDiskMatchesFileSystem() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: "/bin/ls"))
        let expected = (try FileManager.default.attributesOfItem(atPath: "/bin/ls")[.size] as? NSNumber)?.uint64Value
        let report = try Measurer.measure(path: "/bin/ls")
        XCTAssertEqual(report.onDiskBytes, try XCTUnwrap(expected))
    }

    func testRejectsNonMachO() throws {
        let path = NSTemporaryDirectory() + "/plain-\(UUID().uuidString).txt"
        try "not a binary".write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertThrowsError(try Measurer.measure(path: path))
    }

    func testRejectsMissingPath() {
        XCTAssertThrowsError(try Measurer.measure(path: "/no/such/thing")) { error in
            guard case MeasureError.notFound = error else {
                return XCTFail("expected .notFound, got \(error)")
            }
        }
    }

    func testRejectsLyingFatHeader() throws {
        let path = NSTemporaryDirectory() + "/lying-\(UUID().uuidString)"
        var bytes = Data([0xca, 0xfe, 0xba, 0xbe])
        bytes.append(contentsOf: [0xff, 0xff, 0xff, 0xff])   // absurd slice count
        try bytes.write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertThrowsError(try Measurer.measure(path: path))
    }
}

final class SizeArithmeticTests: XCTestCase {

    private func slice(_ architecture: String, text: UInt64, data: UInt64, linkedit: UInt64) -> SliceSize {
        SliceSize(architecture: architecture, segments: [
            SegmentSize(name: "__TEXT", fileSize: text, vmSize: text),
            SegmentSize(name: "__DATA", fileSize: data, vmSize: data),
            SegmentSize(name: "__LINKEDIT", fileSize: linkedit, vmSize: linkedit),
        ])
    }

    /// __LINKEDIT is stripped before shipping, so counting it would inflate
    /// every number a customer is quoted — badly, on a debug build.
    func testShippedBytesExcludesLinkedit() {
        let s = slice("arm64", text: 1000, data: 500, linkedit: 9000)
        XCTAssertEqual(s.shippedBytes, 1500)
        XCTAssertEqual(s.totalBytes, 10500)
    }

    /// App Store thinning delivers one slice per device. Summing a universal
    /// binary's slices would roughly double what a customer actually pays.
    func testBudgetUsesLargestSliceNotTheSum() {
        let report = SizeReport(
            name: "MyKit", onDiskBytes: 0,
            slices: [slice("arm64", text: 1000, data: 500, linkedit: 9000),
                     slice("x86_64", text: 800, data: 400, linkedit: 9000)],
            resourceBytes: 0
        )
        XCTAssertEqual(report.budgetBytes, 1500)   // not 2700
    }

    func testBudgetIncludesResources() {
        let report = SizeReport(
            name: "MyKit", onDiskBytes: 0,
            slices: [slice("arm64", text: 1000, data: 500, linkedit: 0)],
            resourceBytes: 250
        )
        XCTAssertEqual(report.budgetBytes, 1750)
    }
}

final class ByteFormatTests: XCTestCase {

    func testParsesBudgetStrings() {
        XCTAssertEqual(ByteFormat.parse("1KB"), 1024)
        XCTAssertEqual(ByteFormat.parse("2MB"), 2 * 1024 * 1024)
        XCTAssertEqual(ByteFormat.parse("1.5MB"), UInt64(1.5 * 1024 * 1024))
        XCTAssertEqual(ByteFormat.parse("  500 KB "), 500 * 1024)
        XCTAssertEqual(ByteFormat.parse("4096"), 4096)
    }

    func testRejectsUnparseableBudget() {
        XCTAssertNil(ByteFormat.parse("big"))
        XCTAssertNil(ByteFormat.parse("MB"))
    }

    func testFormatsDeltaSign() {
        XCTAssertTrue(ByteFormat.delta(1024).hasPrefix("+"))
        XCTAssertTrue(ByteFormat.delta(-1024).hasPrefix("−"))
        XCTAssertTrue(ByteFormat.delta(0).hasPrefix("±"))
    }
}
