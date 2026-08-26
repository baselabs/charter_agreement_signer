# Getting started

A five-minute path from install to a verified signed descriptor. Everything
here runs with no database, no services, and no network beyond `mix deps.get`.

## 1. Install

```elixir
def deps do
  [
    {:charter_agreement_signer, "~> 0.1"}
  ]
end
```

## 2. Implement a key handle

The handle is a `{module, ref}` pair. The module implements the behaviour
against your custody. The smallest honest in-process version (test/development
posture only — production points this at an HSM or KMS):

```elixir
defmodule MyApp.PartyHandle do
  @behaviour CharterAgreementSigner

  # ref is whatever your custody needs: a kid into your key server, an
  # HSM slot, an agent reference in tests.
  @impl true
  def sign(message, ref) do
    {:ok, private} = MyApp.Custody.private_for(ref)
    {:ok, :crypto.sign(:eddsa, :none, message, [private, :ed25519])}
  end

  @impl true
  def key_identity(ref) do
    with {:ok, kid} <- MyApp.Custody.kid_for(ref),
         {:ok, public} <- MyApp.Custody.public_for(ref) do
      {:ok, {kid, public}}
    end
  end
end
```

`key_identity/1` is the atomic snapshot: kid AND public key resolved in ONE
call against your key store, so a rotation between the two lookups cannot
produce an inconsistent header.

## 3. Sign a party descriptor

Claims are the descriptor's payload — including the `verification_keys` list
that pins your public key. The header `kid` comes from the handle, never from
the claims:

```elixir
public = MyApp.Custody.public_for!(ref)

claims = %{
  "protocol_revision" => 1,
  "descriptor_number" => 1,
  "verification_keys" => [
    %{
      "key_id" => "issuer-2026-08",
      "algorithm" => "Ed25519",
      "public_key" => Base.url_encode64(public, padding: false),
      "status" => "active"
    }
  ],
  "attestation_hints" => [],
  "extensions" => %{"critical" => %{}, "optional" => %{}},
  "effective_from" => "2026-08-26T10:00:00Z"
}

{:ok, %{descriptor: compact}} =
  CharterAgreementSigner.sign_descriptor(claims, {MyApp.PartyHandle, ref})
```

The returned compact is already verified: `CAP.verify_descriptor/3` ran
inside `sign_descriptor/3` before returning. A counterparty verifies the same
bytes with the protocol package alone.

## 4. Sign acceptances and terminations against your retained view

The set-aware paths take the artifact view you retain
(`CAP.build_set/4` over raw compacts). CAP runs the honest-signer refusals
against it BEFORE your key is used:

```elixir
{:ok, set} = CharterAgreementProtocol.build_set(
  [genesis_revision_bytes],
  [],        # counterparty acceptances you retained
  [],        # terminations
  [issuer_descriptor_compact, acceptor_descriptor_compact]
)

{:ok, %{acceptance: compact}} =
  CharterAgreementSigner.sign_acceptance(acceptance_claims, {MyApp.PartyHandle, ref}, set)
```

If the claims contradict the view — false revision coordinates, an
equivocating revision number, an ancestry that excludes an accepted head —
you get `{:error, {:refused, :signing_refused}}` and no signature exists.

## 5. Read the error vocabulary

Every failure is a closed atom or `{:invalid_input, cap_code}` — see
[errors.md](errors.md). Nothing in any error carries key material, message
bytes, or claims content.

## Where to go next

- [errors.md](errors.md) — the full closed error set and what each one means
  for the caller.
- [security.md](security.md) — trust boundaries, the wrong-key guard, and
  what this library deliberately does not do.
- The protocol package's own docs — the verifier's side of every artifact
  this library signs.
