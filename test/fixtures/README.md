# Signer cases

`signer_cases.json` is a language-neutral request table. Its root has
`format_version: 1`, `keys`, `contexts` and `cases`. All claims use JSON
values. All key bytes and seeds use unpadded canonical base64url. Seeds are
public test material: 32-byte Ed25519 seeds or 32-byte FIPS 204 ML-DSA-65
seeds. They belong only to the test custody handles.

Each key entry contains `algorithm`, `kid`, `seed` and `public_key`. A
snapshot returns the entry's kid and public key; signing uses its seed.
Some refusal entries intentionally advertise a different public key.

Each case contains a unique `id`, `kind` (`descriptor`, `acceptance`,
`termination`, `receipt`), a `key` entry name, JSON `claims`, `context`,
`options` and `expected`. A string context refers to `contexts`; other JSON
values are literal malformed contexts or `null`. Context records are:

- `set`: raw `revisions`, `descriptors`, `acceptances`, `terminations` arrays.
- `chain`: the same arrays, verified into retained chain context at default
  limits and full profile before the signing request.
- `revision`: `text`, decoded into bare revision context.
- `predecessor`: `descriptors`, verified genesis first to obtain the last
  descriptor's facts. This context becomes the descriptor-only predecessor
  option.

Omitted options use the signer's defaults. `algorithm` is a literal JSON
value. `limits` overrides named fields of default limits. A valid `profile`
has `algorithms` and inclusive `revisions: [min, max]`; other values remain
malformed inputs.

Expected outcomes contain `shape`, `code`, `snapshot_called` and
`custody_called`. Success is `shape: "ok", code: null`. Nested errors use
`shape: "refused"` or `"invalid_input"` and their code; top-level errors
repeat the atom spelling in both fields. A success must call each callback
once. A refusal must never call custody. Ed25519 successes also contain the
exact `compact`. ML-DSA successes are compared through public verification,
since their signatures can vary.

`expected_limited` replaces `expected` when ML-DSA-65 is unverifiable. ML-DSA
predecessor context requires prior verification on a capable runtime; those
cases carry the suite's `requires_mldsa_substrate` tag. The limited suite
still exercises all four signing kinds and a context-only substrate refusal.

`signer_cases_test.exs` executes each row as a real signing call, traces
callback counts and independently verifies every success. The table also
includes both same-kid receipt candidates in a view with two accepted
revisions. The exact Ed25519 compacts were generated with CAP's canonical
framing and real seed signatures independently of the signer under test.
