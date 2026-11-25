# Release process

The maintainers' release process separates qualification, landing and publication.
A feature-branch push or version tag starts no qualification or publication.

1. Prepare the version commit and stamp its changelog entry with the version and
   publication date. Keep the root, lifecycle and generated-consumer fixture locks
   aligned with the intended dependency graph. Protocol dependencies must already
   be published before the signer is published.
2. Run covering tests on the maintainers' build box, never on a workstation. A
   configured private checkout routes them there with the maintainers' remote-run
   tooling.

   Public repositories have no build-box checkout; their builds and tests run only
   in qualification CI at landing. Never fall back to workstation compilation.
   Qualification includes both dependency audits for the library and lifecycle
   example, the supported runtime matrix, the real capability-limited lane,
   merged coverage, package inspection and reproducibility. Never simulate missing
   crypto support. Qualification also checks the pinned TypeScript sources.
3. Submit the full reviewed commit through the maintainers' landing tool.
   It pushes a landing candidate and moves the default branch only after every
   job passes and `qualified` is green. Do not push the default branch or a tag.
4. Send the release operator one message with the repository, full default-branch commit,
   version, what goes out and the successful `qualified` run. The maintainers do
   not hold a registry publication key or dispatch a publication workflow.
5. The release operator obtains approval and dispatches `publish.yml` on the default branch with the full qualified SHA as `release_commit`.
   The workflow refuses any other ref and an existing version tag. It installs
   the exact runtime and locked dependencies without a cache, builds docs and
   inspects the package. It builds the package and docs archives once
   into `release-assets/`. After the docs build and before packing, root
   `release.json` records exactly `package`, `version` and `commit`, with the run's
   `release_commit` as commit.
6. The registry check refuses a package name the registry lacks: a first
   publication is the owner's decision. It also refuses a retired version or
   differing served package bytes. The package is the release; docs are a
   rendering of it, and an ExDoc build is not byte-stable, so docs bytes are never
   compared: docs the registry already serves for this version are kept. Only the
   keyed step receives the publication key. That step only uploads the two
   verified archives, package first, using `mix run --no-mix-exs` from
   the runner's temporary directory, with absolute paths to the verified
   archives. The uploader re-reads the served state before each POST. It skips a matching
   package and docs that the final read reports as served. For a staged package,
   it first checks the stage checksum and then confirms the release is still
   unpublished. The uploader preserves a matching pending stage with its docs.
   Hex's client can resend an in-flight upload if the connection drops before the
   response. It also retains the key across a redirect from Hex. A second
   publisher or approval after the final read or between attempts is the
   residual race, controlled by custody of the publication key.
7. If either upload is held for approval, the owner approves it and the release operator
   dispatches `publish.yml` again with the same `release_commit`. It compares the rebuilt
   package with the served package. Read-back
   must serve the matching package and a readable docs archive with root
   `index.html` and `release.json`. The record must name this package and version;
   its commit must equal the dispatched commit or an ancestor in the clone. This
   is the published commit. Missing or invalid provenance is refused.
   `release.json` is the uploader's record, not an attestation or protection
   against a forged claim. Read-back replaces the built docs archive with the
   served docs, then records `SHA256SUMS` and exports `release-assets`.
8. After read-back, the release operator tags `v<version>` on the published commit named by the
   served docs' `release.json`, compares the artifact's package archive with the
   registry's bytes, and creates the GitHub release `v<version>` from
   `release-assets`. Consumers verify the archives and
   checksums downloaded from that GitHub release. No workflow creates a release
   or creates or pushes a tag.

### Release source attestation

The build signs the package archive digest with a predicate containing the
qualified `release_commit`. The GitHub signing certificate identifies the
default-branch workflow revision. Read-back verifies the archive digest and the
identity of `publish.yml`, then requires the signed commit to match the served
docs. An ancestor built by the earlier publish workflow can use its original
GitHub provenance attestation, which recorded the checkout commit in the
certificate. For an ancestor, read-back also requires unchanged SBOM inputs
(`mix.exs`, `mix.lock` and `scripts/build_release_sbom.sh`).

The workflow also signs the CycloneDX SBOM for the package. The generator version
is locked and excludes system dependencies. Consumers can verify the source
commit against the release tag.

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
