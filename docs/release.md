# Release candidates

Builds and checks do not authorize a Hex publication, tag push or deployment.
The maintainer approves the exact versions after inspecting the candidates.

## Before publication

1. Run CAP's `mix quality` and `mix hex.build` on the release tree.
2. Materialize the pinned TypeScript sources and build/test them. The
   published-baseline gate does this; during coordinated release preparation
   the paired candidate check uses these exact built source trees.
3. Check the paired candidate without publishing it:

   ```console
   elixir scripts/check_protocol_candidate.exs ../charter_agreement_protocol/charter_agreement_protocol-1.0.0.tar <archive-sha256>
   ```

   This unpacks CAP's real Hex archive and runs the full signer and
   lifecycle suites in disposable copies against that source. It asserts
   the archive SHA-256 and loaded CAP version, then runs
   bidirectional TypeScript interop against this candidate. The repository
   Hex locks are refreshed only after CAP publication. Set
   `CAS_LIMITED_COVERAGE` to a real CI export from identical signer library
   source to run the merged coverage gate too.
4. Run `mix hex.build`. Retain the archive and its SHA-256 for approval.
   `scripts/check_package.exs` checks the unpacked package, its dependency
   metadata, corpus inclusion and a real consumer's signing round trip.

The language-neutral corpus ships at `priv/conformance/signer_cases.json`.
The TypeScript check requires byte equality with the pinned TypeScript
signer, builds and tests the pinned verifier, and installs that local build
for the signer tests and bidirectional interop checks. The test keys are
public fixture material. A passing suite certifies those cases and pins;
it is not a proof over every possible input or every dependency version.

## After approval

Publish CAP 1.0.0 first. Update the library and lifecycle locks to that
published release. Run `MIX_ENV=test mix ci`, with `CAS_LIMITED_PATH` for a
real limited-crypto runtime or `CAS_LIMITED_COVERAGE` from matching CI source,
before publishing CAS 1.0.0. Never simulate missing crypto support.
Change the Unreleased changelog date to the publication date, build and
compare the final archives, then tag the exact commits. The tag workflow
produces provenance, checksums and an SBOM. Publishing remains a manual
maintainer action. Verify both packages from a clean consumer after release.
