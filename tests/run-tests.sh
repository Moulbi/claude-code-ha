#!/usr/bin/env bash
set -euo pipefail

tests_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$tests_dir/.." && pwd)

"$tests_dir/test-release-metadata.sh"
"$tests_dir/test-production-run.sh"
"$tests_dir/test-startup-hardening.sh"

# The image service is the ingress entry point. Its suite needs node and the
# service's dependencies; skip loudly rather than pretend it ran.
service_dir="$repo_root/claude-terminal/image-service"
if ! command -v node >/dev/null 2>&1; then
    echo "SKIP: node not available, image service suite not run" >&2
elif [ ! -d "$service_dir/node_modules" ]; then
    echo "SKIP: run 'npm ci' in $service_dir to enable the image service suite" >&2
else
    node --test "$tests_dir/test-image-service.js"
fi

echo "All regression suites passed"
