#!/usr/bin/env bash
set -euo pipefail

# Enforces the release rule stated in CLAUDE.md: every change ships with a
# version bump and a matching changelog entry. Three files have to agree, and
# nothing checked this before, so they drifted silently.

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
addon_dir="$repo_root/claude-terminal"

fail() {
    echo "FAIL (release metadata): $*" >&2
    exit 1
}

config_version=$(sed -n 's/^version: *"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$addon_dir/config.yaml")
[ -n "$config_version" ] || fail "could not read version from config.yaml"

case "$config_version" in
    [0-9]*.[0-9]*.[0-9]*) ;;
    *) fail "config.yaml version '$config_version' is not semver" ;;
esac

label_version=$(sed -n 's/^ *org.opencontainers.image.version: *"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$addon_dir/build.yaml")
[ "$label_version" = "$config_version" ] || \
    fail "build.yaml image version '$label_version' does not match config.yaml '$config_version'"

grep -qx "## $config_version" "$addon_dir/CHANGELOG.md" || \
    fail "CHANGELOG.md has no '## $config_version' section for the current version"

# The newest changelog section must be the current version, so a bump cannot
# land with its notes buried under an older release.
newest=$(grep -m1 '^## ' "$addon_dir/CHANGELOG.md" | sed 's/^## //')
[ "$newest" = "$config_version" ] || \
    fail "newest CHANGELOG entry is '$newest' but config.yaml is at '$config_version'"

# Every architecture the add-on claims must have a base image to build from.
while IFS= read -r arch; do
    grep -q "^  ${arch}: " "$addon_dir/build.yaml" || \
        fail "arch '$arch' is declared in config.yaml but has no build_from in build.yaml"
done < <(sed -n '/^arch:/,/^[a-z]/{s/^  - //p;}' "$addon_dir/config.yaml")

# Publishing a host port would bypass Home Assistant ingress authentication and
# expose ttyd's unauthenticated root shell on the LAN. Keep that closed.
if grep -qE '^\s+[0-9]+/tcp: *[0-9]+' "$addon_dir/config.yaml"; then
    fail "config.yaml publishes a host port; ttyd runs --writable with no auth, use ingress only"
fi

grep -q 'interface 127.0.0.1' "$addon_dir/run.sh" || \
    fail "ttyd must bind 127.0.0.1 only; it runs --writable with no credentials"

echo "Release metadata suite passed (version $config_version)"
