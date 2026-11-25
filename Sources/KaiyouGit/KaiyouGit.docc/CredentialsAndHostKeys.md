# Credentials and Host Keys

Sign in to an ssh remote and decide which servers to trust.

## Overview

An ssh connection needs two things: who you are, and who you are talking to. ``RemoteAuth`` holds both, and neither can be left out.

```swift
let auth = RemoteAuth(
    credentials: .sshKey(user: "git", privateKey: pemText, passphrase: nil),
    hostKeys: .pinned(sha256: ["SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU"])
)
```

The private key is the PEM text itself, held in memory, never a file path. Read it from the Keychain or wherever your app keeps it.

### Where GitHub's fingerprints come from

The library ships no fingerprints, because servers rotate keys (GitHub replaced its RSA host key in 2023) and a built-in list would go stale silently. GitHub publishes the current ones at `https://api.github.com/meta`, in `ssh_key_fingerprints`:

```json
{
  "SHA256_ECDSA": "p2QAMXNIC1TJYWeIOttrVc98/R1BUFWu3/LiyKgUfQM",
  "SHA256_ED25519": "+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU",
  "SHA256_RSA": "uNiVztksCsDhcc0u9e8BujQXVUpKZIDTMczCvj3tD2s"
}
```

Those were read on 24 November 2026. Do not copy them from here; read them yourself, from the GitHub documentation or the endpoint, when you build the app. For example:

```sh
gh api meta --jq '.ssh_key_fingerprints'
```

The values are unpadded base64 SHA-256. ``HostKeyPolicy/pinned(sha256:)`` takes them in that form. A leading `SHA256:` prefix (the form `ssh-keygen -l` prints) is accepted and stripped, and so is base64 padding (`=`), so either spelling matches. Pass all of the ones you trust, for example all three of GitHub's, as a set.

### What the two policies do

- ``HostKeyPolicy/pinned(sha256:)``: accepts the connection only if the server's host key SHA-256 is in the set. Anything else throws ``GitError/hostKeyRejected``.
- ``HostKeyPolicy/custom(_:)``: your closure gets a ``HostKey`` (the host name and the unpadded base64 SHA-256 of its key) and returns whether to trust it. Use it for a trust-on-first-use store or a per-host table. Keep it quick; it runs during the connection.

There is deliberately no case that trusts every host. A host key that is not a SHA-256 hash libgit2 can read is rejected as well.

### The pairing

``Repository/clone(from:to:auth:progress:)``, ``Repository/fetch(remote:auth:progress:)`` and ``Repository/push(remote:refspec:auth:)`` take an optional ``RemoteAuth``. An ssh URL (`ssh://...` or scp style `git@host:path`) with `auth: nil` throws ``GitError/authenticationFailed`` before anything connects. A local path or `file://` URL needs none.

The library offers the key once. If the server refuses it, the call throws ``GitError/authenticationFailed`` rather than retrying.

### Keeping secrets out of logs

Printing, interpolating or dumping a ``Credentials`` or ``RemoteAuth`` shows `privateKey: <redacted>` and, if there is one, `passphrase: <redacted>`. That covers `print`, string interpolation, `debugPrint` and `dump`. It does not cover a copy of the key string you hold yourself, so do not log that.

### A bad key

A key libssh2 cannot use (a malformed file, a wrong passphrase) throws ``GitError/authenticationFailed``. The library recognises this from libssh2's error text ("private key", "passphrase", "key data"), and that wording is tied to libssh2 1.11.1. Other ssh session failures, a dropped connection for example, stay ``GitError/network(_:)``. When libssh2 is upgraded, re-check the mapping in `Errors.swift`.
