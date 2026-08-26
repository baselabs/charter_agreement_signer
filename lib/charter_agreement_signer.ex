defmodule CharterAgreementSigner do
  @moduledoc """
  The private key never enters this library.

  Holder-side companion signer for the [Charter Agreement
  Protocol](https://hex.pm/packages/charter_agreement_protocol) (CAP). CAP
  produces the deterministic RFC 7515 signing input for each charter artifact
  (party descriptor, acceptance, termination notice, receipt) and **refuses to
  sign** — it is a pure, verifier-only package with no key parameter, signer
  callback, or custody handle. This library takes a local `{module(), term()}`
  key handle and produces the signed compact form, then verifies the assembled
  artifact through CAP's own public verify functions before returning it.

  What this library does:

    * resolves the signing key's identity (`kid` + public key) as ONE atomic
      snapshot from the handle — a stateful handle cannot split them across a
      key-rotation race;
    * builds the signing input via CAP's producers — the honest-signer refusal
      rules (R1–R3: claims-truth, no-equivocation, ancestry/governing
      coverage) run inside CAP **before** the key is ever used, and a refusal
      surfaces here as `{:error, {:refused, :signing_refused}}`;
    * signs through the handle's `sign/2` (the custody boundary — an HSM, a
      KMS, or an in-process key in test), verifies the raw signature against
      the snapshot's public key (the wrong-key guard — a signature made by a
      different key is `:signing_failed`, never a silent false-success), and
      assembles the compact via CAP;
    * re-verifies the assembled compact through the matching CAP public verify
      function (with the predecessor/descriptor-chain/revision context the
      caller supplies) before returning it.

  What this library does NOT do: it never holds a key, never verifies
  third-party artifacts (verifiers depend only on CAP), never transports,
  persists, or evaluates charter terms, and never authorizes anything.

  ## The key-handle contract

  Callers supply `{module, ref}`; `module` implements the callbacks against
  its own custody. `sign/2` and `key_identity/1` are required — every CAP
  artifact's protected header carries the signing `kid`, so the identity
  snapshot is not optional here the way proof-only handles are in the BAP
  sibling. `public_key/1` and `thumbprint/1` are optional and unused by this
  library; they exist so callers can self-check a handle against a party
  descriptor's `verification_keys` before signing (the adapter does not
  enforce that equality — pinning the descriptor is the verifier's job).

  The test-only reference handles (`Keys.RawKey`, the wrong-key probe
  `Keys.RogueKey`) compile under `:test` alone and never ship.
  """

  alias CharterAgreementProtocol, as: CAP
  alias CharterAgreementProtocol.{ArtifactSet, Error, Limits, SigningInput}
  alias CharterAgreementSigner.Telemetry

  @typedoc "A caller-supplied key handle: a module implementing the callbacks plus its ref."
  @type key_handle :: {module(), term()}

  @typedoc """
  Per-call options — a map or a keyword list. Any other shape is rejected as
  `{:error, {:invalid_input, :invalid_type}}` (the closed-vocabulary posture:
  a malformed opts argument is a returned error, never a raised exception).
  """
  @type opts :: map() | keyword()

  @typedoc """
  The closed signer error vocabulary.

    * `:invalid_key_handle` — the handle is malformed, a callback crashed
      (raise/exit/throw), or the `key_identity/1` snapshot was not a
      non-empty `kid` plus a 32-byte Ed25519 public key.
    * `:signing_failed` — `sign/2` rejected, returned a non-64-byte
      signature, violated the `{:ok, _} | {:error, _}` contract, or the
      signature did not verify against the snapshot's public key (the
      wrong-key guard).
    * `{:refused, :signing_refused}` — CAP's honest-signer refusal (R1–R3):
      the claims contradict the caller's own verified artifact view. An
      honest signer refuses; a dishonest one bypasses CAP entirely, which no
      library can prevent.
    * `{:invalid_input, code}` — CAP rejected the claims shape, the artifact
      set, or the assembly; `code` is drawn from CAP's closed, gated
      error-code vocabulary (`:signing_input_invalid`, `:compact_invalid`,
      `:signature_invalid`, `:invalid_limits`, ...).
    * `:verification_failed` — the post-sign CAP verify of the assembled
      artifact rejected it (for example the handle's key is not in the
      descriptor's `verification_keys`, or a successor descriptor was signed
      without the `:predecessor` facts).

  No key material, message bytes, or claims content ever appear in errors.
  """
  @type sign_error ::
          :invalid_key_handle
          | :signing_failed
          | :verification_failed
          | {:refused, :signing_refused}
          | {:invalid_input, atom()}

  @doc """
  Signs one Party Descriptor.

  Returns `{:ok, %{descriptor: compact}}` — the attached compact JWS
  (`typ cap+party`), verified via `CAP.verify_descriptor/3` before return.

  The header `kid` comes from the handle's atomic `key_identity/1` snapshot,
  never from the claims. For a genesis descriptor (`descriptor_number` 1) the
  default post-sign verify context (`nil` predecessor) is correct; a successor
  descriptor MUST pass `:predecessor` — the `DescriptorFacts` of the verified
  prior descriptor — or the post-sign verify fails as
  `:verification_failed`.

  ## Options

  Options may be given as a map or a keyword list.

    * `:predecessor` — `nil | CAP.DescriptorFacts.t()` (default `nil`):
      the verified predecessor's facts for a successor descriptor.
    * `:limits` — `CAP.Limits.t()` (default `CAP.Limits.default()`).

  ## Example

      {:ok, %{descriptor: compact}} =
        CharterAgreementSigner.sign_descriptor(claims, {MyCustody.Handle, ref})
  """
  @spec sign_descriptor(map(), key_handle(), opts()) ::
          {:ok, %{descriptor: binary()}} | {:error, sign_error()}
  def sign_descriptor(claims, key_handle, opts \\ %{}) do
    Telemetry.sign_span(:descriptor, fn -> do_sign_descriptor(claims, key_handle, opts) end)
  end

  defp do_sign_descriptor(claims, key_handle, opts) do
    with {:ok, {kid, public_key}} <- resolve_key_identity(key_handle),
         {:ok, opts} <- normalize_opts(opts),
         {:ok, limits} <- resolve_limits(opts) do
      sign_common(:descriptor, claims, kid, key_handle, public_key, limits,
        context: Map.get(opts, :predecessor)
      )
    end
  end

  @doc """
  Signs one Receipt (`typ cap+receipt`).

  Returns `{:ok, %{receipt: compact}}` — verified via `CAP.verify_receipt/3`
  against `context` before return. `context` is the caller's verified view:
  a decoded `CAP.CharterRevision.t()` (revision-only) or `CAP.ChainFacts.t()`
  (full chain). Receipts bind an effect to an invocation; the issuing host
  supplies the exact view the receipt is anchored to.

  ## Options

  Options may be given as a map or a keyword list.

    * `:limits` — `CAP.Limits.t()` (default `CAP.Limits.default()`).
  """
  @spec sign_receipt(map(), key_handle(), CAP.ChainFacts.t() | CAP.CharterRevision.t(), opts()) ::
          {:ok, %{receipt: binary()}} | {:error, sign_error()}
  def sign_receipt(claims, key_handle, context, opts \\ %{}) do
    Telemetry.sign_span(:receipt, fn -> do_sign_receipt(claims, key_handle, context, opts) end)
  end

  defp do_sign_receipt(claims, key_handle, context, opts) do
    with {:ok, {kid, public_key}} <- resolve_key_identity(key_handle),
         {:ok, opts} <- normalize_opts(opts),
         {:ok, limits} <- resolve_limits(opts) do
      sign_common(:receipt, claims, kid, key_handle, public_key, limits, context: context)
    end
  end

  @doc """
  Signs one Acceptance (`typ cap+acceptance`) after the honest-signer checks.

  Returns `{:ok, %{acceptance: compact}}` — verified via
  `CAP.verify_acceptance/4` before return, against the descriptor chain and
  the retained revision derived from `set` (the same set CAP's producer
  already verified internally when it ran the R1–R3 refusals).

  `set` is the signer's own artifact view (`CAP.build_set/4` over the raw
  compacts/bytes the caller retains). If the acceptance claims contradict
  that view — false revision coordinates, an equivocating number, an ancestry
  that excludes an accepted head — CAP refuses and this returns
  `{:error, {:refused, :signing_refused}}` BEFORE the key is used.

  ## Options

  Options may be given as a map or a keyword list.

    * `:limits` — `CAP.Limits.t()` (default `CAP.Limits.default()`).
  """
  @spec sign_acceptance(map(), key_handle(), ArtifactSet.t(), opts()) ::
          {:ok, %{acceptance: binary()}} | {:error, sign_error()}
  def sign_acceptance(claims, key_handle, set, opts \\ %{}) do
    Telemetry.sign_span(:acceptance, fn -> do_sign_acceptance(claims, key_handle, set, opts) end)
  end

  defp do_sign_acceptance(claims, key_handle, set, opts) do
    with {:ok, {kid, public_key}} <- resolve_key_identity(key_handle),
         {:ok, opts} <- normalize_opts(opts),
         {:ok, limits} <- resolve_limits(opts) do
      sign_common(:acceptance, claims, kid, key_handle, public_key, limits,
        context: {:set, set, claims}
      )
    end
  end

  @doc """
  Signs one Termination Notice (`typ cap+termination`) after the
  honest-signer checks.

  Returns `{:ok, %{termination: compact}}` — verified via
  `CAP.verify_termination/4` before return, against the descriptor chain and
  the governing revision derived from `set`. CAP's producer refuses every
  revision except the unique governing revision at the notice's own
  `effective_at`; a stale or contested view is
  `{:error, {:refused, :signing_refused}}` BEFORE the key is used.

  ## Options

  Options may be given as a map or a keyword list.

    * `:limits` — `CAP.Limits.t()` (default `CAP.Limits.default()`).
  """
  @spec sign_termination(map(), key_handle(), ArtifactSet.t(), opts()) ::
          {:ok, %{termination: binary()}} | {:error, sign_error()}
  def sign_termination(claims, key_handle, set, opts \\ %{}) do
    Telemetry.sign_span(:termination, fn -> do_sign_termination(claims, key_handle, set, opts) end)
  end

  defp do_sign_termination(claims, key_handle, set, opts) do
    with {:ok, {kid, public_key}} <- resolve_key_identity(key_handle),
         {:ok, opts} <- normalize_opts(opts),
         {:ok, limits} <- resolve_limits(opts) do
      sign_common(:termination, claims, kid, key_handle, public_key, limits,
        context: {:set, set, claims}
      )
    end
  end

  # ---------------------------------------------------------------------------
  # The shared signing tail (the BARA universal-companion primitive, the
  # R-1/C3 house grammar):
  #
  # resolve_key_identity → CAP producer → sign_via_handle → verify_signature
  # → CAP.assemble_compact → CAP post-sign verify. Every artifact this
  # library signs flows through here. verify_signature is the wrong-key guard:
  # a signature that does not verify against the snapshot's public key is
  # :signing_failed, never a silent false-success.
  # ---------------------------------------------------------------------------

  defp sign_common(kind, claims, kid, key_handle, public_key, limits, context: context) do
    with {:ok, signing_input} <- produce(kind, claims, kid, context),
         {:ok, signature} <- sign_via_handle(key_handle, signing_input.message),
         :ok <- verify_signature(signing_input.message, signature, public_key),
         {:ok, compact} <- assemble(signing_input, signature),
         :ok <- post_sign_verify(kind, compact, context, limits) do
      {:ok, %{result_key(kind) => compact}}
    end
  end

  defp result_key(:descriptor), do: :descriptor
  defp result_key(:receipt), do: :receipt
  defp result_key(:acceptance), do: :acceptance
  defp result_key(:termination), do: :termination

  # The producer input is closed: %{"kid" => kid, "claims" => claims}. The kid
  # is ALWAYS the atomic snapshot's — a caller cannot name a kid the handle
  # does not control, so the signed header's kid and the signing key cannot
  # disagree by construction.
  defp produce(:descriptor, claims, kid, _context),
    do: mapped(CAP.descriptor_signing_input(%{"kid" => kid, "claims" => claims}))

  defp produce(:receipt, claims, kid, _context),
    do: mapped(CAP.receipt_signing_input(%{"kid" => kid, "claims" => claims}))

  defp produce(:acceptance, claims, kid, {:set, set, _claims}),
    do: mapped(CAP.acceptance_signing_input(%{"kid" => kid, "claims" => claims}, set))

  defp produce(:termination, claims, kid, {:set, set, _claims}),
    do: mapped(CAP.termination_signing_input(%{"kid" => kid, "claims" => claims}, set))

  defp mapped({:ok, %SigningInput{} = input}), do: {:ok, input}

  defp mapped({:error, %Error{code: :signing_refused}}),
    do: {:error, {:refused, :signing_refused}}

  defp mapped({:error, %Error{code: code}}), do: {:error, {:invalid_input, code}}

  defp assemble(signing_input, signature) do
    case CAP.assemble_compact(signing_input, signature) do
      {:ok, compact} when is_binary(compact) -> {:ok, compact}
      {:error, %Error{code: code}} -> {:error, {:invalid_input, code}}
    end
  end

  # The post-sign verify-before-return: the assembled artifact must pass the
  # matching CAP public verify function against the caller's context. This is
  # the protocol-level half of the discipline — it catches a snapshot key that
  # is not in the party descriptor's verification_keys, a successor descriptor
  # signed without predecessor facts, and any structural drift the assembler's
  # provisional decode did not cover.
  defp post_sign_verify(:descriptor, compact, predecessor, limits),
    do: verified(CAP.verify_descriptor(compact, predecessor, limits))

  defp post_sign_verify(:receipt, compact, context, limits),
    do: verified(CAP.verify_receipt(compact, context, limits))

  defp post_sign_verify(:acceptance, compact, {:set, set, claims}, limits) do
    with {:ok, revision} <- retained_revision(set, claims["revision_digest"], limits),
         {:ok, chain} <-
           party_descriptor_chain(set, claims["party_descriptor_digest"], limits),
         {:ok, _facts} <- CAP.verify_acceptance(compact, revision, chain, limits) do
      :ok
    else
      _set_or_verify_failure -> {:error, :verification_failed}
    end
  end

  defp post_sign_verify(:termination, compact, {:set, set, claims}, limits) do
    with {:ok, revision} <-
           retained_revision(set, claims["governing_revision_digest"], limits),
         {:ok, chain} <-
           party_descriptor_chain(set, claims["party_descriptor_digest"], limits),
         {:ok, _facts} <- CAP.verify_termination(compact, revision, chain, limits) do
      :ok
    else
      _set_or_verify_failure -> {:error, :verification_failed}
    end
  end

  # The claims' party's descriptor chain — NOT the whole set's descriptor
  # list: each party owns its own chain (its genesis plus its successors,
  # threaded by party_id), and a bilateral set carries one chain per party.
  # A chain view mixing two parties' descriptors is invalid by CAP's own
  # chain semantics, so the set-aware paths select the signing party's chain
  # before handing it to CAP's verifier. Every failure here is a verification
  # failure — raw CAP errors never escape the closed vocabulary.
  defp party_descriptor_chain(set, party_digest, limits) do
    with {:ok, pairs} <- decode_descriptors(set.descriptors, limits),
         {:ok, chain_compacts} <- party_chain(pairs, party_digest) do
      CAP.verify_descriptor_chain(chain_compacts, limits)
    else
      _decode_or_select_failure -> {:error, :verification_failed}
    end
  end

  defp decode_descriptors(compacts, limits) do
    compacts
    |> Enum.reduce_while({:ok, []}, fn compact, {:ok, acc} ->
      case CAP.decode_party_descriptor(compact, limits) do
        {:ok, descriptor} -> {:cont, {:ok, [{compact, descriptor} | acc]}}
        _decode_error -> {:halt, {:error, :verification_failed}}
      end
    end)
  end

  defp party_chain(pairs, party_digest) do
    target =
      Enum.find(pairs, fn {_compact, descriptor} ->
        CAP.descriptor_digest(descriptor) == party_digest
      end)

    case target do
      nil ->
        {:error, :verification_failed}

      {_compact, target_descriptor} ->
        root_digest = target_descriptor.party_id || party_digest

        chain_compacts =
          pairs
          |> Enum.filter(fn {_compact, descriptor} ->
            CAP.descriptor_digest(descriptor) == root_digest or
              descriptor.party_id == root_digest
          end)
          |> Enum.sort_by(fn {_compact, descriptor} -> descriptor.descriptor_number end)
          |> Enum.map(&elem(&1, 0))

        {:ok, chain_compacts}
    end
  end

  defp verified({:ok, _facts}), do: :ok
  defp verified({:error, %Error{}}), do: {:error, :verification_failed}

  # The revision the claims name, out of the SAME set the producer already
  # Chain.verify'd — decoded and digest-matched through CAP's public API. A
  # claims digest no set revision matches cannot happen past a successful
  # producer refusal pass; if it ever does, it is a verification failure.
  defp retained_revision(set, digest, limits) when is_binary(digest) do
    set.revisions
    |> Enum.reduce_while({:error, :verification_failed}, fn bytes, acc ->
      case CAP.decode_charter_revision(bytes, limits) do
        {:ok, revision} -> retained_revision_step(revision, digest, acc)
        _decode_error -> {:cont, acc}
      end
    end)
  end

  defp retained_revision(_set, _digest, _limits), do: {:error, :verification_failed}

  defp retained_revision_step(revision, digest, acc) do
    if CAP.revision_digest(revision) == digest,
      do: {:halt, {:ok, revision}},
      else: {:cont, acc}
  end

  defp normalize_opts(opts) when is_map(opts), do: {:ok, opts}
  defp normalize_opts(opts) when is_list(opts), do: {:ok, Map.new(opts)}
  defp normalize_opts(_opts), do: {:error, {:invalid_input, :invalid_type}}

  defp resolve_limits(opts) do
    case Map.get(opts, :limits, Limits.default()) do
      %Limits{} = limits ->
        if Limits.valid?(limits),
          do: {:ok, limits},
          else: {:error, {:invalid_input, :invalid_limits}}

      _not_limits ->
        {:error, {:invalid_input, :invalid_limits}}
    end
  end

  # The atomic key identity — the signed-header `kid` AND the 32-byte public
  # key — resolved as ONE snapshot. A single key_identity/1 call cannot split
  # kid from public_key across a rotation race. The remaining surface — sign/2
  # signing with a key different from the snapshot's public_key — is caught by
  # verify_signature in the shared tail.
  defp resolve_key_identity({module, handle}) when is_atom(module) do
    case safe_callback(module, :key_identity, [handle]) do
      {:ok, {kid, public_key}}
      when is_binary(kid) and byte_size(kid) > 0 and is_binary(public_key) and
             byte_size(public_key) == 32 ->
        {:ok, {kid, public_key}}

      _malformed_or_failed ->
        {:error, :invalid_key_handle}
    end
  end

  defp resolve_key_identity(_handle), do: {:error, :invalid_key_handle}

  defp sign_via_handle({module, handle}, message) when is_atom(module) and is_binary(message) do
    case safe_callback(module, :sign, [message, handle]) do
      {:ok, signature} when is_binary(signature) and byte_size(signature) == 64 ->
        {:ok, signature}

      _rejected_wrong_size_or_failed ->
        {:error, :signing_failed}
    end
  end

  defp sign_via_handle(_handle, _message), do: {:error, :invalid_key_handle}

  # The wrong-key guard: the signature MUST verify against the snapshot's
  # public key. A callback signing with a different key (a rotation or
  # misconfiguration race — key_identity/1 returns key A, sign/2 uses key B)
  # is :signing_failed, never a silent false-success.
  defp verify_signature(message, signature, public_key)
       when is_binary(message) and is_binary(signature) and is_binary(public_key) do
    if :crypto.verify(:eddsa, :none, message, signature, [public_key, :ed25519]),
      do: :ok,
      else: {:error, :signing_failed}
  end

  defp verify_signature(_message, _signature, _public_key), do: {:error, :signing_failed}

  # The callback is caller-supplied; a missing module, a function-clause raise
  # inside it, or any other fault must map to the closed-atom error rather
  # than escape the sign path (mirrors BAP's fixed/1 wrapper). A production
  # key-handle callback (HSM / key server) that times out does so via exit/1
  # (e.g. a GenServer.call timeout) — rescue catches exceptions only, so
  # :exit/:throw are caught and mapped to the same failure shape.
  defp safe_callback(module, function, args) do
    apply(module, function, args)
  rescue
    _error -> {:error, :callback_failed}
  catch
    :exit, _reason -> {:error, :callback_failed}
    :throw, _reason -> {:error, :callback_failed}
  end

  @doc """
  Signs `message` with the key behind `handle`.

  The caller's callback performs the actual `:crypto.sign`; this library
  never references the private key. Returns the raw 64-byte Ed25519
  signature.
  """
  @callback sign(message :: binary(), handle :: term()) ::
              {:ok, binary()} | {:error, term()}

  @doc """
  Returns the key's identity — the protected-header `kid` AND its 32-byte raw
  Ed25519 public key — as a single atomic `{kid, public_key}` snapshot.

  Required by every sign path here: CAP's protected header carries the
  signing `kid`, and resolving kid and public key in ONE call means a stateful
  handle cannot split them across a rotation race. Any `sign/2`-vs-snapshot
  mismatch is caught by the wrong-key guard in the shared tail.
  """
  @callback key_identity(handle :: term()) ::
              {:ok, {kid :: binary(), public_key :: binary()}} | {:error, term()}

  @doc """
  Returns the 32-byte raw Ed25519 public key for the key behind `handle`.

  Optional: unused by this library — it exists so callers can self-check a
  handle against a party descriptor's `verification_keys` before signing.
  """
  @callback public_key(handle :: term()) :: {:ok, binary()} | {:error, term()}

  @doc """
  Returns the RFC 7638 thumbprint (raw 32-byte SHA-256) of the public key
  behind `handle`.

  Optional: unused by this library — same caller-side self-check purpose as
  `public_key/1`.
  """
  @callback thumbprint(handle :: term()) :: {:ok, binary()} | {:error, term()}

  @optional_callbacks [public_key: 1, thumbprint: 1]
end
