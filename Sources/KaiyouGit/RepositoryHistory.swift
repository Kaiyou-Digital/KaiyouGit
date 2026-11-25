import CLibGit2
import Foundation

/// Queries over commits and the differences between them.
public extension Repository {
    /// `git diff --name-only --no-renames base tip -- paths`: the files that differ between the trees of the two
    /// commits (the working tree and index are not consulted). Added, modified and deleted files are listed, a
    /// deleted file by its old path; there is no rename detection, so a rename lists the old path and the new path.
    /// The result is sorted, with no duplicates. An empty `paths` means no restriction; otherwise `paths` may be
    /// files, directories or globs (and `.`), with the same spellings as the other path arguments (`./x` and `x/.`
    /// mean `x`), a directory matches everything under it, and `archive` never matches `archive-old/x`.
    /// `base` and `tip` are revisions as `resolve` takes them (`HEAD`, a branch, `origin/main`, `HEAD~1`, `@{u}`);
    /// either one that does not exist throws `.notFound`, and a malformed one (`HEAD^{nope}`, an empty string, `a..b`)
    /// throws
    /// `.other` (class 3, code -12), while `resolve` returns nil for it. `base` need not be an ancestor of `tip`: this
    /// is a plain
    /// tree comparison, and swapping the two lists the same files.
    func changedPaths(from base: String, to tip: String, under paths: [String] = []) throws -> [String] {
        let baseTree = try peeled(base, to: GIT_OBJECT_TREE)
        defer { git_object_free(baseTree) }
        let tipTree = try peeled(tip, to: GIT_OBJECT_TREE)
        defer { git_object_free(tipTree) }
        var opts = git_diff_options()
        try check(git_diff_options_init(&opts, UInt32(GIT_DIFF_OPTIONS_VERSION)))
        let specs = CStrings(pathspec: paths)
        defer { specs.free() }
        opts.pathspec = specs.array
        var diff: OpaquePointer?
        try check(git_diff_tree_to_tree(&diff, handle, baseTree, tipTree, &opts))
        defer { git_diff_free(diff) }
        var names = Set<String>()
        for position in 0 ..< git_diff_num_deltas(diff) {
            if let delta = git_diff_get_delta(diff, position)?.pointee,
               let path = delta.new_file.path ?? delta.old_file.path
            {
                names.insert(String(cString: path))
            }
        }
        return names.sorted()
    }

    /// `git log --format=... base..tip`: the commits reachable from `tip` and not from `base`, newest first (by
    /// commit time, a child always before its parents), at most `limit` of them: `nil` is all of them, `0` is none,
    /// and a negative `limit` throws `GitError.other`. An empty range (including `base` ahead of `tip`) is `[]`, and
    /// a diverged `base` and `tip` list only the commits `tip` has. `base` and `tip` are revisions as `resolve` takes
    /// them (`HEAD`, a branch, `origin/main`, `HEAD~1`, `@{u}`); either one that does not exist throws `.notFound`.
    /// A malformed revision (`HEAD^{nope}`, an empty string, `a..b`) throws `.other` (class 3, code -12), while
    /// `resolve`
    /// returns nil for it. The commits others published, after a fetch, are `log(from: "HEAD", to: "@{u}", limit: 10)`.
    func log(from base: String, to tip: String, limit: Int? = nil) throws -> [CommitSummary] {
        if let limit, limit < 0 {
            throw GitError.other(class: 0, code: 0, message: "log limit must not be negative (got \(limit))")
        }
        var tipOid = try commitOid(tip)
        var baseOid = try commitOid(base)
        var walker: OpaquePointer?
        try check(git_revwalk_new(&walker, handle))
        defer { git_revwalk_free(walker) }
        git_revwalk_sorting(walker, GIT_SORT_TIME.rawValue | GIT_SORT_TOPOLOGICAL.rawValue)
        try check(git_revwalk_push(walker, &tipOid))
        try check(git_revwalk_hide(walker, &baseOid))
        var found: [CommitSummary] = []
        var oid = git_oid()
        while found.count < (limit ?? Int.max) {
            let step = git_revwalk_next(&oid, walker)
            if step == GIT_ITEROVER.rawValue { break }
            try check(step) // a corrupt or missing object must not look like the end of the range
            var commit: OpaquePointer?
            try check(git_commit_lookup(&commit, handle, &oid))
            defer { git_commit_free(commit) }
            let author = git_commit_author(commit)?.pointee
            found.append(CommitSummary(
                id: CommitID(hex: String(cString: git_oid_tostr_s(&oid))),
                subject: Self.text(git_commit_summary(commit)),
                authorName: Self.text(author?.name),
                authorEmail: Self.text(author?.email),
                date: Date(timeIntervalSince1970: TimeInterval(git_commit_time(commit)))
            ))
        }
        return found
    }

    /// A C string as text; bytes that are not UTF-8 become U+FFFD instead of crashing.
    private static func text(_ pointer: UnsafePointer<CChar>?) -> String {
        guard let pointer else { return "" }
        return String(cString: pointer) // repairs invalid UTF-8 with U+FFFD, never traps
    }
}
