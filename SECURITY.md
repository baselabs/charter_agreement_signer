# Security policy

## Supported versions

The `1.0.x` line is supported. Older lines are unsupported; upgrade to 1.0.x. Wire compatibility is governed
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
- The library depends only on the public protocol package and telemetry — never a runtime,
  never a transport, never an HTTP client/server (enforced by the
  dependency-direction wall test).
- The test-only reference handles compile only under `:test` and never ship
  in the artifact (package-census-gated).

## Reporting a vulnerability

Report it privately through GitHub's private vulnerability reporting for
`baselabs/charter_agreement_signer` (the repository's Security tab, then
"Report a vulnerability"). Do NOT open a public issue
containing an exploit, credential, private key, or unreleased vulnerability
detail.

A report should include:

- the affected version or commit;
- the violated property (the invariant above, in your own words);
- a minimal, VALUE-FREE reproduction (no real keys, no production claims
  content);
- the expected security outcome.

## Verifying a release (supply-chain provenance)

The maintainers' release process dispatches `publish.yml` from a qualified
commit on the default branch. The keyed step only uploads the two verified
archives with no project loaded; it never builds under the key. Registry checks
refuse a missing package name, a retired version or differing served bytes.
After approval, dispatching a held release again on the same commit uploads
only what is missing. Read-back must serve matching package and docs bytes.

The workflow exports consumer files as `release-assets`. After read-back, infra
tags the published commit and creates its GitHub release `v<version>` from those
assets, comparing the package archive with the registry first. Consumers verify
files downloaded from the GitHub release.

The public release also includes a CycloneDX SBOM and provenance and SBOM
attestations for the exact package archive. To verify it:

```sh
# Download all assets from the GitHub release for the version being verified.
gh release download "v<version>" --repo baselabs/charter_agreement_signer
sha256sum -c SHA256SUMS

# Verify the downloaded package archive's attestations.
gh attestation verify "charter_agreement_signer-<version>.tar" --repo baselabs/charter_agreement_signer

# Compare its SHA-256 with the archive checksum on hex.pm's version page.
```

Qualification runs the reproducibility gate on the CI runner: two
cache-isolated builds of the exact archive must agree byte for byte.

## Acknowledgment

We will acknowledge reports within 7 days and send status updates at least
weekly until resolution, coordinating disclosure through the private advisory.
This is a best-effort cadence from a small maintainer team, not a contractual
SLA — urgent disclosures are handled faster when marked as such.
