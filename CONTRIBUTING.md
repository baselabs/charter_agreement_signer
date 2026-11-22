# Contributing

Contributions must preserve the invariants the repository exists to hold: the
dependency-direction wall (the library depends only on the public protocol
package — never a runtime, never a transport), the atomic-snapshot key
discipline, the closed-atom value-free error vocabulary, and the test-only
status of `test/support/` (nothing there ships).

## Toolchain

The supported toolchain is enforced in code, before anything compiles: the
tested Elixir 1.19.x and 1.20.x lines (mix.exs's `~> 1.19`; anything outside refuses
with `Mix.ElixirVersionError`) on Erlang/OTP 28 or 29 (config/config.exs
refuses any other OTP major). You cannot compile on a wrong toolchain by
accident. `.tool-versions` pins the dev lane (asdf); CI covers three
supported cells: Elixir 1.19.5 and 1.20.2 on OTP 28, and 1.20.3 on OTP 29.
Lockstep: mix.exs's range, config/config.exs's supported-OTP set,
`.tool-versions`, and CI's matrix move together in ONE commit; divergence
between them is a defect.

Dependency currency is mechanical: `scripts/check_deps_current.exs` (wired
into CI and `mix ci`) exits nonzero on any resolvable `mix hex.outdated`
drift; anything deliberately below latest carries an inline reason in
mix.exs. `mix hex.audit` and `mix deps.audit` run for both projects after every dependency move.

## Before a pull request

Run the covering tests on the maintainers' build box, never on a workstation.
A configured private checkout routes the covering Mix tasks there with the
maintainers' remote-run tooling.
Public repositories have no build-box checkout; their checks run in qualification
CI at landing. Nothing compiles or tests on a workstation.

Land the full commit through the maintainers' landing tool. Qualification includes
formatting, warnings-as-errors compilation, Credo, tests, merged coverage, Dialyzer,
docs, both dependency audits, package checks and the pinned TypeScript checks.
The supported runtime matrix and real capability-limited lane are CI jobs.
`MIX_ENV=test` is required so test support compiles. Follow
[the maintainers' release process](https://github.com/baselabs/charter_agreement_signer/blob/master/docs/release.md) for a version change.

## Windows

The developer platforms are macOS and Linux. Windows developers use WSL2
(clone inside the WSL filesystem, not under `/mnt/c`) and follow the Linux
path with the same commands; no native-Windows developer path is maintained.
CI runs on Linux only; macOS portability is a property of the developer
setup, not a CI lane. The ML-DSA-65 mint test needs an OTP build linked against OpenSSL 3.5
or newer on any platform (the same boundary as Ubuntu 24.04).

## Commits

Surgical pathspecs — `git commit -o <files>` or explicit paths, never `git
add -A` (process state and tool directories must never ride in a commit).
Single tree on `master`; no feature branches unless the maintainer asks.
Never `git stash`.

## Tests and gates

- New behavior ships red-first: write the test, watch it fail for the
  intended reason, then make it green.
- A new gate must be proven RED by a named mutation before it counts (plant
  the contract violation, confirm the gate fires, restore). A gate that
  cannot go red is a rubber stamp — the wrong-key gate in this repo carries
  its own non-vacuity proof (the rogue signature is shown structurally
  assemblable, so the guard is the only rejection point).
- Behavior-CHANGING work greps the tests for the OLD contract before
  changing it.

## Protocol dependency bumps

A `charter_agreement_protocol` version bump is a deliberate, reviewed change
— the wall test and the package census pin the shipped dependency set, and a
bare `mix deps.update` reds the gates by design. Every bump moves the
requirement + the lock in ONE commit, with the `lib/` delta classified
against the protocol package's changelog (verdict-flipping changes are
never absorbed silently).

## Docs

Docs for a capability ship in the same landing as the capability. The
doc-currency tripwire (the dependency-direction test's documentation
assertions) checks the shipped guides name the live API — if you rename an
API, fix the docs in the same commit; the suite will tell you.
