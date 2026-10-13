defmodule CharterAgreementSigner.AlgorithmTest do
  use ExUnit.Case, async: false

  alias CharterAgreementProtocol, as: CAP
  alias CharterAgreementProtocol.Limits

  alias CharterAgreementSigner.{
    AcceptanceFixture,
    ChainFixture,
    Keys.RawKey,
    ReceiptFixture,
    TerminationFixture
  }

  setup do
    Code.ensure_loaded!(RawKey)

    for {function, arity} <- [key_identity: 1, sign: 2] do
      :erlang.trace_pattern({RawKey, function, arity}, true, [:call_count])
    end

    on_exit(fn ->
      for {function, arity} <- [key_identity: 1, sign: 2] do
        :erlang.trace_pattern({RawKey, function, arity}, false, [:call_count])
      end
    end)

    setup = ChainFixture.base()
    handle = {RawKey, setup.issuer_handle}
    {:ok, pending} = ChainFixture.raw_set(setup, [setup.genesis], [], [])

    {:ok, accepted} =
      ChainFixture.raw_set(
        setup,
        [setup.genesis],
        ChainFixture.dual_acceptances(setup.genesis, setup),
        []
      )

    {:ok, revision} = CAP.decode_charter_revision(setup.genesis.bytes, Limits.default())

    calls = [
      fn opts ->
        CharterAgreementSigner.sign_descriptor(
          ChainFixture.mint(setup.issuer.claims),
          handle,
          opts
        )
      end,
      fn opts ->
        claims =
          ChainFixture.mint(AcceptanceFixture.claims(setup.genesis, setup.issuer, "issuer"))

        CharterAgreementSigner.sign_acceptance(claims, handle, pending, opts)
      end,
      fn opts ->
        claims =
          ChainFixture.mint(TerminationFixture.claims(setup.genesis, setup.issuer, "issuer"))

        CharterAgreementSigner.sign_termination(claims, handle, accepted, opts)
      end,
      fn opts ->
        claims = ChainFixture.mint(ReceiptFixture.claims(setup.genesis))
        CharterAgreementSigner.sign_receipt(claims, handle, revision, opts)
      end
    ]

    %{calls: calls}
  end

  test "absent and nil algorithms select the default on every entry point", %{calls: calls} do
    for call <- calls do
      assert {:ok, result} = call.(%{})
      assert {:ok, ^result} = call.(algorithm: nil)
      assert {:ok, ^result} = call.(%{algorithm: "Ed25519"})
    end

    assert {:call_count, 12} = :erlang.trace_info({RawKey, :key_identity, 1}, :call_count)
    assert {:call_count, 12} = :erlang.trace_info({RawKey, :sign, 2}, :call_count)
  end

  test "unsupported algorithms refuse before either key callback on every entry point", %{
    calls: calls
  } do
    for value <- [
          "",
          "EdDSA",
          "ML-DSA-44",
          "ML-DSA-87",
          :Ed25519,
          false,
          true,
          0,
          [],
          %{},
          {"Ed25519"}
        ],
        call <- calls,
        opts <- [%{algorithm: value}, [algorithm: value]] do
      assert {:error, {:invalid_input, :algorithm_unsupported}} = call.(opts)
    end

    assert {:call_count, 0} = :erlang.trace_info({RawKey, :key_identity, 1}, :call_count)
    assert {:call_count, 0} = :erlang.trace_info({RawKey, :sign, 2}, :call_count)
  end

  test "an unsupported string leaves the snapshot unused", %{calls: calls} do
    for call <- calls do
      assert {:error, {:invalid_input, :algorithm_unsupported}} =
               call.(algorithm: "unknown")
    end

    assert {:call_count, 0} = :erlang.trace_info({RawKey, :key_identity, 1}, :call_count)
    assert {:call_count, 0} = :erlang.trace_info({RawKey, :sign, 2}, :call_count)
  end
end
