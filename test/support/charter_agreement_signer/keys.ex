defmodule CharterAgreementSigner.Keys.RawKey do
  @moduledoc """
  TEST-ONLY reference implementation of the `CharterAgreementSigner`
  key-handle behaviour.

  The handle term is a `{kid, public_key, private_key}` tuple: a registry
  key id plus raw 32-byte Ed25519 key material. This compiles ONLY under
  `:test` (via `mix.exs` `elixirc_paths`) — it does NOT ship in the artifact.

  ## Why test-only (the BARA ADR-0014 posture)

  A tuple carrying the private key puts it in process memory as a recoverable
  BEAM binary. That posture is acceptable for tests and local development,
  but shipping it in `lib/` would pave a production road to the exact failure
  mode the companion-signer architecture exists to prevent ("once the signing
  key is in the app, extracting it is a re-architecture, not a refactor").
  Production holders implement the callbacks themselves with proper custody
  (HSM, OS keychain, a key server) — never this module.

  The callbacks match the `CharterAgreementSigner` behaviour contract:
  `sign/2` performs the `:crypto.sign` (the holder's job),
  `key_identity/1` returns the atomic kid + public-key snapshot,
  `public_key/1` + `thumbprint/1` are the optional caller self-check
  surface.
  """

  @behaviour CharterAgreementSigner

  def generate(kid, seed) when is_binary(kid) do
    {public, private} = :crypto.generate_key(:eddsa, :ed25519, seed)
    {kid, public, private}
  end

  @impl true
  def sign(message, {_kid, _public, private}) when is_binary(message) do
    {:ok, :crypto.sign(:eddsa, :none, message, [private, :ed25519])}
  end

  def sign(_message, _handle), do: {:error, :invalid_handle}

  @impl true
  def key_identity({kid, public, _private})
      when is_binary(kid) and byte_size(public) == 32,
      do: {:ok, {kid, public}}

  def key_identity(_handle), do: {:error, :invalid_handle}

  @impl true
  def public_key({_kid, public, _private}), do: {:ok, public}

  def public_key(_handle), do: {:error, :invalid_handle}

  @impl true
  def thumbprint({_kid, public, _private}) do
    # RFC 7638 + RFC 8037: the Ed25519 JWK thumbprint input is the
    # lexicographically-ordered minimal JSON over crv/kty/x, hashed raw.
    x = public |> Base.url_encode64(padding: false)

    {:ok, :crypto.hash(:sha256, ~s({"crv":"Ed25519","kty":"OKP","x":"#{x}"}))}
  end

  def thumbprint(_handle), do: {:error, :invalid_handle}
end

defmodule CharterAgreementSigner.Keys.RogueKey do
  @moduledoc """
  TEST-ONLY wrong-key probe handle.

  `key_identity/1` advertises key A (the honest snapshot) while `sign/2`
  signs with key B — the rotation/misconfiguration race the shared tail's
  `verify_signature` guard exists to catch. Used by the wrong-key gate test
  to prove a `{pub_A, sig_B}` artifact can NEVER leave `sign_descriptor/3`
  as `{:ok, _}`.
  """

  @behaviour CharterAgreementSigner

  alias CharterAgreementSigner.Keys.RawKey

  @impl true
  def sign(message, {_kid, _advertised_public, rogue_private}) when is_binary(message) do
    {:ok, :crypto.sign(:eddsa, :none, message, [rogue_private, :ed25519])}
  end

  def sign(_message, _handle), do: {:error, :invalid_handle}

  @impl true
  def key_identity({kid, advertised_public, _rogue_private})
      when is_binary(kid) and byte_size(advertised_public) == 32,
      do: {:ok, {kid, advertised_public}}

  def key_identity(_handle), do: {:error, :invalid_handle}

  @impl true
  def public_key({_kid, advertised_public, _rogue_private}), do: {:ok, advertised_public}

  def public_key(_handle), do: {:error, :invalid_handle}

  @impl true
  def thumbprint({_kid, advertised_public, _rogue_private}),
    do: RawKey.thumbprint({nil, advertised_public, nil})

  def thumbprint(_handle), do: {:error, :invalid_handle}
end
