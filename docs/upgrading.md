# Upgrading

Per-version notes, newest first. This library has exactly one released
version so far — this page also states the versioning policy that governs
how it evolves alongside the protocol package.

## Versioning policy

- **This library follows pre-1.0 SemVer §4 semantics**: anything may change
  at a 0.x minor bump; pin `~> 0.1.0` (the three-part form) and read this
  page at every minor.
- **The protocol dependency is double-pinned** to the tested `0.1.x` line
  (`{:charter_agreement_protocol, "~> 0.1.0"}` + a lock parity gate). CAP's
  package semver carries no compatibility promise (its governance: the
  `protocol_revision` claim is the sole wire identity), so a CAP bump here is
  always a deliberate, reviewed release of THIS library — never something a
  bare `mix deps.update` can drift into.
- **The error vocabulary is closed and additive-only** within the 0.x line:
  new `{:invalid_input, code}` codes may appear as CAP's gated vocabulary
  grows; a removal or rename of any error shape is a breaking change that
  bumps the minor and is called out here by name.
- **Telemetry axes are closed and additive-only**: new objects or classes
  appear in `docs/telemetry.md`'s tables (tied bidirectionally by the test
  suite) and in this page's notes.

## 0.1.0 — 2026-08-26

First public release. There is no upgrade path to document yet — nothing
predates it. What shipped:

- The four signing entry points with the shared tail: atomic
  `key_identity/1` snapshot (header `kid` sourced only from it), CAP
  producers with the R1–R3 honest-signer refusals before the key is used,
  the wrong-key guard, CAP assembly, and post-sign verification through
  CAP's own public verify functions.
- The closed five-shape error vocabulary.
- The value-free telemetry surface (`[:charter_agreement_signer, :sign,
  :start|:stop]`; no handler is attached by default — see
  [telemetry.md](telemetry.md)).
- Runtime dependencies: `charter_agreement_protocol ~> 0.1.0` and
  `:telemetry ~> 1.4` (zero transitive deps).
- The full guide set, the runnable `examples/charter_lifecycle` reference
  app, and the supply-chain workflow (SLSA provenance + CycloneDX SBOM on
  every `v*` tag).

## The 1.0 stability contract

Deferred until the release sees real consumer use (the family precedent:
BARA's 1.0 deferral). Until then, pre-1.0 semantics above govern. When 1.0
lands, this section becomes the operative contract: the public function
shapes, the error vocabulary, and the telemetry axes freeze; only the
forward-compatible growth paths above continue.
