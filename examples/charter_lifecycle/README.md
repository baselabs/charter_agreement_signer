# charter_lifecycle — a complete bilateral charter, runnable

An issuer host and an acceptor host, each with its own DEMO-ONLY custody,
form a charter through the real signer; a CAP-only `Counterparty` verifies
every artifact the way a real counterparty would. No transport — the
exchange between hosts is an explicit in-process boundary module
(`CharterLifecycle.Exchange`); swap it for yours without touching anything
else. CAP defines no wire format, and this repo invents none.

```bash
mix deps.get
mix run -e 'IO.inspect(CharterLifecycle.run(), label: "lifecycle")'
mix test
```

`run/0` executes: both party descriptors → the genesis revision → the dual
acceptances (offer + countersignature) → a verified governing view → an
effect receipt → a mutual termination → and the wrong-key negative (a rogue
custody is refused loudly). Every hop crosses `Exchange`, which collapses
failures to closed atoms at the boundary — the discipline
`docs/consumer-integration.md` §3 obligates any host to apply.

## Module map

| Module | Role | May depend on |
|---|---|---|
| `CharterLifecycle.IssuerHost` / `AcceptorHost` | signing hosts (custody + claims + sign calls) | the signer + CAP |
| `CharterLifecycle.Counterparty` | the receiving side: verifies everything | **CAP only** (test-enforced) |
| `CharterLifecycle.Exchange` | the inter-host boundary; closed-atom error collapse | stdlib |
| `CharterLifecycle.Keys` | DEMO-ONLY in-process custodies (incl. the rogue probe) | :crypto |

DEMO-ONLY: the key handles hold seeded in-process pairs. Real custody is an
HSM/KMS behind each host's own handle module (`docs/recipes.md` in the
library).
