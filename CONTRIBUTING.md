# Contributing

Contributions must preserve the invariants the repository exists to hold: the
dependency-direction wall (the library depends only on the public protocol
package — never a runtime, never a transport), the atomic-snapshot key
discipline, the closed-atom value-free error vocabulary, and the test-only
status of `test/support/` (nothing there ships).

## Toolchain

The supported toolchain is enforced in code, before anything compiles: the
tested Elixir 1.20.x line (mix.exs's `~> 1.20` — anything outside refuses
with `Mix.ElixirVersionError`) on Erlang/OTP 28 or 29 (config/config.exs
refuses any other OTP major). You cannot compile on a wrong toolchain by
accident. `.tool-versions` pins the dev lane (asdf); CI covers both
supported lanes. Lockstep: mix.exs's range, config/config.exs's supported-OTP
set, `.tool-versions`, and CI's matrix lanes move together in ONE commit —
divergence between them is a defect.

Dependency currency is mechanical: `scripts/check_deps_current.sh` (wired
into CI and `mix ci`) exits nonzero on any resolvable `mix hex.outdated`
drift; anything deliberately below latest carries an inline reason in
mix.exs. `mix hex.audit` runs in the battery after every dependency move.

## Before a pull request

Run the per-file floor on EVERY file you touched:

```sh
mix format
MIX_ENV=test mix compile --warnings-as-errors   # NOT bare mix compile — it skips test/support
mix credo --strict
mix test
```

Then the one-command whole-repo check (every gate, aborts at the first red
step — the local parity of CI). It must boot under `MIX_ENV=test`; a bare
`mix ci` refuses with the per-shell invocation in the message:

```sh
MIX_ENV=test mix ci
```

`MIX_ENV=test` matters: a bare compile runs in `:dev` and misses warnings in
`test/support/`, which only compiles under `:test`.

## Windows

A plain clone is workable on Windows: install Elixir and Erlang/OTP from
their official installers on any supported lane, then the same commands with
PowerShell's environment syntax (`$env:MIX_ENV = "test"; mix ci`). The
battery is platform-portable end to end (the gate scripts spawn mix through
`cmd /c` on Windows and use no POSIX utilities), and the `windows-latest`
CI lane proves it on every push. The ML-DSA-65 mint test is excluded on
that lane when the Windows OTP build links an OpenSSL older than 3.5 — a
substrate boundary, not a portability one (same class as Ubuntu 24.04).

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
