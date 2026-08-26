# DEMO-ONLY custodies for the lifecycle example. Each handle is a seeded
# in-process Ed25519 pair behind the signer's behaviour — an illustrative
# fiction standing in for HSM/KMS custody. Production hosts implement these
# callbacks against their own custody (the library's docs/recipes.md).
defmodule CharterLifecycle.Keys do
  @moduledoc false

  def issuer, do: macro_key("issuer-key-demo-001", <<1::256>>)
  def acceptor, do: macro_key("acceptor-key-demo-001", <<2::256>>)

  # The wrong-key probe: advertises the issuer's public key, signs with a
  # different private key — the rotation/misconfiguration race the signer's
  # wrong-key guard exists to catch.
  def rogue_issuer do
    {kid, public, _private} = issuer()
    {_rogue_pub, rogue_private} = :crypto.generate_key(:eddsa, :ed25519, <<9::256>>)
    {kid, public, rogue_private}
  end

  def macro_key(kid, seed) do
    {public, private} = :crypto.generate_key(:eddsa, :ed25519, seed)
    {kid, public, private}
  end
end

defmodule CharterLifecycle.Keys.Handle do
  @moduledoc false
  @behaviour CharterAgreementSigner

  # The handle term is {kid, public, private} — DEMO-ONLY (key material in
  # process memory). A production handle's term is a key REFERENCE.
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
end
