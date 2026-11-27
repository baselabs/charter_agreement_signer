defmodule CharterAgreementSigner do
  @moduledoc """
  Holder-side companion signer for the Charter Agreement Protocol (CAP).
  The private key never enters this library.

  Every signing path resolves options and uses one atomic `key_identity/1`
  snapshot. With the optional `:key_identity` tuple `{kid, public_key}`, CAP
  prepares the signing request before the handle is called. Otherwise CAP
  prepares with the snapshot identity. CAP checks claims, context,
  limits, profile, the holder's own descriptor key, signer scope and runtime
  support before the custody callback runs. CAP also owns the R1-R3 refusals.

  The handle signs `plan.signing_input.message`. This library checks the
  signature against the snapshot public key, then calls
  `CharterAgreementProtocol.finish_signing/2` to assemble and publicly
  verify the result with CAP's retained context, limits and profile.

  This library never holds private keys, verifies third-party artifacts,
  transports or persists artifacts, or evaluates charter terms.

  ## Key handles

  Supply `{module, ref}`. The module implements `key_identity/1` and
  `sign/2` against its own custody. The snapshot contains the non-empty
  `kid` and binary public key together, so rotation cannot split them
  across two calls. CAP checks the selected algorithm's key shape and
  descriptor membership. A callback that signs with a different key still
  fails the signer's wrong-key guard with `:signing_failed`.

  `public_key/1` and `thumbprint/1` are optional caller self-checks and are
  unused by the signer. The reference handles compile only under `:test`
  and never ship.
  """

  alias CharterAgreementProtocol, as: CAP
  alias CharterAgreementProtocol.{ArtifactSet, Capability.Profile, Error, Limits}
  alias CharterAgreementSigner.Telemetry

  @signing_options [:algorithm, :limits, :profile, :key_identity]
  @descriptor_options [:predecessor | @signing_options]

  @typedoc "A module implementing the custody callbacks and its local reference."
  @type key_handle :: {module(), term()}

  @typedoc """
  A map or keyword list with the documented atom keys, each at most once.
  `:key_identity` supplies a non-empty binary kid and a raw public key as
  `{kid, public_key}`. A match with the subsequent handle snapshot is required.
  Unknown, repeated or non-atom keys, structs and non-keyword lists return
  `{:error, {:invalid_input, :invalid_type}}`.
  """
  @type opts :: map() | keyword()

  @typedoc """
  Closed, value-free errors. No key material, message bytes or claims content.

  * `:invalid_key_handle`: malformed handle or snapshot, faulting identity
    callback, or CAP's `:signing_key_invalid`.
  * `:signing_failed`: faulting or rejecting sign callback, wrong signature
    length, or failure of the wrong-key guard.
  * `{:refused, :signing_refused}`: CAP's R1-R3 claims or view refusal.
  * `{:refused, :signing_key_mismatch}`: the requested identity does not match an
    active descriptor key or the handle snapshot differs from the prepared identity.
  * `{:refused, :signer_outside_scope}`: the key is outside the pinned
    descriptor's scope for an acceptance, termination or receipt.
  * `:algorithm_unsupported_on_substrate`: the runtime cannot verify the
    artifact or a context artifact's required algorithm.
  * `{:invalid_input, code}`: malformed options or another CAP preparation
    error, including invalid profile, context, claims or limits.
  * `:verification_failed`: CAP's finish step rejected a result its
    preparation approved, after the custody signature passed the guard.
  """
  @type sign_error ::
          :invalid_key_handle
          | :signing_failed
          | :verification_failed
          | :algorithm_unsupported_on_substrate
          | {:refused, :signing_refused | :signing_key_mismatch | :signer_outside_scope}
          | {:invalid_input, atom()}

  @doc """
  Sign a Party Descriptor and return `{:ok, %{descriptor: compact}}`.

  A successor requires `:predecessor`, the prior descriptor's verified
  `CAP.DescriptorFacts`. Missing or incorrect predecessor facts reject
  before `sign/2`. The header kid comes only from the atomic snapshot.
  If the predecessor declares scopes, the key needs the `descriptor` kind
  under a role there. An outside key returns `{:invalid_input, :descriptor_chain_invalid}`.

  Options are a map or keyword list with each key at most once:

  * `:algorithm`: `"Ed25519"` (default, including absent or `nil`) or
    `"ML-DSA-65"`. Legacy descriptors use revision 2 or 3 respectively.
    Revision-8 descriptors can use either algorithm.
    An unsupported algorithm returns `{:error, {:invalid_input, :algorithm_unsupported}}`.
  * `:limits`: `CAP.Limits.t()`, default `CAP.Limits.default()`. Bounds
    apply to every artifact read and to the final compact.
  * `:profile`: `CAP.Capability.Profile.t()`, default `Profile.full()`.
    Applies to the artifact and predecessor history. A malformed profile
    returns `{:error, {:invalid_input, :invalid_profile}}`.
  * `:predecessor`: `nil` (genesis default) or `CAP.DescriptorFacts.t()`.

  Options resolve in this order: limits, profile, algorithm, then key selection.
  With `:key_identity`, CAP prepares before the handle snapshot.

      {:ok, %{descriptor: compact}} =
        CharterAgreementSigner.sign_descriptor(claims, {MyCustody.Handle, ref},
          profile: profile, limits: limits)
  """
  @spec sign_descriptor(map(), key_handle(), opts()) ::
          {:ok, %{descriptor: binary()}} | {:error, sign_error()}
  def sign_descriptor(claims, key_handle, opts \\ %{}) do
    Telemetry.sign_span(:descriptor, fn ->
      sign_common(:party_descriptor, claims, key_handle, nil, opts)
    end)
  end

  @doc """
  Sign a Receipt and return `{:ok, %{receipt: compact}}`.

  Context is `CAP.ChainFacts.t()` or a decoded `CAP.CharterRevision.t()`.
  CAP re-verifies the context before signing. Chain context checks the
  snapshot against the issuing party's active descriptor keys and receipt scope.
  A bare legacy revision skips membership checking because it names no signing key.
  A bare revision-8 charter returns `{:error, {:refused, :signing_refused}}`.
  Receipt claims use revision 2 for Ed25519 or revision 3 for ML-DSA-65.

  Call `CharterAgreementProtocol.inspect_receipt/4` with the resulting compact,
  the raw retained set, an optional tagged grant digest and the signing limits.

  Options: `:algorithm`, `:limits`, `:profile`, as in `sign_descriptor/3`.
  The profile applies to the receipt and every context artifact; limits
  bound the whole retained set and the final compact. `:predecessor` is
  descriptor-only. Invalid profile returns `{:error, {:invalid_input, :invalid_profile}}`.
  """
  @spec sign_receipt(map(), key_handle(), CAP.ChainFacts.t() | CAP.CharterRevision.t(), opts()) ::
          {:ok, %{receipt: binary()}} | {:error, sign_error()}
  def sign_receipt(claims, key_handle, context, opts \\ %{}) do
    Telemetry.sign_span(:receipt, fn ->
      sign_common(:receipt, claims, key_handle, context, opts)
    end)
  end

  @doc """
  Sign an Acceptance and return `{:ok, %{acceptance: compact}}`.

  `set` is the holder's own artifact view, built with `CAP.build_set/4`.
  CAP verifies it, applies the R1-R3 refusals, derives the signing party's
  descriptor chain and claimed revision, and checks the snapshot key
  and acceptance scope before signing. Contradictory claims return
  `{:error, {:refused, :signing_refused}}`.
  A key mismatch returns `{:error, {:refused, :signing_key_mismatch}}`.

  Options: `:algorithm`, `:limits`, `:profile`, as in `sign_descriptor/3`.
  Limits bound the whole set read and the final compact. The caller's
  profile covers the revision, the signing party's own descriptor chain and
  the new artifact. CAP checks the rest of the set under the full profile.
  `:predecessor` is descriptor-only. Invalid profile returns
  `{:error, {:invalid_input, :invalid_profile}}`.
  """
  @spec sign_acceptance(map(), key_handle(), ArtifactSet.t(), opts()) ::
          {:ok, %{acceptance: binary()}} | {:error, sign_error()}
  def sign_acceptance(claims, key_handle, set, opts \\ %{}) do
    Telemetry.sign_span(:acceptance, fn ->
      sign_common(:acceptance, claims, key_handle, set, opts)
    end)
  end

  @doc """
  Sign the departing party's acceptance of a proposed assignment.

  The claims carry protocol revision 8 and a `replacement_role` matching
  the departing party's role. The assignee and the remaining parties sign
  separately with `sign_acceptance/4`. CAP checks the departing party's
  pinned descriptor for the acceptance scope. Each successful call signs once and
  returns `{:ok, %{acceptance: compact}}`. Use Ed25519 or ML-DSA-65.
  """
  @spec sign_party_replacement(map(), key_handle(), ArtifactSet.t(), opts()) ::
          {:ok, %{acceptance: binary()}} | {:error, sign_error()}
  def sign_party_replacement(claims, key_handle, set, opts \\ %{}) do
    Telemetry.sign_span(:acceptance, fn ->
      sign_common(:party_replacement, claims, key_handle, set, opts)
    end)
  end

  @doc """
  Sign a Termination Notice and return `{:ok, %{termination: compact}}`.

  CAP verifies `set`, applies its refusals at the notice's `effective_at`,
  derives the governing revision and signing party's descriptor chain, and
  checks the snapshot key and termination scope before signing. Contradictory
  claims give `{:error, {:refused, :signing_refused}}`. A key mismatch returns
  `{:error, {:refused, :signing_key_mismatch}}`.

  Options: `:algorithm`, `:limits`, `:profile`, as in `sign_descriptor/3`.
  Limits bound the whole set read and the final compact. The caller's
  profile covers the revision, the signing party's own descriptor chain and
  the new artifact. CAP checks the rest of the set under the full profile.
  `:predecessor` is descriptor-only. Invalid profile returns
  `{:error, {:invalid_input, :invalid_profile}}`.
  """
  @spec sign_termination(map(), key_handle(), ArtifactSet.t(), opts()) ::
          {:ok, %{termination: binary()}} | {:error, sign_error()}
  def sign_termination(claims, key_handle, set, opts \\ %{}) do
    Telemetry.sign_span(:termination, fn ->
      sign_common(:termination, claims, key_handle, set, opts)
    end)
  end

  defp sign_common(kind, claims, key_handle, context, opts) do
    with {:ok, opts} <- normalize_opts(opts, known_options(kind)),
         {:ok, limits} <- resolve_limits(opts),
         {:ok, profile} <- resolve_profile(opts),
         {:ok, algorithm} <- resolve_algorithm(Map.get(opts, :algorithm)),
         context = if(kind == :party_descriptor, do: Map.get(opts, :predecessor), else: context),
         request = {kind, claims, context, algorithm, limits, profile},
         {:ok, plan, public_key} <- prepare_with_handle(request, key_handle, opts),
         {:ok, signature} <- sign_via_handle(key_handle, plan.signing_input.message),
         :ok <- verify_signature(plan.signing_input.message, signature, public_key, algorithm),
         {:ok, compact} <- finish(plan, signature) do
      {:ok, %{result_key(kind) => compact}}
    end
  end

  defp prepare_with_handle(request, handle, %{key_identity: {kid, public_key} = identity})
       when is_binary(kid) and byte_size(kid) > 0 and is_binary(public_key) do
    with {:ok, plan} <- prepare(request, identity),
         {:ok, snapshot} <- resolve_key_identity(handle),
         :ok <- match_identity(identity, snapshot) do
      {:ok, plan, public_key}
    end
  end

  defp prepare_with_handle(_request, _handle, %{key_identity: _invalid}),
    do: {:error, {:invalid_input, :invalid_type}}

  defp prepare_with_handle(request, handle, _opts) do
    with {:ok, {_kid, public_key} = identity} <- resolve_key_identity(handle),
         {:ok, plan} <- prepare(request, identity) do
      {:ok, plan, public_key}
    end
  end

  defp match_identity(identity, identity), do: :ok
  defp match_identity(_requested, _snapshot), do: {:error, {:refused, :signing_key_mismatch}}

  defp prepare({kind, claims, context, algorithm, limits, profile}, {kid, public_key}) do
    input = %{
      "kid" => kid,
      "claims" => claims,
      "public_key" => public_key,
      "algorithm" => algorithm
    }

    mapped(CAP.prepare_signing(kind, input, context, limits, profile))
  end

  defp known_options(:party_descriptor), do: @descriptor_options
  defp known_options(_kind), do: @signing_options
  defp result_key(:party_descriptor), do: :descriptor
  defp result_key(:receipt), do: :receipt
  defp result_key(kind) when kind in [:acceptance, :party_replacement], do: :acceptance
  defp result_key(:termination), do: :termination

  defp mapped({:error, %Error{code: :signing_refused, subject: ["signing_input", "scope"]}}),
    do: {:error, {:refused, :signer_outside_scope}}

  defp mapped({:error, %Error{code: code}})
       when code in [:signing_refused, :signing_key_mismatch],
       do: {:error, {:refused, code}}

  defp mapped({:error, %Error{code: :signing_key_invalid}}),
    do: {:error, :invalid_key_handle}

  defp mapped({:error, %Error{code: :algorithm_unsupported_on_substrate}}),
    do: {:error, :algorithm_unsupported_on_substrate}

  defp mapped({:error, %Error{code: code}}), do: {:error, {:invalid_input, code}}
  defp mapped({:ok, plan}), do: {:ok, plan}

  defp finish(plan, signature) do
    result = CAP.finish_signing(plan, signature)
    if match?({:ok, _}, result), do: result, else: {:error, :verification_failed}
  end

  defp resolve_algorithm(nil), do: {:ok, CAP.Algorithm.default_emission_name()}

  defp resolve_algorithm(algorithm) do
    if Map.has_key?(CAP.Algorithm.emissions(), algorithm),
      do: {:ok, algorithm},
      else: {:error, {:invalid_input, :algorithm_unsupported}}
  end

  defp normalize_opts(opts, allowed) when is_map(opts) do
    if opts |> Map.keys() |> Enum.all?(&(&1 in allowed)),
      do: {:ok, opts},
      else: {:error, {:invalid_input, :invalid_type}}
  end

  defp normalize_opts(opts, allowed) when is_list(opts) do
    keys = if Keyword.keyword?(opts), do: Keyword.keys(opts), else: nil

    if is_list(keys) and Enum.uniq(keys) == keys and Enum.all?(keys, &(&1 in allowed)),
      do: {:ok, Map.new(opts)},
      else: {:error, {:invalid_input, :invalid_type}}
  end

  defp normalize_opts(_opts, _allowed), do: {:error, {:invalid_input, :invalid_type}}

  defp resolve_limits(opts) do
    limits = Map.get(opts, :limits, Limits.default())
    if Limits.valid?(limits), do: {:ok, limits}, else: {:error, {:invalid_input, :invalid_limits}}
  end

  defp resolve_profile(opts) do
    profile = Map.get(opts, :profile, Profile.full())

    if Profile.valid?(profile),
      do: {:ok, profile},
      else: {:error, {:invalid_input, :invalid_profile}}
  end

  # One snapshot call. CAP owns algorithm-specific shape and membership checks.
  defp resolve_key_identity({module, handle}) when is_atom(module) do
    case safe_callback(module, :key_identity, [handle]) do
      {:ok, {kid, public_key}}
      when is_binary(kid) and byte_size(kid) > 0 and is_binary(public_key) ->
        {:ok, {kid, public_key}}

      _malformed_or_failed ->
        {:error, :invalid_key_handle}
    end
  end

  defp resolve_key_identity(_handle), do: {:error, :invalid_key_handle}

  defp sign_via_handle({module, handle}, message)
       when is_atom(module) and is_binary(message) do
    case safe_callback(module, :sign, [message, handle]) do
      {:ok, signature} when is_binary(signature) ->
        {:ok, signature}

      _rejected_or_failed ->
        {:error, :signing_failed}
    end
  end

  # Custody may rotate after the snapshot. Keep the raw wrong-key guard.
  defp verify_signature(message, signature, public_key, algorithm)
       when is_binary(message) and is_binary(signature) and is_binary(public_key) do
    case CAP.Signature.verify(message, signature, public_key, algorithm) do
      :ok -> :ok
      {:error, _code} -> {:error, :signing_failed}
    end
  end

  defp safe_callback(module, function, args) do
    apply(module, function, args)
  rescue
    _error -> {:error, :callback_failed}
  catch
    :exit, _reason -> {:error, :callback_failed}
    :throw, _reason -> {:error, :callback_failed}
  end

  @doc "Sign the supplied message through the caller's custody and return the raw signature."
  @callback sign(message :: binary(), handle :: term()) :: {:ok, binary()} | {:error, term()}

  @doc "Return one atomic non-empty kid and binary public key snapshot. CAP checks the key."
  @callback key_identity(handle :: term()) ::
              {:ok, {kid :: binary(), public_key :: binary()}} | {:error, term()}

  @doc "Optional caller self-check: return the raw public key. Unused by the signer."
  @callback public_key(handle :: term()) :: {:ok, binary()} | {:error, term()}

  @doc "Optional caller self-check: return the raw RFC 7638 thumbprint. Unused by the signer."
  @callback thumbprint(handle :: term()) :: {:ok, binary()} | {:error, term()}

  @optional_callbacks [public_key: 1, thumbprint: 1]
end
