# Upgrading

Per-version notes, newest first. This page also states the versioning policy
that governs how the library evolves alongside the protocol package.

## Versioning policy

- **This library follows pre-1.0 SemVer §4 semantics**: anything may change
  at a 0.x minor bump; pin `~> 0.5.0` (the three-part form) and read this
  page at every minor.
- **The protocol dependency is deliberately selected**: this library requires
  CAP `~> 0.6.0` from Hex. Both projects lock CAP 0.6.0, and the dependency
  and lock-parity tests enforce the requirement and resolved version.
- **The error vocabulary is closed and additive-only** within the 0.x line:
  new `{:invalid_input, code}` codes may appear as CAP's gated vocabulary
  grows; a removal or rename of any error shape is a breaking change that
  bumps the minor and is called out here by name.
- **Telemetry axes are closed and additive-only**: new objects or classes
  appear in `docs/telemetry.md`'s tables (tied bidirectionally by the test
  suite) and in this page's notes.

## 0.4.1 to 0.5.0 (CAP 0.6.0)

Signer 0.5.0 requires CAP `~> 0.6.0` from Hex, locked to 0.6.0 in the
library and example. All signing paths use CAP's `prepare_signing/5` and
`finish_signing/2`.

Calls that used to sign and then return `:verification_failed` now reject
before custody. Update error matches:

- Snapshot kid or bytes absent from the holder's active descriptor keys:
  `{:refused, :signing_key_mismatch}`.
- Invalid public key for the selected algorithm: `:invalid_key_handle`.
- Successor predecessor errors use these codes:
  `{:invalid_input, :descriptor_chain_invalid}` for no predecessor (`nil`),
  verified facts that do not link to the successor, an unverifiable nonempty
  binary lineage, or a retained digest inconsistent with that lineage;
  `{:invalid_input, :invalid_type}` for a non-facts value or malformed retained
  field types, including empty, non-list, improper or nonbinary lineage;
  `{:invalid_input, :algorithm_outside_profile}` or
  `{:invalid_input, :revision_outside_profile}` when the profile excludes
  an algorithm or revision in the predecessor history;
  `:algorithm_unsupported_on_substrate` when the runtime
  cannot verify that history.
- An unheld descriptor named by acceptance or termination claims:
  `{:invalid_input, :acceptance_claims_mismatch}` or
  `{:invalid_input, :termination_claims_mismatch}`.
- Final compact too large: `{:invalid_input, :signing_input_invalid}`;
  retained context too large: `{:invalid_input, :limit_exceeded}`.
- Receipt claims against their context: `{:invalid_input,
  :receipt_claims_mismatch}`. Malformed context types use `:invalid_type`;
  malformed retained fields use the same `:invalid_type` code.
- Unsupported runtime for the artifact or any context artifact:
  top-level `:algorithm_unsupported_on_substrate`.

CAP fully decodes Ed25519 snapshot keys before custody. It rejects
non-canonical y values, bytes with no curve point, zero x with the sign bit
set (the two negative-zero encodings) and small-order points with
`:invalid_key_handle`. Valid mixed-order points remain admitted and can sign.

Malformed fields inside caller-built context consistently return
`{:invalid_input, :invalid_type}` on every signing surface. Update matches
that expected `:receipt_invalid` or `:descriptor_chain_invalid` for these
field-type errors. Incomplete limits structs and malformed profile fields,
including improper algorithm lists, return `{:invalid_input, :invalid_limits}`
or `{:invalid_input, :invalid_profile}` without raising. CAP owns these
validation rules.

`:verification_failed` now means CAP finish rejected what preparation
approved after the custody guard passed. The raw wrong-key guard still
returns `:signing_failed`.

Add `:profile` to calls that need narrowed verification. It is a
`CAP.Capability.Profile.t()`, defaulting to `Profile.full()`. Malformed
profiles return `{:invalid_input, :invalid_profile}`. For acceptance and termination, both axes cover the revision, the signing
party's own descriptor chain and the new artifact. CAP checks the rest of
the set under the full profile, so a counterparty descriptor outside the
caller's profile can still sign. The runtime must still verify every
algorithm in the set. A receipt's profile covers the whole
retained set; a descriptor's covers its predecessor history and new
artifact. A profile admitting only EdDSA, only
ML-DSA-44/87, or revisions `{1, 1}` refuses every emission this signer can
make. The same profile code covers an excluded artifact or context revision.

CAP owns all set-to-context derivation. Limits now apply to every byte of
the set read, including the counterparty's artifacts, and also to building
and assembling the final compact. Raised limits work through both steps.
The earlier signer decoded and selected retained revisions and descriptor
chains itself under caller limits after a producer checked the set under
default limits. That disagreement is removed. Supply only the documented
context; CAP derives the signing party's chain from the verified set.

This release also absorbs CAP 0.4 to 0.5 changes. CAP requires distinct
parties: a revision repeating a descriptor digest fails with
`:revision_invalid`; roles resolving to one history, or a held history no
revision names, fail with `:chain_invalid`. Re-verify views stored under
CAP 0.4.x. Profile exclusions within the scope above use `:algorithm_outside_profile`
or `:revision_outside_profile`. The pinned
TypeScript verifier source is 0.7.0. The pinned TypeScript signer 0.3.0
also locks verifier 0.7.0 and executes all 121 shared request rows, including
callback counts, refusal codes, exact Ed25519 compacts and verified
ML-DSA-65 successes.

An absent or `nil` `:algorithm` selects Ed25519. Any other value outside
`"Ed25519"` and `"ML-DSA-65"`, including a non-string, now returns
`{:error, {:invalid_input, :algorithm_unsupported}}` before the key snapshot.
Callers that passed an atom or other non-string to select the default must
omit the option, use `nil`, or pass `"Ed25519"`.

Options must be a map or a keyword list whose keys are the function's option
atoms, each at most once: `:algorithm`, `:limits` and `:profile`, plus
`:predecessor` for `sign_descriptor/3`. A misspelled or unknown key, a
string key, a struct, a repeated key, or a list that is not a keyword list returns
`{:error, {:invalid_input, :invalid_type}}` (a non-keyword list used to
raise, and a misspelled `:algorithm` key used to sign with Ed25519).

The checks now run in a fixed order: options, then limits, then the
profile, then algorithm, then the key snapshot. A call with bad options or
limits and a bad key handle returns the options or limits error, where it
used to return `:invalid_key_handle`.

A short snapshot key plus bad claims now returns `{:invalid_input,
:signing_input_invalid}` instead of `:invalid_key_handle`. The snapshot
checks binary shape only; CAP builds claims before checking the selected
algorithm's key length. Update matches that relied on key length taking
precedence over bad claims.

Telemetry's closed class list adds `:unsupported_substrate` for the
`:algorithm_unsupported_on_substrate` span outcome. A
`{:refused, :signing_key_mismatch}` outcome uses `:refused`. The telemetry
guide lists all seven classes; the public signing functions retain the
return shapes in [errors.md](errors.md).

The in-tree TypeScript copy is removed. Local CI now fetches pinned public
sources, builds them and runs the pinned signer's own suite using its npm
lockfile. See the README for cached materialization and stamp checks.

## 0.4.1 - 2026-10-04

Documentation records macOS and Linux as the developer platforms. Windows
developers use WSL2 and the Linux commands. CI runs on Linux only.

## 0.4.0 - 2026-09-24

The CAP requirement moved to `~> 0.4.0`, locked to 0.4.1 in both projects.
CAP added verification capability profiles, substrate reports and facts
fields. The signer continued using the same producers and public function
shapes; there was no signing behavior change.

## 0.3.5 - 2026-09-24

Documentation describes CAP 0.4.0's consumer surfaces. The library still
required `~> 0.3.0` and locked CAP 0.3.1; no signing behavior changed.

## 0.3.4 - 2026-09-17

The CI alias requires `MIX_ENV=test` at entry instead of re-executing each
step through a POSIX `env` command. The dependency-currency script became
Elixir, and package checks gained portable command and cleanup handling.
The developer-platform instructions from this release are superseded by
0.4.1.

## 0.3.3 - 2026-09-16

The supported Elixir range widened to `~> 1.19`, covering tested 1.19.x and
1.20.x releases on OTP 28/29. Elixir 1.19.x uses the OTP 28 lane. The
library, example and CI matrix moved together.

## 0.3.2 - 2026-09-16

The library and example began checking their Elixir and OTP ranges before
compilation. The dependency-currency gate became part of the battery, and
the coverage floor rose to 100.0%. Unreachable defensive branches were
removed; reachable signing results stayed unchanged.

## 0.3.1 - 2026-09-15

Docs-and-tooling correction release; no behavioral `lib/` change (only
doc-comment corrections). The protocol dependency line moves within the
tested span: `charter_agreement_protocol` locked 0.3.0 → 0.3.1 (the
requirement stays `~> 0.3.0`; both locks moved in this release commit per
ADR-0002's discipline; CAP 0.3.1 is docs-and-tooling only, no
verdict-flipping change). Also riding this release:

- CI substrate correction: the gate, example, and supply-chain jobs run on
  ubuntu-26.04 (the ML-DSA-65 mint test needs a linked OpenSSL ≥ 3.5;
  ubuntu-latest is 24.04 / OpenSSL 3.0.x today), and the supply-chain build
  gains the Node setup and TypeScript build steps its `mix ci` battery needs.
  The declared floors now state the crypto-library axis: OTP ≥ 28.1 with a
  linked OpenSSL ≥ 3.5 for the ML-DSA-65 emission pair (README, AGENTS).
- Documentation re-trued to the algorithm-aware 0.3.0 surface: install pins
  (`~> 0.3.0`), the emission-pair rule (default `Ed25519`/2, opt-in
  `ML-DSA-65`/3) in every guide that stated the 0.2-era single-pair rule,
  signature-length prose keyed to the registry row instead of a universal
  64 bytes, and the key-identity snapshot's registry key lengths.

## 0.3.0 - 2026-09-14

Adopts CAP 0.3.0 (the deliberate line move `~> 0.2.1` → `~> 0.3.0`,
ADR-0002) and makes the signer algorithm-aware. The upgrade note the
release should have shipped:

- **The `:algorithm` option** (on `sign_descriptor/3` and the other entry
  points' opts) selects the emission pair: `"Ed25519"` (default, claims at
  `protocol_revision` 2) or `"ML-DSA-65"` (claims at `protocol_revision` 3).
  Claims must already carry the matching revision; CAP's producer enforces
  the pair. An unsupported string name is `{:error, {:invalid_input,
  :algorithm_unsupported}}` (a non-string selection falls to the Ed25519
default, where CAP's pair rule then decides).
- **The handle-signature length and the wrong-key guard follow the registry
  row** (64 bytes for `Ed25519`, 3309 for `ML-DSA-65`); the key-identity
  snapshot accepts any registry key length (32 / 1312 / 1952 / 2592).
- Selecting `ML-DSA-65` needs an OTP runtime linked against OpenSSL ≥ 3.5.
- Retained revision-1/2 artifacts keep verifying (cross-revision
  composition); no migration for existing hosts beyond the deliberate
  dependency bump.

## 0.2.1 - 2026-08-30

Documentation-only. The 0.2.0 migration rule (mint claims at
`"protocol_revision" => 2`) is now stated in every guide where a host or
counterparty looks for it: errors, consumer-integration, recipes (the
non-Elixir porting note), usage rules, and the README landing page. Nothing
to do if you already followed the 0.2.0 note.

## 0.2.0 - 2026-08-29

The protocol dependency line moves: `charter_agreement_protocol ~> 0.1.0` →
`~> 0.2.1` (ADR-0002's deliberate-bump discipline; both locks moved in the
release commit). CAP 0.2.0 shipped `protocol_revision` 2 and the RFC 9864
alg-name bundle; 0.2.1 is docs-only. One migration item:

- **Claims must mint at revision 2.** CAP's producers now emit exactly
  (`"Ed25519"`, `protocol_revision` 2); the protected header's alg name is
  the fully-specified RFC 9864 spelling, and the binding rule runs at the
  producer's provisional decode. Claims carrying `"protocol_revision" => 1`
  (or omitting it) are refused as `{:invalid_input, :signing_input_invalid}`
  BEFORE the key is used. Set `"protocol_revision" => 2` on every claims map
  you hand to `sign_descriptor/3`, `sign_acceptance/4`,
  `sign_termination/4`, or `sign_receipt/4`.
- **Retained revision-1 artifacts need nothing.** Cross-revision composition
  is the protocol's supported mixed deployment: a revision-2 signature
  anchored to revision-1 views verifies (legacy `("EdDSA", 1)` artifacts
  verify forever; the signer's own suite proves the mixed path).
- No signer API, error vocabulary, or telemetry change rides this release.
  the surface is byte-for-byte what 0.1.0 shipped.

## 0.1.0 - 2026-08-26

First public release. There is no upgrade path to document yet; nothing
predates it. What shipped:

- The four signing entry points with the shared tail: atomic
  `key_identity/1` snapshot (header `kid` sourced only from it), CAP
  producers with the R1–R3 honest-signer refusals before the key is used,
  the wrong-key guard, CAP assembly, and post-sign verification through
  CAP's own public verify functions.
- The closed five-shape error vocabulary.
- The value-free telemetry surface (`[:charter_agreement_signer, :sign,
  :start|:stop]`; no handler is attached by default; see
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
