# Errors

The signer's error vocabulary is closed and value-free: no key material,
message bytes, or claims content ever appears in an error, and callers may
pattern-match on exactly the shapes below.

## The closed set

| Error | Meaning | Caller action |
|---|---|---|
| `:invalid_key_handle` | The handle is malformed (`{module, ref}` with a non-module first element), the module is missing, a callback crashed (raise/exit/throw), or the `key_identity/1` snapshot was not a non-empty `kid` plus a 32-byte Ed25519 public key. | Fix the handle or the custody behind it. |
| `:signing_failed` | `sign/2` rejected, returned a non-64-byte signature, violated the `{:ok, _} \| {:error, _}` contract, or — the load-bearing case — the signature did not verify against the snapshot's public key (the wrong-key guard). | Escalate to the operator; a wrong-key sign is a custody misconfiguration or a rotation race, never something to retry with the same handle state. |
| `{:refused, :signing_refused}` | CAP's honest-signer refusal (R1–R3): the acceptance/termination claims contradict the caller's own verified artifact set — false revision coordinates, an equivocating number, an ancestry that excludes an accepted head, a non-governing revision at the notice's effective time, an unlisted reason code, or a party not in the revision. The refusal happens BEFORE `sign/2` is called; no signature exists. | Fix the claims or the view. Never bypass by hand-building a signing input. |
| `{:invalid_input, code}` | CAP (or the opts normalization) rejected the input structurally. `code` is drawn from the protocol package's closed, architecture-gated vocabulary: `:signing_input_invalid` (claims shape — unknown member, wrong scalar type, or a `protocol_revision` below the protocol's emission revision: CAP 0.2+ mints exactly `("Ed25519", 2)` and its binding rule refuses revision-1 claims at mint — OR the handle snapshot's `kid` failing the protocol's charset/length gate, which the signer checks only for non-emptiness), `:compact_invalid` (a set member is not a compact JWS), `:signature_invalid` (defensive: unreachable through this library — a non-64-byte signature is `:signing_failed` before assembly; listed because CAP's assembler emits it on the raw path), `:invalid_limits` (caller-supplied limits malformed or out of range), `:invalid_type` (an opts argument that is neither a map nor a keyword list), and the rest of CAP's code table as the set evolves. | Fix the input per the protocol package's error reference. |
| `:verification_failed` | The post-sign CAP verify of the assembled artifact rejected it: the snapshot key is not pinned in the descriptor's `verification_keys` (or its `kid` does not match), or a successor descriptor was signed without `:predecessor` facts. | Align the handle's key with the descriptor you are signing, or supply the predecessor facts. |

## Reading order for a failure

1. `:invalid_key_handle` / `:signing_failed` — the custody boundary; nothing
   about the protocol is wrong.
2. `{:refused, _}` / `{:invalid_input, _}` — the claims-or-view side; CAP
   refused before any key was touched (`:refused`) or rejected the shape.
3. `:verification_failed` — the signed artifact and the verifying context
   disagree; the signature itself is fine.

## Stability

The atom set is closed and additive-only within the 0.x line; a removal or
rename is a breaking change and will follow the protocol package's
compatibility discipline. `{:invalid_input, code}` tracks the protocol
package's own gated vocabulary — codes appear here as CAP emits them, and
CAP gates both directions (an undeclared emission fails CAP's build).
