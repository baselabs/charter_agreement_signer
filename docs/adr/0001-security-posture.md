# 1. The signer's security posture: wall, snapshot, guard, post-sign verify

Date: 2026-08-26

## Status

Accepted. Records decisions in force since the scaffold (2026-08-26, commits
`aff42eb`/`cef8a6c`); authored retroactively during the release-readiness
pass when the alignment audit ranked the ungoverned posture the repo's #1
ADR gap. One posture, four inseparable controls.

## Context

`charter_agreement_signer` is CAP's holder-side companion signer — the
`bounded_authority_report_adapter` (BARA) pattern applied to the Charter
Agreement Protocol. The protocol package is a pure, verifier-only producer
of deterministic RFC 7515 signing inputs; it refuses to sign and holds no
keys. The signer occupies the seat CAP's governance reserved for a companion
package: it takes a caller-supplied `{module, ref}` key handle and produces
signed compacts. The load-bearing question: which custody-boundary controls
live HERE, so that a host hand-rolling the glue cannot silently omit them?

## Decision

Four controls are this package's reason to exist, and they are enforced as
one posture:

1. **The dependency wall.** `lib/` depends only on `charter_agreement_protocol`,
   the standard library, and (per ADR-0003) `:telemetry`. Never a runtime,
   never a transport, never a sibling portfolio package. Architecture-tested
   and package-census-gated.
2. **kid-from-snapshot-only.** The protected header's `kid` and the signing
   public key resolve from ONE atomic `key_identity/1` callback call; the
   claims carry no key material and the API accepts no caller-supplied kid.
   A stateful handle cannot split kid from key across a rotation race, and a
   caller cannot name a kid the handle does not control.
3. **The wrong-key guard.** Every sign path verifies the raw signature
   against the snapshot public key BEFORE assembly. A `{pub_A, sig_B}`
   artifact is `:signing_failed`, never a silent false-success. The gate is
   proven red-capable with its own non-vacuity proof (the rogue signature is
   shown structurally assemblable through CAP — the guard is the only
   pre-assembly rejection point and the only `:signing_failed` producer).
4. **Post-sign verification.** Every path runs the matching CAP public
   verify function on the assembled artifact before returning it (per-party
   descriptor-chain selection for the set-aware paths — the semantic choice
   ADR-0004 records).

## Consequences

Removing or weakening any control is a protocol-level regression, not a
refactor. The rejected alternative — hosts hand-roll the glue from CAP's
producers directly — remains legal (CAP's spec documents the normative host
obligations; a direct-signing host is conformant), but duplicates exactly
the rotation/wrong-key boundary whose divergence this package centralizes.
