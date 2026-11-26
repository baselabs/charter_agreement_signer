# Release process

The maintainers' release process separates qualification, landing and publication.
A feature-branch push or version tag starts no qualification or publication.

1. Prepare the version commit and stamp its changelog entry with the version and
   publication date. Keep the root, lifecycle and generated-consumer fixture locks
   aligned with the intended dependency graph. Protocol dependencies must already
   be published before the signer is published.
2. Run qualification in CI. It checks the supported runtime matrix, capability-limited
   lane, merged coverage, dependency audits, TypeScript sources, signing from the
   packaged archive and package reproducibility. CI also builds the package and
   HTML documentation with locked dependencies, stamps `release.json` and retains
   the two archives and their manifest for seven days.
3. Land the commit after `qualified` succeeds and obtain publication authorization.
   Dispatch `publish.yml` on the default branch using the full qualified SHA as
   `release_commit`.
4. The upload job verifies the exact qualification run and archives. It requires
   the package to exist and checks the version tag, stamped changelog, registry
   state and OTP application version collisions. The `publish` environment
   authorizes the shared action to exchange its workload identity for a short-lived,
   package-scoped token when an archive needs uploading.
5. After approval for a held release or docs upload, dispatch again with the same
   `release_commit` and pass the original CI run ID as `qualification_run`.
   Read-back verifies both served archives against that qualification and requires
   `release.json` to identify the dispatched commit. The workflow then generates the
   SBOM from the verified commit and exports it with both archives and `SHA256SUMS`
   in `release-assets`.
6. The release operator compares the package archive with Hex's checksum and
   creates the version tag and GitHub release on the commit named by the served
   docs. Consumers verify the downloaded assets with `SHA256SUMS`.

### Release source attestation

After verifying the served archives, the workflow signs the package archive
digest with a predicate containing the commit from `release.json`. It verifies
the signed commit against the served record and attests the CycloneDX SBOM
against the same package digest. The runner's own provenance describes the
default-branch workflow revision.

```sh
published_commit=$(gh api \
  "repos/baselabs/charter_agreement_signer/commits/v<version>" -q .sha)
gh attestation verify "charter_agreement_signer-<version>.tar" \
  --repo baselabs/charter_agreement_signer \
  --signer-workflow baselabs/charter_agreement_signer/.github/workflows/publish.yml \
  --source-ref refs/heads/master \
  --predicate-type 'https://github.com/baselabs/charter_agreement_signer/blob/master/docs/release.md#release-source-attestation' \
  --format json |
  jq -e --arg commit "$published_commit" \
    'any(.[]; .verificationResult.statement.predicate.release_commit == $commit)'
```

The release operator separately dispatches `pages.yml` to deploy the static site from the default
branch.
