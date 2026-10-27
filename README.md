# GitDocumentStorage

A shared documents folder that is actually a GitHub repository.

Save a file in Finder and, within a few seconds, it is on GitHub for everyone who connected the same folder. Several folders, several GitHub accounts. The folder is there while the app is running.

## Why

Shared documents usually end up in a chat, where files get lost and versions get mixed up, or in git, where branches, commits, and pull requests are overhead for a contract, a spreadsheet, or a note. What you want is an ordinary folder that Word, Preview, and Finder can open, with real storage underneath: history, access control, and a backup on GitHub.

GitDocumentStorage is that layer. For a person it is a network folder. For GitHub it is an ordinary repository: each save becomes a commit, the previous version stays in history, and access is granted the same way as for any other repo. A participant does not install git, clone the repository, or remember to commit.

There is no local `.git`. The app talks to GitHub over the HTTPS API only. Quit the app and the Finder folder goes away. Nothing on GitHub changes.

## How you use it

1. Sign in to GitHub (Device Flow or a personal access token).
2. Connect a repository. A folder appears in Finder.
3. Create and edit files with any app. Saving uploads them to GitHub.
4. Other people's edits arrive in the same folder.

The folder lives at `~/Library/CloudStorage/GitDocumentStorage-<name>/`. File contents download when you open the file.

## What is inside

A native macOS 15+ app (Swift 6, SwiftUI + AppKit). The Finder folder is a File Provider (`NSFileProviderReplicatedExtension`), the same mechanism Dropbox and iCloud use. Writes are fast-forward commits through the GitHub API (`createCommitOnBranch` / Git Data API). No force-push.

Details: [plan](docs/00-PLAN.md), [architecture](docs/01-ARCHITECTURE.md), [decisions](docs/06-DECISIONS.md).

## Quick start

```sh
cp Config/Local.xcconfig.example Config/Local.xcconfig   # Team ID and OAuth Client ID stay local
make test      # swift test in Packages/GitDocsKit
make build     # compile without signing
make run       # signed build → ~/Applications → launch
make logs      # extension and fileproviderd logs
```

`Config/Local.xcconfig` is not in git. Tokens are not either: they live in the Keychain.

Requires macOS 15+, Xcode 26+, and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
