# Recipes

Four integration shapes: a network-HSM key handle, a KMS key-identity handle,
a counterparty verifier, and a porting note for non-Elixir signers. Runnable
shapes, not a runnable app — each code block compiles as written against
this package + the named dependencies. The HSM/KMS recipes reference your
client module via config; compiling them as-is emits undefined-integration
warnings naming exactly those modules — that is the paste-verify passing
(the marked integration points are yours to fill).

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

      config :my_app, :hsm_client, MyApp.HsmClient  # implements sign_ed25519/2

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
    with {:ok, kid} <- client().key_id(hsm_key_ref),
         {:ok, public} <- client().public_key(hsm_key_ref) do
      {:ok, {kid, public}}
    end
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
way). The point of this shape: some KMSes expose the public key and the key
id through different calls than signing — keep all three behind ONE module
and keep `key_identity/1` a single consistent observation.

```elixir
defmodule MyApp.KmsHandle do
  @behaviour CharterAgreementSigner

  # ref is the KMS key ARN or alias.
  @impl true
  def sign(message, kms_ref) when is_binary(message) do
    case MyApp.Kms.sign(kms_ref, message) do
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
           MyApp.Kms.describe_signing_key(kms_ref) do
      {:ok, {kid, public}}
    end
  end

  # Optional self-check surface: compare against the party descriptor's
  # verification_keys BEFORE signing, so a mismatched descriptor is caught
  # by you — not by the post-sign verify.
  @impl true
  def public_key(kms_ref), do: key_identity(kms_ref) |> then(fn
    {:ok, {_kid, public}} -> {:ok, public}
    error -> error
  end)
end
```

Note the wrong-size signature clause: this signer rejects any non-64-byte
signature as `:signing_failed` after `sign/2` returns it — mapping the size
check to your own error keeps the failure cause readable at the boundary.

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
header `{alg, kid, typ}` + canonical payload), sign it with Ed25519, attach
the raw 64-byte signature. `alg` is the registry's emission name —
`"Ed25519"` at `protocol_revision` 2; the binding rule rejects
`(revision 1, "Ed25519")`, while legacy `"EdDSA"` artifacts remain
verifiable. Three disciplines travel with the port:

1. The atomic kid+public-key snapshot, and the wrong-key verify-before-return
   guard, are not Elixir conveniences — they are the failure modes the
   custody boundary must not have (silent `{pub_A, sig_B}` successes).
2. Mint at the protocol's current emission identity exactly (`"Ed25519"`,
   `protocol_revision` 2) — a port that hand-writes revision-1 claims or the
   deprecated `"EdDSA"` name is refused at best and nonconformant at worst.
3. Gate the port against CAP's published conformance corpus (its
   `docs/test-vectors.md` manifest defines the byte-agreement procedure) —
   canonical-JSON construction is where cross-language implementations
   diverge, and the corpus is what catches it.
