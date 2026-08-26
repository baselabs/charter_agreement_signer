defmodule CharterAgreementSigner.RefusalTest do
  @moduledoc """
  CAP's honest-signer refusals (R1–R3) surface BEFORE the key is used, and
  producer/set rejections keep CAP's typed codes — neither is flattened into
  a generic failure that would hide WHY the signer refused.
  """

  use ExUnit.Case, async: true

  alias CharterAgreementSigner.{
    AcceptanceFixture,
    ChainFixture,
    CharterRevisionFixture,
    Keys.RawKey,
    TerminationFixture
  }

  setup do
    setup = ChainFixture.base()
    {:ok, set} = ChainFixture.raw_set(setup, [setup.genesis], [], [])
    %{setup: setup, set: set}
  end

  defp successor(predecessor, number, legal_text) do
    claims =
      CharterRevisionFixture.base_claims(legal_text)
      |> Map.merge(%{
        "charter_id" => predecessor.charter_id,
        "revision_number" => number,
        "prev_revision_digest" => predecessor.digest,
        "effective_from" => "2026-08-25T12:00:0#{number}Z",
        "parties" => predecessor.claims["parties"]
      })

    CharterRevisionFixture.from_claims(claims, legal_text, charter_id: predecessor.charter_id)
  end

  test "false revision coordinates are refused before the key is used", %{
    setup: setup,
    set: set
  } do
    false_claims =
      AcceptanceFixture.claims(setup.genesis, setup.issuer, "issuer", %{
        "revision_digest" =>
          CharterRevisionFixture.tagged(:charter_revision_content, "not-retained")
      })

    assert {:error, {:refused, :signing_refused}} =
             CharterAgreementSigner.sign_acceptance(
               false_claims,
               {RawKey, setup.issuer_handle},
               set
             )
  end

  test "equivocation at an occupied revision number is refused", %{setup: setup} do
    left = successor(setup.genesis, 2, "left\n")
    right = successor(setup.genesis, 2, "right\n")

    {_claims, right_acceptance} =
      ChainFixture.acceptance(right, setup.issuer, setup.issuer_handle, "issuer")

    {:ok, fork_set} =
      ChainFixture.raw_set(setup, [setup.genesis, left, right], [right_acceptance], [])

    left_claims = AcceptanceFixture.claims(left, setup.issuer, "issuer")

    assert {:error, {:refused, :signing_refused}} =
             CharterAgreementSigner.sign_acceptance(
               left_claims,
               {RawKey, setup.issuer_handle},
               fork_set
             )
  end

  test "an unlisted termination reason is refused", %{setup: setup, set: set} do
    claims =
      TerminationFixture.claims(setup.genesis, setup.issuer, "issuer", %{
        "reason_code" => "not-in-charter"
      })

    assert {:error, {:refused, :signing_refused}} =
             CharterAgreementSigner.sign_termination(claims, {RawKey, setup.issuer_handle}, set)
  end

  test "a stale termination (non-governing revision) is refused", %{setup: setup} do
    advanced = successor(setup.genesis, 2, "amended\n")

    acceptances =
      ChainFixture.dual_acceptances(setup.genesis, setup) ++
        ChainFixture.dual_acceptances(advanced, setup)

    {:ok, advanced_set} = ChainFixture.raw_set(setup, [setup.genesis, advanced], acceptances, [])

    stale_claims = TerminationFixture.claims(setup.genesis, setup.issuer, "issuer")

    assert {:error, {:refused, :signing_refused}} =
             CharterAgreementSigner.sign_termination(
               stale_claims,
               {RawKey, setup.issuer_handle},
               advanced_set
             )
  end

  test "invalid claims shapes keep CAP's typed code", %{setup: setup} do
    for bad <- [%{atom_key: "bad"}, %{"bad" => fn -> :bad end}, "not-a-map"] do
      assert {:error, {:invalid_input, :signing_input_invalid}} =
               CharterAgreementSigner.sign_descriptor(bad, {RawKey, setup.issuer_handle})
    end
  end

  test "a malformed artifact set keeps CAP's typed code", %{setup: setup} do
    {:ok, malformed_set} =
      CharterAgreementProtocol.ArtifactSet.build(
        [setup.genesis.bytes],
        ["not-a-compact-jws"],
        [],
        ChainFixture.descriptors(setup)
      )

    claims = AcceptanceFixture.claims(setup.genesis, setup.issuer, "issuer")

    assert {:error, {:invalid_input, :compact_invalid}} =
             CharterAgreementSigner.sign_acceptance(
               claims,
               {RawKey, setup.issuer_handle},
               malformed_set
             )
  end
end
