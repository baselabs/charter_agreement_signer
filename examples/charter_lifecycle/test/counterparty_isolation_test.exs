defmodule CharterLifecycle.CounterpartyIsolationTest do
  @moduledoc """
  The mechanical half of the counterparty contract: the receiving side
  references ONLY charter_agreement_protocol — never the signer. The claim
  in docs/consumer-integration.md is prose; THIS is the proof. A drift (an
  import of the signer into Counterparty) reds here.
  """

  use ExUnit.Case, async: true

  test "the counterparty module references only CAP and the standard library" do
    source = File.read!(Path.expand("../lib/charter_lifecycle/counterparty.ex", __DIR__))

    assert source =~ "CharterAgreementProtocol",
           "the counterparty must verify through CAP"

    refute source =~ "CharterAgreementSigner",
           "the counterparty must never reference the signer (the wall)"

    refute source =~ "alias CharterLifecycle.{",
           "the counterparty must not pull host modules into its verify kit"
  end
end
