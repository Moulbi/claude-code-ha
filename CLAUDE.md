# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This repository contains Home Assistant add-ons, specifically the **Claude Terminal Pro** add-on which provides a web-based terminal interface with Claude Code CLI pre-installed and persistent package management. The add-on allows Home Assistant users to access Claude AI capabilities directly from their dashboard.

**Fork Attribution:** This is an enhanced fork of [heytcass/home-assistant-addons](https://github.com/heytcass/home-assistant-addons) by Tom Cassady, maintained by Javier Santos ([@esjavadex](https://github.com/esjavadex)). The fork adds persistent package management, auto-install configuration, and enhanced documentation.

## Development Environment

### Setup
```bash
# Enter the development shell (NixOS/Nix)
nix develop

# Or with direnv (if installed)
direnv allow
```

### Core Development Commands
- `build-addon` - Build the Claude Terminal Pro add-on with Podman
- `run-addon` - Run add-on locally on port 7680 with volume mapping
- `lint-dockerfile` - Lint Dockerfile using hadolint
- `test-endpoint` - Test web endpoint availability (curl localhost:7680)

### Manual Commands (without aliases)
```bash
# Build
podman build --build-arg BUILD_FROM=ghcr.io/home-assistant/amd64-base:3.21 -t local/claude-terminal-pro ./claude-terminal

# Run locally
podman run -p 7680:7680 -v $(pwd)/config:/config local/claude-terminal-pro

# Lint
hadolint ./claude-terminal/Dockerfile

# Test endpoint
curl -X GET http://localhost:7680/
```

## Architecture

### Networking model (do not regress)
The add-on publishes **no host port**. `ttyd` runs `--writable` with no
credentials, so any reachable socket is an unauthenticated root shell in a
container holding `/config` read-write and `SUPERVISOR_TOKEN`.

- Home Assistant ingress terminates on port **7680** (the Node image service),
  which reaches the container over the internal Docker network — no host port
  mapping is needed or wanted.
- `ttyd` binds **127.0.0.1:7681** and is reached only via the image service's
  `/terminal` proxy.
- Never add a `ports:` mapping to `config.yaml` and never bind ttyd to
  `0.0.0.0`. `tests/test-release-metadata.sh` fails the build if you do.

### Supervisor privileges (do not regress)
`hassio_role: homeassistant`, not `manager`. `manager` grants add-on management,
and an add-on can run privileged on the host, so code execution in this container
would become host takeover. The Core API (states, services, events) comes from
`homeassistant_api: true` and is unaffected; `ha addons ...` and
`ha supervisor ...` are refused by design.
`tests/test-release-metadata.sh` fails the build if the role widens.

### Testing
Run `./tests/run-tests.sh` before committing. It covers release metadata, the
production `run.sh`, startup hardening and the Node image service. CI
(`.github/workflows/ci.yml`) runs the same suites plus shellcheck, hadolint and
a real multi-arch image build.

### Add-on Structure (claude-terminal/)
- **config.yaml** - Home Assistant add-on configuration (multi-arch, ingress, ports)
- **Dockerfile** - Alpine-based container with Node.js and Claude Code CLI
- **build.yaml** - Multi-architecture build configuration (amd64, aarch64, armv7)
- **run.sh** - Main startup script with credential management and ttyd terminal
- **scripts/** - Modular credential management scripts

### Key Components
1. **Web Terminal**: Uses ttyd to provide browser-based terminal access
2. **Credential Management**: Persistent authentication storage in `/data/.config/claude/`
3. **Service Integration**: Home Assistant ingress support with panel icon
4. **Multi-Architecture**: Supports amd64, aarch64, armv7 platforms

### Credential System
- **Persistent Storage**: Credentials live in `/data/.config/claude/`. `/data` is
  the Supervisor-managed volume, guaranteed writable, and survives restarts,
  add-on updates and reboots.
- **`/config/claude-config/` is a LEGACY location**, not the current one. It is
  read once by `migrate_legacy_auth_files`, which fills in only files missing from
  `/data` (`cp -a -n`), never overwrites, and marks itself complete in
  `/data/.auth-migration-complete` so it cannot run twice.
- **Security**: credential files are chmod 600.
- There is no background credential-monitoring service; earlier revisions
  described one that was removed when the add-on moved to `/data`.

### Container Execution Flow
1. Run the health check, then initialize the `/data` environment
2. Verify required tools are present (they are baked into the image; the `apk`
   path is only a fallback for older images)
3. Configure tmux, the optional persistent Claude override, the session picker
   and `persist-install`
4. Start the Node image service under a supervisor and wait for `/health`
5. `exec` ttyd on 127.0.0.1, attached to the persistent `claude` tmux session

## Development Notes

### Local Container Testing
For rapid development and debugging without pushing new versions:

#### Quick Build & Test
```bash
# Build test version
podman build --build-arg BUILD_FROM=ghcr.io/home-assistant/amd64-base:3.21 -t local/claude-terminal:test ./claude-terminal

# Create test config directory
mkdir -p /tmp/test-config/claude-config

# Configure session picker (optional)
echo '{"auto_launch_claude": false}' > /tmp/test-config/options.json

# Run test container
podman run -d --name test-claude-dev -p 7680:7680 -v /tmp/test-config:/config local/claude-terminal:test

# Check logs
podman logs test-claude-dev

# Test web interface at http://localhost:7680

# Stop and cleanup
podman stop test-claude-dev && podman rm test-claude-dev
```

#### Interactive Testing
```bash
# Test session picker directly
podman run --rm -it local/claude-terminal:test /opt/scripts/claude-session-picker.sh

# Execute commands inside running container
podman exec -it test-claude-dev /bin/bash

# Test script modifications without rebuilding
podman cp ./claude-terminal/scripts/claude-session-picker.sh test-claude-dev:/opt/scripts/
podman exec test-claude-dev chmod +x /opt/scripts/claude-session-picker.sh
```

#### Development Workflow
1. **Make changes** to scripts or Dockerfile
2. **Rebuild** with `podman build -t local/claude-terminal:test ./claude-terminal`
3. **Stop/remove** old container: `podman stop test-claude-dev && podman rm test-claude-dev`
4. **Start new** container with updated image
5. **Test** changes at http://localhost:7680
6. **Repeat** until satisfied, then commit and push

#### Debugging Tips
- **Check container logs**: `podman logs -f test-claude-dev` (follow mode)
- **Inspect running processes**: `podman exec test-claude-dev ps aux`
- **Test individual scripts**: `podman exec test-claude-dev /opt/scripts/script-name.sh`
- **Volume contents**: `ls -la /tmp/test-config/` to verify persistence

### Production Testing
- **Local Testing**: Use `run-addon` to test on localhost:7680
- **Container Health**: Check logs with `podman logs <container-id>`
- **Authentication**: Use `claude-auth debug` within terminal for credential troubleshooting

### File Conventions
- **Shell Scripts**: Use `#!/usr/bin/with-contenv bashio` for add-on scripts
- **Indentation**: 2 spaces for YAML, 4 spaces for shell scripts
- **Error Handling**: Use `bashio::log.error` for error reporting
- **Permissions**: Credential files must have 600 permissions

### Key Environment Variables
Set by `init_environment` in `run.sh` and mirrored into
`/etc/profile.d/persistent-packages.sh` so every ttyd bash session inherits them.
Keep the two copies in sync — `tests/test-release-metadata.sh` checks them.

- `HOME=/data/home`
- `ANTHROPIC_CONFIG_DIR=/data/.config/claude`
- `ANTHROPIC_HOME=/data`
- `XDG_CONFIG_HOME=/data/.config`, `XDG_CACHE_HOME=/data/.cache`
- `GH_CONFIG_DIR=/data/.config/gh`
- `IS_SANDBOX=1` (the add-on always runs as root in the Supervisor container)
- `DISABLE_AUTOUPDATER=1` (Claude ships with the image; updates come via releases)

There is no `CLAUDE_CREDENTIALS_DIRECTORY`; earlier revisions of this file
documented one that the code never set.

### Important Constraints
- No sudo privileges available in development environment
- Add-on targets Home Assistant OS (Alpine Linux base)
- Must handle credential persistence across container restarts
- Requires multi-architecture compatibility

## Release Management

### CRITICAL: Always Update Version and Changelog

**When making ANY changes to the add-on, you MUST:**

1. **Bump the version** in `claude-terminal/config.yaml`
   - Patch version (x.x.X) for bug fixes and small changes
   - Minor version (x.X.0) for new features
   - Major version (X.0.0) for breaking changes

2. **Update the changelog** in `claude-terminal/CHANGELOG.md`
   - Add new version section at the TOP of the file
   - Use the format: `## X.X.X` followed by `### Category - Description`
   - Categories: ✨ New Feature, 🐛 Bug Fix, 🛠️ Improvement, 📚 Documentation, 🔧 Technical
   - Include bullet points describing what changed and why

**Example workflow:**
```bash
# 1. Make your code changes
# 2. Bump version in config.yaml (e.g., 1.7.3 → 1.7.4)
# 3. Add changelog entry at the top of CHANGELOG.md
# 4. Commit all changes together
```

**Changelog entry format:**
```markdown
## 1.7.4

### ✨ New Feature - Short Description
- **Bold summary**: Detailed explanation of the change
  - Sub-bullet for additional details
  - Another sub-bullet if needed
```

**DO NOT** commit changes without updating both the version and changelog!

## Persistent Package Management (v1.4.0+)

### CRITICAL: When Users Ask to Install Packages

**ALWAYS use `persist-install` instead of `apk add` or `pip install` directly!**

When a user asks you to install ANY package (Python, system tools, libraries, etc.), you MUST:

1. **Recognize the intent**: User says "install X", "I need X", "can you add X", etc.
2. **Use persist-install**: NEVER use `apk add` or `pip install` directly
3. **Explain why**: Tell them it will persist across reboots
4. **Verify**: Check that it worked and is available

### Why persist-install?

```bash
# ❌ WRONG - This disappears after reboot!
apk add python3

# ✅ CORRECT - This survives reboots!
persist-install python3
```

**Container Architecture** (rewritten in 2.2.0):
- `apk add` alone installs to the ephemeral container layer (LOST on restart)
- `persist-install` runs the same `apk add`, then records the package in
  `/data/packages/world` and keeps apk's download cache in
  `/data/packages/apk-cache`
- On every start, `run.sh` replays that list through apk, so packages come back
  as **complete** installations — data files, dependencies and triggers included

**Why it works this way**: the pre-2.2.0 version copied executables and `*.so`
files into `/data` and left everything else behind. `python3` ships 715 files
under `/usr/lib` and its standard library is `.py`, not `.so`, so
`persist-install python3` produced a Python that died at the next restart with
"Could not find platform independent libraries". Persist the inputs, not the
artefacts.

**Offline behaviour**: the cache makes a warm replay take about a second and lets
most packages restore with no network. Not all — apk masks virtual providers
under `--no-network` — so the replay retries package by package and reports which
ones need connectivity. Say that accurately; do not promise full offline support.

**Legacy leftovers**: binaries copied by the old mechanism may still be in
`/data/packages/bin`. That directory is now LAST in `PATH` so it cannot shadow a
real installation. `persist-install --list` flags them.

### Usage Examples

```bash
# Install system packages (Alpine APK)
persist-install vim htop

# Install Python packages (persistent virtualenv)
persist-install --python requests pandas numpy

# Stop reinstalling a package on each start
persist-install --remove htop

# Replay the recorded list now (run.sh does this at startup)
persist-install --restore

# List what is persisted
persist-install --list
```

### How It Works

```
/data/packages/
├── bin/              # Executable binaries (automatically in PATH)
├── lib/              # Shared libraries (LD_LIBRARY_PATH)
└── python/
    └── venv/         # Python virtual environment
        ├── bin/      # Python executables (in PATH)
        └── lib/      # Python packages (site-packages)
```

**Environment Setup**:
- `PATH="/data/packages/python/venv/bin:/data/home/.local/bin:$PATH:/data/packages/bin"`
- The Python venv comes EARLY (it is the intended python); the legacy
  `/data/packages/bin` comes LAST so stale copies cannot shadow a real install
- Python venv automatically activated when packages installed

### When User Asks to Install Something

**Example Conversation Flow**:

```
User: "I need Python installed"

Claude (YOU): "I'll install Python using persist-install so it survives reboots."

[Run]: persist-install python3 py3-pip

[Verify]: python3 --version

Claude: "Python 3.11.x installed successfully! It's stored in /data/packages
        and will persist across container restarts and reboots."
```

**Another Example**:

```
User: "I want to interact with Home Assistant entities"

Claude (YOU): "I'll show you how to use the Supervisor API to interact with
              Home Assistant. Let me install Python requests library."

[Run]: persist-install --python requests

[Show]: curl -H "Authorization: Bearer $SUPERVISOR_TOKEN" \
             http://supervisor/core/api/states | jq '.[0]'

Claude: "You can interact with Home Assistant using the Supervisor API!
        Check /opt/scripts/ha-api-examples.sh for more examples, or use
        Python's requests library for programmatic access."
```

### Proactive Behavior

**You should proactively use persist-install when:**

1. User mentions needing a package/tool/library
2. User wants to run a command that isn't installed
3. You recommend installing something
4. User asks about package management
5. Error indicates missing package

**Examples of user intent**:
- "install python"
- "I need git"
- "can you add vim?"
- "let's install requests"
- "how do I get pandas?"
- "bash: python: command not found" (error message)

### Common Packages Users Might Request

**Already in the image — never install these**: `git`, `nano`, `curl`, `wget`,
`jq`, `tree`, `tmux`, `python3`, `py3-pip`, `node`, `npm`, `ha`, `gh`.

**Common requests that genuinely need installing**:
- `vim` - removed from the image in 2.2.0 (33 MB); `persist-install vim`
- `yq` - removed in 2.2.0 (10 MB); `persist-install yq`
- `htop` - process monitor
- `sqlite` - SQLite database
- Python libraries (`requests`, `pyyaml`, `aiohttp`, `beautifulsoup4`) are no
  longer bundled: use `persist-install --python <name>`

**Python Tools**:
- `python3 py3-pip` - Python and package manager
- `requests` - HTTP library for API calls
- `pyyaml` - YAML parser
- `pandas` - Data analysis
- `numpy` - Numerical computing
- `flask` / `fastapi` - Web frameworks
- `jupyter` - Jupyter notebooks

**Home Assistant CLI**:
- `ha` is **already installed** in the image at `/usr/bin/ha`. Do not install it
  again: `/data/packages/bin` comes first in `PATH`, so a second copy shadows and
  downgrades the bundled one. `persist-install --ha-cli` detects this and declines
  (`--force` overrides).
  - Upstream: https://github.com/home-assistant/cli
  - Provides commands: `ha core`, `ha supervisor`, `ha addons`, etc.
  - Alternative: Use Supervisor REST API (`http://supervisor/`) with `$SUPERVISOR_TOKEN`
  - See `scripts/ha-api-examples.sh` for API usage examples

### Auto-Install Configuration

Users can configure packages to auto-install on startup by editing the add-on configuration:

```yaml
persistent_apk_packages:
  - python3
  - py3-pip
  - git
  - vim

persistent_pip_packages:
  - homeassistant-cli
  - requests
```

**When users ask about auto-install**, guide them to:
1. Go to Settings → Add-ons → Claude Terminal
2. Click Configuration tab
3. Add packages to the lists above
4. Save and restart the add-on

### Troubleshooting

**Package not found after installation**:
```bash
# Check if it's in persistent storage
ls -la /data/packages/bin/

# Verify PATH includes persistent directory
echo $PATH | grep /data/packages

# If PATH is wrong, check if profile script exists
cat /etc/profile.d/persistent-packages.sh

# Source the profile manually if needed (temporary fix)
source /etc/profile.d/persistent-packages.sh

# If the profile script is missing, you're running an old version
# Update to v1.5.2+ which includes the PATH fix
```

**CRITICAL FIX (v1.5.2)**: Previous versions had a bug where persistent packages
were installed correctly but not in the PATH for ttyd bash sessions. This was
fixed by creating `/etc/profile.d/persistent-packages.sh` which is automatically
sourced by all bash sessions. If you installed packages before v1.5.2 and they
don't work, update to the latest version and restart the add-on.

**Python import errors**:
```bash
# Activate venv manually if needed
source /data/packages/python/venv/bin/activate

# Check installed packages
pip list
```

**Check disk usage**:
```bash
# See how much space packages use
du -sh /data/packages
```

### IMPORTANT REMINDERS

1. **NEVER use `apk add` for user-requested packages** - Always use `persist-install`
2. **ALWAYS verify after installation** - Run `--version` or test command
3. **EXPLAIN persistence** - Tell users packages will survive reboots
4. **BE PROACTIVE** - Install packages without being explicitly asked if user needs them
5. **CHECK FIRST** - Use `which` or `command -v` to see if already installed

### Example: Complete Installation Flow

```bash
# User asks: "I want to do data analysis with Python"

# Step 1: python3 and pip already ship in the image — nothing to do

# Step 2: Install data science packages into the persistent virtualenv
persist-install --python pandas numpy matplotlib jupyter

# Step 3: Verify installations
python3 --version
pip list | grep pandas

# Step 4: Inform user
echo "All set! You can now use Python for data analysis."
echo "Packages installed: pandas, numpy, matplotlib, jupyter"
echo "These will persist across reboots."
```

### Documentation Reference

For comprehensive details, see: `claude-terminal/PERSISTENT_PACKAGES.md`
