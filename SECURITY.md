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
refuse a missing package name, a retired version or differing served package
bytes. Docs are a rendering of the package and are not byte-stable across
builds, so their bytes are not compared. After approval, dispatching a held
release again on the same commit uploads only what is missing. Read-back must
serve the matching package and a readable docs archive with root `index.html`
and `release.json`. Written after the docs build and before packing, the record
has exactly `package`, `version` and `commit` (the run's `GITHUB_SHA`). Read-back
requires this package and version and a commit equal to the dispatched commit or
an ancestor in the clone; that is the published commit. Missing or invalid
provenance is refused. `release.json` is the uploader's record, not an attestation
or protection against forgery. The workflow never replaces a package or served
docs.

The workflow exports consumer files as `release-assets`. After read-back, infra
tags the published commit and creates its GitHub release `v<version>` from those
assets, comparing the package archive with the registry first. Consumers verify
files downloaded from the GitHub release. Read-back replaces the built docs in
`release-assets` with the served archive before checksums and artifact upload;
the docs archive is exactly the bytes downloaded and inspected from Hex.

Every file in the GitHub release is the published commit's, which `v<version>`
names. The public release includes a CycloneDX SBOM and provenance and SBOM
attestations for the exact package archive. Before exporting assets, the workflow
verifies the package attestation against the published commit. When that commit
is an ancestor, it requires unchanged SBOM inputs (`mix.exs`, `mix.lock` and
`scripts/build_release_sbom.sh`); a difference requires a new version. System
dependencies are excluded and the generator version is locked. To verify it:

```sh
# Download all assets from the GitHub release for the version being verified.
gh release download "v<version>" --repo baselabs/charter_agreement_signer
sha256sum -c SHA256SUMS

# Verify against the commit named by the release tag.
published_commit=$(gh api \
  "repos/baselabs/charter_agreement_signer/commits/v<version>" -q .sha)
gh attestation verify "charter_agreement_signer-<version>.tar" \
  --repo baselabs/charter_agreement_signer --source-digest "$published_commit"

# Compare its SHA-256 with the archive checksum on hex.pm's version page.
```

Qualification runs the reproducibility gate on the CI runner: two
cache-isolated builds of the exact archive must agree byte for byte.

## Acknowledgment

We will acknowledge reports within 7 days and send status updates at least
weekly until resolution, coordinating disclosure through the private advisory.
This is a best-effort cadence from a small maintainer team, not a contractual
SLA — urgent disclosures are handled faster when marked as such.
