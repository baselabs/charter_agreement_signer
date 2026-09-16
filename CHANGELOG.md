# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
  it). Every matrix lane keeps its pinned versions, and the CAP pin (locked
  0.3.0 from Hex) is untouched. No test, error atom, or assertion changed.

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
- The key-handle behaviour (`sign/2`, `key_identity/1` required;
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

[Unreleased]: https://github.com/baselabs/charter_agreement_signer/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/baselabs/charter_agreement_signer/releases/tag/v0.3.0
[0.2.1]: https://github.com/baselabs/charter_agreement_signer/releases/tag/v0.2.1
[0.2.0]: https://github.com/baselabs/charter_agreement_signer/releases/tag/v0.2.0
[0.1.0]: https://github.com/baselabs/charter_agreement_signer/releases/tag/v0.1.0
