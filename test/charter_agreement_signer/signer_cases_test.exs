defmodule CharterAgreementSigner.SignerCasesTest do
  use ExUnit.Case, async: false

  alias CharterAgreementProtocol, as: CAP
  alias CharterAgreementProtocol.{Capability.Profile, Limits}
  alias CharterAgreementSigner.Keys.{RawKey, RawMLDSA65}

  @table File.read!(Path.expand("../fixtures/signer_cases.json", __DIR__)) |> JSON.decode!()

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
    if row["context"] in ["ml-predecessor", "ml-wrong-predecessor"],
      do: @tag(:requires_mldsa_substrate)

    test row["id"] do
      row = @row
      key = @table["keys"][row["key"]]
      module = if key["algorithm"] == "Ed25519", do: RawKey, else: RawMLDSA65
      seed = Base.url_decode64!(key["seed"], padding: false)
      private = if module == RawKey, do: seed, else: {:seed, seed}
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
      assert called == if(expected["custody_called"], do: 1, else: 0)

      assert {:call_count, snapshots} =
               :erlang.trace_info({module, :key_identity, 1}, :call_count)

      assert snapshots == if(expected["snapshot_called"], do: 1, else: 0)

      if expected["shape"] == "ok" do
        {:ok, result} = result
        compact = result |> Map.values() |> hd()

        if key["algorithm"] == "Ed25519", do: assert(compact == expected["compact"])
        assert {:ok, _facts} = verify(row["kind"], compact, context)
      end
    end
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
        {:limits, struct!(Limits.default(), atom_keys(values))}

      {"profile", %{"algorithms" => names, "revisions" => [low, high]}} ->
        {:profile, %Profile{algorithms: names, revisions: {low, high}}}

      {"profile", value} ->
        {:profile, value}

      {"algorithm", value} ->
        {:algorithm, value}
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

  defp verify("acceptance", compact, set),
    do:
      CAP.verify_chain(
        set.revisions,
        set.acceptances ++ [compact],
        set.descriptors,
        set.terminations,
        Limits.default()
      )

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
