# Signer cases

`signer_cases.json` is a language-neutral request table. Its root has
`format_version: 1`, `keys`, `contexts` and `cases`. All claims use JSON
values. All key bytes and seeds use unpadded canonical base64url. Seeds are
public test material: 32-byte Ed25519 seeds or 32-byte FIPS 204 ML-DSA-65
seeds. They belong only to the test custody handles.

Each key entry contains `algorithm`, `kid`, `seed` and `public_key`. The
optional `mixed_order: true` selects real mixed-order signing in `RawKey`. A
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

`expected_limited` replaces `expected` when ML-DSA-65 is unverifiable.
`ml-successor-ok` and `ml-successor-wrong` run in both suites. On the limited
runtime, both return `algorithm_unsupported_on_substrate`, with one snapshot
call and no custody call. CAP re-verifies the predecessor's signed lineage
before checking successor linkage, so even the wrong predecessor returns
the substrate error there.

`mldsa_predecessors.etf` retains the public predecessor facts returned by
CAP 4469403 on a capable runtime. It contains no private keys. The runner
checks its lineage against the table and, on a capable runtime, compares
the entire facts record with fresh public verification. The limited runtime
passes these retained facts to the real signer, whose CAP preparation
re-verifies the signatures. Regenerate the fixture on a capable runtime
with `MIX_ENV=test mix run --no-start scripts/build_mldsa_predecessors.exs`.
Cases that need a freshly verified ML-DSA chain context still carry the
suite's `requires_mldsa_substrate` tag. The limited suite also exercises all
four signing kinds and a context-only substrate refusal.

`signer_cases_test.exs` executes each row as a real signing call, traces
callback counts and independently verifies every success. The table also
includes both same-kid receipt candidates in a view with two accepted
revisions. The exact Ed25519 compacts were generated with CAP's canonical
framing and real seed signatures independently of the signer under test.

The runner requires at least 121 rows, unique ids, and every id in its
explicit required list. It checks that refusals never call custody even
if a row's expected callback count says otherwise. Fault pairs pin each
adjacent signer step: options before limits, limits before profile, profile
before algorithm, algorithm before snapshot, and snapshot before claims or
context. Single
fault rows cover invalid limits, unknown options and malformed snapshots.

The successor key row checks a key absent from the predecessor. The
wrong-key row uses a real seed that differs from the snapshot key and
expects `signing_failed` after one custody call. Receipt and termination
rows also exclude context algorithms and revision numbers. A verified
ML-DSA chain context requires a capable runtime.

For acceptance and termination, profile rows admit the revision, the
signing party's own descriptor chain and the new artifact. Excluding only
the counterparty's descriptor algorithm must still sign. The rest of the
set is checked under the full profile. Excluding the signing party's own
chain or the revision rejects before custody. A receipt's profile covers
the whole retained set, pinned by `receipt-profile-counterparty`; a
descriptor's covers its predecessor history.

The key rows reject a public key with no curve point and both negative-zero
encodings before custody. The mixed-order row signs with the seed's public
point plus the order-two point. The existing `RawKey` handle computes a real
signature with an even challenge, which cancels that order-two component.
CAP checks the raw signature and the finished descriptor. The compact was
built through CAP with a signature checked by independent Edwards arithmetic.

The profile and malformed limits regressions run in both runtime suites.
CAP validates incomplete limits structs and improper profile lists without
raising. Malformed retained context fields use `invalid_type`.

`termination-profile-counterparty` uses a governing revision and succeeds
when only the counterparty's descriptor algorithm is outside the profile.
`termination-profile-own-chain` and `termination-profile-context-revision`
reject the signing party's descriptor history and the context revision,
respectively, before custody. `acceptance-excluded-context` returns
`algorithm_unsupported_on_substrate` on the limited runtime: the full-profile
set check needs ML-DSA verification before the caller's profile is applied.

A real termination call cannot reach `termination_claims_mismatch` for an
unheld descriptor in a valid set. A governing revision must be accepted;
its verified acceptances already require the named party descriptor in a
held chain. An unheld successor in an unaccepted revision fails the earlier
governing check with `signing_refused`, pinned by
`termination-unheld-successor`. No synthetic facts bypass that check here.
