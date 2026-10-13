# Sign telemetry

The signer emits a closed, value-free telemetry surface for its four signing
entry points (`sign_descriptor/3`, `sign_receipt/4`, `sign_acceptance/4`,
`sign_termination/4`). The library does NOT attach a handler — a fresh
application sees nothing until it attaches one.

## Events

| Event | Measurements | Metadata |
|---|---|---|
| `[:charter_agreement_signer, :sign, :start]` | `%{count: 1}` | `%{object: object}` |
| `[:charter_agreement_signer, :sign, :stop]` | `%{duration: native_monotonic_delta}` | `%{object: object, result_class: result_class}` |

`duration` is the monotonic time delta of the WHOLE signing span (entry point
to closed-atom return), in `:erlang.monotonic_time/0` units — aggregate only,
never per-callback timing (a per-custody-operation split would leak which
HSM operation was slow or failing).

## The closed axes

The object axis — one atom per signing entry point:

| Object | Entry point |
|---|---|
| `:descriptor` | `sign_descriptor/3` |
| `:receipt` | `sign_receipt/4` |
| `:acceptance` | `sign_acceptance/4` |
| `:termination` | `sign_termination/4` |

The result-class axis covers these closed span outcomes:

| Class | Span result | Operator reading |
|---|---|---|
| `:ok` | `{:ok, %{...}}` | nothing |
| `:invalid_input` | `{:error, {:invalid_input, code}}` | claims, context, options, limits or profile rejected before signing; the code never rides along |
| `:invalid_key_handle` | `{:error, :invalid_key_handle}` | caller wiring: malformed handle, faulting identity callback or invalid snapshot key |
| `:signing_failed` | `{:error, :signing_failed}` | custody misconfiguration or a wrong-key race — the highest-priority signal this surface offers |
| `:verification_failed` | `{:error, :verification_failed}` | CAP finish rejected what preparation approved after the custody guard passed |
| `:refused` | `{:error, {:refused, code}}` | claims contradict the supplied view (`signing_refused`) or the snapshot key does not match (`signing_key_mismatch`) |
| `:unsupported_substrate` | `{:error, :algorithm_unsupported_on_substrate}` | the runtime cannot verify the required algorithm |

The axes are the single source of truth (`CharterAgreementSigner.Telemetry.objects/0`
and `classes/0`); this section's tables are diffed against them by the test
suite, in both directions — a value here that the module does not emit, or an
axis member missing here, reds the build.

Real signing calls exercise key mismatch and substrate classes. The
capability-limited job exercises substrate failures on every signing kind.
The finish failure class is tested at the public `sign_span/2` seam because
CAP preparation plus the custody guard prevents a caller from producing
that outcome under CAP's contract. Signing entry point return shapes are in
[errors.md](errors.md). The TypeScript signer has no telemetry surface.

## Attaching

```elixir
:telemetry.attach_many(
  "my-app-charter-signer",
  [
    [:charter_agreement_signer, :sign, :start],
    [:charter_agreement_signer, :sign, :stop]
  ],
  fn event, measurements, metadata, _config ->
    # event is one of the two names above — :telemetry dispatches by exact
    # name; there is no wildcard attach.
  end,
  nil
)
```

## The value-free invariant

Metadata carries exactly two closed atoms and NOTHING else — never key ids,
thumbprints, message bytes, claims content, caller opts, or error values.
Adding a value-carrying field to an emission is a named MISUSE of this
surface, not an extension: the emitters are shape-validated and refuse
anything outside the closed shapes with `{:error, :telemetry_invalid}`
rather than emitting it.

## Known quiet failure: a faulting handler detaches — but not silently

`:telemetry` 1.4 detaches any handler that raises, exits, or throws — one
exception in your reporter takes the `:signing_failed` custody alarm with it
and the surface goes quiet while every sign path keeps working. The detach
is not silent, though: `:telemetry` re-reports every handler fault on the
`[:telemetry, :handler, :failure]` event (metadata carries `:kind`, `:reason`,
`:stacktrace`, and which `:event_name`/`:handler_id` faulted), so the
operator move is to attach an alarm to THAT event instead of polling
`list_handlers/1`. Keep handlers defensive regardless — the signer's own
emissions carry no dispatch rescue by design (containment is `:telemetry`'s
job, and the signature is never subordinated to telemetry).
