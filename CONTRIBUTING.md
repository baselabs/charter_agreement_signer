# Contributing

Contributions must preserve the invariants the repository exists to hold: the
dependency-direction wall (the library depends only on the public protocol
package — never a runtime, never a transport), the atomic-snapshot key
discipline, the closed-atom value-free error vocabulary, and the test-only
status of `test/support/` (nothing there ships).

## Before a pull request

Run the per-file floor on EVERY file you touched:

```sh
mix format
MIX_ENV=test mix compile --warnings-as-errors   # NOT bare mix compile — it skips test/support
mix credo --strict
mix test
```

Then the one-command whole-repo check (every gate, aborts at the first red
step — the local parity of CI):

```sh
mix ci
```

`MIX_ENV=test` matters: a bare compile runs in `:dev` and misses warnings in
`test/support/`, which only compiles under `:test`.

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
