# 2. The CAP dependency pin: three-part, double-pinned, deliberate

Date: 2026-08-26

## Status

Accepted. Reverses the scaffold's two-part pin — a real correction, not a
formalization. Found by the release-readiness adversarial review (2026-08-26)
on three authorities at once.

## Context

The scaffold shipped `{:charter_agreement_protocol, "~> 0.1"}`. In Hex's
semantics that admits every future pre-1.0 CAP — but CAP's own governance
says its package semver carries NO compatibility promise (`spec/evolution.md`:
the `protocol_revision` claim is the sole wire identity, and evolution never
happens via parallel artifact family, media type, or header shape), and
CAP's README instructs dependents to pin `"~> 0.1.0"`. A 0.2.0 CAP with
verdict-flipping producer/verify changes would be auto-resolved by every
fresh consumer while this repo's gates stay green against the locked 0.1.0 —
the published metadata vouching for a span no gate ever tested. Hex metadata
is unfixable after publication (yank is the only remedy), so this had to be
corrected BEFORE the first release.

## Decision

1. The requirement is the three-part `"~> 0.1.0"` — exactly CAP's own
   dependent guidance, admitting only the tested 0.1.x line.
2. The pin is double-pinned BARA-style (ADR-0010 there): the wall test
   asserts the exact requirement string AND the exact locked version; drift
   in either reds the suite. A silent `mix deps.update` cannot pass.
3. Every bump is a deliberate, reviewed release of THIS library: the
   requirement, the library lock, and the example lock move in ONE commit,
   with the `lib/` delta classified against CAP's changelog
   (verdict-flipping changes are never absorbed silently).

## Consequences

Consumers wanting a newer CAP must wait for (or PR) a reviewed signer
release — the conservative cost of depending on a protocol whose semver
promises nothing. The example project carries a lock-parity test so the
integration canary never drifts from the library's tested span.
