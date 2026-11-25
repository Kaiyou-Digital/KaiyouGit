import CLibGit2
import Foundation

/// How a path differs, in one of the two columns of `git status`.
public enum Change: Sendable {
    /// New in the index (staged).
    case added
    /// Content or type changed.
    case modified
    /// Removed.
    case deleted
    /// Not tracked and not ignored; only ever in `StatusEntry.workingTree`.
    case untracked
}

/// One path in `git status --porcelain=v1 --no-renames -uall` terms: `index` is the staged change
/// (HEAD to index), `workingTree` the unstaged one (index to working tree; `.untracked` only here).
public struct StatusEntry: Equatable, Sendable {
    /// The path relative to the working tree, with `/` separators.
    public let path: String
    /// The staged change, or nil when the index matches HEAD.
    public let index: Change?
    /// The unstaged change, or nil when the working tree matches the index.
    public let workingTree: Change?

    /// An entry with these columns.
    public init(path: String, index: Change?, workingTree: Change?) {
        self.path = path
        self.index = index
        self.workingTree = workingTree
    }
}

/// Heap copies of `strings` as a `git_strarray`; the caller must `free()` it (use `defer`).
struct CStrings {
    let array: git_strarray
    private let copies: [UnsafeMutablePointer<CChar>?]

    init(_ strings: [String]) {
        copies = strings.map { strdup($0) }
        let buffer = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: max(copies.count, 1))
        buffer.initialize(from: copies, count: copies.count)
        array = git_strarray(strings: buffer, count: copies.count)
    }

    /// For a pathspec handed to a libgit2 diff. Its matcher reads a bare `.` as everything, but the diff walks only
    /// paths that start with the pathspec's literal prefix (`git_pathspec_prefix`), so `.` reached only dotfiles; `*`
    /// also matches everything and has no prefix.
    init(pathspec paths: [String]) {
        self.init(paths.map(normalizePath).map { $0 == "." ? "*" : $0 })
    }

    func free() {
        copies.forEach { Foundation.free($0) }
        array.strings?.deallocate()
    }
}

/// `./x` and `x/.` mean `x`, and a trailing `/` is dropped; libgit2 matches these spellings literally and finds
/// nothing.
/// A bare `.` stays as it is.
func normalizePath(_ original: String) -> String {
    var path = original
    while path.hasPrefix("./") {
        path.removeFirst(2)
    }
    while path.count > 1, path.hasSuffix("/") || path.hasSuffix("/.") {
        path.removeLast(path.hasSuffix("/.") ? 2 : 1)
    }
    return path.isEmpty && !original.isEmpty ? "." : path
}

/// Working tree and index operations: status, staging, commit, reset and checkout.
public extension Repository {
    /// `git status --porcelain=v1 --no-renames -uall`, optionally limited to `paths` (files, directories or globs).
    func status(paths: [String] = []) throws -> [StatusEntry] {
        var opts = git_status_options()
        try check(git_status_options_init(&opts, UInt32(GIT_STATUS_OPTIONS_VERSION)))
        opts.show = GIT_STATUS_SHOW_INDEX_AND_WORKDIR
        opts.flags = GIT_STATUS_OPT_INCLUDE_UNTRACKED.rawValue | GIT_STATUS_OPT_RECURSE_UNTRACKED_DIRS.rawValue
        let specs = CStrings(pathspec: paths)
        defer { specs.free() }
        opts.pathspec = specs.array
        var list: OpaquePointer?
        try check(git_status_list_new(&list, handle, &opts))
        defer { git_status_list_free(list) }

        var entries: [StatusEntry] = []
        for position in 0 ..< git_status_list_entrycount(list) {
            guard let entry = git_status_byindex(list, position)?.pointee,
                  let delta = (entry.head_to_index ?? entry.index_to_workdir)?.pointee,
                  let cPath = delta.new_file.path ?? delta.old_file.path else { continue }
            let flags = entry.status.rawValue
            func has(_ flag: git_status_t) -> Bool {
                flags & flag.rawValue != 0
            }
            let index: Change? = if has(GIT_STATUS_INDEX_NEW) {
                .added
            } else if has(GIT_STATUS_INDEX_MODIFIED) || has(GIT_STATUS_INDEX_TYPECHANGE) {
                .modified
            } else if has(GIT_STATUS_INDEX_DELETED) {
                .deleted
            } else {
                nil
            }
            let workingTree: Change? = if has(GIT_STATUS_WT_NEW) {
                .untracked
            } else if has(GIT_STATUS_WT_MODIFIED) || has(GIT_STATUS_WT_TYPECHANGE) {
                .modified
            } else if has(GIT_STATUS_WT_DELETED) {
                .deleted
            } else {
                nil
            }
            entries.append(StatusEntry(path: String(cString: cPath), index: index, workingTree: workingTree))
        }
        return entries
    }

    /// `git add -A -- paths`: adds, modifies and removes, so a deleted file is staged as deleted. `paths` may be files,
    /// directories or globs (and `.`). Unlike git, a path that is ignored and named explicitly, or that matches
    /// nothing, is skipped without an error. The index is read from disk first, so staging done elsewhere is kept.
    func stage(paths: [String]) throws {
        guard !paths.isEmpty else { return }
        try addToIndex(paths)
    }

    /// `git add -A`.
    func stageAll() throws {
        try addToIndex(nil)
    }

    /// `git reset -q -- paths`; with no commits yet the entries are simply removed from the index. `paths` may be
    /// files, directories or globs (and `.`).
    func unstage(paths: [String]) throws {
        guard !paths.isEmpty else { return }
        var shared: OpaquePointer?
        try check(git_repository_index(&shared, handle))
        defer { git_index_free(shared) }
        try check(git_index_read(shared, 0)) // staging done elsewhere since the last read must survive
        var target: OpaquePointer?
        if git_repository_head_unborn(handle) != 1 { try check(git_revparse_single(&target, handle, "HEAD")) }
        defer { git_object_free(target) }
        let specs = CStrings(pathspec: paths)
        defer { specs.free() }
        var array = specs.array
        try check(git_reset_default(handle, target, &array))
    }

    /// Without `paths`, commits what is staged. With `paths`, behaves like `git commit -m msg -- paths`:
    /// those working-tree paths (files, or directories covering everything under them) are committed
    /// and the rest of the index is left alone. `paths` are plain file paths and directory names only: a glob or `.`
    /// matches nothing here. Unlike git, a path that is ignored and named explicitly, or that matches nothing, is
    /// skipped without an error (`commit(paths: ["dir", "config"])` commits only `dir` when `config` is ignored).
    /// Throws `.nothingToCommit` when there is nothing to commit; the index is then as it was. Throws
    /// `.commitCreatedButIndexNotSaved` when the commit landed but the index file could not be written; the commit
    /// exists, so do not retry.
    @discardableResult
    func commit(message: String, author: Author, paths: [String]? = nil) throws -> CommitID {
        if paths?.isEmpty == true { throw GitError.nothingToCommit }
        let paths = paths?.map(normalizePath)
        var index: OpaquePointer?
        try check(git_repository_index(&index, handle))
        defer { git_index_free(index) }
        try check(git_index_read(index, 0))

        var parentOid = git_oid()
        var parent: OpaquePointer?
        if git_reference_name_to_id(&parentOid, handle, "HEAD") == 0 {
            try check(git_commit_lookup(&parent, handle, &parentOid))
        }
        defer { git_commit_free(parent) }

        // A path-scoped commit stages its paths in the shared index first; undo that unless it lands.
        var landed = paths == nil
        defer { if !landed { git_index_read(index, 1) } }

        var treeOid = git_oid()
        var entryCount = 0
        if let paths {
            try addToIndex(paths, index: index)
            entryCount = try writeScopedTree(&treeOid, paths: paths, index: index, parent: parent)
        } else {
            try check(git_index_write_tree(&treeOid, index))
            entryCount = git_index_entrycount(index)
        }
        let unchanged = parent.map { git_oid_equal(git_commit_tree_id($0), &treeOid) != 0 } ?? (entryCount == 0)
        if unchanged { throw GitError.nothingToCommit }

        var tree: OpaquePointer?
        try check(git_tree_lookup(&tree, handle, &treeOid))
        defer { git_tree_free(tree) }
        var signature: UnsafeMutablePointer<git_signature>?
        try check(git_signature_now(&signature, author.name, author.email))
        defer { git_signature_free(signature) }

        let text = message.hasSuffix("\n") ? message : message + "\n"
        var commitOid = git_oid()
        var parents: [OpaquePointer?] = parent.map { [$0] } ?? []
        try check(git_commit_create(
            &commitOid,
            handle,
            "HEAD",
            signature,
            signature,
            nil,
            text,
            tree,
            parents.count,
            &parents
        ))
        landed = true // the commit exists now: a failed index write below must not reverse its paths
        let id = CommitID(hex: String(cString: git_oid_tostr_s(&commitOid)))
        try saveIndexAfterCommit(index, commit: id)
        return id
    }

    /// Saves the index after a commit landed; a failure is `.commitCreatedButIndexNotSaved`, not a plain error.
    private func saveIndexAfterCommit(_ index: OpaquePointer?, commit: CommitID) throws(GitError) {
        guard git_index_write(index) < 0 else { return }
        let reason = git_error_last().map { String(cString: $0.pointee.message) } ?? "no message"
        throw .commitCreatedButIndexNotSaved(commit: commit, reason: reason)
    }

    /// Writes the tree for HEAD with only `paths` taken from `index`; returns its entry count.
    private func writeScopedTree(
        _ oid: inout git_oid, paths: [String], index: OpaquePointer?, parent: OpaquePointer?
    ) throws(GitError) -> Int {
        var scoped: OpaquePointer?
        try check(git_index_new(&scoped))
        defer { git_index_free(scoped) }
        if parent != nil {
            var parentTree: OpaquePointer?
            try check(git_commit_tree(&parentTree, parent))
            defer { git_tree_free(parentTree) }
            try check(git_index_read_tree(scoped, parentTree))
        }
        // A path covers itself and, as a directory, everything under it; drop what HEAD has there
        // (so deletions land), then take what the index has there.
        let specs = paths.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
        func covered(_ entry: UnsafePointer<git_index_entry>) -> Bool {
            let path = String(cString: entry.pointee.path)
            return specs.contains { path == $0 || path.hasPrefix($0 + "/") }
        }
        var dropped: [String] = []
        for position in 0 ..< git_index_entrycount(scoped) {
            if let entry = git_index_get_byindex(scoped, position), covered(entry) {
                dropped.append(String(cString: entry.pointee.path))
            }
        }
        for path in dropped {
            _ = git_index_remove(scoped, path, 0)
        }
        for position in 0 ..< git_index_entrycount(index) {
            if let entry = git_index_get_byindex(index, position), covered(entry) {
                try check(git_index_add(scoped, entry))
            }
        }
        try check(git_index_write_tree_to(&oid, scoped, handle))
        return git_index_entrycount(scoped)
    }

    /// `git check-ignore --no-index`: what the ignore rules say, whether or not the path is tracked. Throws for a
    /// path that is not a plain relative one (empty, absolute, or with `.` or `..` anywhere in it) and for any libgit2
    /// failure, never reading either as "not ignored".
    func isIgnored(_ path: String) throws -> Bool {
        let path = normalizePath(path)
        let parts = path.split(separator: "/")
        if path.isEmpty || path.hasPrefix("/") || parts.contains(".") || parts.contains("..") {
            throw GitError.other(class: 0, code: -1, message: "'\(path)' is not a plain path inside the working tree")
        }
        var ignored: Int32 = 0
        try check(git_ignore_path_is_ignored(&ignored, handle, path))
        return ignored == 1
    }

    /// `git reset --hard rev`.
    func resetHard(to rev: String = "HEAD") throws {
        var target: OpaquePointer?
        try check(git_revparse_single(&target, handle, rev))
        defer { git_object_free(target) }
        try check(git_reset(handle, target, GIT_RESET_HARD, nil))
    }

    /// `git checkout rev -- paths`: writes those files from `rev` into the working tree and the index. `paths` are
    /// plain file paths and directory names only (no globs, no `.`); a directory restores the files `rev` has under
    /// it and leaves every other file there alone. Throws `.notFound` for a path `rev` lacks.
    func checkout(paths: [String], from rev: String = "HEAD") throws {
        guard !paths.isEmpty else { return }
        let paths = paths.map(normalizePath)
        var object: OpaquePointer?
        try check(git_revparse_single(&object, handle, rev))
        defer { git_object_free(object) }
        var tree: OpaquePointer?
        try check(git_object_peel(&tree, object, GIT_OBJECT_TREE))
        defer { git_object_free(tree) }
        // git refuses a path the rev does not have; under FORCE libgit2 would delete the tracked file instead.
        for path in paths {
            var entry: OpaquePointer?
            guard git_tree_entry_bypath(&entry, tree, path) == 0 else {
                throw GitError.notFound("pathspec '\(path)' did not match any file(s) known to git")
            }
            git_tree_entry_free(entry)
        }
        // A directory pathspec under FORCE makes libgit2 delete every index-tracked file under it that `rev` lacks
        // (staged-new files, files added since `rev`). So name exactly the files `rev` has there, matched literally.
        var scratch: OpaquePointer?
        try check(git_index_new(&scratch))
        defer { git_index_free(scratch) }
        try check(git_index_read_tree(scratch, tree))
        var files: [String] = []
        for position in 0 ..< git_index_entrycount(scratch) {
            guard let entry = git_index_get_byindex(scratch, position) else { continue }
            let name = String(cString: entry.pointee.path)
            if paths.contains(where: { name == $0 || name.hasPrefix($0 + "/") }) { files.append(name) }
        }
        guard !files.isEmpty else { throw GitError.notFound("no file in \(rev) matches \(paths)") } // empty means all
        var opts = git_checkout_options()
        try check(git_checkout_options_init(&opts, UInt32(GIT_CHECKOUT_OPTIONS_VERSION)))
        opts.checkout_strategy = GIT_CHECKOUT_FORCE.rawValue | GIT_CHECKOUT_DISABLE_PATHSPEC_MATCH.rawValue
        let specs = CStrings(files)
        defer { specs.free() }
        opts.paths = specs.array
        try check(git_checkout_tree(handle, tree, &opts))
    }

    /// `git add -A` for `paths` (all when nil): adds, modifies and removes, then saves the index.
    private func addToIndex(_ paths: [String]?) throws(GitError) {
        var index: OpaquePointer?
        try check(git_repository_index(&index, handle))
        defer { git_index_free(index) }
        try check(git_index_read(index, 0))
        try addToIndex(paths, index: index)
        try check(git_index_write(index))
    }

    private func addToIndex(_ paths: [String]?, index: OpaquePointer?) throws(GitError) {
        guard let paths else { // all of them
            try check(git_index_add_all(index, nil, 0, nil, nil))
            try check(git_index_update_all(index, nil, nil, nil))
            return
        }
        let specs = CStrings(paths.map(normalizePath))
        defer { specs.free() }
        var array = specs.array
        try check(git_index_add_all(index, &array, 0, nil, nil))
        try check(git_index_update_all(index, &array, nil, nil))
    }
}
