# Getting started

Install the signer, create two demo key handles, sign descriptors and verify
both with CAP alone. The code blocks below run in order in one `iex -S mix`
session. No database or custody service is required for this demo.

## Install

```elixir
def deps do
  [{:charter_agreement_signer, "~> 1.0.0"}]
end
```

Run `mix deps.get`, then `iex -S mix`. Signer 1.0.x requires CAP `~> 1.0.0`.
Elixir `~> 1.19` on OTP 28 or 29 is required; this Ed25519 example does not
need ML-DSA support. See the README for the tested toolchains.

## Create demo handles

A handle is `{module, ref}`. Its required callbacks are `key_identity/1`,
returning `{:ok, {kid, public_key}}` from one atomic snapshot, and `sign/2`,
returning `{:ok, raw_signature}`. These fixed seeds are public test material.
The in-memory private-key tuple below is for this demo only; in production,
`ref` names an immutable key version in your custody service and `sign/2`
delegates signing without exporting private bytes.

```elixir
defmodule Demo.Keys do
  @behaviour CharterAgreementSigner

  def key(kid, seed) do
    {public, private} = :crypto.generate_key(:eddsa, :ed25519, seed)
    {kid, public, private}
  end

  @impl true
  def sign(message, {_kid, _pub, priv}) when is_binary(message),
    do: {:ok, :crypto.sign(:eddsa, :none, message, [priv, :ed25519])}

  def sign(_, _), do: {:error, :invalid_handle}

  @impl true
  def key_identity({kid, pub, _priv}), do: {:ok, {kid, pub}}
  def key_identity(_), do: {:error, :invalid_handle}
end

alias CharterAgreementProtocol, as: CAP
alias CharterAgreementSigner, as: Signer

issuer = Demo.Keys.key("issuer-demo", <<1::256>>)
acceptor = Demo.Keys.key("acceptor-demo", <<2::256>>)

# Display only public identifiers, not the demo private bytes.
[elem(issuer, 0), elem(acceptor, 0)]
```

## Sign and verify the descriptors

Descriptor claims include public verification keys. Private keys remain behind
the handle. The protected header's `kid` comes only from the identity callback.

```elixir
descriptor_claims = fn {kid, public, _priv} ->
  %{
    "protocol_revision" => 2,
    "descriptor_number" => 1,
    "verification_keys" => [
      %{
        "key_id" => kid,
        "algorithm" => "Ed25519",
        "public_key" => Base.url_encode64(public, padding: false),
        "status" => "active"
      }
    ],
    "attestation_hints" => [],
    "extensions" => %{"critical" => %{}, "optional" => %{}},
    "effective_from" => "2026-08-26T10:00:00Z"
  }
end

{:ok, profile} = CAP.Capability.Profile.new(algorithms: ["Ed25519"], revisions: {1, 2})
options = [profile: profile, limits: CAP.Limits.default()]

{:ok, %{descriptor: issuer_descriptor}} =
  Signer.sign_descriptor(descriptor_claims.(issuer), {Demo.Keys, issuer}, options)

{:ok, %{descriptor: acceptor_descriptor}} =
  Signer.sign_descriptor(descriptor_claims.(acceptor), {Demo.Keys, acceptor}, options)

# The verifier's side needs ONLY the protocol package:
{:ok, _facts} = CAP.verify_descriptor(issuer_descriptor, nil, CAP.Limits.default())
{:ok, _facts} = CAP.verify_descriptor(acceptor_descriptor, nil, CAP.Limits.default())
```

Both matches return `{:ok, #CharterAgreementProtocol.DescriptorFacts<redacted>}`.
The signer prepares through CAP before calling custody, checks the raw signature
against the snapshot key, and calls CAP's `finish_signing/2` before returning.
This proves possession of a descriptor key; identifying its real-world owner
and deciding whether to trust that genesis key are your application's jobs.

## Try the wrong-key guard

Advertise the issuer's public key while signing with a different demo key:

```elixir
{_pub_b, priv_b} = :crypto.generate_key(:eddsa, :ed25519, <<9::256>>)
rogue = put_elem(issuer, 2, priv_b)

{:error, :signing_failed} =
  Signer.sign_descriptor(descriptor_claims.(issuer), {Demo.Keys, rogue})
```

The result is `{:error, :signing_failed}`. No compact is returned.

## Continue with a complete charter

- [Produce and verify](https://hexdocs.pm/charter_agreement_protocol/produce-and-verify.html)
  forms a revision, dual acceptances and a governing view using both 1.0 packages.
- [The lifecycle example](https://github.com/baselabs/charter_agreement_signer/tree/master/examples/charter_lifecycle)
  also signs a receipt and a termination. Its source includes tests.
- [Custody recipes](recipes.md) describe the adapter contract for a real HSM or KMS.
- [Errors](errors.md) and [security](security.md) explain refusals, limits and trust.
- [The Livebook](https://github.com/baselabs/charter_agreement_signer/blob/master/examples/charter_signing_roundtrip.livemd)
  runs this same descriptor flow interactively.
