# Release process

The maintainers' release process separates qualification, landing and publication.
A feature-branch push or version tag starts no qualification or publication.

1. Prepare the version commit and stamp its changelog entry with the version and
   publication date. Keep the root, lifecycle and generated-consumer fixture locks
   aligned with the intended dependency graph. Protocol dependencies must already
   be published before the signer is published.
2. Run covering tests on the build box, never on a workstation. For a configured
   private checkout, run from the repository root:

   ```sh
   python3 ~/Developer/kimosabe/bin/kimosabe-remote where
   python3 ~/Developer/kimosabe/bin/kimosabe-remote run -- kimosabe-box-mix test <covering-test-paths>
   ```

   Public repositories have no build-box checkout; their builds and tests run only
   in qualification CI at landing. Never fall back to workstation compilation.
   Qualification includes both dependency audits for the library and lifecycle
   example, the supported runtime matrix, the real capability-limited lane,
   merged coverage, package inspection and reproducibility. Never simulate missing
   crypto support. Qualification also checks the pinned TypeScript sources.
3. Submit the reviewed commit through `kimosabe-land --repo . --sha <full-commit>`.
   It pushes a landing candidate and moves the default branch only after every
   job passes and `qualified` is green. Do not push the default branch or a tag.
4. Send infra one message with the repository, full default-branch commit,
   version, what goes out and the successful `qualified` run. The maintainers do
   not hold a registry publication key or dispatch a publication workflow.
5. Infra obtains approval and dispatches `publish.yml` on the default branch.
   The workflow refuses any other ref and an existing version tag. It installs
   the exact runtime and locked dependencies without a cache, builds docs and
   inspects the package. It builds the package and docs archives once
   into `release-assets/`, records `SHA256SUMS`, and exports the `release-assets`
   artifact before any registry upload.
6. The registry check refuses a package name the registry lacks: a first
   publication is the owner's decision. It also refuses a retired version or
   differing served package bytes. The package is the release; docs are a
   rendering of it, and an ExDoc build is not byte-stable, so docs bytes are never
   compared: docs the registry already serves for this version are kept. Only the
   keyed step receives the publication key. That step only uploads the two
   verified archives, package first, using `mix run --no-mix-exs` from
   `release-assets/`, where no `mix.exs` exists and no project is loaded. It
   uploads only what is missing and never replaces a version.
7. If either upload is held for approval, the owner approves it and infra
   dispatches `publish.yml` again on the same commit. It compares the rebuilt
   package with the served package and uploads only what is missing. Read-back
   must serve the matching package and its docs for the run to succeed.
8. After read-back, infra tags `v<version>` on the published commit, compares the
   artifact's package archive with the registry's bytes, and creates the GitHub
   release `v<version>` from `release-assets`. Consumers verify the archives and
   checksums downloaded from that GitHub release. No workflow creates a release
   or creates or pushes a tag.

`publish.yml` includes the CycloneDX SBOM in `release-assets` and attests
provenance and the SBOM for that exact archive. Infra separately dispatches
`pages.yml` to deploy the static site from the default branch.
