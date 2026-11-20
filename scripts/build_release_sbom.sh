#!/usr/bin/env bash
set -euo pipefail

# Inputs: mix.exs, mix.lock and this script; the generator version is locked.
# Dropping --exclude-system-dependencies means adding .tool-versions to the input diff.
mix sbom.cyclonedx --only prod --exclude-system-dependencies \
  --classification library --schema 1.6 --format json \
  --output release-assets/release.cdx.json --force
