// Crash and hang reports from iOS (MetricKit). After a crash, iOS hands the
// app a diagnostic payload on a later launch: the crashing thread's stack,
// the exception, or that it was killed for memory. Each payload is saved as
// JSON under Documents/lumber/diagnostics so it can be shared from the
// Library ("Share crash report").

import Foundation
import MetricKit

final class CrashReports: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = CrashReports()

    static var directory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("lumber/diagnostics", isDirectory: true)
    }

    /// Saved reports, newest first.
    static func saved() -> [URL] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a > b
            }
    }

    func start() {
        MXMetricManager.shared.add(self)
        save(MXMetricManager.shared.pastDiagnosticPayloads)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) { save(payloads) }

    private func save(_ payloads: [MXDiagnosticPayload]) {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withFullDate, .withTime]
        for p in payloads {
            let interesting = (p.crashDiagnostics?.isEmpty == false) || (p.hangDiagnostics?.isEmpty == false)
                || (p.cpuExceptionDiagnostics?.isEmpty == false) || (p.diskWriteExceptionDiagnostics?.isEmpty == false)
            guard interesting else { continue }
            let name = "lumber-diagnostic-\(stamp.string(from: p.timeStampEnd)).json".replacingOccurrences(of: ":", with: "")
            let url = Self.directory.appendingPathComponent(name)
            if !fm.fileExists(atPath: url.path) { try? p.jsonRepresentation().write(to: url) }
        }
        // Keep the 10 newest.
        for old in Self.saved().dropFirst(10) { try? fm.removeItem(at: old) }
    }
}
