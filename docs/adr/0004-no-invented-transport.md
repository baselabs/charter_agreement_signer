# 4. No invented transport: the in-process bilateral example topology

Date: 2026-08-26

## Status

Accepted. Records the release pass's deliberate divergence from the family
precedent — the decision the adversarial review was sharpest about.

## Context

The BARA precedent ships an HTTP example app (a Plug/Bandit receiver + a
Req-signing agent) and its consumer-integration guide recommends a wire
shape (two headers carrying the compacts). The release scoping for this
package considered cloning that topology wholesale ("full BARA parity").
Three findings blocked it:

1. **CAP's governance owns header shapes.** `spec/evolution.md`: protocol
   agility happens via revision advance, "never a parallel artifact family,
   media type, or header shape." A companion signer recommending a wire
   shape moves a protocol-layer decision into a package one layer below the
   protocol — governance capture.
2. **BARA's recommendation was grounded in a referent this repo lacks.**
   BARA's headers document a real first consumer's deployed contract ("the
   de facto contract of record is the first consumer's own integration").
   With zero consumers, recommending headers invents a contract ex nihilo.
3. **The wire shape is incomplete on its own terms.** CAP's artifact family
   includes unsigned charter revisions and descriptor chains; two
   compact-carrying headers cannot carry them without inventing a third
   channel plus ordering rules — compounding the invention.

## Decision

1. The example (`examples/charter_lifecycle`) runs over NO transport: two
   host modules with separate DEMO-ONLY custodies exchange compacts through
   an explicit in-process boundary module. Swap the boundary for a real
   transport without touching anything else.
2. `docs/consumer-integration.md` is transport-agnostic: it verifies
   artifacts, prescribes the counterparty's closed-atom collapse
   obligation, and recommends nothing on the wire.
3. A counterparty's verification module inside the example depends ONLY on
   CAP — enforced mechanically by a source-scan test, not prose.
4. If a transport is ever blessed for charters, that happens in CAP's
   governance, and this repo follows it then.

## Consequences

Full parity is preserved in every dimension the family's gates encode (own
mix project, own CI lane, lock parity, README, Livebook) while the one
surface that would have fabricated protocol surface is re-derived from what
this package actually is: a custody boundary over a transport-less protocol.
