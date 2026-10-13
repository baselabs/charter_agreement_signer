# Charter Agreement Signer

Holder-side companion signer for the [Charter Agreement
Protocol](https://hex.pm/packages/charter_agreement_protocol) (CAP).
CAP checks claims, context, limits, profile and the holder's own descriptor
key before this library calls the custody handle. The handle signs CAP's
canonical bytes; the signer verifies the raw signature against its atomic
snapshot, then CAP assembles and publicly verifies the compact.

**The private key never enters the library.** Callers supply a
`{module(), term()}` handle backed by their own custody. Verifiers depend
only on CAP. Runtime dependencies are CAP and the value-free `:telemetry`
signing span.

## Installation

```elixir
def deps do
  [
    {:charter_agreement_signer, "~> 0.5.0"}
  ]
end
```

## What it is

A charter party proves mutual assent by signing offers, acceptances and
countersignatures with the party key its descriptor pins. This
signer is what a host calls to *produce* those signatures. Every path runs
the same shared tail:

| Function | Artifact | Post-sign verify |
|---|---|---|
| `sign_descriptor/3` | party descriptor (`typ cap+party`) | `CAP.verify_descriptor/4` |
| `sign_acceptance/4` | acceptance (`cap+acceptance`) | `CAP.verify_acceptance/5` |
| `sign_termination/4` | termination notice (`cap+termination`) | `CAP.verify_termination/5` |
| `sign_receipt/4` | effect receipt (`cap+receipt`) | `CAP.verify_receipt/4` |

Every call resolves limits, profile and algorithm before taking one atomic
`key_identity/1` snapshot. The header kid comes only from that snapshot.
`CAP.prepare_signing/5` checks the public key and context, including R1-R3
for acceptance and termination, before `sign/2`. Key mismatches return
`{:error, {:refused, :signing_key_mismatch}}`; contradictory claims return
`{:error, {:refused, :signing_refused}}`.

The wrong-key guard remains between custody and `CAP.finish_signing/2`.
A signature from another key returns `:signing_failed`. CAP's finish step
assembles under the caller's limits and runs the matching public verifier
with CAP's retained context and profile before a success returns.

All four functions accept `:algorithm`, `:limits` and `:profile` in a map
or keyword list. Only descriptors accept `:predecessor`. A successor must
supply verified predecessor facts. For acceptance and termination, the caller's profile covers the revision,
the signing party's own descriptor chain and the new artifact. CAP checks
the rest of the set under the full profile. A receipt's profile covers the
whole retained set; a descriptor's covers its predecessor history and new
artifact. Limits bound the whole set read and the final compact.
Malformed profiles return `{:error, {:invalid_input, :invalid_profile}}`.

```elixir
{:ok, profile} = CharterAgreementProtocol.Capability.Profile.new(
  algorithms: ["Ed25519"], revisions: {1, 2})
{:ok, %{descriptor: compact}} = CharterAgreementSigner.sign_descriptor(
  claims, {MyCustody.Handle, ref}, profile: profile,
  limits: CharterAgreementProtocol.Limits.default())
```

Claims you sign mint at the protocol's current revision; CAP 0.3's emission
rule is exactly (`"Ed25519"`, `protocol_revision` 2) or (`"ML-DSA-65"`,
`protocol_revision` 3), selected by the `:algorithm` option (default
`"Ed25519"`); claims carry the matching `"protocol_revision"`, and retained
revision-1/2 artifacts keep verifying (cross-revision composition). See
[docs/upgrading.md](docs/upgrading.md).

## Key custody

The library never holds a key. A caller passes a `{module, ref}` handle; the
module implements `sign/2` and `key_identity/1` (required; every CAP header
carries the signing `kid`) plus optional `public_key/1` / `thumbprint/1` for
caller-side self-checks, against its own key store. A production party points
the handle at an HSM or KMS; the in-memory reference handle used in tests
compiles only in the test environment and never ships.

## Telemetry

The four signing entry points emit a closed, value-free two-event surface,
`[:charter_agreement_signer, :sign, :start|:stop]`, whose class axis mirrors
the error vocabulary exactly (a refusal is `:refused`, a post-sign verify
failure is `:verification_failed`; neither ever wears the `:signing_failed`
custody label). No handler is attached by default. See
[docs/telemetry.md](docs/telemetry.md).

## Examples

- [`examples/charter_lifecycle`](https://github.com/baselabs/charter_agreement_signer/tree/master/examples/charter_lifecycle):
  a complete bilateral charter (descriptors → genesis revision → dual
  acceptances → receipt → mutual termination) with a CAP-only counterparty
  verifying every artifact, the wrong-key rejection, and its own CI lane. No
  transport; CAP defines none and this repo invents none (`docs/adr/0004`).
- [`examples/charter_signing_roundtrip.livemd`](https://github.com/baselabs/charter_agreement_signer/blob/master/examples/charter_signing_roundtrip.livemd):
  the Livebook walkthrough.

## Development

```bash
mix deps.get
MIX_ENV=test mix ci
```

A bare `mix ci` refuses with the fix in hand (a `:dev` boot skips
`test/support/`; the warnings trap). The developer platforms are macOS and
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
[`priv/signer-source.json`](https://github.com/baselabs/charter_agreement_signer/blob/master/priv/signer-source.json) and
[`priv/verifier-source.json`](https://github.com/baselabs/charter_agreement_signer/blob/master/priv/verifier-source.json).
`MIX_ENV=test mix typescript.sources` fetches public `main`, refuses a pin
outside that branch, refuses a newest pin change that moves backward on the
first-parent history (so it needs a full git clone), and extracts both
source trees under `_build/`. `mix typescript.sources --cached` uses the
last fetched public refs without a network fetch; it still checks
reachability and forward movement. `mix typescript.sources --check` checks
the stamps. `mix typescript.check` requires current stamps and builds both
sources. It runs the signer's own tests with the npm dependencies in its
committed lockfile (verifier 0.5.0 at the current signer pin) and requires
at least the pin's `minimum_tests` to run, all passing. It then signs a
descriptor with the pinned TypeScript signer and verifies it under CAP. The
separate verifier source pin names 0.6.0. The Elixir suite also runs the
language-neutral [signer case table](test/fixtures/README.md), checking
callback counts, refusal codes, exact Ed25519 compacts and verified ML-DSA
successes. The pinned TypeScript suite does not execute that table.

Supported toolchain, enforced in code before anything compiles: the tested
Elixir 1.19.x–1.20.x lines (`~> 1.19`; anything outside the range refuses
with `Mix.ElixirVersionError`; 1.19.x rides the OTP-28 lane) on Erlang/OTP
28 or 29 (config/config.exs asserts the OTP build; a same-Elixir binary
built on an unsupported OTP would otherwise compile incompatible BEAMs
silently). `.tool-versions` pins the dev lane, CI's matrix covers the
supported lanes, and all of it moves in ONE commit. Selecting the ML-DSA-65
emission pair additionally needs the OTP runtime linked against
OpenSSL ≥ 3.5; FIPS 204 reached OpenSSL in 3.5.0, and a runtime linked
against OpenSSL 3.0.x cannot generate or verify ML-DSA keys.

## Scope

Verifiers use the protocol package. This signer produces artifacts through
a caller's key handle. It has no transport or persistence layer and does
not evaluate charter terms or authorize operations.

## Protocol dependency

This tree uses the local CAP 0.6.0 build at `../cap-060`; the example resolves
the same build. CAP owns pre-sign checks, context derivation and final
verification. CAP 0.5.0's distinct-party checks also apply: re-verify views
stored under CAP 0.4.x. [docs/upgrading.md](docs/upgrading.md) lists the
changed outcomes and migration requirements.
