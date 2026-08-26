# 5. The closed error vocabulary and the CAP-code mapping

Date: 2026-08-26

## Status

Accepted. Records decisions in force since the scaffold; the mapping table
was tightened by the 2026-08-26 alignment audit's fix pass.

## Context

CAP returns typed, value-free failures (`%CharterAgreementProtocol.Error{}`).
A companion signer must decide what ITS callers see: CAP's structs (rich but
coupled to another package's closed vocabulary), free-form terms (leaky), or
its own closed set. The scaffold chose its own closed set; the audit and the
release pass hardened it.

## Decision

1. **Five shapes, closed and value-free:** `:invalid_key_handle`,
   `:signing_failed`, `:verification_failed`,
   `{:refused, :signing_refused}`, and `{:invalid_input, code}` where
   `code` is drawn from CAP's closed, architecture-gated code vocabulary.
   No key material, message bytes, or claims content in any error — ever.
2. **The refusal is its own shape.** `{:refused, :signing_refused}` (CAP's
   R1–R3 honest-signer rules firing BEFORE the key is used) is operationally
   distinct from `:signing_failed` (custody) and `:invalid_input` (shape);
   collapsing any two misroutes the operator. The telemetry class axis
   (ADR-0003) mirrors this exactly.
3. **The mapping is total by construction.** Every branch of every public
   path was escape-analyzed (the audit's branch trace): raw CAP errors are
   destructured and re-wrapped; no `%Error{}` escapes. `:invalid_type`
   covers a malformed opts argument (maps and keyword lists are both
   accepted); `:signature_invalid` is documented as defensively unreachable
   through this library (a non-64-byte signature is `:signing_failed`
   before assembly).
4. **Additive-only within the 0.x line**; a removal or rename is a breaking
   change (per `docs/upgrading.md`).

## Consequences

Callers pattern-match on exactly the documented set. The cost — dropping
CAP's `subject` detail at this boundary — is deliberate: the signer's
boundary is a custody boundary, and value-free failures are what make it
safe to log and relay. Diagnosing a specific `{:invalid_input, code}` means
reproducing against CAP directly, which the errors doc points to.
