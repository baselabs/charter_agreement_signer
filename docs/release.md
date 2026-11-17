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
   That workflow refuses any other ref (only a commit whose `qualified` run
   succeeded reaches the default branch), refuses an existing registry
   version or tag, installs the exact runtime and locked dependencies without a
   cache, builds documentation, and builds and inspects the package before
   publication. Only its publish step receives the environment's `HEX_API_KEY`.
6. Infra reads the registry publication back, checks the archive identity and
   documentation, and tags `v<version>` on that published commit. No workflow
   creates or pushes a tag.

`publish.yml` also retains the archive checksum and CycloneDX SBOM and attests
provenance and the SBOM for that exact commit. Infra separately dispatches
`pages.yml` to deploy the static site from the default branch.
