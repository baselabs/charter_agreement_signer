#!/usr/bin/env bash
# Dependency-currency gate: exits nonzero whenever `mix hex.outdated` shows
# RESOLVABLE drift ("Update possible"), so staying current is mechanical,
# not remembered. Resolver-rejected packages ("Update not possible") are
# printed with the requirement chain that holds them back — the deliberate
# pins stay visible instead of silently reading as current. A failed
# hex.pm lookup also exits nonzero: an unverified currency state must never
# pass the gate. Dev/test-only and transitive deps are covered (--all).
#
# hex.outdated itself exits nonzero BOTH on drift and on lookup failure, so
# the classifier is the rendered result table, not the command's exit code.
set -euo pipefail

cd "$(dirname "$0")/.."

out="$(mix hex.outdated --all 2>&1 || true)"

if ! printf '%s\n' "$out" | grep -q '^Dependency'; then
  echo "FAIL: mix hex.outdated rendered no result table — currency unverified."
  printf '%s\n' "$out"
  exit 1
fi

# The table pads rows with trailing spaces — anchor on optional trailing
# whitespace, not a hard line end (a hard "$" would silently miss every
# row: fail-open on drift, invisible pins).
drift="$(printf '%s\n' "$out" | grep -cE 'Update possible[[:space:]]*$' || true)"
rejected="$(printf '%s\n' "$out" | grep -E 'Update not possible[[:space:]]*$' || true)"

if [ -n "$rejected" ]; then
  echo "Resolver-rejected updates (deliberate pins — the requirement chain below holds each back):"
  while IFS= read -r row; do
    echo "  $row"
    mix hex.outdated "$(printf '%s' "$row" | awk '{print $1}')" 2>/dev/null | sed 's/^/    /' || true
  done <<<"$rejected"
fi

if [ "$drift" -ne 0 ]; then
  echo ""
  echo "FAIL: ${drift} resolvable update(s) available — run 'mix deps.update <pkg>'"
  echo "now, or record the deliberate pin with an inline reason in mix.exs."
  printf '%s\n' "$out"
  exit 1
fi

echo "Dependency currency: no resolvable drift."
