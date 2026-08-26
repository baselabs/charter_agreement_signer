# Security policy

## Supported versions

The latest published `0.x` line is supported. Wire compatibility is governed
by the protocol package's contract discipline — this library's releases track
`charter_agreement_protocol`.

## Security invariants (what a change is measured against)

Restated from the signer's boundary invariants, for reporting:

- The library never solicits, processes, or retains private key material —
  custody lives entirely behind the caller's key-handle callbacks (a handle
  that embeds key bytes in its term has chosen that posture itself — see
  [docs/security.md](docs/security.md) § Trust boundaries).
- Every signature is verified against the handle-snapshot public key before
  success — a wrong-key sign is `:signing_failed`, never a false success
  (proven red-capable in the suite).
- Key identity (`kid` + public key) is resolved from ONE atomic
  `key_identity/1` snapshot on every path; caller-supplied key ids do not
  exist in the API (the signer injects the snapshot kid).
- Errors are closed atoms and carry no values: no key material, message
  bytes, or claims content can appear in any error. A defect that leaks
  values into that channel is a security defect, not a cosmetic one.
- The library depends only on the public protocol package — never a runtime,
  never a transport, never an HTTP client/server (enforced by the
  dependency-direction wall test).
- The test-only reference handles compile only under `:test` and never ship
  in the artifact (package-census-gated).

## Reporting a vulnerability

Report privately to the repository maintainer. Do NOT open a public issue
containing an exploit, credential, private key, or unreleased vulnerability
detail.

A report should include:

- the affected version or commit;
- the violated property (the invariant above, in your own words);
- a minimal, VALUE-FREE reproduction (no real keys, no production claims
  content);
- the expected security outcome.

## Verifying a release (supply-chain provenance)

Every `v*` tag push runs the supply-chain workflow: it builds the exact Hex
archive through the full gate battery, records its SHA-256 in `SHA256SUMS`,
and attests build provenance (SLSA) plus a CycloneDX SBOM via GitHub
attestations. To verify a published release against that evidence:

```sh
# 1. Download the release evidence artifact (the workflow run for the tag)
#    and the tarball, then compare checksums:
sha256sum -c SHA256SUMS

# 2. Verify the attestations against the subject digest (requires the
#    gh CLI and the workflow run's artifact):
gh attestation verify <tarball> --repo baselabs/charter_agreement_signer

# 3. Cross-check against hex.pm's published checksum for the release
#    (hex.pm shows the archive checksum on the version page — it must
#    equal the SHA-256 in SHA256SUMS for the same bytes).
```

Locally, before any release, `mix ci` runs the same reproducibility gate the
workflow uses: two cache-isolated builds of the exact archive must agree byte
for byte.

## Acknowledgment

We will acknowledge reports within 7 days and send status updates at least
weekly until resolution, coordinating disclosure through the private advisory.
This is a best-effort cadence from a small maintainer team, not a contractual
SLA — urgent disclosures are handled faster when marked as such.
