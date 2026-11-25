import CLibGit2
import Foundation

/// Read-only queries (history, revisions, file contents) and local configuration.
public extension Repository {
    /// `git rev-list -n 1 --all` has output: HEAD is born, or some ref peels to a commit.
    var hasCommits: Bool {
        if git_repository_head_unborn(handle) == 0 { return true } // 1 is unborn, below 0 an unreadable HEAD
        var names = git_strarray()
        defer { git_strarray_dispose(&names) }
        guard git_reference_list(&names, handle) == 0 else { return false }
        for position in 0 ..< names.count {
            var ref: OpaquePointer?
            var commit: OpaquePointer?
            defer {
                git_object_free(commit)
                git_reference_free(ref)
            }
            if git_reference_lookup(&ref, handle, names.strings[position]) == 0,
               git_reference_peel(&commit, ref, GIT_OBJECT_COMMIT) == 0 { return true }
        }
        return false
    }

    /// `git symbolic-ref --quiet HEAD` without `refs/heads/`; nil when detached. An unborn HEAD still names its branch.
    var currentBranch: String? {
        var head: OpaquePointer?
        guard git_reference_lookup(&head, handle, "HEAD") == 0 else { return nil }
        defer { git_reference_free(head) }
        guard let target = git_reference_symbolic_target(head) else { return nil }
        let name = String(cString: target)
        let prefix = "refs/heads/"
        return name.hasPrefix(prefix) ? String(name.dropFirst(prefix.count)) : name
    }

    /// The full name of the current branch's upstream (`refs/remotes/origin/main`), or nil.
    var upstream: String? {
        guard let branch = currentBranch else { return nil }
        var buffer = git_buf()
        defer { git_buf_dispose(&buffer) }
        guard git_branch_upstream_name(&buffer, handle, "refs/heads/" + branch) == 0, let text = buffer.ptr else {
            return nil
        }
        return String(cString: text)
    }

    /// `git rev-parse --verify -q rev`: the commit `rev` names, or nil when there is none.
    func resolve(_ rev: String) throws -> CommitID? {
        var object: OpaquePointer?
        let code = git_revparse_single(&object, handle, rev)
        defer { git_object_free(object) }
        if code == GIT_ENOTFOUND.rawValue || code == GIT_EINVALIDSPEC.rawValue { return nil }
        try check(code)
        var commit: OpaquePointer?
        try check(git_object_peel(&commit, object, GIT_OBJECT_COMMIT))
        defer { git_object_free(commit) }
        return CommitID(hex: String(cString: git_oid_tostr_s(git_object_id(commit))))
    }

    /// Commits `local` has that `upstream` lacks (ahead), and the reverse (behind); both are rev names.
    func aheadBehind(local: String, upstream: String) throws -> (ahead: Int, behind: Int) {
        var localOid = try commitOid(local)
        var upstreamOid = try commitOid(upstream)
        var ahead = 0
        var behind = 0
        try check(git_graph_ahead_behind(&ahead, &behind, handle, &localOid, &upstreamOid))
        return (ahead, behind)
    }

    /// `git show rev:path`; throws `.notFound` for a missing path or rev.
    func contents(of path: String, at rev: String) throws -> Data {
        var object: OpaquePointer?
        try check(git_revparse_single(&object, handle, "\(rev):\(path)"))
        defer { git_object_free(object) }
        var blob: OpaquePointer?
        try check(git_object_peel(&blob, object, GIT_OBJECT_BLOB))
        defer { git_object_free(blob) }
        let size = Int(git_blob_rawsize(blob))
        return size == 0 ? Data() : Data(bytes: git_blob_rawcontent(blob), count: size)
    }

    /// `git ls-tree --name-only rev path/`: the full relative names directly inside `path` (empty when
    /// `path` is missing or not a directory). Throws `.notFound` for a missing rev.
    func listTree(at rev: String, path: String) throws -> [String] {
        var object: OpaquePointer?
        try check(git_revparse_single(&object, handle, rev))
        defer { git_object_free(object) }
        var root: OpaquePointer?
        try check(git_object_peel(&root, object, GIT_OBJECT_TREE))
        defer { git_object_free(root) }
        let directory = path.hasSuffix("/") ? String(path.dropLast()) : path
        var tree: OpaquePointer? = root
        var subtree: OpaquePointer?
        defer { git_tree_free(subtree) }
        if !directory.isEmpty {
            var entry: OpaquePointer?
            guard git_tree_entry_bypath(&entry, root, directory) == 0 else { return [] }
            defer { git_tree_entry_free(entry) }
            guard git_tree_entry_type(entry) == GIT_OBJECT_TREE,
                  git_tree_lookup(&subtree, handle, git_tree_entry_id(entry)) == 0 else { return [] }
            tree = subtree
        }
        let prefix = directory.isEmpty ? "" : directory + "/"
        return (0 ..< git_tree_entrycount(tree)).compactMap { position in
            git_tree_entry_byindex(tree, position).map { prefix + String(cString: git_tree_entry_name($0)) }
        }
    }

    /// `git diff --name-only rev -- paths`: tracked files, staged or not, that differ between the commit
    /// `rev` and the working tree. `paths` may be files, directories or globs (and `.`); sorted, no duplicates.
    /// Untracked files are not listed.
    func changedPaths(against rev: String, under paths: [String] = []) throws -> [String] {
        let tree = try peeled(rev, to: GIT_OBJECT_TREE)
        defer { git_object_free(tree) }
        var opts = git_diff_options()
        try check(git_diff_options_init(&opts, UInt32(GIT_DIFF_OPTIONS_VERSION)))
        let specs = CStrings(pathspec: paths)
        defer { specs.free() }
        opts.pathspec = specs.array
        var diff: OpaquePointer?
        try check(git_diff_tree_to_workdir_with_index(&diff, handle, tree, &opts))
        defer { git_diff_free(diff) }
        var names = Set<String>()
        for position in 0 ..< git_diff_num_deltas(diff) {
            if let delta = git_diff_get_delta(diff, position)?.pointee,
               let path = delta.new_file.path ?? delta.old_file.path,
               !workingFileMatchesOld(delta)
            {
                names.insert(String(cString: path))
            }
        }
        return names.sorted()
    }

    /// True when a modified delta's working-tree file has the old side's content after all. libgit2 builds this diff
    /// by merging tree-to-index with index-to-workdir, so a file staged with other content and then put back as the
    /// tree has it comes out modified; git compares those contents (diffcore's skip_stat_unmatch). shortcut: a
    /// symlink put back the same way still lists; compare its target if that matters.
    private func workingFileMatchesOld(_ delta: git_diff_delta) -> Bool {
        let regular = [GIT_FILEMODE_BLOB, GIT_FILEMODE_BLOB_EXECUTABLE].map { UInt16($0.rawValue) }
        guard delta.status == GIT_DELTA_MODIFIED, delta.old_file.mode == delta.new_file.mode,
              regular.contains(delta.new_file.mode) else { return false }
        var old = delta.old_file.id
        var new = delta.new_file.id // set when libgit2 hashed the file (same size as the index), else zero
        if git_oid_is_zero(&new) == 1,
           git_repository_hashfile(&new, handle, delta.new_file.path, GIT_OBJECT_BLOB, nil) != 0 { return false }
        return git_oid_equal(&old, &new) == 1
    }

    /// The effective value of `key` (local, then global and system config), or nil when unset.
    func config(_ key: String) throws -> String? {
        var config: OpaquePointer?
        try check(git_repository_config_snapshot(&config, handle))
        defer { git_config_free(config) }
        var buffer = git_buf()
        defer { git_buf_dispose(&buffer) }
        let code = git_config_get_string_buf(&buffer, config, key)
        if code == GIT_ENOTFOUND.rawValue { return nil }
        try check(code)
        return buffer.ptr.map { String(cString: $0) }
    }

    /// `git config --local key value`; never touches global or system config.
    func setConfig(_ key: String, _ value: String) throws {
        var all: OpaquePointer?
        try check(git_repository_config(&all, handle))
        defer { git_config_free(all) }
        var local: OpaquePointer?
        try check(git_config_open_level(&local, all, GIT_CONFIG_LEVEL_LOCAL))
        defer { git_config_free(local) }
        try check(git_config_set_string(local, key, value))
    }

    /// Throws when a remote called `name` already exists.
    func addRemote(name: String, url: String) throws {
        var remote: OpaquePointer?
        try check(git_remote_create(&remote, handle, name, url))
        git_remote_free(remote)
    }

    /// Replaces the URL of an existing remote; throws `.notFound` when there is none.
    func setRemoteURL(name: String, url: String) throws {
        var remote: OpaquePointer?
        try check(git_remote_lookup(&remote, handle, name))
        git_remote_free(remote)
        try check(git_remote_set_url(handle, name, url))
    }

    /// The URL of remote `name`, or nil when there is no such remote.
    func remoteURL(name: String) throws -> String? {
        var remote: OpaquePointer?
        let code = git_remote_lookup(&remote, handle, name)
        if code == GIT_ENOTFOUND.rawValue { return nil }
        try check(code)
        defer { git_remote_free(remote) }
        return git_remote_url(remote).map { String(cString: $0) }
    }

    /// The object `rev` names (any spelling `git rev-parse` takes), peeled to `type` (a tag to its commit, a commit
    /// to its tree); the caller frees it with `git_object_free`. A `rev` that cannot be peeled that way (a blob asked
    /// for as a commit or tree) throws the libgit2 error as `.other`; one that does not exist throws `.notFound`.
    internal func peeled(_ rev: String, to type: git_object_t) throws -> OpaquePointer? {
        var object: OpaquePointer?
        try check(git_revparse_single(&object, handle, rev))
        defer { git_object_free(object) }
        var peeled: OpaquePointer?
        try check(git_object_peel(&peeled, object, type))
        return peeled
    }

    /// The id of the commit `rev` names (a tag is peeled); throws as `peeled` does.
    internal func commitOid(_ rev: String) throws -> git_oid {
        let commit = try peeled(rev, to: GIT_OBJECT_COMMIT)
        defer { git_object_free(commit) }
        return git_object_id(commit).pointee
    }
}
