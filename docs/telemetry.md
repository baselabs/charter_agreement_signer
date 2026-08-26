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

The result-class axis — the exact image of the signer's public error
vocabulary:

| Class | Fires when the entry point returned | Operator reading |
|---|---|---|
| `:ok` | `{:ok, %{...}}` | nothing |
| `:invalid_input` | `{:error, {:invalid_input, code}}` | claims shape, opts, limits, or a set the protocol rejected — the code never rides along |
| `:invalid_key_handle` | `{:error, :invalid_key_handle}` | caller wiring: the handle is malformed or its callback crashed |
| `:signing_failed` | `{:error, :signing_failed}` | custody misconfiguration or a wrong-key race — the highest-priority signal this surface offers |
| `:verification_failed` | `{:error, :verification_failed}` | the assembled artifact failed the post-sign protocol verify (unpinned key, missing predecessor facts) |
| `:refused` | `{:error, {:refused, :signing_refused}}` | the honest-signer refusal: the claims contradict the caller's own verified view — NOT a custody condition |

The axes are the single source of truth (`CharterAgreementSigner.Telemetry.objects/0`
and `classes/0`); this section's tables are diffed against them by the test
suite, in both directions — a value here that the module does not emit, or an
axis member missing here, reds the build.

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

## Known quiet failure: a raising handler detaches silently

`:telemetry` detaches any handler that raises, silently and permanently —
one exception in your reporter takes the `:signing_failed` custody alarm with
it and the surface goes quiet while every sign path keeps working. Keep
handlers defensive; if sign telemetry matters to you, monitor handler
liveness (`:telemetry.list_handlers/1` for the event names above).
