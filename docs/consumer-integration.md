# Consuming charter artifacts from this signer

This is the counterparty contract: how any OTHER party — the acceptor of
your charter, a receipt verifier, an auditor — consumes the artifacts this
signer produces. The counterparty depends **only on the public
`charter_agreement_protocol` package (CAP)** — never on this library (the
dependency-direction wall). This guide is deliberately transport-agnostic:
CAP defines no transport and no wire format beyond the artifacts themselves,
and this library does not invent one.

> **Runnable reference:** `examples/charter_lifecycle` implements this whole
> contract end-to-end — the accepting side verifies every artifact this
> signer's issuing side produces, using CAP only. Read it alongside this
> prose.

## 1. What the signer produces

Each entry point returns `{:ok, %{kind => compact}}` — one attached
compact-JWS binary per artifact:

| Artifact | Compact `typ` | Verify with |
|---|---|---|
| Party descriptor | `cap+party` | `CAP.verify_descriptor/3` (genesis: predecessor `nil`; successors: the prior descriptor's facts) |
| Acceptance | `cap+acceptance` | `CAP.verify_acceptance/4` |
| Termination notice | `cap+termination` | `CAP.verify_termination/4` |
| Receipt | `cap+receipt` | `CAP.verify_receipt/3` |

Every artifact was verified through the matching CAP function BEFORE this
signer returned it — but that is the signer's own discipline, not something
the counterparty can observe. The counterparty re-verifies from scratch.

## 2. The counterparty's verify kit (CAP only)

```elixir
alias CharterAgreementProtocol, as: CAP
limits = CAP.Limits.default()

# Descriptors: verify each party's chain (genesis first), retain the facts.
{:ok, issuer_facts} = CAP.verify_descriptor(issuer_descriptor_compact, nil, limits)

# The charter revision itself is UNSIGNED canonical bytes — integrity is its
# content digest; decode it for the revision contract.
{:ok, revision} = CAP.decode_charter_revision(revision_bytes, limits)

# The descriptor chain view the set-aware verifies need:
{:ok, chain} = CAP.verify_descriptor_chain([issuer_descriptor_compact], limits)

# An acceptance the counterparty received:
{:ok, acceptance_facts} =
  CAP.verify_acceptance(acceptance_compact, revision, chain, limits)

# A receipt (revision-only or full-chain context):
{:ok, receipt_facts} = CAP.verify_receipt(receipt_compact, revision, limits)
```

## 3. The counterparty's obligations (where its own signing host would call this library)

If the counterparty is also a charter party (the bilateral case — the
acceptor countersigns), ITS signing side may use this library with its own
key handle, exactly as the issuing side did. Three obligations from CAP's
governance apply to any host that signs:

1. **Atomic key custody.** `kid` and the public key resolve in one
   `key_identity/1` snapshot; the party descriptor's `verification_keys`
   pins exactly the key the handle signs with.
2. **Post-sign verification.** Verify what you signed, through CAP, before
   releasing the artifact (this library does it on every path; a host that
   signs by hand owes the same).
3. **Closed, value-free failures.** A signing host never echoes claims
   content, raw protocol errors, or key material into logs, HTTP bodies, or
   other cross-boundary channels. CAP's failures are value-free precisely so
   they are safe to relay; collapse raw errors to closed atoms at your
   boundary. `examples/charter_lifecycle`'s exchange module shows the
   collapse in code.

## 4. What verification proves (and does not)

CAP verifies canonical structure, signature validity against the pinned
descriptor keys, revision/acceptance/termination semantics within the
supplied view, and equivocation within that view. It does NOT establish
organizational identity, legal validity, descriptor freshness, or authority
to transact — those are host policy. Nothing in this chain authorizes
anything: CAP never authorizes, and neither does its signer.
