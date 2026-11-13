#!/usr/bin/env bash
#
# Backwards-compatible entry point for the toolbx image smoke test.
# The real tests live in tests/smoke-container.sh, which is flavour aware.

set -euo pipefail
exec bash "$(dirname -- "${BASH_SOURCE[0]}")/smoke-container.sh" toolbx
