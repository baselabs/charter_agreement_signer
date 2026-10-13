# Errors

Errors are closed and value-free. They contain no key material, message
bytes or claims content. Public functions return `{:error, reason}` with
one of these reasons.

| Reason | Meaning | Caller action |
|---|---|---|
| `:invalid_key_handle` | Malformed handle, missing or crashing identity callback, a snapshot without a non-empty binary kid and binary key, or CAP's `:signing_key_invalid` for the selected algorithm. | Fix the handle or snapshot. |
| `:signing_failed` | The custody callback rejected, crashed, returned an invalid signature shape or length, or signed with a key different from the snapshot. | Check custody and rotation handling. |
| `{:refused, :signing_refused}` | CAP's R1-R3 checks found contradictory claims, equivocation, missing ancestry coverage, or a termination inconsistent with the governing view. | Correct the claims or retained view. |
| `{:refused, :signing_key_mismatch}` | No active descriptor key matches the snapshot kid, public key bytes and selected key algorithm in the holder's own context. | Align the handle with the descriptor for the signing role. |
| `:algorithm_unsupported_on_substrate` | The runtime cannot verify the artifact or a context artifact's required algorithm. | Use a runtime that supports the required algorithm. |
| `{:invalid_input, code}` | Options or CAP's pre-sign checks rejected input. Codes include `:invalid_type`, `:invalid_limits`, `:invalid_profile`, `:algorithm_unsupported`, `:algorithm_outside_profile`, `:revision_outside_profile`, `:signing_input_invalid`, `:limit_exceeded`, `:descriptor_chain_invalid`, `:acceptance_claims_mismatch`, `:termination_claims_mismatch` and `:receipt_claims_mismatch`. Other CAP preparation codes pass through in this shape. | Correct the input according to CAP's error reference. |
| `:verification_failed` | CAP's finish step rejected what its pre-sign step approved, after the signature passed the wrong-key guard. | Report the reproducible CAP contract failure. |

Option checks run before the snapshot: normalize options, resolve limits,
profile, then algorithm. An absent or `nil` algorithm selects `"Ed25519"`;
anything outside `"Ed25519"` and `"ML-DSA-65"` returns
`{:invalid_input, :algorithm_unsupported}`. A malformed profile returns
`{:invalid_input, :invalid_profile}`. Explicit `nil` limits or profile are
malformed. Only descriptor signing accepts `:predecessor`.

The snapshot check validates only its shape. CAP validates key shape for
the selected algorithm and checks the holder's own descriptor membership.
A bare-revision receipt skips membership because a revision does not name
its signing key; key shape and runtime support still apply.

Every preparation refusal occurs before `sign/2`. Limits cover the whole
set read, including counterparties' artifacts, and the final compact.
Malformed context types return `{:invalid_input, :invalid_type}`; malformed
fields inside retained facts return CAP's typed context errors.

CAP maps `:signing_refused` and `:signing_key_mismatch` to the refusal
shape, `:signing_key_invalid` to `:invalid_key_handle`, and substrate errors
to the top-level substrate reason. Every other preparation error is
`{:invalid_input, code}`. Every finish error is `:verification_failed`.

The vocabulary is additive within a minor line. Changed error shapes or
codes require a minor release and an upgrade note.
