defmodule CharterAgreementSignerTest do
  @moduledoc """
  Round-trips for all four signing surfaces: each sign path produces a
  compact that CAP's own public verify functions accept, the protected
  header's kid is ALWAYS the handle snapshot's, and the post-sign verify
  catches a snapshot key the party descriptor does not pin.
  """

  use ExUnit.Case, async: true

  alias CharterAgreementProtocol, as: CAP
  alias CharterAgreementProtocol.Limits
  alias CharterAgreementSigner.Keys.RawKey

  alias CharterAgreementSigner.{
    AcceptanceFixture,
    ChainFixture,
    ReceiptFixture,
    TerminationFixture
  }

  test "sign_descriptor round-trips through CAP verify with the snapshot kid" do
    setup = ChainFixture.base()
    handle = {RawKey, setup.issuer_handle}

    assert {:ok, %{descriptor: compact}} =
             CharterAgreementSigner.sign_descriptor(setup.issuer.claims, handle)

    assert {:ok, _facts} = CAP.verify_descriptor(compact, nil, Limits.default())

    assert header_kid(compact) == "issuer-key-001"
  end

  test "sign_acceptance round-trips through CAP verify against the retained view" do
    setup = ChainFixture.base()
    {:ok, set} = ChainFixture.raw_set(setup, [setup.genesis], [], [])
    claims = AcceptanceFixture.claims(setup.genesis, setup.issuer, "issuer")

    assert {:ok, %{acceptance: compact}} =
             CharterAgreementSigner.sign_acceptance(claims, {RawKey, setup.issuer_handle}, set)

    {:ok, revision} = CAP.decode_charter_revision(setup.genesis.bytes, Limits.default())
    {:ok, chain} = CAP.verify_descriptor_chain([setup.issuer.compact], Limits.default())

    assert {:ok, _facts} = CAP.verify_acceptance(compact, revision, chain, Limits.default())
  end

  test "sign_termination round-trips through CAP verify against the accepted view" do
    setup = ChainFixture.base()
    acceptances = ChainFixture.dual_acceptances(setup.genesis, setup)
    {:ok, set} = ChainFixture.raw_set(setup, [setup.genesis], acceptances, [])
    claims = TerminationFixture.claims(setup.genesis, setup.issuer, "issuer")

    assert {:ok, %{termination: compact}} =
             CharterAgreementSigner.sign_termination(claims, {RawKey, setup.issuer_handle}, set)

    {:ok, revision} = CAP.decode_charter_revision(setup.genesis.bytes, Limits.default())
    {:ok, chain} = CAP.verify_descriptor_chain([setup.issuer.compact], Limits.default())

    assert {:ok, _facts} = CAP.verify_termination(compact, revision, chain, Limits.default())
  end

  test "sign_receipt round-trips through CAP verify against the revision context" do
    setup = ChainFixture.base()
    {:ok, revision} = CAP.decode_charter_revision(setup.genesis.bytes, Limits.default())
    claims = ReceiptFixture.claims(setup.genesis)

    assert {:ok, %{receipt: compact}} =
             CharterAgreementSigner.sign_receipt(claims, {RawKey, setup.issuer_handle}, revision)

    assert {:ok, _facts} = CAP.verify_receipt(compact, revision, Limits.default())
  end

  test "the post-sign verify rejects a snapshot key the descriptor does not pin" do
    setup = ChainFixture.base()
    # A handle whose key is NOT the descriptor's pinned key: the producer and
    # the crypto guard both pass (the handle signs with exactly the key it
    # advertises), but CAP's descriptor verify fails — so the signer must
    # refuse to return the artifact.
    stranger = RawKey.generate("stranger-key-001", <<7::256>>)

    assert {:error, :verification_failed} =
             CharterAgreementSigner.sign_descriptor(setup.issuer.claims, {RawKey, stranger})
  end

  test "a successor descriptor requires predecessor facts for the post-sign verify" do
    setup = ChainFixture.base()
    # Signing the SAME genesis claims while claiming descriptor_number 2 via
    # claims override: CAP's producer accepts the claims shape, the signature
    # verifies, but verify_descriptor with a nil predecessor cannot verify a
    # non-genesis descriptor — surfaced here as :verification_failed, never a
    # silent success.
    successor_claims =
      Map.merge(setup.issuer.claims, %{
        "descriptor_number" => 2,
        "party_id" => setup.issuer.party_id,
        "prev_descriptor_digest" => setup.issuer.digest
      })

    assert {:error, :verification_failed} =
             CharterAgreementSigner.sign_descriptor(
               successor_claims,
               {RawKey, setup.issuer_handle}
             )
  end

  test "invalid limits are rejected as input, not as verification failures" do
    setup = ChainFixture.base()

    assert {:error, {:invalid_input, :invalid_limits}} =
             CharterAgreementSigner.sign_descriptor(
               setup.issuer.claims,
               {RawKey, setup.issuer_handle},
               %{
                 limits: :not_limits
               }
             )
  end

  defp header_kid(compact) do
    [protected_segment, _payload_segment, _signature] = String.split(compact, ".")

    {:ok, protected_bytes} = CharterAgreementProtocol.Base64Url.decode(protected_segment)
    %{"kid" => kid} = JSON.decode!(protected_bytes)
    kid
  end
end
