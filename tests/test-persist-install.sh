#!/usr/bin/env bash
set -euo pipefail

# Regression suite for the 2.2.0 persistent package manager.
#
# The mechanism it replaced copied a package's executables and .so files into
# /data and left everything else behind, so `persist-install python3` produced a
# python3 whose standard library was missing. What matters now is the bookkeeping:
# the world file must record exactly what was asked for, only when the install
# actually succeeded, and the startup replay must feed it back to apk.
#
# apk itself is stubbed here so the suite stays hermetic and fast.

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

fail() {
    echo "FAIL (persist-install): $*" >&2
    exit 1
}

persist_install="$repo_root/claude-terminal/scripts/persist-install"
export PERSIST_ROOT="$tmp_dir/packages"
export PERSIST_CACHE="$PERSIST_ROOT/apk-cache"
export PERSIST_WORLD="$PERSIST_ROOT/world"
export PERSIST_PYTHON="$PERSIST_ROOT/python"
export PERSIST_LEGACY_BIN="$PERSIST_ROOT/bin"
export APK_BIN="$tmp_dir/apk"
export APK_LOG="$tmp_dir/apk.log"

cat > "$APK_BIN" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$APK_LOG"
for arg in "$@"; do
    if [ -n "${APK_FAIL_ON:-}" ] && [ "$arg" = "$APK_FAIL_ON" ]; then
        # Mimic apk: a package that cannot be resolved fails the whole call.
        exit 1
    fi
done
exit 0
STUB
chmod +x "$APK_BIN"

world() { cat "$PERSIST_WORLD" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; }

# --- a successful install is recorded, and uses the persistent cache ---------
: > "$APK_LOG"
"$persist_install" git htop >/dev/null 2>&1 || fail "install of two packages failed"
[ "$(world)" = "git htop" ] || fail "world file should contain 'git htop', got '$(world)'"
grep -q -- "--cache-dir $PERSIST_CACHE" "$APK_LOG" || \
    fail "apk was not pointed at the persistent cache: $(cat "$APK_LOG")"

# --- installing again must not duplicate entries ----------------------------
"$persist_install" git >/dev/null 2>&1 || fail "reinstall failed"
[ "$(world)" = "git htop" ] || fail "world file gained a duplicate: '$(world)'"

# --- a FAILED install must not be recorded ----------------------------------
# Recording a package apk could not install would make every later startup
# replay fail on it.
: > "$APK_LOG"
APK_FAIL_ON="nosuchpkg" "$persist_install" nosuchpkg >/dev/null 2>&1 && \
    fail "install of a nonexistent package should report failure"
printf '%s\n' "$(world)" | grep -q nosuchpkg && \
    fail "a package that failed to install must not enter the world file"

# --- the startup replay feeds the whole world file back to apk --------------
: > "$APK_LOG"
"$persist_install" --restore >/dev/null 2>&1 || fail "--restore failed"
grep -qE 'add .*(git.*htop|htop.*git)' "$APK_LOG" || \
    fail "--restore did not replay the recorded packages: $(cat "$APK_LOG")"

# --- offline fallback: retried per package so one bad entry blocks nothing ---
: > "$APK_LOG"
APK_FAIL_ON="htop" "$persist_install" --restore >/dev/null 2>&1 || true
grep -qE '^add --no-progress --cache-dir [^ ]+ --no-network git$' "$APK_LOG" || \
    fail "offline fallback should retry each package individually: $(cat "$APK_LOG")"

# --- removal takes a package out of the replay ------------------------------
"$persist_install" --remove htop >/dev/null 2>&1 || fail "--remove failed"
[ "$(world)" = "git" ] || fail "--remove did not update the world file: '$(world)'"

# --- an empty world file is a clean no-op -----------------------------------
"$persist_install" --remove git >/dev/null 2>&1 || fail "--remove of the last package failed"
: > "$APK_LOG"
"$persist_install" --restore >/dev/null 2>&1 || fail "--restore on an empty world failed"
[ ! -s "$APK_LOG" ] || fail "an empty world file should not invoke apk: $(cat "$APK_LOG")"

# --- --ha-cli must never shadow the CLI shipped in the image ----------------
: > "$APK_LOG"
out=$("$persist_install" --ha-cli 2>&1)
printf '%s' "$out" | grep -qi "already ships" || \
    fail "--ha-cli should decline and point at the bundled CLI, got: $out"
[ ! -s "$APK_LOG" ] || fail "--ha-cli must not install anything"
[ ! -e "$PERSIST_LEGACY_BIN/ha" ] || fail "--ha-cli must not write a second ha binary"

# --- --list surfaces legacy leftovers so users can clean them up ------------
mkdir -p "$PERSIST_LEGACY_BIN"
printf '#!/bin/sh\n' > "$PERSIST_LEGACY_BIN/python3"
# Capture first: `grep -q` closes the pipe on its first match, which kills the
# writer with SIGPIPE and, under `set -o pipefail`, fails the whole pipeline.
listing=$("$persist_install" --list 2>/dev/null)
printf '%s' "$listing" | grep -qi "legacy" || \
    fail "--list should warn about leftover binaries from the old mechanism"
printf '%s' "$listing" | grep -q "python3" || \
    fail "--list should name the leftover binaries so they can be cleaned up"

echo "persist-install regression suite passed"
