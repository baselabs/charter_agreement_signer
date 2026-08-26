# Security

## Trust boundaries

```
caller claims ──▶ CharterAgreementSigner ──▶ CAP producers (pure) ──▶ signing input
                         │
   {module, ref} ────────┘ sign/2 + key_identity/1 run against CALLER custody
                         │  (HSM / KMS / key server / test process memory)
                         ▼
        wrong-key guard ──▶ CAP assembly ──▶ CAP post-sign verify ──▶ {:ok, compact}
```

- **The library never sees a private key.** All key operations run inside the
  caller's `sign/2` / `key_identity/1` callbacks. A handle that embeds key
  bytes in its term has chosen that posture itself; the shipped library never
  solicits, processes, or retains key material, and no error or log line it
  produces can carry it (closed, value-free vocabulary).
- **The protocol package is pure.** Every producer, assembler, and verifier
  call runs inside `charter_agreement_protocol`, which has no filesystem,
  network, clock, config, or randomness access — mirrored by this library's
  own dependency-direction wall (architecture-tested: `lib/` may reference
  only the two packages plus `:crypto`).

## The wrong-key guard

The load-bearing control: after `sign/2` returns, the raw 64-byte signature
is verified against the public key from the SAME atomic `key_identity/1`
snapshot that sourced the header `kid`. A custody layer that signs with a
different key than it advertises (rotation race, misconfigured slot, a
compromised callback substituting its own key) produces `:signing_failed` —
the artifact is never returned. The test suite proves this gate red-capable:
the wrong-key test mints a structurally assemblable rogue signature (CAP's
own assembler accepts it — the framing layer cannot know which key was
intended) and shows the guard is the only rejection point.

## What is deliberately NOT defended here

- **A dishonest signer.** The refusal rules (R1–R3) protect honest signers
  relative to their own supplied view. A party determined to sign
  contradictory artifacts can bypass this library entirely and hand-forge
  compacts — detection is the verifier's equivocation predicates, not the
  signer's job.
- **Key identity in any registry.** The snapshot's `kid` names a key in the
  party descriptor's `verification_keys`; whether that naming is truthful is
  established by CAP's descriptor verification and the descriptor chain, not
  by signing-time checks (the post-sign verify catches the mismatch locally).
- **Descriptor freshness, legal effect, term evaluation, effect execution.**
  Host policy per the protocol's governance — this library signs and verifies
  bytes; it never authorizes anything.

## Reporting

See [SECURITY.md](../SECURITY.md). In short: report privately to the
maintainer with a value-free reproduction; every `v*` tag carries SLSA build
provenance and a CycloneDX SBOM attestation verifiable via `gh attestation
verify`.
