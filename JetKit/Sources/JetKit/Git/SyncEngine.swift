import Foundation

public struct SyncReport: Sendable {
    public var committed = false
    public var workingTreeChanged = false
    public var pushed = false
    public var hasRemote = true
    public var conflicts: [String] = []

    public var summary: String {
        guard hasRemote else { return committed ? "Committed locally" : "No remote configured" }
        if !conflicts.isEmpty {
            return conflicts.count == 1 ? "Synced, 1 conflict resolved" : "Synced, \(conflicts.count) conflicts resolved"
        }
        return "Synced"
    }
}

/// The whole sync cycle: commit local work, fetch, merge, push.
public enum SyncEngine {
    public static func sync(
        vaultPath: String,
        credentials: GitCredentials?,
        author: GitAuthor,
        deviceName: String
    ) throws -> SyncReport {
        var report = SyncReport()
        let repo = try GitRepository.openOrCreate(at: vaultPath)

        let stamp = timestamp()
        report.committed = try repo.commitAll(message: "Jet: \(deviceName) \(stamp)", author: author)

        guard repo.remoteURL != nil else {
            report.hasRemote = false
            return report
        }

        // Another device may push between our fetch and push, so retry a couple of times.
        var lastError: Error?
        for _ in 0..<3 {
            try repo.fetch(credentials: credentials)
            let outcome = try repo.integrateRemote(
                author: author,
                message: "Jet: merge on \(deviceName) \(stamp)",
                conflictSuffix: "conflict \(stamp.replacingOccurrences(of: ":", with: "."))",
                resolver: resolve
            )
            if outcome.changedWorkingTree { report.workingTreeChanged = true }
            if case .merged(let conflicts) = outcome { report.conflicts += conflicts }

            guard try repo.needsPush() else { return report }
            do {
                try repo.push(credentials: credentials)
                report.pushed = true
                return report
            } catch let error as GitError where error.isNonFastForward {
                lastError = error
            }
        }
        throw lastError ?? GitError(code: -1, message: "Sync failed after several attempts")
    }

    /// Handwriting merges stroke-by-stroke; everything else keeps both versions.
    static func resolve(_ conflict: MergeConflict) -> ConflictResolution {
        // The sidebar's manual order: this device's arrangement wins rather than leaving a copy.
        if conflict.path == VaultSession.orderFile, let ours = conflict.ours {
            return .write(ours)
        }
        if conflict.path.lowercased().hasSuffix(".ink"),
           let ours = conflict.ours, let theirs = conflict.theirs,
           let merged = InkMerge.merge(base: conflict.base, ours: ours, theirs: theirs) {
            return .write(merged)
        }
        return .keepBoth
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: Date())
    }
}
