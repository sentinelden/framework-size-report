// FrameworkSize.swift: CLI entry point.
//
// Not named main.swift: that filename is treated as top-level code, which is
// incompatible with @main.
//
//   framework-size measure MyKit.framework --output size.json
//   framework-size diff base.json head.json --budget 2MB --tolerance 50KB
//
// Two commands rather than one so the measurement and the comparison can
// happen in different CI jobs, which they must, since the base and head
// builds are different checkouts.

import ArgumentParser
import Foundation
import FrameworkSizeCore

let toolVersion = "0.1.0"

@main
struct FrameworkSize: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "framework-size",
        abstract: "Measure what a framework costs an app, and hold it to a budget.",
        version: toolVersion,
        subcommands: [Measure.self, Diff.self],
        defaultSubcommand: Measure.self
    )
}

struct Measure: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "measure",
        abstract: "Measure a .framework, .xcframework slice, .app, or bare binary."
    )

    @Argument(help: "Path to the bundle or binary to measure.")
    var target: String

    @Option(help: "Write JSON here. Without this, prints a human-readable summary.")
    var output: String?

    @Option(help: "Fail when the shipped size exceeds this, e.g. 2MB.")
    var budget: String?

    func run() throws {
        let report: SizeReport
        do {
            report = try Measurer.measure(path: target)
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            throw ExitCode(65)
        }

        if let output {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: URL(fileURLWithPath: output))
            print("wrote \(output)")
        }

        print(render(report))

        if let budgetText = budget {
            guard let limit = ByteFormat.parse(budgetText) else {
                FileHandle.standardError.write(Data("error: could not parse budget \(budgetText)\n".utf8))
                throw ExitCode(64)
            }
            if report.budgetBytes > limit {
                let over = Int64(report.budgetBytes) - Int64(limit)
                FileHandle.standardError.write(Data(
                    "error: over budget by \(ByteFormat.delta(over))\n".utf8))
                throw ExitCode(1)
            }
        }
    }

    private func render(_ report: SizeReport) -> String {
        var out: [String] = []
        out.append("")
        out.append("  \(report.name)")
        out.append("  " + String(repeating: "─", count: 52))
        out.append("  shipped        \(ByteFormat.human(report.budgetBytes))   "
                   + "← budget against this")
        out.append("  on disk        \(ByteFormat.human(report.onDiskBytes))")
        if report.resourceBytes > 0 {
            out.append("  resources      \(ByteFormat.human(report.resourceBytes))")
        }
        out.append("")

        for slice in report.slices {
            out.append("  \(slice.architecture)")
            for segment in slice.segments.sorted(by: { $0.fileSize > $1.fileSize }) {
                let note = segment.name == "__LINKEDIT" ? "   (excluded, stripped before shipping)" : ""
                out.append("    \(segment.name.padding(toLength: 14, withPad: " ", startingAt: 0))"
                           + "\(ByteFormat.human(segment.fileSize))\(note)")
            }
            out.append("    \("total".padding(toLength: 14, withPad: " ", startingAt: 0))"
                       + "\(ByteFormat.human(slice.shippedBytes))")
            out.append("")
        }
        return out.joined(separator: "\n")
    }
}

struct Diff: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "diff",
        abstract: "Compare two measurements and enforce a budget or tolerance."
    )

    @Argument(help: "Baseline JSON, from `measure --output` on the base branch.")
    var before: String

    @Argument(help: "Current JSON, from `measure --output` on this change.")
    var after: String

    @Option(help: "Absolute ceiling on shipped size, e.g. 2MB.")
    var budget: String?

    @Option(help: "Maximum growth this single change may add, e.g. 50KB.")
    var tolerance: String?

    @Option(help: "Output format: text | markdown | json. Default: text.")
    var format: DiffFormat = .text

    @Option(help: "Write the rendered report here instead of stdout.")
    var output: String?

    func run() throws {
        let decoder = JSONDecoder()
        let baseReport: SizeReport
        let headReport: SizeReport
        do {
            baseReport = try decoder.decode(SizeReport.self, from: Data(contentsOf: URL(fileURLWithPath: before)))
            headReport = try decoder.decode(SizeReport.self, from: Data(contentsOf: URL(fileURLWithPath: after)))
        } catch {
            FileHandle.standardError.write(Data("error: could not read measurements: \(error.localizedDescription)\n".utf8))
            throw ExitCode(65)
        }

        var budgetBytes: UInt64?
        var toleranceBytes: UInt64?
        if let budget {
            guard let parsed = ByteFormat.parse(budget) else {
                FileHandle.standardError.write(Data("error: could not parse budget \(budget)\n".utf8))
                throw ExitCode(64)
            }
            budgetBytes = parsed
        }
        if let tolerance {
            guard let parsed = ByteFormat.parse(tolerance) else {
                FileHandle.standardError.write(Data("error: could not parse tolerance \(tolerance)\n".utf8))
                throw ExitCode(64)
            }
            toleranceBytes = parsed
        }

        let diff = Differ.compare(before: baseReport, after: headReport,
                                  budget: budgetBytes, tolerance: toleranceBytes)

        let body: String
        switch format {
        case .text: body = renderText(diff)
        case .markdown: body = Differ.markdown(diff)
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            body = String(decoding: try encoder.encode(diff), as: UTF8.self)
        }

        if let output {
            try body.write(toFile: output, atomically: true, encoding: .utf8)
            print("wrote \(output)")
        } else {
            print(body)
        }

        if diff.exitCode != 0 { throw ExitCode(diff.exitCode) }
    }

    private func renderText(_ diff: SizeDiff) -> String {
        var out: [String] = []
        out.append("")
        out.append("  \(diff.name)")
        out.append("  " + String(repeating: "─", count: 52))
        out.append("  base         \(ByteFormat.human(diff.beforeBytes))")
        out.append("  this change  \(ByteFormat.human(diff.afterBytes))")
        let percent = diff.beforeBytes > 0 ? String(format: "  (%+.2f%%)", diff.percentChange) : ""
        out.append("  delta        \(ByteFormat.delta(diff.delta))\(percent)")
        if let budget = diff.budget {
            out.append("  budget       \(ByteFormat.human(budget))")
        }
        out.append("")

        for slice in diff.slices where slice.delta != 0 {
            out.append("  \(slice.architecture)  \(ByteFormat.delta(slice.delta))")
            for segment in slice.segments where segment.delta != 0 {
                // Shown because it is useful signal, marked because it does
                // not contribute to the headline delta above it.
                let note = segment.name == "__LINKEDIT" ? "   (not counted)" : ""
                out.append("    \(segment.name.padding(toLength: 14, withPad: " ", startingAt: 0))"
                           + "\(ByteFormat.delta(segment.delta))\(note)")
            }
            out.append("")
        }

        switch diff.verdict {
        case .overBudget:    out.append("  OVER BUDGET")
        case .overTolerance: out.append("  OVER TOLERANCE for a single change")
        case .improved:      out.append("  smaller than base")
        case .ok:            out.append("  within limits")
        }
        out.append("")
        return out.joined(separator: "\n")
    }
}

enum DiffFormat: String, ExpressibleByArgument {
    case text, markdown, json
}
