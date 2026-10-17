# GH Watcher

A native macOS (SwiftUI, macOS 26+) app for keeping an eye on your GitHub repositories:
CI/Actions, pull requests, issues, branches, a live commit graph, your notification inbox,
custom desktop notifications and a menu bar status item.

## Build & run

Needs only the Xcode Command Line Tools (Swift 6.2).

```bash
make run        # build build/GH Watcher.app and open it
make install    # copy to /Applications
```

Sign-in uses `gh auth token` automatically if the GitHub CLI is logged in; otherwise paste a
personal access token (scopes: `repo`, `workflow`, `notifications`, `read:org`), stored in the Keychain.

## How it stays near-realtime cheaply

- Every REST GET is conditional (ETag / Last-Modified). GitHub doesn't count `304 Not Modified`
  against the 5,000/hour limit, so idle polling is essentially free.
- Cheap REST "sentinels" (runs, events, recently-updated PRs/issues) detect change; richer GraphQL
  queries (PR lists with check rollups, graph, branches) only run when something changed.
- Intervals adapt: 15s while a workflow runs, faster for the repo you're viewing, slower in the
  background, and back off automatically when the rate-limit budget runs low. `X-Poll-Interval` is honoured.

## Notifications

Settings → Notifications holds a list of rules. Each rule picks an event kind (workflow failed/fixed,
PR opened/merged, review requested, mention, release, …) and optionally limits it to certain repos,
branch globs (`main, release/*`), things involving you, or excludes your own actions.

## Developer flags

```bash
.build/debug/GHWatcher --selftest owner/repo        # exercise every API path, print results
.build/debug/GHWatcher --snapshot <dir> owner/repo  # render main screens offscreen to PNGs
```
