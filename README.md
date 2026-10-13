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
uses the public `charter_agreement_protocol` and `:telemetry` for its closed
signing-span events.

## Installation

```elixir
def deps do
  [
    {:charter_agreement_signer, "~> 0.4.0"}
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

Claims you sign mint at the protocol's current revision — CAP 0.3's emission
rule is exactly (`"Ed25519"`, `protocol_revision` 2) or (`"ML-DSA-65"`,
`protocol_revision` 3), selected by the `:algorithm` option (default
`"Ed25519"`); claims carry the matching `"protocol_revision"`, and retained
revision-1/2 artifacts keep verifying (cross-revision composition). See
[docs/upgrading.md](docs/upgrading.md).

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
MIX_ENV=test mix ci
```

A bare `mix ci` refuses with the fix in hand (a `:dev` boot skips
`test/support/` — the warnings trap). The developer platforms are macOS and
Linux. Windows developers use WSL2 (clone inside the WSL filesystem, not under
`/mnt/c`), which is the Linux path; no native-Windows developer path is
maintained. Developer portability across macOS and Linux is a property of the
developer setup, proven on a developer machine, not a CI leg: CI runs on Linux
only.

`MIX_ENV=test mix ci` runs the library checks (format, warnings as errors,
Credo, tests, 100.0% coverage, Dialyzer, docs, dependency audits and currency,
package census and consumer smoke, and archive reproducibility), the
`examples/charter_lifecycle` battery, and the pinned TypeScript signer's own
suite, plus a build of the pinned verifier. It needs Node 24.8 or newer, Git,
tar, and network access to Hex, GitHub and npm. CI runs these checks in
separate Linux jobs; setup, the Elixir/OTP matrix and the capability-limited
substrate job are additional CI checks.

The TypeScript repositories and full commit hashes are in
[`priv/signer-source.json`](priv/signer-source.json) and
[`priv/verifier-source.json`](priv/verifier-source.json).
`MIX_ENV=test mix typescript.sources` fetches public `main`, refuses a pin
outside that branch or behind the previous pin, and extracts both source
trees under `_build/`. `mix typescript.sources --cached` uses the last
fetched public refs without a network fetch; it still checks reachability
and forward movement. `mix typescript.sources --check` checks the stamps.
`mix typescript.check` requires current stamps and builds both sources.
It runs the signer's own tests with the npm dependencies in its committed
lockfile (verifier 0.5.0 at the current signer pin). The separate verifier
source pin names 0.6.0. This check does not compare Elixir and TypeScript
artifacts or refusals.

Supported toolchain, enforced in code before anything compiles: the tested
Elixir 1.19.x–1.20.x lines (`~> 1.19` — anything outside the range refuses
with `Mix.ElixirVersionError`; 1.19.x rides the OTP-28 lane) on Erlang/OTP
28 or 29 (config/config.exs asserts the OTP build — a same-Elixir binary
built on an unsupported OTP would otherwise compile incompatible BEAMs
silently). `.tool-versions` pins the dev lane, CI's matrix covers the
supported lanes, and all of it moves in ONE commit. Selecting the ML-DSA-65
emission pair additionally needs the OTP runtime linked against
OpenSSL ≥ 3.5 — FIPS 204 reached OpenSSL in 3.5.0, and a runtime linked
against OpenSSL 3.0.x cannot generate or verify ML-DSA keys.

## Scope

Verifiers use the protocol package. This signer produces artifacts through
a caller's key handle. It has no transport or persistence layer and does
not evaluate charter terms or authorize operations.

## Protocol dependency

This tree uses `charter_agreement_protocol ~> 0.5.0`, locked to 0.5.0 in the
library and example. CAP 0.5.0 requires distinct charter parties and rejects
held descriptor histories that no revision names. Re-verify stored views
when upgrading from CAP 0.4.x. The producer API and emitted signing bytes
are unchanged; [docs/upgrading.md](docs/upgrading.md) explains the changed
verdicts and the algorithm option migration.
