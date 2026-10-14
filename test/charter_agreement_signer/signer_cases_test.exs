defmodule CharterAgreementSigner.SignerCasesTest do
  use ExUnit.Case, async: false

  alias CharterAgreementProtocol, as: CAP
  alias CharterAgreementProtocol.{Capability.Profile, Limits}
  alias CharterAgreementSigner.Keys.{RawKey, RawMLDSA65}

  @table File.read!(Path.expand("../fixtures/signer_cases.json", __DIR__)) |> JSON.decode!()

  @required_ids ~w(
    ed-descriptor-ok
    ed-acceptance-ok
    ed-termination-ok
    ed-receipt-ok
    ed-successor-ok
    ml-descriptor-ok
    ml-acceptance-ok
    ml-termination-ok
    ml-receipt-ok
    ml-successor-ok
    ed-receipt-chain-ok
    ed-receipt-first-candidate-ok
    ed-receipt-second-candidate-ok
    descriptor-ed-other-mismatch
    descriptor-ed-same-kid-mismatch
    acceptance-ed-other-mismatch
    acceptance-ed-same-kid-mismatch
    termination-ed-other-mismatch
    termination-ed-same-kid-mismatch
    receipt-ed-other-mismatch
    receipt-ed-same-kid-mismatch
    descriptor-invalid-key
    descriptor-no-curve-point
    descriptor-identity-negative-zero
    descriptor-order-two-negative-zero
    descriptor-mixed-order
    acceptance-other-role-key
    termination-other-role-key
    receipt-other-role-key
    acceptance-false-coordinates
    termination-unlisted-reason
    receipt-claims-mismatch
    acceptance-bad-set
    ed-successor-missing
    ed-successor-wrong
    ml-successor-missing
    ml-successor-wrong
    descriptor-unknown-algorithm
    descriptor-invalid-profile
    descriptor-excluded-artifact
    descriptor-excluded-revision
    acceptance-unknown-algorithm
    acceptance-invalid-profile
    acceptance-excluded-artifact
    acceptance-excluded-revision
    termination-unknown-algorithm
    termination-invalid-profile
    termination-excluded-artifact
    termination-excluded-revision
    receipt-unknown-algorithm
    receipt-invalid-profile
    receipt-excluded-artifact
    receipt-excluded-revision
    descriptor-malformed-context
    acceptance-malformed-context
    termination-malformed-context
    receipt-malformed-context
    acceptance-excluded-context
    descriptor-final-bound-minus-one
    descriptor-final-bound-exact
    acceptance-substrate-context
    descriptor-wrong-kid
    descriptor-non-string-algorithm
    acceptance-wrong-kid
    acceptance-non-string-algorithm
    acceptance-final-bound-minus-one
    termination-wrong-kid
    termination-non-string-algorithm
    termination-final-bound-minus-one
    receipt-wrong-kid
    receipt-non-string-algorithm
    receipt-final-bound-minus-one
    acceptance-unheld-successor
    descriptor-excluded-context
    descriptor-invalid-limits
    descriptor-unknown-option
    descriptor-options-before-limits
    descriptor-limits-before-profile
    descriptor-profile-before-algorithm
    descriptor-algorithm-before-snapshot
    descriptor-malformed-snapshot
    descriptor-snapshot-before-claims
    descriptor-snapshot-before-context
    acceptance-invalid-limits
    acceptance-unknown-option
    acceptance-options-before-limits
    acceptance-limits-before-profile
    acceptance-profile-before-algorithm
    acceptance-algorithm-before-snapshot
    acceptance-malformed-snapshot
    acceptance-snapshot-before-claims
    acceptance-snapshot-before-context
    termination-invalid-limits
    termination-unknown-option
    termination-options-before-limits
    termination-limits-before-profile
    termination-profile-before-algorithm
    termination-algorithm-before-snapshot
    termination-malformed-snapshot
    termination-snapshot-before-claims
    termination-snapshot-before-context
    receipt-invalid-limits
    receipt-unknown-option
    receipt-options-before-limits
    receipt-limits-before-profile
    receipt-profile-before-algorithm
    receipt-algorithm-before-snapshot
    receipt-malformed-snapshot
    receipt-snapshot-before-claims
    receipt-snapshot-before-context
    ed-successor-key-mismatch
    descriptor-wrong-key-guard
    receipt-excluded-context
    acceptance-profile-counterparty
    acceptance-profile-own-chain
    acceptance-profile-context-revision
    termination-profile-counterparty
    termination-profile-own-chain
    termination-profile-context-revision
    termination-unheld-successor
    receipt-profile-counterparty
  )

  test "the table retains every required case and unique ids" do
    rows = @table["cases"]
    assert length(rows) >= 121
    ids = Enum.map(rows, & &1["id"])
    assert Enum.uniq(ids) == ids
    for id <- @required_ids, do: assert(id in ids, "missing required case: #{id}")
  end

  test "the counterparty profile termination has a governing revision" do
    row = Enum.find(@table["cases"], &(&1["id"] == "termination-profile-counterparty"))
    set = context(row["context"])

    assert {:ok, chain} =
             CAP.verify_chain(
               set.revisions,
               set.acceptances,
               set.descriptors,
               set.terminations,
               Limits.default()
             )

    {:ok, at} = CAP.Timestamp.parse(row["claims"]["effective_at"])
    digest = row["claims"]["governing_revision_digest"]
    assert {:ok, ^digest} = CAP.governing_revision(chain, at)

    %{profile: profile} = options(row["options"])

    excluded =
      Enum.filter(set.descriptors, fn compact ->
        {:ok, descriptor} = CAP.PartyDescriptor.decode(compact, Limits.default())
        descriptor.envelope.alg not in profile.algorithms
      end)

    assert length(excluded) == 1
  end

  test "the counterparty profile acceptance is new to the set" do
    row = Enum.find(@table["cases"], &(&1["id"] == "acceptance-profile-counterparty"))
    set = context(row["context"])
    refute row["expected"]["compact"] in set.acceptances
  end

  setup do
    for module <- [RawKey, RawMLDSA65] do
      Code.ensure_loaded!(module)

      for {function, arity} <- [key_identity: 1, sign: 2] do
        :erlang.trace_pattern({module, function, arity}, true, [:call_count])
      end
    end

    on_exit(fn ->
      for module <- [RawKey, RawMLDSA65], {function, arity} <- [key_identity: 1, sign: 2] do
        :erlang.trace_pattern({module, function, arity}, false, [:call_count])
      end
    end)
  end

  for row <- @table["cases"] do
    @row row

    if row["requires_mldsa_substrate"] == true,
      do: @tag(:requires_mldsa_substrate)

    test row["id"] do
      row = @row
      key = @table["keys"][row["key"]]
      module = if key["algorithm"] == "Ed25519", do: RawKey, else: RawMLDSA65
      seed = Base.url_decode64!(key["seed"], padding: false)
      private = if module == RawKey, do: seed, else: {:seed, seed}
      private = if key["mixed_order"], do: {:mixed_order, seed}, else: private
      public = Base.url_decode64!(key["public_key"], padding: false)
      handle = {module, {key["kid"], public, private}}
      context = context(row["context"])
      options = options(row["options"])
      limited? = not CAP.Capability.kat_verifies?("ML-DSA-65")

      expected =
        if limited?, do: Map.get(row, "expected_limited", row["expected"]), else: row["expected"]

      result = sign(row["kind"], row["claims"], handle, context, options)

      assert outcome(result) == Map.take(expected, ["shape", "code"])
      assert {:call_count, called} = :erlang.trace_info({module, :sign, 2}, :call_count)
      if match?({:error, {:refused, _}}, result), do: assert(called == 0)
      if expected["shape"] == "refused", do: refute(expected["custody_called"])
      assert called == if(expected["custody_called"], do: 1, else: 0)

      assert {:call_count, snapshots} =
               :erlang.trace_info({module, :key_identity, 1}, :call_count)

      assert snapshots == if(expected["snapshot_called"], do: 1, else: 0)

      if expected["shape"] == "ok" do
        {:ok, result} = result
        result_key = String.to_existing_atom(row["kind"])
        assert Map.keys(result) == [result_key]
        compact = Map.fetch!(result, result_key)

        if key["algorithm"] == "Ed25519", do: assert(compact == expected["compact"])
        assert {:ok, _facts} = verify(row["kind"], compact, context)
      end
    end
  end

  defp context(name) when name in ["ml-predecessor", "ml-wrong-predecessor"] do
    predecessors =
      Path.expand("../fixtures/mldsa_predecessors.etf", __DIR__)
      |> File.read!()
      |> :erlang.binary_to_term()

    facts = Map.fetch!(predecessors, name)
    input = Map.fetch!(@table["contexts"], name)
    assert facts.lineage == input["descriptors"]

    if CAP.Capability.kat_verifies?("ML-DSA-65"), do: assert(facts == context(input))
    facts
  end

  defp context(name) when is_binary(name), do: context(Map.fetch!(@table["contexts"], name))

  defp context(%{"type" => "set"} = input) do
    {:ok, set} =
      CAP.build_set(
        input["revisions"],
        input["acceptances"],
        input["terminations"],
        input["descriptors"]
      )

    set
  end

  defp context(%{"type" => "chain"} = input) do
    {:ok, facts} =
      CAP.verify_chain(
        input["revisions"],
        input["acceptances"],
        input["descriptors"],
        input["terminations"],
        Limits.default()
      )

    facts
  end

  defp context(%{"type" => "revision", "text" => text}) do
    {:ok, revision} = CAP.decode_charter_revision(text, Limits.default())
    revision
  end

  defp context(%{"type" => "predecessor", "descriptors" => [compact]}) do
    {:ok, facts} = CAP.verify_descriptor(compact, nil, Limits.default())
    facts
  end

  defp context(value), do: value

  defp options(input) do
    Map.new(input, fn
      {"limits", values} ->
        {:limits,
         if(is_map(values), do: struct!(Limits.default(), atom_keys(values)), else: values)}

      {"profile", %{"algorithms" => names, "revisions" => [low, high]}} ->
        {:profile, %Profile{algorithms: names, revisions: {low, high}}}

      {"profile", value} ->
        {:profile, value}

      {"algorithm", value} ->
        {:algorithm, value}

      {"unexpected_option", value} ->
        {:unexpected_option, value}
    end)
  end

  defp atom_keys(map),
    do: Map.new(map, fn {key, value} -> {String.to_existing_atom(key), value} end)

  defp sign("descriptor", claims, handle, nil, options),
    do: CharterAgreementSigner.sign_descriptor(claims, handle, options)

  defp sign("descriptor", claims, handle, predecessor, options),
    do:
      CharterAgreementSigner.sign_descriptor(
        claims,
        handle,
        Map.put(options, :predecessor, predecessor)
      )

  defp sign("receipt", claims, handle, context, options),
    do: CharterAgreementSigner.sign_receipt(claims, handle, context, options)

  defp sign("acceptance", claims, handle, context, options),
    do: CharterAgreementSigner.sign_acceptance(claims, handle, context, options)

  defp sign("termination", claims, handle, context, options),
    do: CharterAgreementSigner.sign_termination(claims, handle, context, options)

  defp outcome({:ok, _result}), do: %{"shape" => "ok", "code" => nil}

  defp outcome({:error, {shape, code}}),
    do: %{"shape" => Atom.to_string(shape), "code" => Atom.to_string(code)}

  defp outcome({:error, code}),
    do: %{"shape" => Atom.to_string(code), "code" => Atom.to_string(code)}

  defp verify("descriptor", compact, predecessor),
    do: CAP.verify_descriptor(compact, predecessor, Limits.default())

  defp verify("receipt", compact, context),
    do: CAP.verify_receipt(compact, context, Limits.default())

  defp verify("acceptance", compact, set) do
    acceptances =
      if compact in set.acceptances, do: set.acceptances, else: set.acceptances ++ [compact]

    CAP.verify_chain(
      set.revisions,
      acceptances,
      set.descriptors,
      set.terminations,
      Limits.default()
    )
  end

  defp verify("termination", compact, set),
    do:
      CAP.verify_chain(
        set.revisions,
        set.acceptances,
        set.descriptors,
        set.terminations ++ [compact],
        Limits.default()
      )
end
