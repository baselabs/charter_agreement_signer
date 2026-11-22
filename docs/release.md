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
5. The release operator obtains approval and dispatches `publish.yml` on the default branch.
   The workflow refuses any other ref and an existing version tag. It installs
   the exact runtime and locked dependencies without a cache, builds docs and
   inspects the package. It builds the package and docs archives once
   into `release-assets/`. After the docs build and before packing, root
   `release.json` records exactly `package`, `version` and `commit`, with the run's
   `GITHUB_SHA` as commit.
6. The registry check refuses a package name the registry lacks: a first
   publication is the owner's decision. It also refuses a retired version or
   differing served package bytes. The package is the release; docs are a
   rendering of it, and an ExDoc build is not byte-stable, so docs bytes are never
   compared: docs the registry already serves for this version are kept. Only the
   keyed step receives the publication key. That step only uploads the two
   verified archives, package first, using `mix run --no-mix-exs` from
   `release-assets/`, where no `mix.exs` exists and no project is loaded. It
   uploads only what is missing and never replaces a package or served docs.
7. If either upload is held for approval, the owner approves it and the release operator
   dispatches `publish.yml` again on the same commit. It compares the rebuilt
   package with the served package and uploads only what is missing. Read-back
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

Every file in the GitHub release is the published commit's, which `v<version>`
names. `publish.yml` includes the CycloneDX SBOM in `release-assets` and attests
provenance and the SBOM for the package archive before any upload. After read-back,
it verifies the package attestation with the published commit as source digest.
If that commit is an ancestor, it also requires the SBOM inputs (`mix.exs`,
`mix.lock` and `scripts/build_release_sbom.sh`) to be unchanged; otherwise it
refuses and the fix is a new version. System dependencies are excluded from the
SBOM, and the generator version is locked. Consumers can verify the source with:

```sh
published_commit=$(gh api \
  "repos/baselabs/charter_agreement_signer/commits/v<version>" -q .sha)
gh attestation verify "charter_agreement_signer-<version>.tar" \
  --repo baselabs/charter_agreement_signer --source-digest "$published_commit"
```

The release operator separately dispatches `pages.yml` to deploy the static site from the default
branch.
