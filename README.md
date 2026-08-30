# Charter Agreement Signer

Holder-side companion signer for the [Charter Agreement
Protocol](https://hex.pm/packages/charter_agreement_protocol) (CAP). The
protocol package produces the deterministic RFC 7515 signing input for each
charter artifact (party descriptor, acceptance, termination notice, receipt)
and **refuses to sign** — it is a pure, verifier-only package with no key
parameter, signer callback, or custody handle. This library takes a local key
handle and a claims map and produces the signed compact form. **The private
key never enters the library** — callers supply a `{module(), term()}` handle
whose module implements the signing callbacks against their own custody (an
HSM, a KMS, or an in-process key in test).

Verifiers depend only on the protocol package, never on this signer. This
package occupies the seat the protocol's governance reserved for a companion
signer (the `bounded_authority_report_adapter` pattern applied to CAP), and it
depends on exactly one package: the public `charter_agreement_protocol`.

## Installation

```elixir
def deps do
  [
    {:charter_agreement_signer, "~> 0.2"}
  ]
end
```

## What it is

A charter party proves mutual assent — offer, acceptance, countersignature —
by signing protocol artifacts with the party key its descriptor pins. This
signer is what a host calls to *produce* those signatures. Every path runs
the same shared tail:

| Function | Artifact | Post-sign verify |
|---|---|---|
| `sign_descriptor/3` | party descriptor (`typ cap+party`) | `CAP.verify_descriptor/3` |
| `sign_acceptance/4` | acceptance (`cap+acceptance`) | `CAP.verify_acceptance/4` |
| `sign_termination/4` | termination notice (`cap+termination`) | `CAP.verify_termination/4` |
| `sign_receipt/4` | effect receipt (`cap+receipt`) | `CAP.verify_receipt/3` |

Three disciplines are load-bearing on every path:

1. **Atomic identity snapshot.** The protected header's `kid` and the public
   key are resolved from ONE `key_identity/1` callback call — a stateful
   handle cannot split them across a key-rotation race, and a caller cannot
   name a `kid` the handle does not control (the signer injects the snapshot
   kid; the claims carry no key material).
2. **Honest-signer refusals before the key is used.** For acceptances and
   terminations, CAP's producer runs the R1–R3 refusal rules (claims-truth,
   no-equivocation, ancestry/governing coverage) against the caller's own
   verified artifact view *before* this library ever calls `sign/2`. A
   refusal surfaces as `{:error, {:refused, :signing_refused}}`.
3. **Wrong-key guard + post-sign verify.** The raw signature is verified
   against the snapshot's public key before assembly (a `{pub_A, sig_B}`
   artifact is `:signing_failed`, never a silent false-success — proven
   red-capable in the test suite), and the assembled compact must then pass
   the matching CAP verify function before it is returned.

## Key custody

The library never holds a key. A caller passes a `{module, ref}` handle; the
module implements `sign/2` and `key_identity/1` (required — every CAP header
carries the signing `kid`) plus optional `public_key/1` / `thumbprint/1` for
caller-side self-checks, against its own key store. A production party points
the handle at an HSM or KMS; the in-memory reference handle used in tests
compiles only in the test environment and never ships.

## Telemetry

The four signing entry points emit a closed, value-free two-event surface —
`[:charter_agreement_signer, :sign, :start|:stop]` — whose class axis mirrors
the error vocabulary exactly (a refusal is `:refused`, a post-sign verify
failure is `:verification_failed`; neither ever wears the `:signing_failed`
custody label). No handler is attached by default. See
[docs/telemetry.md](docs/telemetry.md).

## Examples

- [`examples/charter_lifecycle`](https://github.com/baselabs/charter_agreement_signer/tree/master/examples/charter_lifecycle) —
  a complete bilateral charter (descriptors → genesis revision → dual
  acceptances → receipt → mutual termination) with a CAP-only counterparty
  verifying every artifact, the wrong-key rejection, and its own CI lane. No
  transport — CAP defines none and this repo invents none (`docs/adr/0004`).
- [`examples/charter_signing_roundtrip.livemd`](https://github.com/baselabs/charter_agreement_signer/blob/master/examples/charter_signing_roundtrip.livemd) —
  the Livebook walkthrough.

## Development

```bash
mix deps.get
mix ci
```

`mix ci` reproduces the CI pipeline locally for BOTH projects: format,
warnings-as-errors compilation, Credo, the full test suite (including the
wrong-key gate, the refusal battery, and the dependency-direction wall), the
coverage floor, Dialyzer, doc warnings, dependency audits, the
shipped-artifact package census with a consumer smoke against the unpacked
package, the release-candidate reproducibility gate, and the
`examples/charter_lifecycle` battery (its own audits, format, compile,
lint, and the bilateral round-trip tests).

Requires Elixir 1.20+ (developed on 1.20 / OTP 29) — the protocol package's
own floor.

## What this is not

This library never verifies third-party artifacts (verifiers use only the
protocol package), never transports or persists anything, never evaluates
charter terms, and never authorizes anything — CAP never authorizes, and
neither does its signer.
