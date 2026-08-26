defmodule CharterLifecycleTest do
  @moduledoc """
  The full bilateral round-trip plus the rejection classes that must never
  cross the exchange: a wrong-key custody is refused loudly, and a
  non-compact handoff collapses to :rejected with no detail riding along.
  """

  use ExUnit.Case, async: true

  alias CharterAgreementSigner, as: Signer
  alias CharterLifecycle.{Charter, Counterparty, Exchange, Keys, Keys.Handle}

  alias CharterAgreementProtocol, as: CAP

  test "the complete lifecycle round-trips and every artifact verifies" do
    result = CharterLifecycle.run()

    # Every compact the counterparty received verifies from scratch, CAP-only.
    assert :ok = Counterparty.verify_descriptor(result.issuer_descriptor)
    assert :ok = Counterparty.verify_descriptor(result.acceptor_descriptor)

    {:ok, revision} = CAP.decode_charter_revision(result.revision, CAP.Limits.default())
    assert :ok = Counterparty.verify_receipt(result.receipt, revision)

    assert result.wrong_key == :refused_loudly
    assert String.contains?(result.issuer_descriptor, ".")
  end

  test "a wrong-key custody never produces a deliverable artifact" do
    issuer = Keys.issuer()
    claims = Charter.descriptor_claims(issuer, "2026-08-26T10:00:00Z")

    assert {:error, :signing_failed} =
             Signer.sign_descriptor(claims, {Handle, Keys.rogue_issuer()})

    # And the boundary collapses it to the closed atom with no detail.
    assert {:error, :signing_failed} =
             Exchange.deliver_result({:error, :signing_failed})
  end

  test "the exchange boundary collapses failures without leaking detail" do
    # Transport moves bytes; anything not a deliverable binary is refused.
    # (Garbage STRINGS ride the transport like any bytes would — verification
    # at the receiving side is what catches them; the Exchange is not a
    # verifier by design.)
    assert {:error, :rejected} = Exchange.deliver(42)
    assert {:error, :rejected} = Exchange.deliver(nil)

    # Pair-shaped errors collapse to their kind atom — CAP's code detail
    # never crosses the boundary.
    assert {:error, :invalid_input} =
             Exchange.deliver_result({:error, {:invalid_input, :compact_invalid}})

    assert {:error, :rejected} = Exchange.deliver_result(:off_spec)
  end
end
