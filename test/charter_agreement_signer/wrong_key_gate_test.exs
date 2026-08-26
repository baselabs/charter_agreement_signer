defmodule CharterAgreementSigner.WrongKeyGateTest do
  @moduledoc """
  The wrong-key gate — the red-capable proof that a `{pub_A, sig_B}` artifact
  can never leave a sign path as `{:ok, _}`.

  Non-vacuity: the rogue signature is proven STRUCTURALLY ASSEMBLABLE via
  CAP's own producer + assembler (nothing in the framing layer rejects it);
  the ONLY thing standing between it and `{:ok, _}` is the shared tail's
  verify_signature guard. Remove that guard and this suite goes red on the
  first assertion below while the manual assembly still succeeds.
  """

  use ExUnit.Case, async: true

  alias CharterAgreementProtocol, as: CAP
  alias CharterAgreementSigner.{AcceptanceFixture, ChainFixture, Keys.RogueKey}

  setup do
    setup = ChainFixture.base()

    rogue_private =
      :crypto.generate_key(:eddsa, :ed25519, <<9::256>>) |> elem(1)

    # Advertises the issuer's key A; signs with key B.
    rogue_handle =
      {elem(setup.issuer_handle, 0), elem(setup.issuer_handle, 1), rogue_private}

    %{setup: setup, rogue_handle: rogue_handle, rogue_private: rogue_private}
  end

  test "a wrong-key sign is :signing_failed on the descriptor path", %{
    setup: setup,
    rogue_handle: rogue_handle
  } do
    assert {:error, :signing_failed} =
             CharterAgreementSigner.sign_descriptor(setup.issuer.claims, {RogueKey, rogue_handle})
  end

  test "a wrong-key sign is :signing_failed on the set-based acceptance path", %{
    setup: setup,
    rogue_handle: rogue_handle
  } do
    {:ok, set} = ChainFixture.raw_set(setup, [setup.genesis], [], [])
    claims = AcceptanceFixture.claims(setup.genesis, setup.issuer, "issuer")

    assert {:error, :signing_failed} =
             CharterAgreementSigner.sign_acceptance(claims, {RogueKey, rogue_handle}, set)
  end

  test "the rogue signature is structurally assemblable — the guard is the only rejection point",
       %{setup: setup, rogue_private: rogue_private} do
    {:ok, input} =
      CAP.descriptor_signing_input(%{
        "kid" => elem(setup.issuer_handle, 0),
        "claims" => setup.issuer.claims
      })

    signature =
      :crypto.sign(:eddsa, :none, input.message, [rogue_private, :ed25519])

    # CAP's assembler accepts it: correct shape, correct 64-byte signature —
    # the framing layer cannot know which key was intended. Only the signer's
    # guard verifies the signature against the advertised public key.
    assert {:ok, compact} = CAP.assemble_compact(input, signature)

    # And the protocol verifier rejects the very same bytes — proving the
    # artifact the guard suppressed was genuinely bad, not merely unproven.
    assert {:error, %CAP.Error{}} = CAP.verify_descriptor(compact, nil, CAP.Limits.default())
  end
end
