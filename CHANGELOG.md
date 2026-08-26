# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] — 2026-08-26

### Added

- Initial public release: the holder-side companion signer for the Charter
  Agreement Protocol (`charter_agreement_protocol` ~&gt; 0.1).
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
  content in errors.
- Gate battery: red-capable wrong-key gate (with the structural
  assemblability non-vacuity proof), refusal propagation, handle-contract
  totals (raise/exit/throw/reject/short-signature), dependency-direction
  wall, shipped-artifact package census + consumer smoke, and the
  release-candidate reproducibility gate (`mix ci` mirrors CI step-for-step).

[0.1.0]: https://github.com/baselabs/charter_agreement_signer/releases/tag/v0.1.0
