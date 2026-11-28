#!/usr/bin/env bash
set -euo pipefail

# Inputs: mix.exs, mix.lock and this script; the generator version is locked.
# Dropping --exclude-system-dependencies means adding .tool-versions to the input diff.
# The generator is a runtime: false dependency, so Mix would prune the OTP
# applications it starts (hex_core needs ssh). Compile without pruning first,
# in the same Mix run.
mix do compile --no-prune-code-paths + sbom.cyclonedx --only prod --exclude-system-dependencies \
  --classification library --schema 1.6 --format json \
  --output release-assets/release.cdx.json --force
