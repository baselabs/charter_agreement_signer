# 3. The telemetry surface: translated axis, sanctioned clock seam

Date: 2026-08-26

## Status

Accepted. Deliberately REVERSES the scaffold's recorded "no telemetry surface
in v0.1.0" scope decision (mix.exs comment at commit `aff42eb`) — the
release pass chose family-surface uniformity over the smaller dep set.

## Context

BARA ships a closed, value-free telemetry surface for its signing entry
points. Two questions arose for this package's first release: whether to
ship telemetry at all (operator decision: yes), and — the load-bearing one —
what the class axis should be. BARA's axis classes are the image of BARA's
error vocabulary (`:invalid_report`, `{:producer_error, :invalid}`, ...);
this signer's vocabulary is different (`{:refused, :signing_refused}`,
`:verification_failed`, ...). Separately, the signer's purity architecture
test banned every `System.*` call in `lib/`, and a duration measurement
needs `System.monotonic_time/0` — a clause STRICTER than BARA's wall (BARA
has no purity clause).

## Decision

1. **The class axis is TRANSLATED, never ported.** It is the exact image of
   this signer's public error vocabulary: `:ok`, `:invalid_input`,
   `:invalid_key_handle`, `:signing_failed`, `:verification_failed`,
   `:refused`. An exact structural port of BARA's classify would fold
   refusal storms and post-sign verify failures into `:signing_failed` —
   sending operators down the custody-misconfiguration path for conditions
   that are not custody failures — while a docs-table parity test stays
   green (parity proves docs == module, never module == truth). The proof
   that the axis is right is the failure drivers through the REAL entry
   points, which the test suite ships.
2. **Value-free by construction.** Metadata carries exactly two closed
   atoms; the emitters are shape-validated and refuse anything outside the
   closed shapes. Aggregate-only duration (never per-custody-operation
   timing — that would leak which HSM operation was slow or failing).
3. **The clock seam is sanctioned and scoped.** `System.monotonic_time/0`
   is admitted ONLY in `lib/charter_agreement_signer/telemetry.ex`, via a
   negative-lookahead clause in the purity test; every other `System.*`
   shape stays banned everywhere, including that module. The core signer
   stays clock-free absolutely, and the monotonic read provably cannot reach
   any return value (`sign_span/2` returns the wrapped result unchanged).
4. **`:telemetry` joins the wall** as the one sanctioned runtime seam beyond
   CAP (zero transitive deps, no custody, no transport) — the census,
   dependency test, and package allowlist grew in the same commit.

## Consequences

The scope note on the no-install-task absence (no Igniter installer in
0.1.0) rides here: adding one is additive tooling, gated on the same
same-commit allowlist discipline. The axis may only grow additively; a
rename is a breaking change per `docs/upgrading.md`.
