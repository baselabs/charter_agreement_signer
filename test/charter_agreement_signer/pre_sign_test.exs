defmodule CharterAgreementSigner.PreSignTest do
  use ExUnit.Case, async: false

  alias CharterAgreementProtocol, as: CAP
  alias CharterAgreementProtocol.{Capability.Profile, Limits}
  alias CharterAgreementSigner.Keys.{RawKey, RawMLDSA65}

  alias CharterAgreementSigner.{
    AcceptanceFixture,
    ChainFixture,
    ReceiptFixture,
    TerminationFixture
  }

  setup do
    for module <- [RawKey, RawMLDSA65] do
      Code.ensure_loaded!(module)
      :erlang.trace_pattern({module, :sign, 2}, true, [:call_count])
      :erlang.trace_pattern({module, :key_identity, 1}, true, [:call_count])
    end

    on_exit(fn ->
      for module <- [RawKey, RawMLDSA65], {function, arity} <- [sign: 2, key_identity: 1] do
        :erlang.trace_pattern({module, function, arity}, false, [:call_count])
      end
    end)

    setup = ChainFixture.base()
    {:ok, pending} = ChainFixture.raw_set(setup, [setup.genesis], [], [])

    {:ok, accepted} =
      ChainFixture.raw_set(
        setup,
        [setup.genesis],
        ChainFixture.dual_acceptances(setup.genesis, setup),
        []
      )

    {:ok, revision} = CAP.decode_charter_revision(setup.genesis.bytes, Limits.default())

    {:ok, chain} =
      CAP.verify_chain(
        accepted.revisions,
        accepted.acceptances,
        accepted.descriptors,
        [],
        Limits.default()
      )

    {:ok, predecessor} = CAP.verify_descriptor(setup.issuer.compact, nil, Limits.default())
    descriptor = ChainFixture.mint(setup.issuer.claims)
    receipt = ChainFixture.mint(ReceiptFixture.claims(setup.genesis))

    calls = [
      fn handle, opts -> CharterAgreementSigner.sign_descriptor(descriptor, handle, opts) end,
      fn handle, opts ->
        CharterAgreementSigner.sign_acceptance(
          ChainFixture.mint(AcceptanceFixture.claims(setup.genesis, setup.issuer, "issuer")),
          handle,
          pending,
          opts
        )
      end,
      fn handle, opts ->
        CharterAgreementSigner.sign_termination(
          ChainFixture.mint(TerminationFixture.claims(setup.genesis, setup.issuer, "issuer")),
          handle,
          accepted,
          opts
        )
      end,
      fn handle, opts -> CharterAgreementSigner.sign_receipt(receipt, handle, revision, opts) end
    ]

    %{
      setup: setup,
      calls: calls,
      descriptor: descriptor,
      receipt: receipt,
      revision: revision,
      chain: chain,
      predecessor: predecessor
    }
  end

  defp refute_signed,
    do: assert({:call_count, 0} == :erlang.trace_info({RawKey, :sign, 2}, :call_count))

  test "limits, profile and algorithm resolve in order before the snapshot", %{
    calls: calls,
    setup: setup
  } do
    for call <- calls do
      assert {:error, {:invalid_input, :invalid_limits}} =
               call.(:bad_handle, limits: nil, profile: nil, algorithm: "unknown")

      assert {:error, {:invalid_input, :invalid_profile}} =
               call.(:bad_handle, profile: nil, algorithm: "unknown")

      assert {:error, {:invalid_input, :algorithm_unsupported}} =
               call.(:bad_handle, algorithm: "unknown")

      assert {:error, {:invalid_input, :invalid_profile}} =
               call.({RawKey, setup.issuer_handle}, profile: nil)
    end

    assert {:call_count, 0} = :erlang.trace_info({RawKey, :key_identity, 1}, :call_count)
    refute_signed()
  end

  test "malformed profile fields reject before custody", %{calls: calls, setup: setup} do
    for profile <- [
          nil,
          %{},
          %Profile{algorithms: [], revisions: {1, 3}},
          %Profile{algorithms: ["Ed25519" | 42], revisions: {1, 3}},
          %Profile{algorithms: ["Ed25519"], revisions: :bad}
        ],
        call <- calls do
      assert {:error, {:invalid_input, :invalid_profile}} =
               call.({RawKey, setup.issuer_handle}, profile: profile)
    end

    refute_signed()
  end

  test "profile excludes predecessor history before signing", %{
    descriptor: descriptor,
    predecessor: predecessor,
    setup: setup
  } do
    claims =
      Map.merge(descriptor, %{
        "descriptor_number" => 2,
        "party_id" => setup.issuer.digest,
        "prev_descriptor_digest" => setup.issuer.digest
      })

    {:ok, profile} = Profile.new(algorithms: ["Ed25519"])

    assert {:error, {:invalid_input, :algorithm_outside_profile}} =
             CharterAgreementSigner.sign_descriptor(claims, {RawKey, setup.issuer_handle},
               predecessor: predecessor,
               profile: profile
             )

    refute_signed()
  end

  test "profile excludes a receipt chain artifact before signing", %{
    chain: chain,
    receipt: receipt,
    setup: setup
  } do
    {:ok, profile} = Profile.new(algorithms: ["Ed25519"])

    assert {:error, {:invalid_input, :algorithm_outside_profile}} =
             CharterAgreementSigner.sign_receipt(receipt, {RawKey, setup.issuer_handle}, chain,
               profile: profile
             )

    refute_signed()
  end

  test "malformed retained receipt fields return typed errors before signing", %{
    chain: chain,
    revision: revision,
    receipt: receipt,
    setup: setup
  } do
    [acceptance | rest] = chain.acceptance_facts
    envelope = %{acceptance.acceptance.envelope | signature: :invalid}
    corrupted = %{acceptance | acceptance: %{acceptance.acceptance | envelope: envelope}}
    bad_chain = %{chain | acceptance_facts: [corrupted | rest]}

    for {context, code} <- [
          {%{chain | descriptor_chains: [nil]}, :receipt_invalid},
          {%{chain | revision_facts: [nil | 42]}, :receipt_invalid},
          {bad_chain, :receipt_invalid},
          {%{revision | canonical_bytes: 42}, :invalid_type}
        ] do
      assert {:error, {:invalid_input, ^code}} =
               CharterAgreementSigner.sign_receipt(
                 receipt,
                 {RawKey, setup.issuer_handle},
                 context
               )
    end

    refute_signed()
  end

  test "malformed predecessor fields return typed errors before signing", %{
    descriptor: descriptor,
    predecessor: predecessor,
    setup: setup
  } do
    claims =
      Map.merge(descriptor, %{
        "descriptor_number" => 2,
        "party_id" => setup.issuer.digest,
        "prev_descriptor_digest" => setup.issuer.digest
      })

    for bad <- [
          %{predecessor | lineage: [setup.issuer.compact | 42]},
          %{predecessor | descriptor: nil},
          %{predecessor | descriptor_number: :bad}
        ] do
      assert {:error, {:invalid_input, :descriptor_chain_invalid}} =
               CharterAgreementSigner.sign_descriptor(claims, {RawKey, setup.issuer_handle},
                 predecessor: bad
               )
    end

    refute_signed()
  end

  test "snapshot binary shape precedes CAP's selected key length check", %{
    descriptor: descriptor,
    setup: setup
  } do
    {kid, _public, private} = setup.issuer_handle

    assert {:error, {:invalid_input, :signing_input_invalid}} =
             CharterAgreementSigner.sign_descriptor(%{}, {RawMLDSA65, {kid, "short", private}})

    assert {:error, :invalid_key_handle} =
             CharterAgreementSigner.sign_descriptor(
               descriptor,
               {RawMLDSA65, {kid, "short", private}}
             )

    assert {:call_count, 0} = :erlang.trace_info({RawMLDSA65, :sign, 2}, :call_count)
    refute_signed()
  end

  test "raised limits reach CAP preparation and finish", %{
    receipt: receipt,
    revision: revision,
    setup: setup
  } do
    claims =
      put_in(receipt["extensions"]["optional"], %{
        "com.example/pad" => String.duplicate("x", 800_000)
      })

    handle = {RawKey, setup.issuer_handle}

    assert {:error, {:invalid_input, :signing_input_invalid}} =
             CharterAgreementSigner.sign_receipt(claims, handle, revision)

    refute_signed()
    {:ok, limits} = Limits.new(max_bytes: 2_000_000, max_string_bytes: 900_000)

    assert {:ok, %{receipt: compact}} =
             CharterAgreementSigner.sign_receipt(claims, handle, revision, limits: limits)

    assert byte_size(compact) > Limits.default().max_bytes
    assert {:ok, _facts} = CAP.verify_receipt(compact, revision, limits)
  end
end
