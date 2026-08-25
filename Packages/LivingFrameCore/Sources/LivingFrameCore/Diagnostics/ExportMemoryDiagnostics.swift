import Darwin.Mach
import Foundation
#if os(iOS)
import os
#endif

/// Lightweight export-only memory sampling. The logs are intentionally sparse so
/// diagnostics do not materially change frame rendering or encoder backpressure.
struct ExportMemoryDiagnostics {
    private struct Snapshot {
        let residentBytes: UInt64
        let residentPeakBytes: UInt64
        let footprintBytes: UInt64
        let internalBytes: UInt64
        let compressedBytes: UInt64
        let availableBytes: UInt64?
    }

    private let exporter: String
    private let baseline: Snapshot?
    private let frameInterval: Int
    private var peakFootprintBytes: UInt64

    init(exporter: String, frameCount: Int) {
        self.exporter = exporter
        // Aim for roughly 10-20 samples during a normal export, capped at every
        // 10 frames so short exports still show where a sudden jump occurred.
        frameInterval = max(1, min(10, frameCount / 12))
        baseline = Self.snapshot()
        peakFootprintBytes = baseline?.footprintBytes ?? 0
    }

    mutating func log(_ stage: String, frame: Int? = nil, totalFrames: Int? = nil) {
        guard let snapshot = Self.snapshot() else {
            LogStore.log("export.memory exporter=\(exporter) stage=\(stage) unavailable")
            return
        }
        peakFootprintBytes = max(peakFootprintBytes, snapshot.footprintBytes)
        let delta = Int64(snapshot.footprintBytes) - Int64(baseline?.footprintBytes ?? snapshot.footprintBytes)
        let frameText: String
        if let frame, let totalFrames {
            frameText = " frame=\(frame)/\(totalFrames)"
        } else {
            frameText = ""
        }
        let availableText = snapshot.availableBytes.map { " available=\(Self.mib($0))MB" } ?? ""
        LogStore.log(
            "export.memory exporter=\(exporter) stage=\(stage)\(frameText) "
                + "footprint=\(Self.mib(snapshot.footprintBytes))MB "
                + "delta=\(Self.signedMib(delta))MB "
                + "peakSample=\(Self.mib(peakFootprintBytes))MB "
                + "resident=\(Self.mib(snapshot.residentBytes))MB "
                + "residentPeak=\(Self.mib(snapshot.residentPeakBytes))MB "
                + "internal=\(Self.mib(snapshot.internalBytes))MB "
                + "compressed=\(Self.mib(snapshot.compressedBytes))MB"
                + availableText
        )
    }

    func shouldLog(frame index: Int, totalFrames: Int) -> Bool {
        index == 0 || index == totalFrames - 1 || (index + 1).isMultiple(of: frameInterval)
    }

    private static func snapshot() -> Snapshot? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_VM_INFO),
                    $0,
                    &count
                )
            }
        }
        guard status == KERN_SUCCESS else { return nil }

        #if os(iOS)
        let available = UInt64(os_proc_available_memory())
        #else
        let available: UInt64? = nil
        #endif
        return Snapshot(
            residentBytes: UInt64(info.resident_size),
            residentPeakBytes: UInt64(info.resident_size_peak),
            footprintBytes: UInt64(info.phys_footprint),
            internalBytes: UInt64(info.internal),
            compressedBytes: UInt64(info.compressed),
            availableBytes: available
        )
    }

    private static func mib(_ bytes: UInt64) -> String {
        String(format: "%.1f", Double(bytes) / 1_048_576)
    }

    private static func signedMib(_ bytes: Int64) -> String {
        String(format: "%+.1f", Double(bytes) / 1_048_576)
    }
}
