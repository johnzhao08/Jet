import Foundation
import libgit2

public struct NoteRevision: Identifiable, Sendable {
    public var id: String { commit + "/" + path }
    public let path: String
    public let commit: String
    public let date: Date
    public let summary: String
}

extension GitRepository {
    /// Changes to a note, or the most recent committed version of each currently missing note.
    public func noteHistory(path note: String? = nil) throws -> [NoteRevision] {
        var walker: OpaquePointer?
        try gitCheck(git_revwalk_new(&walker, repo))
        defer { git_revwalk_free(walker) }
        if git_repository_head_unborn(repo) == 1 { return [] }
        git_revwalk_sorting(walker, GIT_SORT_TOPOLOGICAL.rawValue | GIT_SORT_TIME.rawValue)
        try gitCheck(git_revwalk_push_head(walker))
        var oid = git_oid()
        var revisions: [NoteRevision] = []
        var seen = Set<String>()
        var status = git_revwalk_next(&oid, walker)
        while status == 0 {
            var commit: OpaquePointer?, tree: OpaquePointer?, parent: OpaquePointer?, previous: OpaquePointer?
            var diff: OpaquePointer?
            defer {
                git_diff_free(diff)
                git_tree_free(previous)
                git_commit_free(parent)
                git_tree_free(tree)
                git_commit_free(commit)
            }
            try gitCheck(git_commit_lookup(&commit, repo, &oid))
            try gitCheck(git_commit_tree(&tree, commit))
            if git_commit_parentcount(commit) > 0 {
                try gitCheck(git_commit_parent(&parent, commit, 0))
                try gitCheck(git_commit_tree(&previous, parent))
            }
            try gitCheck(git_diff_tree_to_tree(&diff, repo, previous, tree, nil))
            for i in 0..<git_diff_num_deltas(diff) {
                guard let delta = git_diff_get_delta(diff, i)?.pointee,
                      let rawPath = delta.new_file.path,
                      [GIT_FILEMODE_BLOB.rawValue, GIT_FILEMODE_BLOB_EXECUTABLE.rawValue].contains(UInt32(delta.new_file.mode))
                else { continue }
                let name = String(cString: rawPath)
                if let note {
                    guard name == note else { continue }
                } else {
                    guard VaultSession.noteExtensions.contains((name as NSString).pathExtension.lowercased()),
                          !name.split(separator: "/").contains(where: { $0.hasPrefix(".") }),
                          seen.insert(name).inserted,
                          !FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(name))
                    else { continue }
                }
                revisions.append(NoteRevision(path: name, commit: String(cString: git_oid_tostr_s(&oid)),
                    date: Date(timeIntervalSince1970: Double(git_commit_time(commit))),
                    summary: git_commit_summary(commit).map { String(cString: $0) } ?? ""))
            }
            status = git_revwalk_next(&oid, walker)
        }
        if status != GIT_ITEROVER.rawValue { try gitCheck(status) }
        return revisions
    }

    private func revisionBlob(path: String, commit: String) throws -> OpaquePointer {
        guard commit.utf8.count == 40 && commit.allSatisfy(\.isHexDigit) else {
            throw GitError(code: -1, message: "Expected a full Git commit ID.")
        }
        var oid = git_oid(), version: OpaquePointer?, tree: OpaquePointer?, entry: OpaquePointer?, blob: OpaquePointer?
        defer { git_commit_free(version); git_tree_free(tree); git_tree_entry_free(entry) }
        try gitCheck(git_oid_fromstr(&oid, commit))
        try gitCheck(git_commit_lookup(&version, repo, &oid))
        try gitCheck(git_commit_tree(&tree, version))
        try gitCheck(git_tree_entry_bypath(&entry, tree, path))
        let mode = git_tree_entry_filemode(entry)
        guard mode == GIT_FILEMODE_BLOB || mode == GIT_FILEMODE_BLOB_EXECUTABLE else {
            throw GitError(code: -1, message: "The revision is not a regular file.")
        }
        try gitCheck(git_blob_lookup(&blob, repo, git_tree_entry_id(entry)))
        return blob!
    }

    public func noteVersion(path: String, commit: String) throws -> Data {
        let blob = try revisionBlob(path: path, commit: commit)
        defer { git_blob_free(blob) }
        guard let bytes = git_blob_rawcontent(blob) else { return Data() }
        return Data(bytes: bytes, count: Int(git_blob_rawsize(blob)))
    }

    public func noteDiff(path: String, from: String, to: String) throws -> String {
        let old = try revisionBlob(path: path, commit: from)
        defer { git_blob_free(old) }
        let new = try revisionBlob(path: path, commit: to)
        defer { git_blob_free(new) }
        var patch: OpaquePointer?, buffer = git_buf()
        defer { git_patch_free(patch); git_buf_dispose(&buffer) }
        try gitCheck(git_patch_from_blobs(&patch, old, path, new, path, nil))
        guard let patch else { return "No changes." }
        try gitCheck(git_patch_to_buf(&buffer, patch))
        guard let bytes = buffer.ptr, buffer.size > 0 else { return "No changes." }
        return String(decoding: UnsafeRawBufferPointer(start: bytes, count: buffer.size), as: UTF8.self)
    }
}

extension URL {
    /// Git history and MCP paths can come from outside Jet. Never traverse symlinks or hidden folders.
    func vaultFile(_ relative: String) throws -> URL {
        let root = standardizedFileURL.resolvingSymlinksInPath()
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.contains(where: { $0.isEmpty || $0.hasPrefix(".") }),
              !relative.utf8.contains(0) else { throw CocoaError(.fileReadInvalidFileName) }
        var url = root
        for part in parts {
            url.appendPathComponent(String(part))
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil {
                throw CocoaError(.fileReadNoPermission)
            }
        }
        return url
    }
}
