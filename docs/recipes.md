# Recipes

Four integration shapes: a network-HSM key handle, a KMS key-identity handle,
a counterparty verifier, and a porting note for non-Elixir signers.
The HSM/KMS adapters are integration templates: they compile against this
package but require your configured client and a real custody service to run.
Their callback contracts are specified below. For an executable in-memory
demo with real Ed25519 signatures, start with [Getting started](getting-started.md).

## Recipe: a network-HSM key handle

Requires: nothing beyond this package (the HSM client is injected via config
— your client module is the integration point).

The handle's `sign/2` fronts a network HSM. The two properties that matter:
the callback must return the closed `{:ok, binary} | {:error, term}`
contract, and a TIMEOUT (a `GenServer.call` exit) must not escape — the
signer's `safe_callback` catch-all maps an exited callback to a closed error
rather than crashing your caller, so return errors explicitly whenever you
can.

```elixir
defmodule MyApp.HsmHandle do
  @moduledoc """
  Key handle backed by a network HSM. The handle term is the HSM's key
  reference (never key material). The client module is injected:

      config :my_app, :hsm_client, MyApp.HsmClient

  The client implements sign_ed25519/2 and key_identity/1. Its identity
  call returns {:ok, {kid, public_key}} from one atomic observation of the
  same immutable key version used for signing. It never exports private keys.

  A client timeout (a GenServer.call exit) never crashes your caller — the
  signer's safe_callback exit-catch contains it. WHERE it surfaces depends
  on the callback: a sign/2 timeout maps to :signing_failed; a
  key_identity/1 timeout maps to :invalid_key_handle.
  """

  @behaviour CharterAgreementSigner

  @impl true
  def sign(message, hsm_key_ref) when is_binary(message) do
    client().sign_ed25519(hsm_key_ref, message)
  end

  def sign(_message, _ref), do: {:error, :invalid_handle}

  @impl true
  def key_identity(hsm_key_ref) do
    client().key_identity(hsm_key_ref)
  end

  # The atomic-snapshot rule: kid AND public key from ONE consistent view of
  # the HSM's key state. If your HSM can rotate between two lookups, resolve
  # both inside the client's single call — a snapshot that splits across a
  # rotation is exactly the race the rule exists to prevent (the signer's
  # wrong-key guard catches the aftermath loudly, but loudly is still an
  # outage).
  defp client, do: Application.fetch_env!(:my_app, :hsm_client)
end
```

## Recipe: a KMS key-identity handle

Requires: nothing beyond this package (the KMS adapter is injected the same
way). The client implements `sign/2`, returning a raw signature or error,
and `describe_signing_key/1`, returning `{:ok, %{kid: binary, public_key: binary}}`
from one consistent snapshot of that immutable key version. Some KMSes expose
the public key and key id through different calls than signing — keep all three behind ONE module
and keep `key_identity/1` a single consistent observation.

```elixir
defmodule MyApp.KmsHandle do
  @behaviour CharterAgreementSigner

  # ref names an immutable Ed25519 key version, never a mutable rotation alias.
  # Configure :my_app, :kms_client with your client module.
  @impl true
  def sign(message, kms_ref) when is_binary(message) do
    case client().sign(kms_ref, message) do
      {:ok, <<sig::binary-size(64)>>} -> {:ok, sig}
      {:ok, _wrong_size} -> {:error, :kms_bad_signature_size}
      {:error, reason} -> {:error, reason}
    end
  end

  def sign(_message, _ref), do: {:error, :invalid_handle}

  @impl true
  def key_identity(kms_ref) do
    # One describe call, both facts — never two.
    with {:ok, %{kid: kid, public_key: <<_::256>> = public}} <-
           client().describe_signing_key(kms_ref) do
      {:ok, {kid, public}}
    end
  end

  # Optional caller self-check. CAP also checks the snapshot against the
  # holder's own descriptor before the custody callback runs.
  @impl true
  def public_key(kms_ref), do: key_identity(kms_ref) |> then(fn
    {:ok, {_kid, public}} -> {:ok, public}
    error -> error
  end)

  defp client, do: Application.fetch_env!(:my_app, :kms_client)
end
```

Note the wrong-size signature clause: this signer checks the signature's
length against the selected algorithm's registry row — 64 bytes for
`Ed25519`, 3309 for `ML-DSA-65` — and rejects a mismatch as
`:signing_failed` after `sign/2` returns it; mapping the size check to your
own error keeps the failure cause readable at the boundary. (The sample
handle above is written for an Ed25519 key — a `binary-size(64)` clause and
a 256-bit public key — so an ML-DSA-65 flow needs its own length clauses.)

## Recipe: the counterparty verifier (no signer dependency)

The receiving side of any artifact this library signs depends only on CAP:

```elixir
defmodule MyApp.Counterparty do
  alias CharterAgreementProtocol, as: CAP

  # Collapses to closed atoms at the boundary — never echo raw protocol
  # errors or claims content outward (they are value-free BY CAP's design;
  # keep them that way through your layers).
  def verify_acceptance(acceptance_compact, revision, issuer_descriptor_compact) do
    limits = CAP.Limits.default()

    with {:ok, chain} <- CAP.verify_descriptor_chain([issuer_descriptor_compact], limits),
         {:ok, _facts} <- CAP.verify_acceptance(acceptance_compact, revision, chain, limits) do
      :ok
    else
      {:error, %CAP.Error{code: :signature_invalid}} -> {:error, :bad_signature}
      {:error, %CAP.Error{}} -> {:error, :bad_artifact}
    end
  end
end
```

Full walkthrough: [consumer-integration.md](consumer-integration.md).

## Porting note: a non-Elixir signer

A signer in any language produces conformant artifacts by following CAP's
specification alone: build the exact RFC 7515 signing input (protected
header `{alg, kid, typ}` + canonical payload), sign it with the chosen
emission algorithm's key, attach the raw signature at that algorithm's exact
length. `alg` is the registry's emission name — `"Ed25519"` at
`protocol_revision` 2, or `"ML-DSA-65"` at `protocol_revision` 3; the
binding rule rejects `(revision 1, "Ed25519")` and any name below its
minimum revision, while legacy `"EdDSA"` artifacts remain verifiable. Three
disciplines travel with the port:

1. The atomic kid+public-key snapshot, and the wrong-key verify-before-return
   guard, are not Elixir conveniences — they are the failure modes the
   custody boundary must not have (silent `{pub_A, sig_B}` successes).
2. Mint at one of the protocol's two emission identities exactly —
   (`"Ed25519"`, `protocol_revision` 2) or (`"ML-DSA-65"`,
   `protocol_revision` 3) — a port that hand-writes revision-1 claims or the
   deprecated `"EdDSA"` name is refused at best and nonconformant at worst.
3. Gate the port against both shipped corpora: CAP's 541-case verifier
   corpus and CAS's 121-row `priv/conformance/signer_cases.json`. Follow
   [CAP conformance](https://hexdocs.pm/charter_agreement_protocol/conformance.html)
   for byte-identical verifier reports. The signer rows also check callback
   counts, pre-custody refusals, exact Ed25519 compacts and verified ML-DSA
   successes. Keep prepare, wrong-key verification and finish as separate
   obligations; canonical JSON agreement alone does not certify a signer.
