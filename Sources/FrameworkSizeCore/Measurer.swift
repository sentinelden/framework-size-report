// Measurer.swift: walk a bundle, find its Mach-O, and read segment sizes.
//
// Reads segment sizes out of the load commands rather than calling `size` or
// `otool`, so the tool is one self-contained binary that runs in a CI
// container with no Xcode command-line tools installed.

import Foundation

public enum MeasureError: Error, LocalizedError {
    case notFound(path: String)
    case noBinary(in: String)
    case notMachO(path: String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let path): return "no such path: \(path)"
        case .noBinary(let path): return "could not find a Mach-O binary inside \(path)"
        case .notMachO(let path): return "\(path) is not a Mach-O image"
        }
    }
}

public enum Measurer {

    public static func measure(path: String) throws -> SizeReport {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDirectory) else {
            throw MeasureError.notFound(path: path)
        }

        let name = (path as NSString).lastPathComponent

        guard isDirectory.boolValue else {
            // A bare binary. No resources to account for.
            return SizeReport(name: name, onDiskBytes: fileSize(at: path),
                              slices: try readSlices(path: path), resourceBytes: 0)
        }

        let binaryPath = try findBinary(in: path)
        let slices = try readSlices(path: binaryPath)

        let onDisk = directorySize(path)
        let binarySize = fileSize(at: binaryPath)
        // Everything in the bundle that is not the executable: nibs, asset
        // catalogs, localizations. A customer pays for these too, and they are
        // routinely the reason an SDK is larger than its code suggests.
        let resources = onDisk > binarySize ? onDisk - binarySize : 0

        return SizeReport(name: name, onDiskBytes: onDisk,
                          slices: slices, resourceBytes: resources)
    }

    // MARK: Bundle walking

    static func findBinary(in bundlePath: String) throws -> String {
        let fm = FileManager.default
        let infoCandidates = [
            (bundlePath as NSString).appendingPathComponent("Info.plist"),
            (bundlePath as NSString).appendingPathComponent("Resources/Info.plist"),
            (bundlePath as NSString).appendingPathComponent("Contents/Info.plist"),
        ]
        for info in infoCandidates {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: info)),
                  let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
                  let executable = plist["CFBundleExecutable"] as? String
            else { continue }

            let candidates = [
                (bundlePath as NSString).appendingPathComponent(executable),
                (bundlePath as NSString).appendingPathComponent("Contents/MacOS/\(executable)"),
                (bundlePath as NSString).appendingPathComponent("Versions/A/\(executable)"),
            ]
            if let found = candidates.first(where: { fm.fileExists(atPath: $0) }) {
                return found
            }
        }

        // No usable Info.plist, a .framework built without one, or a raw
        // directory. Fall back to the first Mach-O in the bundle root.
        let contents = (try? fm.contentsOfDirectory(atPath: bundlePath))?.sorted() ?? []
        for entry in contents {
            let candidate = (bundlePath as NSString).appendingPathComponent(entry)
            if isMachO(path: candidate) { return candidate }
        }
        throw MeasureError.noBinary(in: bundlePath)
    }

    static func fileSize(at path: String) -> UInt64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    static func directorySize(_ path: String) -> UInt64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: URL(fileURLWithPath: path),
                                             includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        else { return 0 }

        var total: UInt64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true, let size = values?.fileSize else { continue }
            total += UInt64(size)
        }
        return total
    }

    static func isMachO(path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4), head.count == 4 else { return false }
        let magic = head.withUnsafeBytes { $0.load(as: UInt32.self) }
        return [0xfeed_facf, 0xfeed_face, 0xcffa_edfe, 0xcefa_edfe,
                0xbeba_feca, 0xbfba_feca].contains(magic)
    }

    // MARK: Mach-O segment reading

    static func readSlices(path: String) throws -> [SliceSize] {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw MeasureError.notFound(path: path)
        }
        guard data.count >= 8 else { throw MeasureError.notMachO(path: path) }

        let fatMagic = data.u32(0, big: true)
        var offsets: [Int] = []
        if fatMagic == 0xcafe_babe || fatMagic == 0xcafe_babf {
            let is64 = fatMagic == 0xcafe_babf
            let count = Int(data.u32(4, big: true))
            let entry = is64 ? 32 : 20
            guard count > 0, 8 + count * entry <= data.count else {
                throw MeasureError.notMachO(path: path)
            }
            offsets = (0..<count).map { i in
                let base = 8 + i * entry
                return is64 ? Int(data.u64(base + 8, big: true)) : Int(data.u32(base + 8, big: true))
            }
        } else {
            offsets = [0]
        }

        return try offsets.map { try readSlice(data, at: $0, path: path) }
    }

    private static func readSlice(_ data: Data, at base: Int, path: String) throws -> SliceSize {
        guard base + 28 <= data.count else { throw MeasureError.notMachO(path: path) }

        let raw = data.u32(base, big: false)
        let is64: Bool, swap: Bool
        switch raw {
        case 0xfeed_facf: is64 = true;  swap = false
        case 0xfeed_face: is64 = false; swap = false
        case 0xcffa_edfe: is64 = true;  swap = true
        case 0xcefa_edfe: is64 = false; swap = true
        default: throw MeasureError.notMachO(path: path)
        }

        let cpuType = Int32(bitPattern: data.u32(base + 4, big: swap))
        let cpuSubtype = Int32(bitPattern: data.u32(base + 8, big: swap))
        let ncmds = Int(data.u32(base + 16, big: swap))

        var segments: [SegmentSize] = []
        var cursor = base + (is64 ? 32 : 28)

        for _ in 0..<ncmds {
            guard cursor + 8 <= data.count else { break }
            let cmd = data.u32(cursor, big: swap)
            let size = Int(data.u32(cursor + 4, big: swap))
            guard size >= 8, cursor + size <= data.count else { break }

            // LC_SEGMENT_64 (0x19) and LC_SEGMENT (0x1)
            if cmd == 0x19 || cmd == 0x1 {
                let wide = cmd == 0x19
                if let name = data.fixedString(at: cursor + 8, length: 16) {
                    let fileSize = wide
                        ? data.u64(cursor + 48, big: swap)
                        : UInt64(data.u32(cursor + 36, big: swap))
                    let vmSize = wide
                        ? data.u64(cursor + 32, big: swap)
                        : UInt64(data.u32(cursor + 28, big: swap))
                    segments.append(SegmentSize(name: name, fileSize: fileSize, vmSize: vmSize))
                }
            }
            cursor += size
        }

        return SliceSize(architecture: architectureName(cpuType, cpuSubtype), segments: segments)
    }

    static func architectureName(_ cpuType: Int32, _ subtype: Int32) -> String {
        switch cpuType {
        case 0x0100_000c: return (subtype & 0x00ff_ffff) == 2 ? "arm64e" : "arm64"
        case 0x0000_000c: return "arm"
        case 0x0100_0007: return "x86_64"
        case 0x0000_0007: return "i386"
        default: return "cpu(\(cpuType))"
        }
    }
}

// MARK: - Bounds-checked reads

extension Data {
    func u32(_ offset: Int, big: Bool) -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { return 0 }
        let b = startIndex + offset
        let x = (0..<4).map { UInt32(self[b + $0]) }
        return big ? (x[0] << 24 | x[1] << 16 | x[2] << 8 | x[3])
                   : (x[3] << 24 | x[2] << 16 | x[1] << 8 | x[0])
    }

    func u64(_ offset: Int, big: Bool) -> UInt64 {
        guard offset >= 0, offset + 8 <= count else { return 0 }
        let hi = UInt64(u32(big ? offset : offset + 4, big: big))
        let lo = UInt64(u32(big ? offset + 4 : offset, big: big))
        return hi << 32 | lo
    }

    func fixedString(at offset: Int, length: Int) -> String? {
        guard offset >= 0, offset + length <= count else { return nil }
        let slice = subdata(in: (startIndex + offset)..<(startIndex + offset + length))
        return String(data: slice.prefix { $0 != 0 }, encoding: .utf8)
    }
}
