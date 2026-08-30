# Usage rules

How consuming agents and hosts are expected to use `charter_agreement_signer`.
These rules restate the library's invariants operationally; the package
enforces most of them structurally, and the rest are posture.

1. **Never give this library a private key.** Custody lives entirely behind
   your `{module, ref}` handle. If you find yourself putting key bytes into a
   handle term for production, stop — that is a custody design failure, not a
   convenience (see [docs/security.md](docs/security.md)).

2. **Implement `sign/2` and `key_identity/1`.** They are required. Resolve
   `kid` and the public key in the ONE `key_identity/1` call; never split
   them across two callbacks (the rotation race the atomic snapshot exists
   to prevent). `public_key/1` / `thumbprint/1` are optional self-check
   surface — use them to compare the handle against a party descriptor's
   `verification_keys` before signing.

3. **The claims carry no key material.** `sign_descriptor/3`,
   `sign_acceptance/4`, `sign_termination/4`, and `sign_receipt/4` take
   claims only; the protected header's `kid` always comes from the handle
   snapshot. A caller cannot name a kid the handle does not control.

4. **Honor refusals.** `{:error, {:refused, :signing_refused}}` means your
   claims contradict your own verified artifact view (CAP's R1–R3 rules).
   Fix the view or the claims — never retry with a hand-built signing input
   to force the signature through; that is exactly the dishonest-signer path
   the refusal boundary exists to make loud.

5. **Supply real context for the post-sign verify.** A successor descriptor
   needs `:predecessor` facts; a receipt needs the verified revision or chain
   facts context. Signing without the context you will eventually verify
   against trades a loud local failure for a silent downstream one.

6. **Do not catch-and-continue on `:signing_failed`.** It means the custody
   boundary produced a signature that does not match the advertised key (or
   violated the callback contract). Escalate to the operator; a retry loop
   around a wrong-key race signs nothing useful and hides the misconfiguration.

7. **Verifiers never depend on this package.** Consumers verify with the
   protocol package (`charter_agreement_protocol`) alone. If you are tempted
   to add this library to a verifier's deps, you are building the wrong side.

8. **Errors are closed atoms.** Do not pattern-match on error detail beyond
   the documented set; do not log inspect terms as though they might carry
   key material (they cannot — the vocabulary is value-free by construction).

9. **Mint at the protocol's current revision.** Claims you hand to a sign
   path carry `"protocol_revision" => 2` — CAP 0.2's emission rule mints
   exactly `("Ed25519", 2)`, and revision-1 claims are refused at the
   producer before the key is used. Retained revision-1 artifacts keep
   verifying (cross-revision composition); only NEW claims must say 2.
