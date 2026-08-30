# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

[0.2.0]: https://github.com/baselabs/charter_agreement_signer/releases/tag/v0.2.0
[0.1.0]: https://github.com/baselabs/charter_agreement_signer/releases/tag/v0.1.0
