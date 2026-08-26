# examples/README.md

Two runnable references, neither shipped in the Hex package:

- **`charter_lifecycle/`** — a complete bilateral charter in one mix project:
  an issuer host and an acceptor host, each with its own (DEMO-ONLY)
  custody, form a charter through the real signer — descriptors, genesis
  revision, dual acceptances, a receipt, and a mutual termination — while a
  CAP-only `Counterparty` module verifies every artifact exactly the way a
  real counterparty would (never importing this repo's library). Its own CI
  lane runs it on every push.
- **`charter_signing_roundtrip.livemd`** — a Livebook walking the same
  round-trip interactively, including the wrong-key rejection.

The lifecycle example deliberately runs over NO transport: CAP defines none,
and this repository does not invent wire shapes (see
`docs/adr/0004-no-invented-transport.md` in the repo root). The "exchange"
between the two hosts is an explicit in-process boundary module — swap it
for your transport without touching anything else.
