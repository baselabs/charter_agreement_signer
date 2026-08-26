defmodule CharterAgreementSigner.Telemetry do
  @moduledoc """
  The closed, value-free telemetry surface for the four signing entry points.

  The library emits events but does NOT attach a handler — a fresh application
  sees nothing until it attaches one (`:telemetry.attach/4` or a
  `Telemetry.Metrics` reporter; `docs/telemetry.md` carries the runnable
  example). What is emitted is deliberately tiny:

    * `[:charter_agreement_signer, :sign, :start]` —
      measurements `%{count: 1}`, metadata `%{object: object}`.
    * `[:charter_agreement_signer, :sign, :stop]` —
      measurements `%{duration: native_monotonic_delta}`, metadata
      `%{object: object, result_class: class}`.

  ## The translated axis (why this is not a copy of the BARA surface)

  The class axis is the exact image of THIS library's public error
  vocabulary — `:ok`, `:invalid_input` (every `{:invalid_input, code}`
  collapses to the class; the code never rides along), `:invalid_key_handle`,
  `:signing_failed`, `:verification_failed`, and `:refused` (the honest-signer
  refusal). An operator reading `:signing_failed` is being told "custody
  misconfiguration or a wrong-key race"; a refusal storm or a post-sign verify
  failure is a DIFFERENT operational condition and must not wear that label.

  ## The value-free invariant (a named misuse)

  Metadata carries exactly two closed atoms and NOTHING else — never key ids,
  thumbprints, message bytes, claims content, caller opts, or error VALUES
  (`{:invalid_input, :signing_input_invalid}` is the class `:invalid_input`,
  full stop). Adding a value-carrying field to an emission is a named MISUSE
  of this surface, not an extension: the emitters are shape-validated
  (`emit_start/1`, `emit_stop/3`) and REFUSE anything outside the closed
  shapes with `{:error, :telemetry_invalid}` rather than emitting it.

  ## Telemetry never outranks the signature

  `sign_span/2` returns the signer's result UNCHANGED. A failure inside the
  emission is swallowed (`{:error, :telemetry_invalid}`); a raise inside the
  SIGNER propagates — only the emission is guarded, never the crypto.
  """

  @prefix [:charter_agreement_signer, :sign]

  # The single source of truth for both axes. docs/telemetry.md's tables are
  # diffed against these by telemetry_test.exs — a drift reds the suite.
  @objects [:descriptor, :receipt, :acceptance, :termination]
  @classes [
    :ok,
    :invalid_input,
    :invalid_key_handle,
    :signing_failed,
    :verification_failed,
    :refused
  ]

  @doc "The closed object axis (one atom per signing entry point)."
  @spec objects() :: [atom()]
  def objects, do: @objects

  @doc "The closed result-class axis (the classified outcome of a signing span)."
  @spec classes() :: [atom()]
  def classes, do: @classes

  @doc """
  Runs `fun` inside a `:sign` span: emits `:start`, runs it, emits `:stop`
  with the monotonic duration and the classified result, and returns whatever
  `fun` returned — unchanged. `object` must be one of `objects/0`.

  Telemetry failures are swallowed inside the emitters; a raise inside `fun`
  propagates (the emission is guarded, the crypto is not).
  """
  @spec sign_span(atom(), (-> term())) :: term()
  def sign_span(object, fun) when object in @objects and is_function(fun, 0) do
    started = System.monotonic_time()
    emit_start(object)

    result = fun.()

    _ = emit_stop(object, System.monotonic_time() - started, classify(result))
    result
  end

  @doc """
  Emits `[:charter_agreement_signer, :sign, :start]` with
  `%{count: 1}` / `%{object: object}`. Refuses an unknown object with
  `{:error, :telemetry_invalid}` instead of emitting garbage.
  """
  @spec emit_start(atom()) :: :ok | {:error, :telemetry_invalid}
  def emit_start(object) do
    case validate_object(object) do
      :ok ->
        :telemetry.execute(@prefix ++ [:start], %{count: 1}, %{object: object})
        :ok

      :error ->
        {:error, :telemetry_invalid}
    end
  rescue
    _exception -> {:error, :telemetry_invalid}
  catch
    _kind, _reason -> {:error, :telemetry_invalid}
  end

  @doc """
  Emits `[:charter_agreement_signer, :sign, :stop]` with
  `%{duration: duration}` / `%{object: object, result_class: result_class}`.
  Refuses an unknown object or class, or a non-nonnegative-integer duration,
  with `{:error, :telemetry_invalid}` instead of emitting garbage — this
  validation is the mechanical value-free guarantee: a metadata key outside
  the closed shape is not expressible through this emitter.
  """
  @spec emit_stop(atom(), integer(), atom()) :: :ok | {:error, :telemetry_invalid}
  def emit_stop(object, duration, result_class) do
    with :ok <- validate_object(object),
         true <- result_class in @classes,
         true <- is_integer(duration) and duration >= 0 do
      :telemetry.execute(@prefix ++ [:stop], %{duration: duration}, %{
        object: object,
        result_class: result_class
      })

      :ok
    else
      _invalid -> {:error, :telemetry_invalid}
    end
  rescue
    _exception -> {:error, :telemetry_invalid}
  catch
    _kind, _reason -> {:error, :telemetry_invalid}
  end

  # The translated classification — the exact image of the signer's public
  # error vocabulary. Error VALUES never ride along; the {:invalid_input,
  # code} pair collapses to its class. The catch-all is unreachable per the
  # entry points' closed @specs — an off-spec shape is a signing-path
  # anomaly, never classified as success.
  defp classify({:ok, _result}), do: :ok
  defp classify({:error, {:invalid_input, _code}}), do: :invalid_input
  defp classify({:error, :invalid_key_handle}), do: :invalid_key_handle
  defp classify({:error, :signing_failed}), do: :signing_failed
  defp classify({:error, :verification_failed}), do: :verification_failed
  defp classify({:error, {:refused, :signing_refused}}), do: :refused
  defp classify(_off_spec), do: :signing_failed

  defp validate_object(object) when object in @objects, do: :ok
  defp validate_object(_object), do: :error
end
