# ``KaiyouGit``

In-process git over ssh for Swift apps on iOS and macOS.

## Overview

KaiyouGit wraps libgit2, libssh2 and OpenSSL, built into a static xcframework, in a small Swift 6 API. It exists for places where the `git` program cannot run (iPadOS cannot spawn processes), so everything happens inside your app.

The one rule that shapes the API: credentials and a host-key policy travel together in ``RemoteAuth``, and there is no "trust any host" option, so a caller cannot forget to verify the server.

This release speaks ssh only. An `https://` URL throws ``GitError/unsupportedTransport(_:)``. Local paths and `file://` URLs need no credentials.

A ``Repository`` is an actor. Calls on one repository run one at a time on its own serial executor, so a long fetch or push makes later calls on that repository wait.

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:CredentialsAndHostKeys>

### Reference

- ``Repository``
- ``RemoteAuth``
- ``Credentials``
- ``HostKeyPolicy``
- ``HostKey``
- ``GitError``
- ``StatusEntry``
- ``Change``
- ``CommitID``
- ``CommitSummary``
- ``RemoteRef``
- ``Author``
- ``TransferProgress``
- ``LibGit2``

### Project

- <doc:WhatIsNotSupported>
- <doc:BuildAndRelease>
