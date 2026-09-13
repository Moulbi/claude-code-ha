#!/usr/bin/env bash
set -euo pipefail

# Regression suite for the startup hardening in run.sh:
#   - install_tools must not touch the network when the image already has the tools
#   - migrate_legacy_auth_files must run exactly once, and never clobber live
#     credentials with a stale file left behind in /config
#   - the image service readiness check must fail when the service is not up
#     (it used to report success unconditionally)

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

fail() {
    echo "FAIL (startup hardening): $*" >&2
    exit 1
}

bashio::log.info() { :; }
bashio::log.warning() { :; }
bashio::log.error() { :; }
bashio::config() { printf '%s\n' "${2:-}"; }

# shellcheck disable=SC2034  # read by the sourced run.sh
CLAUDE_RUN_SH_SKIP_MAIN=true
# shellcheck source=/dev/null
source "$repo_root/claude-terminal/run.sh"

real_path="$PATH"

# --------------------------------------------------------------------------
# install_tools
# --------------------------------------------------------------------------
fake_bin="$tmp_dir/bin"
mkdir -p "$fake_bin"
apk_log="$tmp_dir/apk.log"

cat > "$fake_bin/apk" <<APK
#!/bin/sh
printf '%s\n' "\$*" >> "$apk_log"
APK
chmod +x "$fake_bin/apk"

for tool in ttyd tmux jq curl; do
    printf '#!/bin/sh\n' > "$fake_bin/$tool"
    chmod +x "$fake_bin/$tool"
done

restricted_path="$fake_bin:/usr/bin:/bin"

: > "$apk_log"
PATH="$restricted_path"
install_tools || { PATH="$real_path"; fail "install_tools failed while every tool was present"; }
PATH="$real_path"
[ ! -s "$apk_log" ] || \
    fail "install_tools hit apk even though every tool was already in the image"

# Only the genuinely missing tool may be installed.
rm "$fake_bin/ttyd"
if PATH="$restricted_path" command -v ttyd >/dev/null 2>&1; then
    echo "SKIP: a system ttyd shadows the stub, cannot test the missing-tool path" >&2
else
    : > "$apk_log"
    PATH="$restricted_path"
    install_tools || { PATH="$real_path"; fail "install_tools failed while ttyd was missing"; }
    PATH="$real_path"
    grep -qx -- "add --no-cache ttyd" "$apk_log" || \
        fail "install_tools should install only the missing tool, got: $(cat "$apk_log")"
fi

# --------------------------------------------------------------------------
# migrate_legacy_auth_files
# --------------------------------------------------------------------------
legacy_dir="$tmp_dir/legacy"
target_dir="$tmp_dir/target"
mkdir -p "$legacy_dir" "$target_dir"
printf 'stale-token\n' > "$legacy_dir/.credentials.json"

AUTH_MIGRATION_MARKER="$tmp_dir/migrated"
AUTH_LEGACY_LOCATIONS="$legacy_dir"
export AUTH_MIGRATION_MARKER AUTH_LEGACY_LOCATIONS

migrate_legacy_auth_files "$target_dir"
[ -f "$target_dir/.credentials.json" ] || fail "first run should migrate legacy credentials"
[ -f "$AUTH_MIGRATION_MARKER" ] || fail "first run should record a migration marker"

# Dotfiles must actually be migrated: the credential file is a dotfile, and a
# plain "$dir"/* glob skips it.
[ "$(cat "$target_dir/.credentials.json")" = "stale-token" ] || \
    fail "migration skipped a hidden file, which is the only kind that matters here"

# Simulate the user logging in again: /data now holds fresher credentials than
# the stale copy still sitting in the legacy location.
printf 'fresh-token\n' > "$target_dir/.credentials.json"
migrate_legacy_auth_files "$target_dir"
[ "$(cat "$target_dir/.credentials.json")" = "fresh-token" ] || \
    fail "re-running migration clobbered live credentials with the stale legacy copy"

# Defence in depth: even with the marker gone, migration must never overwrite a
# file that already exists in the target.
rm -f "$AUTH_MIGRATION_MARKER"
migrate_legacy_auth_files "$target_dir"
[ "$(cat "$target_dir/.credentials.json")" = "fresh-token" ] || \
    fail "migration overwrote an existing credential file; it must only fill gaps"

# ...but it must still migrate a file that is genuinely absent.
rm -f "$AUTH_MIGRATION_MARKER" "$target_dir/.credentials.json"
migrate_legacy_auth_files "$target_dir"
[ "$(cat "$target_dir/.credentials.json")" = "stale-token" ] || \
    fail "migration should restore a credential file that is missing from the target"

# A missing legacy directory must still be a clean, marked run.
rm -f "$AUTH_MIGRATION_MARKER"
AUTH_LEGACY_LOCATIONS="$tmp_dir/does-not-exist"
migrate_legacy_auth_files "$target_dir"
[ -f "$AUTH_MIGRATION_MARKER" ] || fail "a no-op migration should still be marked complete"

unset AUTH_MIGRATION_MARKER AUTH_LEGACY_LOCATIONS

# --------------------------------------------------------------------------
# wait_for_image_service
# --------------------------------------------------------------------------
# Nothing is listening: readiness must fail instead of reporting success.
dead_port=1
while : ; do
    dead_port=$(( (RANDOM % 20000) + 40000 ))
    (exec 3<>"/dev/tcp/127.0.0.1/$dead_port") 2>/dev/null || break
done

# shellcheck disable=SC2034  # read by wait_for_image_service in run.sh
IMAGE_SERVICE_HEALTH_ATTEMPTS=1
if wait_for_image_service "$dead_port" ""; then
    fail "readiness check passed while nothing was listening"
fi

# A supervisor that has already died must short-circuit, not wait out the loop.
sleep 0 & dead_pid=$!
wait "$dead_pid" 2>/dev/null || true
# shellcheck disable=SC2034  # read by wait_for_image_service in run.sh
IMAGE_SERVICE_HEALTH_ATTEMPTS=30
start=$(date +%s)
if wait_for_image_service "$dead_port" "$dead_pid"; then
    fail "readiness check passed with a dead supervisor"
fi
elapsed=$(( $(date +%s) - start ))
[ "$elapsed" -lt 5 ] || \
    fail "readiness check should short-circuit on a dead supervisor, took ${elapsed}s"

# A live service must be detected. The stub serves a file named "health" so
# that GET /health answers 200, which is what the readiness check requires.
mkdir -p "$tmp_dir/www"
: > "$tmp_dir/www/health"
python3 -m http.server "$dead_port" --bind 127.0.0.1 --directory "$tmp_dir/www" >/dev/null 2>&1 &
http_pid=$!
trap 'rm -rf "$tmp_dir"; kill "$http_pid" 2>/dev/null || true' EXIT
# shellcheck disable=SC2034  # read by wait_for_image_service in run.sh
IMAGE_SERVICE_HEALTH_ATTEMPTS=30
wait_for_image_service "$dead_port" "$http_pid" || \
    fail "readiness check did not detect a service that answers"

# --------------------------------------------------------------------------
# log_image_service_output
# --------------------------------------------------------------------------
captured="$tmp_dir/captured.log"
bashio::log.info() { printf '%s\n' "$*" >> "$captured"; }
printf 'line one\nline two\n' | log_image_service_output
bashio::log.info() { :; }
printf '[Image Service] line one\n[Image Service] line two\n' > "$tmp_dir/expected.log"
cmp -s "$tmp_dir/expected.log" "$captured" || \
    fail "image service output was not forwarded line by line"

echo "Startup hardening regression suite passed"
