import Foundation
import libgit2

public struct GitError: LocalizedError {
    public let code: Int32
    public let message: String

    public var isAuth: Bool { code == GIT_EAUTH.rawValue }
    public var isNonFastForward: Bool { code == GIT_ENONFASTFORWARD.rawValue }

    public var errorDescription: String? {
        isAuth ? "Authentication failed. Check the username and access token in Sync settings." : message
    }
}

public struct GitCredentials: Sendable {
    public var username: String
    public var password: String
    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }
}

public struct GitAuthor: Sendable {
    public var name: String
    public var email: String
    public init(name: String, email: String) {
        self.name = name
        self.email = email
    }
}

/// One file that both sides changed since the common ancestor.
public struct MergeConflict {
    public let path: String
    public let base: Data?
    public let ours: Data?
    public let theirs: Data?
}

public enum ConflictResolution {
    /// Replace the file with merged content.
    case write(Data)
    /// Keep the local version in place and save the remote one next to it as a conflict copy.
    case keepBoth
}

public enum MergeOutcome: Equatable {
    case nothingToMerge
    case upToDate
    case fastForward
    case merged(conflicts: [String])

    public var changedWorkingTree: Bool {
        switch self {
        case .fastForward, .merged: return true
        default: return false
        }
    }
}

@discardableResult
func gitCheck(_ code: Int32, _ context: String = "") throws -> Int32 {
    guard code < 0 else { return code }
    var detail = "git error \(code)"
    if let err = git_error_last(), let msg = err.pointee.message {
        detail = String(cString: msg)
    }
    throw GitError(code: code, message: context.isEmpty ? detail : "\(context): \(detail)")
}

private final class CallbackBox {
    let credentials: GitCredentials?
    var attempts = 0
    var pushError: String?
    init(_ credentials: GitCredentials?) { self.credentials = credentials }
}

private let credentialsCallback: git_credential_acquire_cb = { out, _, _, allowedTypes, payload in
    guard let payload else { return GIT_EAUTH.rawValue }
    let box = Unmanaged<CallbackBox>.fromOpaque(payload).takeUnretainedValue()
    box.attempts += 1
    // libgit2 re-asks after a rejected credential; stop instead of looping forever.
    guard box.attempts <= 2, let creds = box.credentials else { return GIT_EAUTH.rawValue }
    guard allowedTypes & GIT_CREDENTIAL_USERPASS_PLAINTEXT.rawValue != 0 else { return GIT_EAUTH.rawValue }
    return git_credential_userpass_plaintext_new(out, creds.username, creds.password)
}

private let pushUpdateCallback: git_push_update_reference_cb = { _, status, payload in
    if let status, let payload {
        let box = Unmanaged<CallbackBox>.fromOpaque(payload).takeUnretainedValue()
        box.pushError = String(cString: status)
    }
    return 0
}

/// Thin wrapper over the parts of libgit2 that Jet's sync needs.
public final class GitRepository {
    let repo: OpaquePointer
    public let path: String

    private static let initialize: Void = { _ = git_libgit2_init() }()

    private init(repo: OpaquePointer, path: String) {
        self.repo = repo
        self.path = path
    }

    deinit { git_repository_free(repo) }

    // MARK: Opening

    public static func isRepository(at path: String) -> Bool {
        FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(".git"))
    }

    public static func open(at path: String) throws -> GitRepository {
        _ = initialize
        var repo: OpaquePointer?
        try gitCheck(git_repository_open(&repo, path), "Could not open repository")
        return GitRepository(repo: repo!, path: path)
    }

    public static func create(at path: String, branch: String = "main") throws -> GitRepository {
        _ = initialize
        var repo: OpaquePointer?
        try gitCheck(git_repository_init(&repo, path, 0), "Could not create repository")
        let result = GitRepository(repo: repo!, path: path)
        try gitCheck(git_repository_set_head(repo, "refs/heads/\(branch)"))
        return result
    }

    public static func openOrCreate(at path: String) throws -> GitRepository {
        isRepository(at: path) ? try open(at: path) : try create(at: path)
    }

    public static func clone(from url: String, to path: String, credentials: GitCredentials?) throws -> GitRepository {
        _ = initialize
        var options = git_clone_options()
        git_clone_options_init(&options, UInt32(GIT_CLONE_OPTIONS_VERSION))
        let box = Unmanaged.passRetained(CallbackBox(credentials))
        defer { box.release() }
        options.fetch_opts.callbacks.credentials = credentialsCallback
        options.fetch_opts.callbacks.payload = box.toOpaque()
        var repo: OpaquePointer?
        try gitCheck(git_clone(&repo, url, path, &options), "Clone failed")
        return GitRepository(repo: repo!, path: path)
    }

    // MARK: Remote

    public var remoteURL: String? {
        var remote: OpaquePointer?
        guard git_remote_lookup(&remote, repo, "origin") == 0 else { return nil }
        defer { git_remote_free(remote) }
        guard let url = git_remote_url(remote) else { return nil }
        return String(cString: url)
    }

    public func setRemoteURL(_ url: String) throws {
        if remoteURL == nil {
            var remote: OpaquePointer?
            try gitCheck(git_remote_create(&remote, repo, "origin", url), "Could not add remote")
            git_remote_free(remote)
        } else {
            try gitCheck(git_remote_set_url(repo, "origin", url), "Could not update remote")
        }
    }

    // MARK: Refs

    /// Full name of the checked-out branch, e.g. `refs/heads/main` (works before the first commit too).
    public func currentBranchRef() throws -> String {
        var ref: OpaquePointer?
        try gitCheck(git_reference_lookup(&ref, repo, "HEAD"))
        defer { git_reference_free(ref) }
        guard let target = git_reference_symbolic_target(ref) else {
            throw GitError(code: -1, message: "HEAD is detached; check out a branch to sync.")
        }
        return String(cString: target)
    }

    private func oid(forRef name: String) -> git_oid? {
        var oid = git_oid()
        return git_reference_name_to_id(&oid, repo, name) == 0 ? oid : nil
    }

    private func oidsEqual(_ a: git_oid, _ b: git_oid) -> Bool {
        var a = a, b = b
        return git_oid_equal(&a, &b) != 0
    }

    private func remoteTrackingRef() throws -> String {
        let branch = try currentBranchRef()
        return "refs/remotes/origin/" + branch.dropFirst("refs/heads/".count)
    }

    /// True when the local branch has commits the remote-tracking branch does not point at.
    public func needsPush() throws -> Bool {
        guard let head = oid(forRef: "HEAD") else { return false }
        guard let remote = oid(forRef: try remoteTrackingRef()) else { return true }
        return !oidsEqual(head, remote)
    }

    // MARK: Committing

    /// Stages every addition, modification and deletion, returning the resulting tree id.
    private func stageAll() throws -> git_oid {
        var index: OpaquePointer?
        try gitCheck(git_repository_index(&index, repo))
        defer { git_index_free(index) }
        try gitCheck(git_index_add_all(index, nil, GIT_INDEX_ADD_DEFAULT.rawValue, nil, nil))
        try gitCheck(git_index_update_all(index, nil, nil, nil))
        try gitCheck(git_index_write(index))
        var tree = git_oid()
        try gitCheck(git_index_write_tree(&tree, index))
        return tree
    }

    private func treeOid(ofCommit oid: git_oid) throws -> git_oid {
        var oid = oid
        var commit: OpaquePointer?
        try gitCheck(git_commit_lookup(&commit, repo, &oid))
        defer { git_commit_free(commit) }
        return git_commit_tree_id(commit).pointee
    }

    private func commit(tree treeOid: git_oid, parents parentOids: [git_oid], message: String, author: GitAuthor) throws {
        var treeOid = treeOid
        var tree: OpaquePointer?
        try gitCheck(git_tree_lookup(&tree, repo, &treeOid))
        defer { git_tree_free(tree) }

        var signature: UnsafeMutablePointer<git_signature>?
        try gitCheck(git_signature_now(&signature, author.name, author.email))
        defer { git_signature_free(signature) }

        var parents: [OpaquePointer?] = []
        defer { parents.forEach { git_commit_free($0) } }
        for var oid in parentOids {
            var commit: OpaquePointer?
            try gitCheck(git_commit_lookup(&commit, repo, &oid))
            parents.append(commit)
        }

        var newOid = git_oid()
        try gitCheck(
            git_commit_create(&newOid, repo, "HEAD", signature, signature, nil, message, tree, parents.count, &parents),
            "Commit failed"
        )
    }

    /// Commits everything in the working tree. Returns false when there was nothing to commit.
    @discardableResult
    public func commitAll(message: String, author: GitAuthor) throws -> Bool {
        let tree = try stageAll()
        if let head = oid(forRef: "HEAD") {
            if oidsEqual(try treeOid(ofCommit: head), tree) { return false }
            try commit(tree: tree, parents: [head], message: message, author: author)
        } else {
            var index: OpaquePointer?
            try gitCheck(git_repository_index(&index, repo))
            defer { git_index_free(index) }
            guard git_index_entrycount(index) > 0 else { return false }
            try commit(tree: tree, parents: [], message: message, author: author)
        }
        return true
    }

    /// Number of files that differ from the last commit.
    public func changeCount() -> Int {
        var options = git_status_options()
        git_status_options_init(&options, UInt32(GIT_STATUS_OPTIONS_VERSION))
        options.show = GIT_STATUS_SHOW_INDEX_AND_WORKDIR
        options.flags = GIT_STATUS_OPT_INCLUDE_UNTRACKED.rawValue | GIT_STATUS_OPT_RECURSE_UNTRACKED_DIRS.rawValue
        var list: OpaquePointer?
        guard git_status_list_new(&list, repo, &options) == 0 else { return 0 }
        defer { git_status_list_free(list) }
        return git_status_list_entrycount(list)
    }

    // MARK: Network

    public func fetch(credentials: GitCredentials?) throws {
        var remote: OpaquePointer?
        try gitCheck(git_remote_lookup(&remote, repo, "origin"), "No remote configured")
        defer { git_remote_free(remote) }
        var options = git_fetch_options()
        git_fetch_options_init(&options, UInt32(GIT_FETCH_OPTIONS_VERSION))
        let box = Unmanaged.passRetained(CallbackBox(credentials))
        defer { box.release() }
        options.callbacks.credentials = credentialsCallback
        options.callbacks.payload = box.toOpaque()
        try gitCheck(git_remote_fetch(remote, nil, &options, nil), "Fetch failed")
    }

    public func push(credentials: GitCredentials?) throws {
        let branch = try currentBranchRef()
        var remote: OpaquePointer?
        try gitCheck(git_remote_lookup(&remote, repo, "origin"), "No remote configured")
        defer { git_remote_free(remote) }

        var options = git_push_options()
        git_push_options_init(&options, UInt32(GIT_PUSH_OPTIONS_VERSION))
        let callbackBox = CallbackBox(credentials)
        let box = Unmanaged.passRetained(callbackBox)
        defer { box.release() }
        options.callbacks.credentials = credentialsCallback
        options.callbacks.push_update_reference = pushUpdateCallback
        options.callbacks.payload = box.toOpaque()

        let refspec = strdup("\(branch):\(branch)")
        defer { free(refspec) }
        var strings: [UnsafeMutablePointer<CChar>?] = [refspec]
        let code = strings.withUnsafeMutableBufferPointer { buffer -> Int32 in
            var array = git_strarray(strings: buffer.baseAddress, count: 1)
            return git_remote_push(remote, &array, &options)
        }
        try gitCheck(code, "Push failed")
        if let rejected = callbackBox.pushError {
            throw GitError(code: GIT_ENONFASTFORWARD.rawValue, message: "Push rejected: \(rejected)")
        }
    }

    // MARK: Merging

    /// Brings the fetched remote branch into the local one. Expects a clean (fully committed) working tree.
    public func integrateRemote(
        author: GitAuthor,
        message: String,
        conflictSuffix: String,
        resolver: (MergeConflict) -> ConflictResolution
    ) throws -> MergeOutcome {
        let branchRef = try currentBranchRef()
        guard var theirOid = oid(forRef: try remoteTrackingRef()) else { return .nothingToMerge }

        var annotated: OpaquePointer?
        try gitCheck(git_annotated_commit_lookup(&annotated, repo, &theirOid))
        defer { git_annotated_commit_free(annotated) }
        var heads: [OpaquePointer?] = [annotated]

        var analysis = git_merge_analysis_t(rawValue: 0)
        var preference = git_merge_preference_t(rawValue: 0)
        try gitCheck(git_merge_analysis(&analysis, &preference, repo, &heads, 1))

        if analysis.rawValue & GIT_MERGE_ANALYSIS_UP_TO_DATE.rawValue != 0 {
            return .upToDate
        }

        let canFastForward = analysis.rawValue
            & (GIT_MERGE_ANALYSIS_FASTFORWARD.rawValue | GIT_MERGE_ANALYSIS_UNBORN.rawValue) != 0
        if canFastForward {
            var target: OpaquePointer?
            try gitCheck(git_object_lookup(&target, repo, &theirOid, GIT_OBJECT_COMMIT))
            defer { git_object_free(target) }
            var checkout = git_checkout_options()
            git_checkout_options_init(&checkout, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
            checkout.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue | GIT_CHECKOUT_RECREATE_MISSING.rawValue
            try gitCheck(git_checkout_tree(repo, target, &checkout), "Could not update files")
            var newRef: OpaquePointer?
            try gitCheck(git_reference_create(&newRef, repo, branchRef, &theirOid, 1, "jet: fast-forward"))
            git_reference_free(newRef)
            return .fastForward
        }

        guard let headOid = oid(forRef: "HEAD") else { return .nothingToMerge }

        var mergeOptions = git_merge_options()
        git_merge_options_init(&mergeOptions, UInt32(GIT_MERGE_OPTIONS_VERSION))
        var checkout = git_checkout_options()
        git_checkout_options_init(&checkout, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
        checkout.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue | GIT_CHECKOUT_ALLOW_CONFLICTS.rawValue
        try gitCheck(git_merge(repo, &heads, 1, &mergeOptions, &checkout), "Merge failed")
        defer { git_repository_state_cleanup(repo) }

        var index: OpaquePointer?
        try gitCheck(git_repository_index(&index, repo))
        defer { git_index_free(index) }

        var conflicts: [MergeConflict] = []
        if git_index_has_conflicts(index) != 0 {
            var iterator: OpaquePointer?
            try gitCheck(git_index_conflict_iterator_new(&iterator, index))
            defer { git_index_conflict_iterator_free(iterator) }
            var ancestor: UnsafePointer<git_index_entry>?
            var ours: UnsafePointer<git_index_entry>?
            var theirs: UnsafePointer<git_index_entry>?
            while git_index_conflict_next(&ancestor, &ours, &theirs, iterator) == 0 {
                guard let entry = ours ?? theirs ?? ancestor, let cPath = entry.pointee.path else { continue }
                conflicts.append(MergeConflict(
                    path: String(cString: cPath),
                    base: blobData(ancestor),
                    ours: blobData(ours),
                    theirs: blobData(theirs)
                ))
            }
        }

        let root = URL(fileURLWithPath: path)
        for conflict in conflicts {
            let fileURL = root.appendingPathComponent(conflict.path)
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            switch (conflict.ours, conflict.theirs) {
            case let (ours?, theirs?):
                switch resolver(conflict) {
                case .write(let merged):
                    try merged.write(to: fileURL, options: .atomic)
                case .keepBoth:
                    try ours.write(to: fileURL, options: .atomic)
                    let ext = fileURL.pathExtension
                    let base = fileURL.deletingPathExtension().lastPathComponent
                    var number = 1
                    while true {
                        let suffix = conflictSuffix + (number == 1 ? "" : " \(number)")
                        let name = "\(base) (\(suffix))" + (ext.isEmpty ? "" : ".\(ext)")
                        let copy = fileURL.deletingLastPathComponent().appendingPathComponent(name)
                        do {
                            try theirs.write(to: copy, options: .withoutOverwriting)
                            break
                        } catch let error as CocoaError where error.code == .fileWriteFileExists {
                            number += 1
                        }
                    }
                }
            case let (ours?, nil):
                // Deleted remotely, edited here: the edit wins.
                try ours.write(to: fileURL, options: .atomic)
            case let (nil, theirs?):
                // Deleted here, edited remotely: the edit wins.
                try theirs.write(to: fileURL, options: .atomic)
            case (nil, nil):
                try? FileManager.default.removeItem(at: fileURL)
            }
            try gitCheck(git_index_conflict_remove(index, conflict.path))
        }

        let tree = try stageAll()
        try commit(tree: tree, parents: [headOid, theirOid], message: message, author: author)
        return .merged(conflicts: conflicts.map(\.path))
    }

    private func blobData(_ entry: UnsafePointer<git_index_entry>?) -> Data? {
        guard let entry else { return nil }
        var oid = entry.pointee.id
        var blob: OpaquePointer?
        guard git_blob_lookup(&blob, repo, &oid) == 0 else { return nil }
        defer { git_blob_free(blob) }
        guard let raw = git_blob_rawcontent(blob) else { return Data() }
        return Data(bytes: raw, count: Int(git_blob_rawsize(blob)))
    }
}
