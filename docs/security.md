# Security

## Trust boundaries

```
claims + context + options
  -> option checks -> atomic snapshot -> CAP.prepare_signing
  -> caller sign/2 -> raw wrong-key guard -> CAP.finish_signing
  -> verified compact
```

- **The library never sees a private key.** All key operations run inside the
  caller's `sign/2` / `key_identity/1` callbacks. A handle that embeds key
  bytes in its term has chosen that posture itself; the shipped library never
  solicits, processes, or retains key material, and no error or log line it
  produces can carry it (closed, value-free vocabulary).
- **The protocol package is pure.** Every producer, assembler, and verifier
  call runs inside `charter_agreement_protocol`, which has no filesystem,
  network, clock, config, or randomness access. This library has its
  own dependency-direction wall (architecture-tested: `lib/` may reference
  these packages, `:crypto` and the value-free `:telemetry` seam).

## The wrong-key guard

The load-bearing control: after `sign/2` returns, the raw signature (at the
selected algorithm's registry-row length: 64 bytes for `Ed25519`, 3309 for
`ML-DSA-65`) is verified against the public key from the SAME atomic
`key_identity/1`
snapshot that sourced the header `kid`. A custody layer that signs with a
different key than it advertises (rotation race, misconfigured slot, a
compromised callback substituting its key) produces `:signing_failed`.
The artifact is never returned. The test suite proves this gate red-capable:
the wrong-key test mints a structurally assemblable rogue signature (CAP's
own assembler accepts it; the framing layer cannot know which key was
intended) and pins `:signing_failed` as the specific outcome. CAP preparation checks the holder's own descriptor key before custody.
The guard then rejects signatures that differ from the snapshot key before
assembly. CAP's `finish_signing/2` runs public verification as a second
barrier. Removing the guard would change the wrong-key outcome to the later
`:verification_failed`, so the gate test pins `:signing_failed`. Faulting or
rejecting custody callbacks also return `:signing_failed`. CAP's signature
verifier owns the signature length check.

## What is deliberately NOT defended here

- **A dishonest signer.** The refusal rules (R1–R3) protect honest signers
  relative to their own supplied view. A party determined to sign
  contradictory artifacts can bypass this library entirely and hand-forge
  compacts; detection is the verifier's equivocation predicates, not the
  signer's job.
- **External key registries.** CAP checks the snapshot against the holder's
  own active descriptor keys before custody. This library does not query
  external registries or key stores. The caller supplies the handle and view.
- **Descriptor freshness, legal effect, term evaluation, effect execution.**
  These are host policies under the protocol's governance. This library signs and verifies
  bytes; it never authorizes anything.

## Reporting

See [SECURITY.md](../SECURITY.md). Report privately to the
maintainer with a value-free reproduction; every `v*` tag carries SLSA build
provenance and a CycloneDX SBOM attestation verifiable via `gh attestation
verify`.
