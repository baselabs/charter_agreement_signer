# AGENTS.md — working in this repo as an AI coding agent

Operational instructions for any agent editing this repository. This is the
*how to work here* doc; the protocol package is the authority for every
artifact this library signs. Read this FIRST.

## What this is

`charter_agreement_signer` — CAP's holder-side companion signer (the
`bounded_authority_report_adapter` pattern applied to the Charter Agreement
Protocol). It takes a `{module(), term()}` key-handle + claims, resolves the
atomic `key_identity/1` snapshot (kid + public key, ONE call), builds the
signing input via CAP's producers (the honest-signer R1–R3 refusals run
there, BEFORE the key is used), signs via the handle's local key, verifies
the raw signature against the snapshot public key (the wrong-key guard),
assembles via CAP, and post-sign-verifies through the matching CAP public
verify function. It does NOT verify third-party artifacts, does NOT
transport, does NOT persist, and is NOT a runtime. The package is public on
GitHub (baselabs/charter_agreement_signer), master branch, Apache-2.0.

## Read CAP first-hand — never trust a summary

The contract surfaces live in the **resolved `charter_agreement_protocol`
dependency** locked from Hex. Before building anything that calls CAP, read
that source first-hand — the version in `mix.lock` plus the resolved checkout
are the compiled truth, not this repo's docs or a prior session's handoff:

- `deps/charter_agreement_protocol/lib/charter_agreement_protocol.ex` — the
  public API surface (producers, verifiers, assembly).
- `deps/charter_agreement_protocol/lib/charter_agreement_protocol/signing_input.ex`
  — the refusal boundary and the input shape (`%{"kid" => kid, "claims" =>
  claims}`).
- `../charter_agreement_protocol/` — the sibling checkout for what CAP has
  decided/shipped beyond the locked release (spec, ADRs, conformance corpus).

## Critical rules

1. **The private key never enters this library.** No key bytes in `lib/`, no
   signer callbacks beyond the caller's handle, no custody. The test-only
   reference handles (`Keys.RawKey`, `Keys.RogueKey`) compile only under
   `:test` and never ship (package-census-gated).
2. **The header `kid` comes only from the atomic `key_identity/1` snapshot.**
   Never add a caller-supplied kid. The snapshot is ONE callback call —
   never split kid from public key across calls (the rotation race).
3. **The wrong-key guard is not removable.** Every sign path verifies the
   raw signature against the snapshot public key before assembly; the
   wrong-key gate test is red-capable and carries its own non-vacuity proof
   (the rogue signature assembles structurally — the guard is the only
   rejection point). Weakening it is a protocol-level regression, not a
   refactor.
4. **Post-sign verify before return.** Every path runs the matching CAP
   verify function before returning `{:ok, _}`. Removing it converts loud
   local failures into silent downstream ones.
5. **Errors are closed atoms, value-free.** No key material, message bytes,
   or claims content in any error. New error shapes update
   `docs/errors.md` in the same commit.
6. **The dependency wall.** `lib/` depends only on `charter_agreement_protocol`
   + the standard library (`:crypto`). Never add a runtime, transport, or
   sibling-package dependency; the wall test and the package census gate
   both red on a violation.
7. **Pure and deterministic.** No filesystem, network, environment, config,
   clock, or randomness in `lib/` (architecture-tested).
8. **Canonical bytes are the contract.** Never re-implement canonicalization
   or digest computation — every byte this library produces flows through
   CAP's producers and assemblers.

## Working here

```sh
mix ci   # the whole battery, local parity with CI (aborts at first red step)
```

MIX_ENV=test for any compile check (test/support only compiles under :test).
Requires Elixir 1.20+ (CAP's floor). Commits: surgical pathspecs, single tree
on `master`, never `git stash`.
