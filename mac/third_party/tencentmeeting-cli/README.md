# tencentmeeting-cli (tmeet), bundled as `Contents/Helpers/tmeet`

The Tencent Meeting entry (PRD ENTRY-013) runs Tencent's official command-line tool to read the meeting
transcripts the user's Tencent Meeting account may view. Mindloom builds it from the pinned source in this
folder with three patches and signs it with the App.

## Pin

| | |
|---|---|
| Upstream | https://github.com/TencentCloud/tencentmeeting-cli (GitHub organization TencentCloud; npm `@tencentcloud/tmeet`) |
| Version | v1.0.18 (released 2026-09-11), commit `e631b355da2b001d24b82f453b65d96f39c59865` (`UPSTREAM_COMMIT`) |
| Mindloom build | `v1.0.18-mindloom3` (`VERSION`; the Swift side checks it equals `TencentMeetingHelper.version`) |
| Vendored | `upstream/`: `cmd/`, `internal/`, `main.go`, `go.mod`, `go.sum`, `LICENSE` exactly as at that commit (`git archive`); `upstream.sha256` lists every file, and the build refuses a tree that is not exactly that list: a file changed, missing, or added (a file or link not listed, which Go would compile), Finder's `.DS_Store` aside; `script/build_tmeet.sh --check-only` runs this check alone |
| Go modules | from `go.sum` (cobra 1.10.2, pflag 1.0.10, gorilla/websocket 1.5.3, gojq 0.12.17, go-keyring 0.2.8, golang.org/x/sys 0.30.0, protobuf 1.34.2, go-winio 0.6.2, and their indirect ones); downloaded through the Go module proxy on the first build and verified against `go.sum` |

## Patches (`patches/`, applied in order by `script/build_tmeet.sh`)

| Patch | What changes | Regression test |
|---|---|---|
| 0001 | Crash reports are never sent (upstream posts the stack and the account's openId to `/v1/cli/crash`); the crash is still logged locally and printed | `internal/crash/reporter_local_test.go`: a test server receives nothing (fails on pristine upstream) |
| 0002 | A token refresh that fails on the network (no answer, gateway error, undecodable body) keeps the saved login; only an explicit rejection by Tencent deletes it | `internal/auth/auth_refresh_keep_test.go`, 3 cases (2 fail on pristine upstream) |
| 0003 | With `TMEET_MASTER_KEY_FD` set, the 32-byte master key that encrypts the saved login comes from that inherited descriptor (base64 or raw), the descriptor is closed and the variable cleared, and the system Keychain is never read or written; a bad or missing key is an error with no fallback. Mindloom keeps the key in its own Keychain item (`app.mindloom.tencent-meeting`, this device only) and hands it over on descriptor 3 every run. Without the variable tmeet behaves as upstream | `internal/core/keychain/keychain_fd_darwin_test.go`: round trip, wrong key, bad keys and descriptors, system Keychain calls fail the test |

Upstream's Keychain integration tests are not run by the build: they write the real login Keychain.

## Build

`script/build_tmeet.sh --output <dir>` checks the vendored tree against `upstream.sha256`, copies it, applies the
patches, runs the patches' tests, and builds with `CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 -trimpath -buildvcs=false
-ldflags "-s -w -X tmeet/cmd.Version=<VERSION>"`, `GOFLAGS=-mod=readonly`, `GOTOOLCHAIN=local`. It rebuilds only when an
input changed. The App's build phase (`script/bundle_tmeet.sh`, `project.yml`) copies the result to
`Contents/Helpers/tmeet` and signs it with the App's identity, the hardened runtime and the identifier
`<bundle id>.tmeet` before Xcode seals the App. A build machine needs Go 1.22 or later (1.25.6 used);
`MINDLOOM_SKIP_TMEET=1` leaves it out, and the App then says the connection cannot start.

## Dependency record (AGENTS.md)

| | |
|---|---|
| Runtime behaviour | A static Go program (no cgo), arm64, 9,702,562 bytes as built with Go 1.25.6 (`-s -w`). Mindloom starts it with `posix_spawn` for one command at a time (`auth login --no-browser`, `auth status`, `record list`, `meeting list-ended`, `meeting get`, `record transcript-get`), only after checking it is the code sealed into the running App, with only descriptors 0–3 open, a fixed environment (`PATH`, `HOME`, `TMPDIR`, `LANG`, `TMEET_CLI_CONFIG_DIR`, `TMEET_CLI_DATA_DIR`, `TMEET_MASTER_KEY_FD`) and a time limit. It runs `sw_vers` once to read the macOS version. It writes only its own folder `<library>/entries/tencent-meeting/` (0700; a reconnection makes the new login in `tencent-meeting-new/` beside it and swaps it in): the encrypted login, a random device number, and a local log of commands and their numbers kept 7 days. Mindloom never runs `event`, so no background process stays |
| Minimum OS | macOS 12.0: the built binary's `LC_BUILD_VERSION` (`vtool -show-build`: platform MACOS, minos 12.0, sdk 12.0); the App requires 14.2 |
| License | MIT, Copyright (C) 2026 Tencent (`LICENSE`; `Legal/tencentmeeting-cli-LICENSE-MIT.txt` in the App). Linked Go code (`go version -m`): the Go standard library (BSD-3-Clause), cobra (Apache-2.0), pflag (BSD-3-Clause), gorilla/websocket (BSD-2-Clause), gojq and timefmt-go (MIT), go-keyring (MIT), protobuf (BSD-3-Clause); texts in `Legal/tmeet-Go-LICENSES.txt`. Recorded in `THIRD-PARTY-NOTICES.md` and `config/dependencies.json` |
| Distribution | Inside the App at `Contents/Helpers/tmeet`, signed with the App's identity and hardened runtime, sealed and notarized with the App. Updating means a new pin, the patches rebased, their tests passing, and a new `VERSION` |
| Hosts it connects to | `api.meeting.qq.com`, `work.medialab.qq.com` and `meeting.tencent.com` (`internal/core/endpoints.go`), only while the entry is on |
| Privacy | Sends Tencent the login token, the meeting and recording numbers and time windows it asks for, and its request headers: the account's openId with the random device number, the macOS version, an empty agent and model name, the CLI version and the command name. Nothing from the library is sent. Crash reports are off (0001). `tshoot log --upload` and `tshoot feedback` would send logs; Mindloom cannot run them. The login is encrypted with Mindloom's key (0003); switching the entry off deletes the folders and the key on this Mac (tmeet's `auth logout` only deletes local files and is not run; the authorization at Tencent lasts until it ends) |
