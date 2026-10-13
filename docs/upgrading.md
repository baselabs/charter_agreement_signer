# Upgrading

Per-version notes, newest first. This page also states the versioning policy
that governs how the library evolves alongside the protocol package.

## Versioning policy

- **This library follows pre-1.0 SemVer §4 semantics**: anything may change
  at a 0.x minor bump; pin `~> 0.4.0` (the three-part form) and read this
  page at every minor.
- **The protocol dependency is double-pinned** to the tested `0.5.x` line
  (`{:charter_agreement_protocol, "~> 0.5.0"}` + a lock parity gate). CAP's
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

## Unreleased (CAP 0.5.0)

The protocol requirement is `~> 0.5.0`, locked to 0.5.0 in the library and
example. CAP 0.5.0 requires distinct parties. Re-verify views stored under
CAP 0.4.x: a revision repeating a `party_descriptor_digest` returns
`:revision_invalid`; a view whose two roles resolve to one descriptor
history, or which holds a history no revision names, returns `:chain_invalid`.
The signer's acceptance and termination producers report these as
`{:error, {:invalid_input, code}}` before signing.

CAP also applies a narrowed verification profile to the context it verifies
and reports profile rejections under their own codes. Calls under its full
profile are unaffected apart from the distinct-party rule. This signer uses
the full profile in its existing verify calls.

An absent or `nil` `:algorithm` selects Ed25519. Any other value outside
`"Ed25519"` and `"ML-DSA-65"`, including a non-string, now returns
`{:error, {:invalid_input, :algorithm_unsupported}}` before the key snapshot.
Callers that passed an atom or other non-string to select the default must
omit the option, use `nil`, or pass `"Ed25519"`.

Options must be an atom-keyed map or a keyword list with each key once. A
string key, a repeated key, or a list that is not a keyword list returns
`{:error, {:invalid_input, :invalid_type}}` (a non-keyword list used to raise).

The checks now run in a fixed order: options, then limits, then the
algorithm, then the key snapshot. A call with bad options or limits and a
bad key handle returns the options or limits error, where it used to return
`:invalid_key_handle`.

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

## 0.3.1 — 2026-09-15

Docs-and-tooling correction release; no behavioral `lib/` change (only
doc-comment corrections). The protocol dependency line moves within the
tested span: `charter_agreement_protocol` locked 0.3.0 → 0.3.1 (the
requirement stays `~> 0.3.0`; both locks moved in this release commit per
ADR-0002's discipline — CAP 0.3.1 is docs-and-tooling only, no
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

## 0.3.0 — 2026-09-14

Adopts CAP 0.3.0 (the deliberate line move `~> 0.2.1` → `~> 0.3.0`,
ADR-0002) and makes the signer algorithm-aware — the upgrade note the
release should have shipped:

- **The `:algorithm` option** (on `sign_descriptor/3` and the other entry
  points' opts) selects the emission pair: `"Ed25519"` (default, claims at
  `protocol_revision` 2) or `"ML-DSA-65"` (claims at `protocol_revision` 3).
  Claims must already carry the matching revision — CAP's producer enforces
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

## 0.2.1 — 2026-08-30

Documentation-only. The 0.2.0 migration rule (mint claims at
`"protocol_revision" => 2`) is now stated in every guide where a host or
counterparty looks for it — errors, consumer-integration, recipes (the
non-Elixir porting note), usage rules, and the README landing page. Nothing
to do if you already followed the 0.2.0 note.

## 0.2.0 — 2026-08-29

The protocol dependency line moves: `charter_agreement_protocol ~> 0.1.0` →
`~> 0.2.1` (ADR-0002's deliberate-bump discipline; both locks moved in the
release commit). CAP 0.2.0 shipped `protocol_revision` 2 and the RFC 9864
alg-name bundle; 0.2.1 is docs-only. One migration item:

- **Claims must mint at revision 2.** CAP's producers now emit exactly
  (`"Ed25519"`, `protocol_revision` 2) — the protected header's alg name is
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
- No signer API, error vocabulary, or telemetry change rides this release —
  the surface is byte-for-byte what 0.1.0 shipped.

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
