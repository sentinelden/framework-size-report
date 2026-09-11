// Diff.swift — compare two measurements and decide whether to fail the build.
//
// The comparison exists to answer one question on a pull request: did this
// change make the framework bigger, and by enough to care?
//
// Two thresholds, because they answer different questions:
//
//   budget     An absolute ceiling on the shipped size. "This SDK must never
//              exceed 2 MB." Crossing it fails, regardless of the delta.
//   tolerance  A per-change limit. "No single PR may add more than 50 KB."
//              Catches the gradual creep that a budget alone permits right up
//              until the day it doesn't.
//
// A budget alone lets a framework drift from 500 KB to 1.9 MB without ever
// failing; a tolerance alone never notices that the total is already too big.
// Most teams want both, so both are optional and independent.

import Foundation

public struct SegmentDelta: Sendable, Codable {
    public let name: String
    public let before: UInt64
    public let after: UInt64
    public var delta: Int64 { Int64(after) - Int64(before) }
}

public struct SliceDelta: Sendable, Codable {
    public let architecture: String
    public let before: UInt64
    public let after: UInt64
    public let segments: [SegmentDelta]
    public var delta: Int64 { Int64(after) - Int64(before) }
}

public enum Verdict: String, Sendable, Codable {
    case ok                 // within both limits
    case overBudget         // absolute ceiling exceeded
    case overTolerance      // single-change limit exceeded
    case improved           // got smaller, which is worth saying out loud
}

public struct SizeDiff: Sendable, Codable {
    public let name: String
    public let beforeBytes: UInt64
    public let afterBytes: UInt64
    public let slices: [SliceDelta]
    public let budget: UInt64?
    public let tolerance: UInt64?
    public let verdict: Verdict

    public var delta: Int64 { Int64(afterBytes) - Int64(beforeBytes) }

    public var percentChange: Double {
        guard beforeBytes > 0 else { return 0 }
        return Double(delta) / Double(beforeBytes) * 100
    }

    /// 0 within limits, 1 over.
    public var exitCode: Int32 {
        switch verdict {
        case .ok, .improved: return 0
        case .overBudget, .overTolerance: return 1
        }
    }
}

public enum Differ {

    public static func compare(before: SizeReport,
                               after: SizeReport,
                               budget: UInt64? = nil,
                               tolerance: UInt64? = nil) -> SizeDiff {

        let beforeBytes = before.budgetBytes
        let afterBytes = after.budgetBytes
        let delta = Int64(afterBytes) - Int64(beforeBytes)

        // Pair slices by architecture. A slice present on only one side shows
        // up with zero on the other, which is exactly right: adding or
        // dropping an architecture IS a size change and should be visible.
        let architectures = Set(before.slices.map(\.architecture))
            .union(after.slices.map(\.architecture))
            .sorted()

        let slices: [SliceDelta] = architectures.map { architecture in
            let old = before.slices.first { $0.architecture == architecture }
            let new = after.slices.first { $0.architecture == architecture }

            let segmentNames = Set((old?.segments ?? []).map(\.name))
                .union((new?.segments ?? []).map(\.name))
                .sorted()

            let segments = segmentNames.map { name in
                SegmentDelta(name: name,
                             before: old?.segment(name) ?? 0,
                             after: new?.segment(name) ?? 0)
            }

            return SliceDelta(architecture: architecture,
                              before: old?.shippedBytes ?? 0,
                              after: new?.shippedBytes ?? 0,
                              segments: segments)
        }

        let verdict: Verdict
        if let budget, afterBytes > budget {
            verdict = .overBudget
        } else if let tolerance, delta > Int64(tolerance) {
            verdict = .overTolerance
        } else if delta < 0 {
            verdict = .improved
        } else {
            verdict = .ok
        }

        return SizeDiff(name: after.name, beforeBytes: beforeBytes, afterBytes: afterBytes,
                        slices: slices, budget: budget, tolerance: tolerance, verdict: verdict)
    }

    // MARK: Markdown rendering for a PR comment

    public static func markdown(_ diff: SizeDiff) -> String {
        var out: [String] = []

        let headline: String
        switch diff.verdict {
        case .overBudget:
            headline = "🔴 **\(diff.name) is over budget**"
        case .overTolerance:
            headline = "🟠 **\(diff.name) grew more than this change is allowed to**"
        case .improved:
            headline = "🟢 **\(diff.name) got smaller**"
        case .ok:
            headline = "**\(diff.name) size report**"
        }
        out.append(headline)
        out.append("")

        let percent = diff.beforeBytes > 0
            ? String(format: " (%+.2f%%)", diff.percentChange)
            : ""
        out.append("| | Size |")
        out.append("|---|---|")
        out.append("| Base | `\(ByteFormat.human(diff.beforeBytes))` |")
        out.append("| This change | `\(ByteFormat.human(diff.afterBytes))` |")
        out.append("| **Delta** | **`\(ByteFormat.delta(diff.delta))`\(percent)** |")
        if let budget = diff.budget {
            let headroom = Int64(budget) - Int64(diff.afterBytes)
            out.append("| Budget | `\(ByteFormat.human(budget))` (headroom `\(ByteFormat.delta(headroom))`) |")
        }
        out.append("")

        // Only show the per-architecture table when something actually moved;
        // an unchanged table on every PR is noise people learn to scroll past.
        let movedSlices = diff.slices.filter { $0.delta != 0 }
        if !movedSlices.isEmpty {
            out.append("<details><summary>Breakdown by architecture</summary>")
            out.append("")
            for slice in movedSlices {
                out.append("**\(slice.architecture)** — \(ByteFormat.delta(slice.delta))")
                out.append("")
                out.append("| Segment | Base | This change | Delta |")
                out.append("|---|---|---|---|")
                for segment in slice.segments where segment.delta != 0 {
                    // Marked because it is excluded from the headline delta.
                    let name = segment.name == "__LINKEDIT"
                        ? "`\(segment.name)` <sub>not counted</sub>"
                        : "`\(segment.name)`"
                    out.append("| \(name) | \(ByteFormat.human(segment.before)) "
                               + "| \(ByteFormat.human(segment.after)) | \(ByteFormat.delta(segment.delta)) |")
                }
                out.append("")
            }
            out.append("</details>")
            out.append("")
        }

        out.append("<sub>Measured excluding `__LINKEDIT`, which is stripped before shipping, "
                   + "and using the largest single architecture, since App Store thinning "
                   + "delivers one slice per device.</sub>")
        return out.joined(separator: "\n")
    }
}
