import CLibGit2
import Foundation

/// How to sign in to an ssh remote. The key is an in-memory PEM, never a path.
public enum Credentials: Sendable {
    /// A private key as PEM text (never a path) for `user` (`git` on GitHub), with its passphrase if it has one.
    case sshKey(user: String, privateKey: String, passphrase: String?)
}

/// The server's ssh host key as libgit2 saw it: `sha256` is the unpadded base64 of its SHA-256.
public struct HostKey: Sendable {
    /// The host name libgit2 connected to.
    public let host: String
    /// The key's SHA-256 fingerprint, unpadded base64 and with no `SHA256:` prefix.
    public let sha256: String

    /// For a caller's own tests of a `.custom` policy; the library makes these from what the server sends.
    public init(host: String, sha256: String) {
        self.host = host
        self.sha256 = sha256
    }
}

/// Which ssh host keys to trust. There is deliberately no "trust any host" case.
public enum HostKeyPolicy: Sendable {
    /// Unpadded base64 SHA-256 fingerprints, as GitHub publishes them; a leading `SHA256:` and padding are ignored.
    case pinned(sha256: Set<String>)
    /// Decides for each host key the server presents; return true to trust it. The closure runs on the calling task's
    /// thread during the connection and must not block.
    case custom(@Sendable (HostKey) -> Bool)
}

/// Credentials for an ssh remote, which cannot exist without a host-key policy.
public struct RemoteAuth: Sendable {
    /// How to sign in.
    public let credentials: Credentials
    /// Which server host keys to trust.
    public let hostKeys: HostKeyPolicy

    /// Pairs `credentials` with the `hostKeys` policy that must accept the server.
    public init(credentials: Credentials, hostKeys: HostKeyPolicy) {
        self.credentials = credentials
        self.hostKeys = hostKeys
    }
}

/// Printing, interpolating or dumping credentials never shows the key or the passphrase.
extension Credentials: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// A description with the key and the passphrase replaced by `<redacted>`.
    public var description: String {
        switch self {
        case let .sshKey(user, _, passphrase):
            "sshKey(user: \(user), privateKey: <redacted>, passphrase: \(passphrase == nil ? "nil" : "<redacted>"))"
        }
    }

    /// Same as `description`.
    public var debugDescription: String { description }
    /// A mirror that shows only `description`, so `dump` cannot reveal the key either.
    public var customMirror: Mirror { Mirror(self, children: ["redacted": description]) }
}

extension RemoteAuth: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// A description built from the redacted credentials.
    public var description: String { "RemoteAuth(credentials: \(credentials), hostKeys: \(hostKeys))" }
    /// Same as `description`.
    public var debugDescription: String { description }
    /// A mirror whose children are the (redacted) credentials and the host-key policy.
    public var customMirror: Mirror { Mirror(self, children: ["credentials": credentials, "hostKeys": hostKeys]) }
}

extension HostKeyPolicy {
    func accepts(_ key: HostKey) -> Bool {
        switch self {
        case let .pinned(fingerprints): fingerprints.contains { Self.unpadded($0) == Self.unpadded(key.sha256) }
        case let .custom(decide): decide(key)
        }
    }

    /// `SHA256:abc=` and `abc` name the same fingerprint (`=` appears in base64 only as padding).
    static func unpadded(_ fingerprint: String) -> String {
        let bare = fingerprint.hasPrefix("SHA256:") ? String(fingerprint.dropFirst(7)) : fingerprint
        return bare.replacingOccurrences(of: "=", with: "")
    }
}

/// What libgit2's remote callbacks need during one call, reached through their C `payload` pointer. libgit2 calls
/// them synchronously on the thread making the call, inside the calling task, so `Task.isCancelled` is that task's.
final class RemoteContext {
    let auth: RemoteAuth?
    let progress: (@Sendable (TransferProgress) -> Void)?
    /// Set by a callback that refused, so the call throws this rather than libgit2's less specific code.
    private var failure: GitError?
    private var keyOffered = false

    init(auth: RemoteAuth?, progress: (@Sendable (TransferProgress) -> Void)?) {
        self.auth = auth
        self.progress = progress
    }

    /// Runs one libgit2 call with callbacks bound to `self`; their payload is valid only while `call` runs.
    func run(_ call: (git_remote_callbacks) -> Int32) throws(GitError) {
        if Task.isCancelled { throw .cancelled }
        var callbacks = git_remote_callbacks()
        try check(git_remote_init_callbacks(&callbacks, UInt32(GIT_REMOTE_CALLBACKS_VERSION)))
        callbacks.payload = Unmanaged.passUnretained(self).toOpaque()
        callbacks.credentials = { out, _, _, allowed, payload in from(payload).credential(out, allowed: allowed) }
        callbacks.certificate_check = { cert, _, host, payload in from(payload).checkHostKey(cert, host: host) }
        callbacks.transfer_progress = { stats, payload in from(payload).transferred(stats) }
        callbacks.push_transfer_progress = { _, _, _, payload in from(payload).transferred(nil) }
        callbacks.push_update_reference = { ref, status, payload in from(payload).pushed(ref, status: status) }
        let code = withExtendedLifetime(self) { call(callbacks) }
        if let failure { throw failure }
        try check(code)
    }

    /// Clone's `remote_cb`: creates the remote as libgit2 would (`url.<base>.insteadOf` applied), then holds the URL it
    /// ended up with to `requireSupportedTransport`. On a refusal libgit2 frees the remote left in `out`.
    static let createRemote: git_remote_create_cb = { out, repo, name, url, payload in
        let code = git_remote_create(out, repo, name, url)
        guard code == 0 else { return code }
        let rewritten = git_remote_url(out?.pointee).map { String(cString: $0) } ?? ""
        do throws(GitError) {
            try requireSupportedTransport(rewritten, auth: from(payload).auth)
        } catch {
            return from(payload).refuse(error, code: GIT_ERROR)
        }
        return 0
    }

    /// The error for a remote's refusal of one ref (`status` is receive-pack's reason, as in `ng <ref> <status>`).
    static func pushRejection(ref: String, status: String) -> GitError {
        if status.contains("non-fast-forward") || status.contains("fetch first") { return .notFastForward }
        return .other(class: 0, code: GIT_ERROR.rawValue, message: "the remote refused \(ref): \(status)")
    }

    private func credential(
        _ out: UnsafeMutablePointer<UnsafeMutablePointer<git_credential>?>?, allowed: UInt32
    ) -> Int32 {
        if case let .sshKey(user, privateKey, passphrase)? = auth?.credentials {
            if allowed & GIT_CREDENTIAL_SSH_KEY.rawValue != 0, !keyOffered {
                keyOffered = true // libgit2 asks again after the server refuses the key; refuse rather than loop
                return git_credential_ssh_key_memory_new(out, user, nil, privateKey, passphrase)
            }
            if allowed == GIT_CREDENTIAL_USERNAME.rawValue { return git_credential_username_new(out, user) }
        }
        return refuse(.authenticationFailed, code: GIT_EAUTH)
    }

    private func checkHostKey(_ cert: UnsafeMutablePointer<git_cert>?, host: UnsafePointer<CChar>?) -> Int32 {
        guard let cert, cert.pointee.cert_type == GIT_CERT_HOSTKEY_LIBSSH2, let policy = auth?.hostKeys else {
            return refuse(.hostKeyRejected, code: GIT_ECERTIFICATE)
        }
        let hostKey = UnsafeRawPointer(cert).load(as: git_cert_hostkey.self)
        guard hostKey.type.rawValue & GIT_CERT_SSH_SHA256.rawValue != 0 else {
            return refuse(.hostKeyRejected, code: GIT_ECERTIFICATE)
        }
        let hash = withUnsafeBytes(of: hostKey.hash_sha256) { Data($0) }
        let key = HostKey(
            host: host.map { String(cString: $0) } ?? "",
            sha256: HostKeyPolicy.unpadded(hash.base64EncodedString())
        )
        return policy.accepts(key) ? 0 : refuse(.hostKeyRejected, code: GIT_ECERTIFICATE)
    }

    private func transferred(_ stats: UnsafePointer<git_indexer_progress>?) -> Int32 {
        if let progress, let stats = stats?.pointee {
            progress(TransferProgress(
                receivedObjects: Int(stats.received_objects),
                totalObjects: Int(stats.total_objects),
                receivedBytes: stats.received_bytes
            ))
        }
        return Task.isCancelled ? refuse(.cancelled, code: GIT_EUSER) : 0
    }

    private func pushed(_ ref: UnsafePointer<CChar>?, status: UnsafePointer<CChar>?) -> Int32 {
        guard let status else { return 0 }
        let name = ref.map { String(cString: $0) } ?? ""
        return refuse(Self.pushRejection(ref: name, status: String(cString: status)), code: GIT_ERROR)
    }

    private func refuse(_ error: GitError, code: git_error_code) -> Int32 {
        failure = error
        return code.rawValue
    }
}

/// The context a callback's `payload` points at (set by `RemoteContext.run`, never nil there).
private func from(_ payload: UnsafeMutableRawPointer?) -> RemoteContext {
    Unmanaged<RemoteContext>.fromOpaque(payload!).takeUnretainedValue()
}
