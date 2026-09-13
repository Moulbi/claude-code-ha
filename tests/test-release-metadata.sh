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

# Supervisor privileges. `manager` and `admin` let this container install
# add-ons, and an add-on can run privileged on the host, so either turns code
# execution here into host takeover. Changing this must be deliberate.
role=$(sed -n 's/^hassio_role: *\([a-z]*\).*/\1/p' "$addon_dir/config.yaml")
case "$role" in
    homeassistant|default) ;;
    manager|admin)
        fail "hassio_role '$role' grants add-on management (host-takeover path); use homeassistant" ;;
    *)
        fail "unexpected or missing hassio_role: '$role'" ;;
esac

# The environment contract is written twice — once in init_environment and once
# in the /etc/profile.d script that every ttyd bash session sources — and it was
# also documented a third time in CLAUDE.md with values the code never set
# (CLAUDE_CREDENTIALS_DIRECTORY, HOME=/root, the pre-/data config path). Pin all
# three so a reader can trust the documentation.
for pair in \
    "HOME=/data/home" \
    "ANTHROPIC_CONFIG_DIR=/data/.config/claude" \
    "ANTHROPIC_HOME=/data" \
    "GH_CONFIG_DIR=/data/.config/gh"
do
    var=${pair%%=*}
    value=${pair#*=}

    grep -q "^export ${var}=\"${value}\"$" "$addon_dir/run.sh" || \
        fail "run.sh's profile script no longer exports ${var}=\"${value}\""

    grep -q "\`${var}=${value}\`" "$repo_root/CLAUDE.md" || \
        fail "CLAUDE.md does not document ${var}=${value}; docs and code have drifted"
done

grep -q 'CLAUDE_CREDENTIALS_DIRECTORY' "$addon_dir/run.sh" && \
    fail "run.sh now sets CLAUDE_CREDENTIALS_DIRECTORY; update CLAUDE.md, which says it does not exist"

# /config/claude-config is a legacy migration source, never the live location.
grep -q 'claude_config_dir="/data/.config/claude"' "$addon_dir/run.sh" || \
    fail "the live Claude config directory moved; CLAUDE.md and the migration notes need updating"

echo "Release metadata suite passed (version $config_version)"
