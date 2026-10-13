# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Breaking

- CAP 0.6.0 checks every request before custody. Snapshot key mismatches
  now return `{:refused, :signing_key_mismatch}`; invalid keys for the
  selected algorithm return `:invalid_key_handle`. Missing or wrong
  predecessor facts return `{:invalid_input, :descriptor_chain_invalid}`.
  Unheld party descriptors return `:acceptance_claims_mismatch` or
  `:termination_claims_mismatch` in the invalid-input shape. These cases
  previously signed and returned a later failure.
- Narrow limits, receipt claims against context and malformed context now
  fail before signing under CAP's typed preparation codes. Final compact
  size uses `:signing_input_invalid`; context size uses `:limit_exceeded`.
  Unsupported artifact or context algorithms return the top-level
  `:algorithm_unsupported_on_substrate`.
- All four functions accept `:profile`. Malformed profiles return
  `{:invalid_input, :invalid_profile}`; excluded algorithms or revisions
  use `:algorithm_outside_profile` or `:revision_outside_profile`.
- For acceptance and termination, the caller's profile covers the selected
  revision, signing party's descriptor history and new artifact. CAP checks
  the rest of the set under the full profile, so a counterparty descriptor
  outside the caller's profile can still sign. The runtime must still
  verify every algorithm in the set. A receipt's profile covers
  the whole retained set; a descriptor's covers its predecessor history
  and new artifact.
- CAP fully decodes Ed25519 snapshot keys. Non-canonical y values, bytes
  that do not encode a curve point, zero x with the sign bit set and
  small-order points return `:invalid_key_handle` before custody.
  Mixed-order points remain admitted and can sign.
- Malformed fields inside caller-built context now return
  `{:invalid_input, :invalid_type}` on every signing surface, replacing
  context-specific errors or exceptions. Incomplete limits structs and
  improper profile lists return `:invalid_limits` and `:invalid_profile`
  in the invalid-input shape without raising.
- CAP owns context derivation. Caller limits cover the whole set read and
  final compact, replacing the signer's default-limit producer followed
  by its own context decoding under caller limits. Raised limits now work.
  `:verification_failed` means only CAP finish rejected what preparation
  approved after the custody guard passed.
- Options must be a map or a keyword list whose keys are the function's
  option atoms, each at most once (`:algorithm`, `:limits`, `:profile`, plus
  `:predecessor` for `sign_descriptor/3`). Anything else returns
  `{:error, {:invalid_input, :invalid_type}}`: a misspelled or unknown key,
  a string key, a struct, a repeated key, or a list that is not a keyword
  list. These used to raise, be ignored, or let the last value win, so a
  misspelled `:algorithm` key signed with Ed25519. Migration: pass only the
  documented keys.
- An absent or `nil` `:algorithm` selects Ed25519. Every other value
  outside `"Ed25519"` and `"ML-DSA-65"`, including non-strings, returns
  `{:error, {:invalid_input, :algorithm_unsupported}}` before the key
  snapshot. Migration: omit the option, pass `nil`, or pass `"Ed25519"`.
- Checks run in a fixed order: options, limits, profile, algorithm, then the key
  snapshot. A call with bad options or limits and a bad key handle now
  returns the options or limits error instead of `:invalid_key_handle`.
  A short snapshot key plus bad claims now returns
  `{:invalid_input, :signing_input_invalid}` instead of `:invalid_key_handle`:
  snapshot shape is checked first, then CAP builds claims before checking
  the selected algorithm's key length. Update error matches for that pair.

### Added

- A shared JSON signer request table with real base64url seeds, all four
  kinds and both emission algorithms, callback counts, refusal codes,
  exact Ed25519 compacts and verified ML-DSA results.
- Real signing and telemetry refusal tests on the capability-limited
  substrate, including the bare-revision receipt and context algorithms.
- A Linux capability-limited CI job on Ubuntu 24.04 and OTP 28.5.0.3.
  It first asserts that ML-DSA is unverifiable and the classical rows are
  verifiable, then runs the existing suite with the ML-DSA mint test
  excluded.
- Public commit pins for the TypeScript signer and verifier, with source
  materialization, cached mode, public `main` reachability, forward-only
  movement, archive blob checks and current-stamp checks.
- A Linux CI job and `mix ci` steps that build both pinned sources and run
  the TypeScript signer's own test suite with its locked npm dependencies.
  The suite must run at least the pin's `minimum_tests` with none failing,
  and a descriptor signed by the pinned TypeScript signer must verify under
  CAP. The newest pin change on the first-parent history must move forward,
  so a committed backward pin fails in its own CI run and a later forward
  commit repairs it; the check needs a full clone. README and `mix ci`
  descriptions state exactly which checks run.
- The telemetry class `:unsupported_substrate` for
  `:algorithm_unsupported_on_substrate`. A `:signing_key_mismatch` refusal
  uses `:refused`. ADR-0003, ADR-0005 and the telemetry guide now list all
  seven closed classes.

### Fixed

- Run the coverage step of `mix ci` in a fresh Mix process. Its earlier
  `test` step caused Mix to skip the second test invocation, so the listed
  coverage floor did not run locally.
- Refresh upgrade notes through CAP 0.5.0 and signer 0.4.1, record the
  CAP pin changes in ADR-0002, repair the README's cut sentence, complete
  the changelog release links, and correct stale pin and toolchain text.

### Changed

- SECURITY.md sends reports through GitHub private vulnerability reporting, now
  enabled for this repository.
- Remove the in-tree TypeScript copy and its old artifact check. The
  supply-chain battery uses the same pinned source steps as local CI.
- Use the local CAP 0.6.0 build in the library and example. Signing uses
  `prepare_signing/5`, the custody callback, the raw wrong-key guard and
  `finish_signing/2`. Remove the signer's context derivation and verify
  routing. Version the signer as 0.5.0.
- CAP 0.5.0 requires distinct charter parties. Re-verify stored views:
  repeated descriptor digests fail with `:revision_invalid`; roles from
  one descriptor history or a supplied history no revision names fail
  with `:chain_invalid`. Acceptance and termination preparation returns
  these failures as `{:invalid_input, code}` before signing.

## [0.4.1] — 2026-10-04

Documentation release: the developer-platform direction, recorded. No
behavioral `lib/` change; the shipped bytes differ only in mix.exs (the
version), README.md, CONTRIBUTING.md, and this file.

### Documentation

- macOS and Linux are the developer platforms; Windows developers use
  WSL2 (clone inside the WSL filesystem, not under `/mnt/c`) and follow
  the Linux path — no native-Windows developer path is maintained
  (owner direction, October 4, 2026). README's development section and
  CONTRIBUTING's Windows section now state this, replacing the
  0.3.4-era PowerShell/cmd.exe and native-installer instructions.
- CI runs on Linux only (`ubuntu-26.04`, the OpenSSL 3.5-or-newer the
  ML-DSA-65 mint path needs); docs-only pushes skip CI, and the site's
  CI badge says Linux.

## [0.4.0] — 2026-09-24

Dependency-line release: this package now tracks the published CAP 0.4.x
line. No behavioral `lib/` change.

### Changed

- The protocol wall moves to `charter_agreement_protocol ~> 0.4.0` and
  the lock to 0.4.1 (wall test and the example app's mirror pin move in
  the same commit, per the one-commit rule). Why now and not with the
  capability alignment: CAP 0.4.x is consumer-surface additive - the
  producer surface this library delegates to is unchanged, so holding the
  wall below the published line bought process coupling, not safety, and
  made the example's dependency gate fight every CAP publish. The
  alignment (mirrored `capabilities()` with refuse-before-mint, declared
  minting metadata, profile-bound signing) is the next feature release
  on this line.

## [0.3.5] — 2026-09-24

### Documentation

- The ecosystem note, post-CAP-0.4.0 (no signer code change; the wall and
  the lock are untouched at `~> 0.3.0` / 0.3.1):
  - **Nothing the signer does is affected.** CAP 0.4.0's release-identity
    act is consumer-surface additive - a capability profile on the verify
    paths, an implementation-local substrate diagnostic
    (`:algorithm_unsupported_on_substrate`, deliberately outside the
    conformance verdict surface), facts-record scalars, and a versioned
    release manifest. The producer surface this library delegates to is
    unchanged, and the wire is unchanged (`protocol_revision` stays 3):
    artifacts minted by this signer verify identically under a 0.4.x
    verifier.
  - **The npm verify side moved to 0.5.0**: `@charter-agreement-protocol/
    verifier` now mirrors the capability probe (`capabilities()`), the
    signature registry's own identity (`algorithmRegistryDigest()`), the
    descriptor timestamp floor, and the 104-case certified corpus.
  - **The producer/verifier capability alignment is recorded and queued**
    (the contract at the protocol repository's partner record): mirror
    `capabilities()` on the producing side with a refuse-before-mint named
    failure, declare minting profile metadata, and add a profile-bound
    signing mode. That work rides the deliberate wall move to
    `charter_agreement_protocol ~> 0.4.0` - possible only after
    CAP 0.4.0 publishes to Hex (currently held by the protocol owner).
    Until then this package stays on the 0.3.x line and remains fully
    compatible.

## [0.3.4] — 2026-09-17

Cross-platform release: a plain clone is workable on Windows, macOS, and
Linux — proven, not asserted. No behavioral `lib/` change; the shipped
bytes differ only in mix.exs (the alias), README, and CONTRIBUTING.

- The `mix ci` alias drops its 21 POSIX `env MIX_ENV=test` re-execs: the
  first step now guards its own boot env and refuses a `:dev` boot with
  the per-shell invocation (`MIX_ENV=test mix ci`; PowerShell
  `$env:MIX_ENV = "test"; mix ci`; cmd.exe `set MIX_ENV=test && mix ci`).
- The dependency-currency gate is a portable `scripts/check_deps_current.exs`
  (same caller-cwd contract and classifiers, red-proven) replacing the bash
  script; the package and reproducibility gates spawn `mix` through
  `cmd /c` on Windows, use no POSIX utilities (`mktemp` → `System.tmp_dir!`),
  walk the census tree instead of globbing (`Path.wildcard` treats
  backslashes as literals on Windows), and treat scratch cleanup as
  best-effort with a bounded retry (a just-exited child's handle is not a
  gate verdict).
- A `windows-latest` CI lane proves the clone-pickup surface on every push:
  deps, format, compile, credo, tests, both dependency audits, the currency
  gate, and the package census with its consumer smoke. The ML-DSA-65 mint
  test is tagged `requires_mldsa_substrate` and excluded there (the Windows
  OTP build's OpenSSL linkage — the same exclusion class as Ubuntu 24.04),
  and the coverage step is absent by design because that exclusion
  subtracts covered lines by construction.
- `.gitattributes` pins `* text=auto eol=lf` so Windows checkouts keep
  `mix format --check-formatted` green.

## [0.3.3] — 2026-09-16

Support-floor widening; no behavioral `lib/` change. The supported Elixir
range moves `~> 1.20` → `~> 1.19` — the tested 1.19.x–1.20.x lines on
Erlang/OTP 28/29, with 1.19.x riding the OTP-28 CI lane. Everything below
was probe-proven before the range moved: on Elixir 1.19.5 / OTP 28.5 the
full tree (the protocol dependency included) compiles, the entire suite
passes, and `mix format --check-formatted` is green; Elixir 1.18 stays
outside the range (the protocol package's compile-time extension registry
does not build on 1.18 — a source incompatibility there, not a declaration
one). CI gains the `1.19.5/28.5.0.3` lane on both jobs; the lockstep
quadruple (mix.exs range, config's supported-OTP set, .tool-versions dev
lane, CI lanes) moved in ONE commit. Note for consumers on 1.19: the
protocol package's hex metadata still declares `~> 1.20`, but its source
compiles and passes on 1.19 — Mix does not enforce dependency Elixir
requirements at `deps.compile`; a future protocol docs-release can re-declare
for metadata honesty.

## [0.3.2] — 2026-09-16

Toolchain-and-hygiene release. No behavioral `lib/` change for any reachable
input: the shipped code differs only by comments, documentation corrections,
and the removal of provably-unreachable defensive lines. The full battery
passes with a MEASURED test coverage of 100.0% (50 tests; the coverage floor
in mix.exs re-pinned 87.0 → 100.0 — any future uncovered line reds the
battery immediately).

- **Toolchain enforcement in code** (supported range, not a single-version
  pin): mix.exs keeps `~> 1.20` — the tested 1.20.x line; anything outside
  refuses with `Mix.ElixirVersionError` before anything compiles — and the
  new config/config.exs asserts the OTP major against the supported set
  {28, 29} (`System.version/0` does not encode the OTP build, so a
  same-Elixir binary built on an unsupported OTP would otherwise compile
  incompatible BEAMs into shared `_build`/PLT state silently). The example
  project enforces identically. Lockstep: the declared range, the
  supported-OTP set, .tool-versions (the dev lane), and CI's matrix lanes
  move together in ONE commit.
- **Dependency currency is mechanical**: `scripts/check_deps_current.sh`,
  wired into CI (gate + example jobs) and `mix ci`, exits nonzero on any
  resolvable `mix hex.outdated` drift and prints resolver-rejected packages
  with the requirement chain holding them back. dialyxir 1.4.7 → 1.4.8 and
  ex_doc 0.40.3 → 0.40.4 moved to latest (`mix hex.audit` and
  `mix deps.audit` re-run clean after the move); hex_core/protobuf/purl
  remain resolver-rejected below latest by sbom 0.10.0's own pins.
- **Eight provably-unreachable defensive lines removed** (each site carries
  a comment naming the subsuming invariant): four in the signer tail (the
  assemble error arm, the non-binary-digest fallback, and two handle-shape
  re-guards — the producer's size/shape gates and the entry
  `resolve_key_identity` gate cover every reachable input, so a miss past
  them is a CAP-contract break that now fails loudly instead of wearing a
  misleading closed atom), and the four dispatch rescue/catch arms in
  Telemetry (`:telemetry` 1.4 contains handler faults itself — a faulting
  handler is removed and re-reported on `[telemetry, handler, failure]`;
  docs/telemetry.md re-trued to the containment-and-alarm story).
- **New coverage pins real properties**: caller-limits post-sign-verify
  branches (revision and descriptor decode under limits narrower than the
  producer's defaults), telemetry fault containment through real signs, the
  off-spec span classification, every reference key-handle's malformed-ref
  fallbacks, and the RogueKey advertised-key semantics. Guarding tests were
  mutant-proven red in a scratch copy.

### Fixed

- `party_chain/2`'s nil arm is REACHABLE and stays: an initially-planned
  deletion (its comment had claimed the producer rejects un-pinned party
  digests) was caught by the decorrelated review — the producer's R1 binds
  claims to the RETAINED REVISION's parties list, never to the set's
  descriptors, so a genesis naming a party digest no set descriptor pins
  passes every producer refusal and must land as the closed
  `:verification_failed`, never a crash. The arm carries the corrected
  invariant comment and its own driving test.
- The `examples/charter_signing_roundtrip.livemd` Setup cell was broken
  since it shipped: `Path.join(__DIR__, "../..")` resolved one directory
  above the repo, so `Mix.install` found no mix.exs. Now `".."`; the
  notebook's cells execute green end-to-end (descriptor round-trips, CAP
  verification, the wrong-key rejection).

## [0.3.1] — 2026-09-15

Docs-and-tooling correction release; no behavioral `lib/` change — only
doc-comment corrections ride the release. The
protocol dependency moves within the tested span: `charter_agreement_protocol`
locked 0.3.0 → 0.3.1 (requirement unchanged `~> 0.3.0`; library lock, wall
test, and example lock moved in this release commit per ADR-0002's
discipline — CAP 0.3.1 is docs-and-tooling only, no verdict-flipping
change).

### Fixed

- The ML-DSA-65 emission pair needs the OTP runtime linked against
  OpenSSL ≥ 3.5 (FIPS 204 reached OpenSSL in 3.5.0; OTP's `:crypto` exposes
  ML-DSA only through the linked libcrypto). CI ran on the ubuntu-latest
  runner (24.04, OpenSSL 3.0.x today), where the end-to-end ML-DSA-65 mint
  test fails with the OpenSSL `Bad key type` error while the same tree
  passes the full local battery on a runtime linked against OpenSSL 3.6 —
  bob's OTP builds dynamically link the distro `libcrypto.so.3` and bundle
  nothing, so the distro library is the only variable. The CI gate and
  example jobs and the tag-triggered supply-chain build now run on
  ubuntu-26.04 (OpenSSL 3.5.x), and the supply-chain build gains the Node
  setup and TypeScript build steps its `mix ci` battery needs (the
  cross-implementation gate imports `typescript/dist`, which is gitignored
  and was never built there — the v0.3.0 tag build failed before reaching
  it). Every matrix lane keeps its pinned versions. No test, error atom, or
  assertion changed.
- Documentation re-trued to the algorithm-aware 0.3.0 surface: the
  upgrading guide now carries the 0.3.0 and 0.3.1 notes and the current
  pin policy (`~> 0.3.0`); every guide that stated the 0.2-era
  single-emission-pair rule now states the pair set (default
  `Ed25519`/revision 2, opt-in `ML-DSA-65`/revision 3 via `:algorithm`);
  signature-length prose keys to the registry row instead of a universal
  64 bytes; the key-identity snapshot documents the registry key lengths;
  install examples pin `~> 0.3.0`; and ADR-0005 records the length
  generalization as a dated amendment.

## [0.3.0] — 2026-09-14

Adopts CAP 0.3.0 (the deliberate line move, ADR 0002) and adds
algorithm-aware signing for CAP's revision-3 ML-DSA registry act:

- The `:algorithm` option (closed to CAP's emission set: `"Ed25519"` at
  `protocol_revision` 2 — the default — and `"ML-DSA-65"` at
  `protocol_revision` 3) selects the mint pair; claims must already carry
  the matching `protocol_revision` (CAP's producer enforces the pair).
- The handle-signature acceptance length and the wrong-key guard follow the
  registry row (64 bytes Ed25519, 3309 ML-DSA-65) instead of the hardcoded
  64; the key-identity snapshot accepts any registry key length
  (32/1312/1952/2592) — a key that does not match the selected algorithm
  still fails closed at the wrong-key guard.
- A test-only ML-DSA-65 key handle (`CharterAgreementSigner.Keys.RawMLDSA65`)
  exercises the full custody path: snapshot → producer → sign → guard →
  assemble → CAP post-verify at revision 3.

## [0.2.1] — 2026-08-30

### Changed

- Documentation-only release (the CAP 0.2.1 pattern): the 0.2.0 adoption
  left the guide set silent on the revision-2 minting rule except where the
  migration note lives. The sweep names it everywhere a host or counterparty
  looks: `errors.md` lists revision-below-emission claims as a cause of
  `:signing_input_invalid`, `consumer-integration.md` tells counterparties
  what header a fresh mint carries (`"Ed25519"`, revision 2) and that legacy
  revision-1 views compose freely, `recipes.md`'s porting note pins the
  emission identity for non-Elixir signers, `usage-rules.md` gains the
  mint-at-current-revision rule, and the README states it on the landing
  page. No library, dependency, or gate change.

## [0.2.0] — 2026-08-29

### Changed

- The protocol dependency moves to the tested 0.2.x line:
  `charter_agreement_protocol ~> 0.2.1` (double-pinned per ADR-0002 — the
  requirement, the library lock, and the example lock moved in this one
  commit). Classified against CAP's changelog: 0.2.0 is `protocol_revision`
  2 with the RFC 9864 alg-name bundle; 0.2.1 is docs-only (it points hosts
  at this signer). No signer API, error-shape, or telemetry change.
- What the new line means for callers: CAP's producers now mint exactly
  (`"Ed25519"`, `protocol_revision` 2), so claims handed to any sign path
  must carry `"protocol_revision" => 2`. Claims carrying revision 1 are
  refused at CAP's producer (the alg-name binding rule) as
  `{:invalid_input, :signing_input_invalid}` — that is the protocol's
  emission rule, not a signer regression. Revision-1 artifacts you retain
  still verify freely (cross-revision composition): a freshly signed
  revision-2 artifact over revision-1 views is the supported mixed
  deployment. See `docs/upgrading.md`.

## [0.1.0] — 2026-08-26

### Added

- Initial public release: the holder-side companion signer for the Charter
  Agreement Protocol (`charter_agreement_protocol` `~> 0.1.0`, double-pinned
  to the tested 0.1.x line per ADR-0002).
- `sign_descriptor/3`, `sign_receipt/4`, `sign_acceptance/4`, and
  `sign_termination/4` — one shared signing tail per the BARA companion-signer
  grammar: atomic `key_identity/1` snapshot (header `kid` sourced only from
  the snapshot), CAP producer with honest-signer R1–R3 refusals before the
  key is used, raw-signature wrong-key guard, CAP assembly, and post-sign
  verification through the matching CAP public verify function.
- The key-handle behavior (`sign/2`, `key_identity/1` required;
  `public_key/1`, `thumbprint/1` optional caller self-checks).
- Closed error vocabulary: `:invalid_key_handle`, `:signing_failed`,
  `:verification_failed`, `{:refused, :signing_refused}`,
  `{:invalid_input, code}` — no key material, message bytes, or claims
  content in errors. Opts accept maps and keyword lists; any other shape
  returns `{:invalid_input, :invalid_type}` rather than raising.
- The value-free telemetry surface (ADR-0003): two events,
  `[:charter_agreement_signer, :sign, :start|:stop]`, with a class axis
  exactly mirroring the error vocabulary (refusals and verification
  failures are their own classes — never folded into `:signing_failed`);
  no handler is attached by default. `:telemetry ~> 1.4` joins the
  dependency set as the one sanctioned runtime seam beyond the protocol
  package.
- The full guide set (`docs/`: errors, getting-started, security, telemetry,
  upgrading, recipes, consumer-integration), five governing ADRs
  (`docs/adr/`), the runnable bilateral `examples/charter_lifecycle`
  reference app with its own CI lane, and the Livebook round-trip.
- Gate battery: red-capable wrong-key gate (with the structural
  assemblability non-vacuity proof), refusal propagation, handle-contract
  totals (raise/exit/throw/reject/short-signature), dependency-direction
  wall, shipped-artifact package census + consumer smoke, and the
  release-candidate reproducibility gate (`mix ci` mirrors CI step-for-step).

[Unreleased]: https://github.com/baselabs/charter_agreement_signer/compare/v0.4.1...HEAD
[0.4.1]: https://github.com/baselabs/charter_agreement_signer/releases/tag/v0.4.1
[0.4.0]: https://github.com/baselabs/charter_agreement_signer/releases/tag/v0.4.0
[0.3.5]: https://github.com/baselabs/charter_agreement_signer/releases/tag/v0.3.5
[0.3.4]: https://github.com/baselabs/charter_agreement_signer/releases/tag/v0.3.4
[0.3.3]: https://github.com/baselabs/charter_agreement_signer/releases/tag/v0.3.3
[0.3.2]: https://github.com/baselabs/charter_agreement_signer/releases/tag/v0.3.2
[0.3.1]: https://github.com/baselabs/charter_agreement_signer/releases/tag/v0.3.1
[0.3.0]: https://github.com/baselabs/charter_agreement_signer/releases/tag/v0.3.0
[0.2.1]: https://github.com/baselabs/charter_agreement_signer/releases/tag/v0.2.1
[0.2.0]: https://github.com/baselabs/charter_agreement_signer/releases/tag/v0.2.0
[0.1.0]: https://github.com/baselabs/charter_agreement_signer/releases/tag/v0.1.0
