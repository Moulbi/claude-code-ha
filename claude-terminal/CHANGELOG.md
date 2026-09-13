# Changelog

## 2.2.1

### 📚 Documentation - This fork now points at its own repository
Installing a Home Assistant add-on repository means handing Supervisor a URL to
clone. Every one of those URLs still named the upstream project, so adding this
fork to Home Assistant would have installed **someone else's** add-on.

- **`repository.yaml`** — the file Supervisor actually reads — now names this
  repository and its maintainer.
- **`config.yaml`**'s `url`, the "Add repository" button, the My Home Assistant
  redirect, the release badge and the issues link all follow.
- **`build.yaml`**'s `org.opencontainers.image.source` pointed at
  `anthropics/claude-code`, which is the CLI, not this add-on. It now points at
  this repository, so the built image identifies its real source.
- **Attribution is preserved and made accurate**, as the MIT licence requires:
  Tom Cassady wrote the original add-on, Javier Santos added persistent packages,
  tmux persistence and multi-arch support, and this fork adds the security
  hardening, the rewritten package manager and CI. The upstream maintainer's
  personal "About the author" section was removed — it is his biography, not
  this fork's.
- **The README version badge** had been stuck at `2.0.13` for three releases.
- CI now fails if `repository.yaml` and `config.yaml` disagree on the repository
  URL, if the install instructions point somewhere else, or if the badge drifts
  from the real version.

### ⚠️ Note for installation
Supervisor clones a repository's **default branch**. Make sure the branch you
intend to serve is the one Home Assistant will fetch, or it will install an
older revision than the one you are reading about here.

## 2.2.0

### 🐛 Bug Fix - `persist-install` did not actually make packages work after a restart
The mechanism installed a package with `apk`, then copied its executables from
`/usr/bin` and its `*.so` files from `/usr/lib` into `/data/packages`. Everything
else the package shipped was silently left behind.

Measured against the real Alpine 3.21 index: **`python3` installs 715 files under
`/usr/lib`**, and its standard library is `.py`, not `.so`. So `persist-install
python3 py3-pip` — the exact command this project's own instructions told the
assistant to run — produced a `python3` that failed at the next restart with
`Could not find platform independent libraries <prefix>`. The same applied to
anything needing data files at runtime (`git`, `vim`, `perl`).

**The fix persists the inputs instead of the artefacts.** Two things now live in
`/data`: the list of packages you asked for (`/data/packages/world`) and apk's
download cache (`/data/packages/apk-cache`). On every container start, `run.sh`
replays that list through `apk`, producing a genuine, complete installation —
data files, symlinks, triggers and dependencies included.

- **Verified end-to-end** against a real Alpine root: install `python3` in one
  container, recreate the container, replay — `import json, ssl, sqlite3` works.
  A warm replay of `python3` and its 25 dependencies takes about **one second**.
- **Mostly works offline too.** The cached `.apk` files and repository indexes
  mean a restart with no internet still restores most packages. Not all: `apk`
  masks virtual providers under `--no-network` (`python3` needs `python3-pyc`),
  so the fallback retries package by package and reports precisely which entries
  need connectivity rather than failing the batch.
- **A failed install is no longer recorded**, so a typo cannot make every future
  startup fail on a package that does not exist.
- **New**: `persist-install --remove <pkg>` and `persist-install --restore`.
- **Legacy leftovers are handled, not abandoned.** Binaries copied by the old
  mechanism stay on disk but move to the **end** of `PATH`, so a real
  installation always wins, and `persist-install --list` points them out.

### 🔒 Security - Supervisor role reduced from `manager` to `homeassistant`
- `manager` grants **add-on management**. An add-on can run privileged on the
  host, so anything achieving code execution in this container — a prompt
  injection, a hostile repository, a compromised dependency — could install one
  and take over the Home Assistant host. That is a large blast radius for a
  terminal, and it was granted for a capability the add-on does not need.
- `homeassistant_api: true` plus the `homeassistant` role still provides the full
  **Core API** — states, services, events, config — which is what "connect Home
  Assistant to Claude" actually requires, along with `ha core ...`.
- **What you lose**: `ha addons ...` and `ha supervisor ...` are refused. If you
  want them back, set `hassio_role: manager` in `config.yaml` and rebuild,
  knowing you are re-opening the path above.
- CI now fails the build if the role returns to `manager` or `admin`.

### 🛠️ Improvement - Smaller image, honestly measured
Measured by installing both package sets into real Alpine 3.21 roots:
**193 MiB in 111 packages → 146 MiB in 67 packages.**

An earlier review of this repository estimated the saving at "300-400 MB". That
was wrong by roughly six times; the real figure is ~53 MB, and the more valuable
outcome is **44 fewer packages** to carry CVEs.

- **Removed**: `vim` (33 MB), `yq` (10 MB), `py3-aiohttp` (6 MB), `py3-requests`,
  `py3-yaml`, `py3-beautifulsoup4`. Every one is a single `persist-install`
  away — and, thanks to the fix above, comes back *working*.
- **Kept**: `tree`, which measured under a megabyte. Dropping it would have cost
  a familiar command and saved nothing.
- The Supervisor API examples now name their prerequisite
  (`persist-install --python requests`) instead of assuming it is bundled, and
  the README no longer advertises tools that are not in the image.

### 🔧 Technical
- New `tests/test-persist-install.sh`: the world file records only successful
  installs, never duplicates, survives removal, drives the startup replay, and
  falls back per package. `--ha-cli` is asserted never to shadow the bundled CLI.
- `tests/test-production-run.sh` updated: startup now replays the persistent
  package list even when no packages are configured, which is the whole point.

## 2.1.0

### 🔒 Security - The add-on no longer publishes a root shell on your LAN
- **Breaking, and deliberate: no host ports are published any more.** `config.yaml`
  mapped `7680` and `7681` to the host. Home Assistant publishes declared ports by
  default, and `ttyd` runs `--writable` with no credentials, so anyone who could
  reach `http://<home-assistant>:7681` got an unauthenticated **root shell** in a
  container holding `/config` read-write, `hassio_role: manager`, the Home
  Assistant API and `SUPERVISOR_TOKEN`. Ingress authentication was simply bypassed.
  - Ingress reaches the container over the internal Docker network and needs no
    host port, so nothing legitimate is lost.
  - **If you were opening the add-on by IP and port, use the sidebar panel instead.**
- **ttyd now binds `127.0.0.1`** instead of `0.0.0.0`. Its only legitimate consumer
  is the image service, which proxies `/terminal` over the loopback.
- **Local add-on state is no longer tracked in git** (`config/claude-config/`,
  `config/options.json`). That directory is where Claude and `gh` drop credential
  files, and nothing stopped one from being committed.
- **Dependencies**: `multer` 1.x (deprecated, known DoS advisories) upgraded to 2.x,
  and `qs` pinned to a patched release. `npm audit` is clean, with no major
  framework upgrade.

### 🐛 Bug Fix - The image service health check was always green
- **`$!` after a pipeline is the wrong PID.** The service was started as
  `node ... | while read`, and `$!` captured the logging loop, not node. The
  `kill -0` readiness probe therefore passed unconditionally: *"Image service is
  running successfully"* was logged even when the service had already died.
  Readiness is now proven by an actual `/health` response.
- **The image service is now supervised and restarted** with capped backoff.
  Previously, if it died the ingress panel went blank until a manual restart,
  because it serves the entry point and proxies the terminal.

### 🐛 Bug Fix - Credential migration never migrated credentials, then overwrote them
- **Hidden files were skipped.** The migration copied `"$legacy_path"/*`, a glob
  that does not match dotfiles — so it skipped exactly the files it exists for
  (`.credentials.json`, `.claude.json`). It now copies `"$legacy_path/."`.
- **Fixing that glob alone would have been worse than the bug.** Correctly copying
  dotfiles would, once, overwrite working credentials in `/data` with the stale
  copy in `/config`. Migration now runs with `cp -a -n`: it only fills in files
  that are missing, which is all a migration should ever do.
- **It ran on every start.** Described as one-time in a comment but not in code, it
  re-copied legacy files over `/data` at each boot, letting a stale file left in
  `/config` overwrite freshly obtained credentials. It now records a marker in
  `/data` and runs exactly once.

### 🐛 Bug Fix - A WebSocket arriving first was never proxied
- `http-proxy-middleware` only subscribes to `upgrade` lazily, on the first HTTP
  request through the middleware. A terminal reconnect that opened with the
  WebSocket handshake hung until timeout. The server now subscribes explicitly.

### 🛠️ Improvement - Startup no longer depends on the Alpine mirrors
- **`ttyd` and `tmux` are baked into the image.** `run.sh` ran an unconditional
  `apk add ttyd jq curl tmux` on *every* container start, with `exit 1` on failure:
  the add-on refused to start whenever the mirrors were unreachable, and paid the
  download on each boot. `jq` and `curl` were already in the image and were being
  re-fetched for nothing. The runtime `apk` path remains only as a fallback for
  images built before this change.

### 🔧 Technical - Dockerfile correctness
- **`pipefail` is now set for every build step that pipes a download.** Three
  `RUN` instructions pipe `curl` into `bash`, `jq` or `sed`. Without `pipefail` a
  pipeline reports only the *last* command's status, so a failed or empty download
  was invisible and the build continued on garbage — precisely the failure mode
  behind this add-on's history of silently broken images.
- **Quoted the GitHub CLI extraction path** (unquoted expansion, flagged SC2086).
- **`WORKDIR` instead of `cd`** for the image service install, restoring `/config`
  afterwards so the terminal still opens in the Home Assistant configuration
  directory.
- Remaining hadolint exclusions are now justified inline in the workflow:
  `FROM ${BUILD_FROM}` is required by the Supervisor build contract, and the npm
  version policy is deliberate.

### 🛠️ Improvement - `persist-install`
- **`--ha-cli` no longer downgrades the bundled CLI.** It installed a hardcoded
  `4.42.0` into `/data/packages/bin`, which comes *first* in `PATH` and therefore
  shadowed the newer `ha` shipped in the image. It now detects the bundled CLI and
  declines, with `--force` as an escape hatch.
- **A failed `apk add` no longer killed the caller's shell** (`exit 1` → `return 1`).
- **Honest limits**: installing system packages now states that only executables and
  shared libraries are copied, so packages needing data files may not survive a
  restart from the persistent copy alone.

### 📚 Documentation - The project instructions described an add-on that no longer exists
- **`CLAUDE.md` documented credential paths the code has not used for several
  releases**, which would have led anyone following it to "fix" authentication into
  the wrong directory:
  - `HOME` is `/data/home`, not `/root`.
  - `ANTHROPIC_CONFIG_DIR` is `/data/.config/claude`, not `/config/claude-config`.
  - `CLAUDE_CREDENTIALS_DIRECTORY` was listed as a key environment variable. It is
    set nowhere in the codebase and never was.
  - `/config/claude-config/` is a **legacy** location, read once by the migration,
    not where credentials live.
  - The "background credential monitoring service" in the startup flow was removed
    when the add-on moved to `/data`.
- **`README.md` claimed `/addons` was mapped.** Only `config:rw` is.
- **`persist-install --ha-cli` guidance corrected**: `ha` already ships in the image.
- **These three files are now pinned against each other.**
  `tests/test-release-metadata.sh` fails if `run.sh` and `CLAUDE.md` disagree on
  `HOME`, `ANTHROPIC_CONFIG_DIR`, `ANTHROPIC_HOME` or `GH_CONFIG_DIR`. Doc/code
  drift is this repository's recurring failure mode; it is now a build failure.

### 🔒 Security - Credential handling hygiene
- **The authentication helper no longer writes your code to `/tmp/claude-auth-code`.**
  It was written on every manual authentication and never read back: an
  authentication code left in plaintext on disk for nothing.
- **GitHub token entry rewritten.** The token was read inside a command
  substitution subshell and `gh`'s output was sent to `/dev/null`, so a rejected
  token looked like a successful login. It is now read in the current shell, errors
  are visible, and the variable is unset afterwards.

### 🔧 Technical - Tests and CI
- **Continuous integration added.** Nothing ran the existing test suite; the only
  workflow was the `@claude` mention handler. Pull requests and pushes now run
  shellcheck, hadolint, the shell suites, the Node suite and a real image build.
- **The image service has tests for the first time** (9 cases): health, config,
  upload, rejection of non-image payloads, hostile filenames, the HTTP proxy and
  the WebSocket upgrade — including the first-request upgrade regression above.
- **Regression tests for every fix in this release**: tool installation, migration
  idempotence, dotfile migration, and readiness probing.
- **Release metadata is enforced**: `config.yaml`, `build.yaml` and `CHANGELOG.md`
  must agree on the version, every declared architecture must have a base image,
  and the security invariants above are asserted in CI.
- **Dead code removed.** `scripts/persistent-packages.sh` (201 lines) was never
  called by `run.sh`, which carries its own copy of those functions — yet half the
  test suite exercised only that dead file. Its real equivalent in `run.sh` is
  already covered by `test-production-run.sh`.
- **Reproducible dependency installs**: `package-lock.json` is now committed and the
  image builds with `npm ci`, so two images tagged with the same version contain the
  same dependency tree.

## 2.0.13

### Bug fixes
- Disabled tmux mouse capture by default so browser paste, including OAuth codes, is reliable; added the `tmux_mouse` option for users who want it (#26).
- Fixed configured APK and pip package installation by handling Bashio's newline-separated list output directly instead of parsing it as JSON (#25).
- Updated persistent Claude detection for current npm releases, which provide `bin/claude` instead of the removed `cli.js` entry point (#21).
- Restored ARMv7 builds after upstream asset changes: Claude Code uses the final portable JavaScript release (`1.0.128`), HA CLI stays on the last release that still ships the ARMv7 asset (`4.46.0`), and GitHub CLI uses its ARMv6-compatible binary pinned to a version verified to publish it. The 64-bit builds continue using current native releases.
- Fixed the architecture detection at the root: the Dockerfile now resolves the target from Home Assistant's `BUILD_ARCH` build argument (falling back to BuildKit's `TARGETARCH`/`TARGETVARIANT` and finally `uname`). The previous `TARGETARCH = "arm/v7"` check never matched — BuildKit reports 32-bit ARM as `TARGETARCH=arm` with `TARGETVARIANT=v7` — so ARMv7 builds silently fell through to the "unsupported architecture" error and the Claude version pin was ignored.
- Persistent Claude overrides are now activated only after the installed binary passes a version check (run under a `timeout` so a hung `--version` cannot block startup); 32-bit ARM startup updates stay on the portable release instead of replacing it with an unsupported native wrapper.

## 2.0.12

### 🐛 Bug Fix - Claude Code ≥2.1.181 crashes with `statx: symbol not found`
- **Bumped base image from Alpine 3.19 to Alpine 3.21** (musl 1.2.4 → musl 1.2.5)
  - Claude Code's native Bun binary began referencing the `statx` libc wrapper at
    v2.1.181. musl only added this wrapper in 1.2.5 (Alpine 3.20+); Alpine 3.19
    (musl 1.2.4) does not export it, causing every version ≥2.1.181 to fail at
    dynamic-link time with `Error relocating … statx: symbol not found` (exit 127).
  - The host Linux kernel has had the `statx` *syscall* since 4.11; only the
    userspace musl wrapper was missing.
  - With musl 1.2.5 present, Claude Code ≥2.1.181 (and the current latest) loads
    and runs correctly.
- **Note on AVX2**: The crash was a linker error, **not** a CPU instruction issue.
  The existing 2.1.179 binary already runs on non-AVX2 hardware (e.g. AMD GX-415).


## 2.0.11

### ✨ New Feature - Optional Persistent Claude Code Override
- **Safe-by-default persistent Claude support**: Added optional `use_persistent_claude` mode that lets advanced users run a Claude Code version installed under `/data/npm/`
  - **Default remains unchanged**: the add-on still uses the Claude version baked into the image unless explicitly enabled
  - **Official startup-managed symlink**: `/usr/local/bin/claude` now points to the persistent install during startup when present
  - **No self-modifying menu scripts**: persistent override is handled in `run.sh`, keeping behavior deterministic and easier to support
- **Optional startup updates**: Added `auto_update_claude_on_start` (default: `false`)
  - When enabled together with `use_persistent_claude`, the add-on runs `npm install -g @anthropic-ai/claude-code@latest` into `/data/npm/` at startup
  - If the update fails, startup continues and uses the previously installed persistent version when available
- **Session picker version visibility**: Interactive menu now shows the active Claude Code version at the top

## 2.0.10

### 🐛 Bug Fix - CPU Compatibility with AVX Fallback
- **Native installer with automatic npm fallback**: Fixed Docker build failure on CPUs without AVX support (#5)
  - **How it works**: Tries native installer first (Bun-based, recommended by Anthropic); if it fails (e.g., CPU lacks AVX), automatically falls back to npm installation
  - **Affected hardware**: Older NUCs, Intel Atom/Celeron processors, some virtualized environments (Proxmox, VirtualBox on older hosts)
  - **Modern hardware**: No change — continues using the native installer as before
  - **Result**: Add-on now builds on all CPUs without sacrificing the recommended install method for capable hardware

## 2.0.9

### 🐛 Bug Fix - First Connection Drop on Terminal Load
- **Removed invalid ttyd client options**: `enableReconnect` and `reconnectInterval` are hterm options not supported by ttyd 1.7.4 (xterm.js-based), causing the WebSocket client to error and disconnect on first load
  - Kept only valid options: `--ping-interval 30` and `--client-option reconnect=5`
  - First connection now establishes cleanly without requiring a retry

## 2.0.8

### 🐛 Bug Fix - Image Service Crash on WebSocket Errors (#8)
- **Fixed `res.status is not a function` crash**: The proxy `onError` handler in `server.js` now checks whether `res` is an Express response (HTTP) or a raw socket (WebSocket) before calling `.status()`
  - Previously, WebSocket proxy errors crashed the entire image service process
  - Now gracefully handles both HTTP and WebSocket error scenarios

### 🐛 Bug Fix - Disable Auto-Update Nag Inside Container (#7)
- **Suppressed Claude CLI update prompts**: Set `DISABLE_AUTOUPDATER=1` in both runtime environment and profile script
  - Claude Code binary is baked into the container image; updates are delivered via add-on releases
  - Eliminates the persistent "update available" banner on every session start

### 🐛 Bug Fix - Session Reconnection After Disconnect (#6)
- **Fixed "Press return to reconnect" not working**: Removed `exec` from session picker launch functions so Claude exiting returns to the menu instead of terminating the process
  - When Claude CLI exits (via `/exit`, Escape, or crash), the session picker menu now reappears automatically
  - Bash shell sessions also return to menu on `exit`
  - Removed aggressive EXIT trap that was killing the session picker prematurely
- **Added ttyd keepalive and auto-reconnect**: Configured `--ping-interval 30` and client-side reconnect options to prevent WebSocket idle disconnects and automatically recover from network interruptions

## 2.0.7

### 🐛 Bug Fix - Native Install Path Mismatch
- **Fixed "installMethod is native, but directory does not exist" error**: Claude binary now available at `$HOME/.local/bin/claude` at runtime
  - **Root cause**: Native installer places Claude at `/root/.local/bin/claude` during Docker build, but at runtime `HOME=/data/home`, so Claude's self-check looks in `/data/home/.local/bin/claude` which didn't exist
  - **Solution**: Symlink created from `/data/home/.local/bin/claude` → `/root/.local/bin/claude` on startup
  - **PATH updated**: Added `/data/home/.local/bin` to PATH in both runtime and profile script
  - **Result**: Claude native binary resolves correctly regardless of HOME directory change

## 2.0.6

### 🛠️ Improvement - Native Claude Code Installation
- **Migrated to native installer**: Claude Code now installed using Anthropic's recommended native binary installer
  - Replaces npm installation (`@anthropic-ai/claude-code`) with `curl -fsSL https://claude.ai/install.sh | bash`
  - More reliable builds (no npm retry logic needed)
  - Follows Anthropic's official distribution method
  - npm installation is deprecated by Anthropic
- **Updated health checks**: Network connectivity now validates `claude.ai` instead of npm registry
- **Simplified run.sh**: Removed `node $(which claude)` wrapper, now calls `claude` directly

## 2.0.5

### 🐛 Bug Fix - Claude CLI Not Found
- **Fixed session picker failing to launch Claude**: Used full path `/usr/local/bin/claude`
  - ttyd bash sessions don't inherit full PATH from parent process
  - All claude invocations now use absolute path for reliability

## 2.0.4

### ✨ New Feature - GitHub CLI Pre-installed
- **GitHub CLI (gh) included**: GitHub's official CLI tool now pre-installed in Docker image
  - Create, view, and manage GitHub issues and pull requests
  - Work with GitHub repositories directly from the terminal
  - Authenticate with `gh auth login`
  - Essential for git workflows: `gh pr create`, `gh issue list`, `gh repo clone`
  - Automatically fetches latest version during build

### 🛠️ Improvement - Persistent GitHub Authentication
- **GitHub credentials survive reboots**: `GH_CONFIG_DIR` set to `/data/.config/gh`
  - Login once with `gh auth login`, credentials persist across container restarts
  - Consistent with Claude credential persistence approach
  - No need to re-authenticate after Home Assistant updates
- **Session picker menu option**: New "🐙 GitHub CLI login" option (choice 6)
  - Guided authentication flow with browser or token options
  - Shows current auth status before prompting
  - Instructions for creating GitHub personal access tokens

## 2.0.3

### ✨ New Features - Enhanced Developer Toolkit
- **Pre-installed Python libraries**: Common libraries for Home Assistant scripting
  - `py3-requests` - HTTP library for API calls
  - `py3-aiohttp` - Async HTTP client/server
  - `py3-yaml` - YAML parsing for HA configuration
  - `py3-beautifulsoup4` - HTML/XML parsing
- **Additional system tools**: More utilities available out-of-the-box
  - `vim` - Advanced text editor
  - `wget` - File download utility
  - `tree` - Directory tree visualization
  - `yq` - YAML processor (essential for Home Assistant configs)

### 📚 Documentation
- **Community Tools section**: Added links to community-built tools in README
  - Featured: `ha-ws-client-go` by @schoolboyqueue for WebSocket API access

### 🔗 PR Attribution
- Incorporates contributions from PR #1 (adapted to current codebase)

## 2.0.2

### 🐛 Bug Fix - Claude CLI Launch Failure
- **Fixed session picker dropping to Node.js REPL**: Claude Code CLI now launches correctly
  - **Root cause**: Scripts incorrectly used `node "$(which claude)"` which passes the claude binary path to Node.js as if it were a JS file to execute
  - **Symptom**: Selecting "New interactive session" showed `Welcome to Node.js v20.15.1` and `>` prompt instead of launching Claude
  - **Solution**: Changed all invocations to use `exec claude $flags` directly, since `claude` is already a properly wrapped executable
  - **Affected scripts**: `claude-session-picker.sh`, `claude-auth-helper.sh`
  - **Result**: All session picker options now correctly launch Claude Code CLI

## 2.0.1

### 🐛 Bug Fix - Build Error
- **Removed unpublished plugin from Dockerfile**: Fixed Docker build failure
  - Plugin `@ESJavadex/claude-homeassistant-plugins` not yet in registry
  - Plugins now recommended for manual installation
  - Build process works correctly again

## 2.0.0

### 🎉 Major Release - Enhanced Developer Experience

### ✨ New Features

- **Git Pre-installed**: Git version control included in base Docker image
  - No need to use `persist-install git` anymore
  - Available immediately on fresh installs
  - Enables version control workflows within the terminal

### 📦 Recommended Plugins

For an enhanced experience, manually install the Claude Home Assistant Plugins:

```bash
npx claude-plugins install @ESJavadex/claude-homeassistant-plugins/homeassistant-config
```

See [claude-homeassistant-plugins](https://github.com/ESJavadex/claude-homeassistant-plugins) for details.

## 1.7.1

### ✨ Improvement - Auto-Copy & Focus for Image Uploads
- **Streamlined image workflow**: Path automatically copied and terminal focused after upload
  - **Auto-copy to clipboard**: File path instantly copied when image uploaded
  - **Auto-focus terminal**: Terminal iframe automatically focused and ready
  - **Auto-paste attempt**: Tries to paste path directly (may be blocked by browser security)
  - **Clear status**: Shows "Ready to use! (path in clipboard)"
  - **Workflow**: Upload image → Press Cmd+V → Done!
  - **Fallback**: If auto-paste blocked, just press Cmd+V (clipboard already has path)

**How it works now**:
1. Paste/drag/upload an image
2. Path is automatically copied to clipboard
3. Terminal is automatically focused
4. Just press Cmd+V to paste the path
5. Ask Claude to analyze it!

This makes the image workflow nearly seamless - you don't need to click anything after uploading!

## 1.7.0

### ✨ New Feature - Voice Input with Web Speech API
- **Talk to Claude instead of typing**: Built-in speech-to-text using Chrome's Web Speech API
  - **Press-to-talk button**: Click 🎤 Voice Input button in header
  - **Real-time transcription**: See your speech converted to text as you speak
  - **Continuous recording**: Keeps listening until you stop
  - **Editable transcript**: Edit the transcribed text before copying
  - **Copy to clipboard**: One-click copy to paste into Claude Terminal
  - **Keyboard shortcuts**:
    - `Space` - Start/stop recording
    - `Enter` - Copy transcript
    - `Escape` - Close modal
  - **Error handling**: Clear messages for microphone issues, permissions, etc.
  - **No external services**: Uses browser's built-in speech recognition (Chrome, Edge, Safari)
  - **Perfect for**: Long questions, complex queries, hands-free operation

- **How to use**:
  1. Click 🎤 Voice Input button
  2. Click "Start Recording" and speak
  3. Click "Stop Recording" when done
  4. Edit text if needed
  5. Click "Copy Text"
  6. Paste into Claude Terminal!

**Browser support**: Chrome, Edge, Safari (requires microphone permissions)

## 1.6.6

### 🐛 Bug Fix - Clipboard API in Home Assistant Ingress
- **Fixed clipboard copy in iframe context**: Added fallback methods for copying file path
  - **Root cause**: `navigator.clipboard` API is blocked in Home Assistant ingress iframes
  - **Error**: "Cannot read properties of undefined (reading 'writeText')"
  - **Solution**: Multi-tier fallback approach:
    1. Try modern Clipboard API if available
    2. Fallback to `document.execCommand('copy')` with text selection
    3. Final fallback: Select text for manual Cmd+C copy
  - **User feedback**: Shows "✓ Copied!" or "✓ Selected! Press Cmd+C to copy"
  - **Result**: Path copying now works in all contexts (direct access, ingress, iframes)

**Technical note**: Browser security restrictions prevent clipboard access in cross-origin iframes. The new implementation uses progressive enhancement to provide the best experience available in each context.

## 1.6.5

### ✨ UX Improvement - Better Path Visibility for Manual Copy
- **Enhanced upload status display**: Full file path now shown prominently with click-to-copy functionality
  - **Previous**: Only showed filename ("Uploaded: pasted-123.png")
  - **Now**: Shows full path with icon ("📋 /data/images/pasted-123.png (click to copy)")
  - **Persistent display**: Path remains visible until next upload (no auto-hide)
  - **Click-to-copy**: Click the status text to copy path to clipboard
  - **Visual feedback**: Shows "✓ Copied to clipboard!" confirmation
  - **Fallback**: If clipboard API fails, shows error and allows manual selection
  - **User-friendly**: Hover effect and cursor pointer indicate clickability

This improvement addresses the issue where users couldn't easily see or copy the full file path to manually paste into Claude Code CLI.

## 1.6.4

### 🐛 Critical Fix - Home Assistant Ingress Compatibility
- **Fixed 404 errors and config loading failures**: Changed all paths to relative for ingress compatibility
  - **Root cause**: Absolute paths (`/config`, `/terminal/`, `/upload`) don't work with Home Assistant ingress
  - **Impact**: All API endpoints returned 404, terminal wouldn't load, uploads failed
  - **Solution**: Changed to relative paths (`config`, `terminal/`, `upload`)
  - **Why**: Home Assistant ingress adds path prefix `/api/hassio_ingress/TOKEN/` to all requests
  - **Result**: All features now work correctly through Home Assistant ingress

**Technical note**: This is a common Home Assistant add-on issue. When using ingress, all fetch calls and iframe sources must use relative paths (without leading `/`) to work correctly with the ingress path prefix.

## 1.6.3

### 🐛 Bug Fix - Image Service Startup Logging
- **Improved error visibility**: Node.js console output now shown directly in add-on logs
  - **Previous issue**: Errors were hidden in /var/log/image-service.log
  - **Solution**: Pipe Node.js stdout/stderr directly to add-on logs with `[Image Service]` prefix
  - **Added checks**: Verify server.js and node_modules exist before starting
  - **Auto-recovery**: Attempt `npm install` if node_modules is missing
  - **Result**: All startup errors now visible in `ha addons logs`

This will help diagnose why the image service isn't starting properly.

## 1.6.2

### 🐛 Critical Bug Fix - Express Route Order
- **Fixed 404 errors on API endpoints**: API routes now registered before static file middleware
  - **Root cause**: Static file middleware was placed before API routes in Express app
  - **Impact**: `/config` returned HTML instead of JSON, `/terminal` returned 404
  - **Solution**: Moved all API routes (/health, /config, /upload, /terminal) before static middleware
  - **Result**: All endpoints now work correctly

This is a common Express.js gotcha - middleware order matters! Static file middleware should come AFTER API routes to prevent it from intercepting API requests.

## 1.6.1

### 🐛 Bug Fixes - Image Paste Service
- **Fixed upload JSON parse errors**: Server now returns proper JSON error responses instead of HTML
  - **Root cause**: Multer errors were not caught, Express returned default HTML error pages
  - **Solution**: Added Multer-specific error handling middleware
  - **Impact**: Upload errors now show clear, actionable messages

- **Fixed terminal not loading through Home Assistant ingress**: Terminal now loads via proxy endpoint
  - **Root cause**: iframe tried to access ttyd on port 7681 directly, incompatible with ingress
  - **Solution**: Added http-proxy-middleware with WebSocket support, created /terminal/ proxy endpoint
  - **Impact**: Terminal works correctly through Home Assistant ingress

- **Improved paste event detection**: Better debugging and compatibility
  - Added detailed console logging for troubleshooting
  - Added window-level paste handler as fallback
  - Enhanced error handling in upload function

### 📦 Dependencies
- Added `http-proxy-middleware@^2.0.6` for WebSocket-capable terminal proxying

## 1.6.0

### ✨ New Feature - Image Paste Support
- **Paste images directly in the terminal**: Upload images via paste (Ctrl+V), drag-drop, or upload button
  - **Lightweight Node.js service**: ~10MB RAM overhead, ARM-compatible for Raspberry Pi
  - **Multiple upload methods**: Clipboard paste, drag-and-drop, or button click
  - **Persistent storage**: Images saved to `/data/images/` (survives restarts)
  - **Claude integration**: Use uploaded images with Claude Code CLI for analysis, OCR, etc.
  - **File formats**: Supports JPEG, PNG, GIF, WebP, SVG (10MB limit)

- **Architecture changes**:
  - New image upload service on port 7680 (Express + Multer)
  - Custom HTML interface embeds ttyd terminal (port 7681)
  - Home Assistant ingress now points to port 7680
  - Both services run concurrently in the container

- **User experience**:
  - Copy image → Paste in terminal → Automatic upload
  - File path shown in status bar: `/data/images/pasted-<timestamp>.png`
  - Use with Claude: `analyze /data/images/pasted-123.png`

### 📚 Documentation
- Added `IMAGE_PASTE.md` with complete feature documentation
- Updated CLAUDE.md with image paste development notes
- Documented troubleshooting and browser compatibility

### 🔧 Technical Details
- Dependencies: Express (4.18.2), Multer (1.4.5-lts.1)
- Security: MIME type validation, 10MB size limit, isolated storage
- Performance: Minimal CPU usage, only active during uploads
- Compatibility: All supported architectures (amd64, aarch64, armv7)

## 1.5.2

### 🐛 Critical Bug Fix - Persistent Packages PATH
- **Fixed persistent packages not available in terminal**: Packages installed via `persist-install` are now correctly available in all bash sessions
  - **Root cause**: Environment variables (PATH, LD_LIBRARY_PATH) were only set in parent run.sh process
  - **Solution**: Created `/etc/profile.d/persistent-packages.sh` which is auto-sourced by all bash shells
  - **Impact**: `python3`, `ha`, and other installed packages now work immediately after installation
  - **Affected versions**: 1.4.0 - 1.5.1 (packages were installed correctly but not in PATH)

- **Technical details**:
  - ttyd spawns bash sessions that don't inherit parent process environment variables
  - Standard Linux solution: Use `/etc/profile.d/` for system-wide environment configuration
  - Profile script sets HOME, XDG variables, and persistent package paths for all sessions
  - No changes needed to existing installations - automatic on container restart

### 📚 Documentation Updates
- Added troubleshooting section for PATH issues in CLAUDE.md
- Documented the fix and migration path from older versions
- Updated development notes with container testing workflow

## 1.5.1

### 🐛 Bug Fixes
- Improved Home Assistant CLI installation verification
- Enhanced error handling for ha command checks

## 1.5.0

### ✨ New Features
- **Official Home Assistant CLI support**: Install with `persist-install --ha-cli`
  - Auto-detects architecture (amd64, aarch64, armv7, armhf, i386)
  - Downloads binary from official GitHub releases
  - Provides full access to Home Assistant management commands
  - Alternative to Supervisor REST API for programmatic access

## 1.4.0

### ✨ New Features - Persistent Package System
- **`persist-install` command**: Install packages that survive container restarts!
  - Simple syntax: `persist-install python3 git vim`
  - Python packages: `persist-install --python homeassistant-cli requests`
  - List installed: `persist-install --list`
  - Packages stored in `/data/packages` (persistent Home Assistant storage)
  - No need to rebuild Docker image for new tools

- **Auto-install packages on startup**: Configure packages in add-on settings
  - `persistent_apk_packages`: System packages (git, vim, htop, etc.)
  - `persistent_pip_packages`: Python packages (homeassistant-cli, requests, etc.)
  - Automatically installed on every container startup
  - Perfect for your essential toolkit

- **Python virtual environment**: Persistent Python environment
  - Located at `/data/packages/python/venv`
  - Automatically activated when packages are installed
  - Survives reboots and container recreations

### 🏗️ Architecture Improvements
- **Scalable package management**: No longer requires Dockerfile modifications
  - Add packages via terminal command or config
  - Instant package installation without rebuilding
  - Reduced image size (only core tools in image)
  - User-specific package installations

- **Smart PATH management**: Persistent binaries take priority
  - `/data/packages/bin` added to PATH
  - Python venv automatically activated
  - Library paths configured for compiled packages

### 📚 Documentation
- **Container architecture explained**: Comprehensive guide to persistence
  - Why runtime installations (apk add) disappear
  - Difference between image layers and volume layers
  - How persistent storage solves the problem
  - Migration from Dockerfile-based approach to persistent storage

## 1.3.2

### 🐛 Bug Fixes
- **Improved installation reliability** (#16): Enhanced resilience for network issues during installation
  - Added retry logic (3 attempts) for npm package installation
  - Configured npm with longer timeouts for slow/unstable connections
  - Explicitly set npm registry to avoid DNS resolution issues
  - Added 10-second delay between retry attempts

### 🛠️ Improvements
- **Enhanced network diagnostics**: Better troubleshooting for connection issues
  - Added DNS resolution checks to identify network configuration problems
  - Check connectivity to GitHub Container Registry (ghcr.io)
  - Extended connection timeouts for virtualized environments
  - More detailed error messages with specific solutions
- **Better virtualization support**: Improved guidance for VirtualBox and Proxmox users
  - Enhanced VirtualBox detection with detailed configuration requirements
  - Added Proxmox/QEMU environment detection
  - Specific network adapter recommendations for VM installations
  - Clear guidance on minimum resource requirements (2GB RAM, 8GB disk)

## 1.3.1

### 🐛 Critical Fix
- **Restored config directory access**: Fixed regression where add-on couldn't access Home Assistant configuration files
  - Re-added `config:rw` volume mapping that was accidentally removed in 1.2.0
  - Users can now properly access and edit their configuration files again

## 1.3.0

### ✨ New Features
- **Full Home Assistant API Access**: Enabled complete API access for automations and entity control
  - Added `hassio_api`, `homeassistant_api`, and `auth_api` permissions
  - Set `hassio_role` to 'manager' for full Supervisor access
  - Created comprehensive API examples script (`ha-api-examples.sh`)
  - Includes Supervisor API, Core API, and WebSocket examples
  - Python and bash code examples for entity control

### 🐛 Bug Fixes
- **Fixed authentication paste issues** (#14): Added authentication helper for clipboard problems
  - New authentication helper script with multiple input methods
  - Manual code entry option when clipboard paste fails
  - File-based authentication via `/config/auth-code.txt`
  - Integrated into session picker as menu option

### 🛠️ Improvements
- **Enhanced diagnostics** (#16): Added comprehensive health check system
  - System resource monitoring (memory, disk space)
  - Permission and dependency validation
  - VirtualBox-specific troubleshooting guidance
  - Automatic health check on startup
  - Improved error handling with strict mode

## 1.2.1

### 🔧 Internal Changes
- Fixed YAML formatting issues for better compatibility
- Added document start marker and fixed line lengths

## 1.2.0

### 🔒 Authentication Persistence Fix (PR #15)
- **Fixed OAuth token persistence**: Tokens now survive container restarts
  - Switched from `/config` to `/data` directory (Home Assistant best practice)
  - Implemented XDG Base Directory specification compliance
  - Added automatic migration for existing authentication files
  - Removed complex symlink/monitoring systems for simplicity
  - Maintains full backward compatibility

## 1.1.4

### 🧹 Maintenance
- **Cleaned up repository**: Removed erroneously committed test files (thanks @lox!)
- **Improved codebase hygiene**: Cleared unnecessary temporary and test configuration files

## 1.1.3

### 🐛 Bug Fixes
- **Fixed session picker input capture**: Resolved issue with ttyd intercepting stdin, preventing proper user input
- **Improved terminal interaction**: Session picker now correctly captures user choices in web terminal environment

## 1.1.2

### 🐛 Bug Fixes
- **Fixed session picker input handling**: Improved compatibility with ttyd web terminal environment
- **Enhanced input processing**: Better handling of user input with whitespace trimming
- **Improved error messages**: Added debugging output showing actual invalid input values
- **Better terminal compatibility**: Replaced `echo -n` with `printf` for web terminals

## 1.1.1

### 🐛 Bug Fixes  
- **Fixed session picker not found**: Moved scripts from `/config/scripts/` to `/opt/scripts/` to avoid volume mapping conflicts
- **Fixed authentication persistence**: Improved credential directory setup with proper symlink recreation
- **Enhanced credential management**: Added proper file permissions (600) and logging for debugging
- **Resolved volume mapping issues**: Scripts now persist correctly without being overwritten

## 1.1.0

### ✨ New Features
- **Interactive Session Picker**: New menu-driven interface for choosing Claude session types
  - 🆕 New interactive session (default)
  - ⏩ Continue most recent conversation (-c)
  - 📋 Resume from conversation list (-r) 
  - ⚙️ Custom Claude command with manual flags
  - 🐚 Drop to bash shell
  - ❌ Exit option
- **Configurable auto-launch**: New `auto_launch_claude` setting (default: true for backward compatibility)
- **Added nano text editor**: Enables `/memory` functionality and general text editing

### 🛠️ Architecture Changes
- **Simplified credential management**: Removed complex modular credential system
- **Streamlined startup process**: Eliminated problematic background services
- **Cleaner configuration**: Reduced complexity while maintaining functionality
- **Improved reliability**: Removed sources of startup failures from missing script dependencies

### 🔧 Improvements
- **Better startup logging**: More informative messages about configuration and setup
- **Enhanced backward compatibility**: Existing users see no change in behavior by default
- **Improved error handling**: Better fallback behavior when optional components are missing

## 1.0.2

### 🔒 Security Fixes
- **CRITICAL**: Fixed dangerous filesystem operations that could delete system files
- Limited credential searches to safe directories only (`/root`, `/home`, `/tmp`, `/config`)
- Replaced unsafe `find /` commands with targeted directory searches
- Added proper exclusions and safety checks in cleanup scripts

### 🐛 Bug Fixes
- **Fixed architecture mismatch**: Added missing `armv7` support to match build configuration
- **Fixed NPM package installation**: Pinned Claude Code package version for reliable builds
- **Fixed permission conflicts**: Standardized credential file permissions (600) across all scripts
- **Fixed race conditions**: Added proper startup delays for credential management service
- **Fixed script fallbacks**: Implemented embedded scripts when modules aren't found

### 🛠️ Improvements
- Added comprehensive error handling for all critical operations
- Improved build reliability with better package management
- Enhanced credential management with consistent permission handling
- Added proper validation for script copying and execution
- Improved startup logging for better debugging

### 🧪 Development
- Updated development environment to use Podman instead of Docker
- Added proper build arguments for local testing
- Created comprehensive testing framework with Nix development shell
- Added container policy configuration for rootless operation

## 1.0.0

- First stable release of Claude Terminal add-on:
  - Web-based terminal interface using ttyd
  - Pre-installed Claude Code CLI
  - User-friendly interface with clean welcome message
  - Simple claude-logout command for authentication
  - Direct access to Home Assistant configuration
  - OAuth authentication with Anthropic account
  - Auto-launches Claude in interactive mode
