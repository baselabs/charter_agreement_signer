defmodule CharterAgreementSigner.CapabilityLimitedTest do
  use ExUnit.Case, async: false

  @moduletag :requires_limited_substrate

  alias CharterAgreementProtocol, as: CAP
  alias CharterAgreementProtocol.Limits
  alias CharterAgreementSigner.Keys.RawMLDSA65

  @table File.read!(Path.expand("../fixtures/signer_cases.json", __DIR__)) |> JSON.decode!()
  @prefix [:charter_agreement_signer, :sign]

  setup do
    refute CAP.Capability.kat_verifies?("ML-DSA-65")
    Code.ensure_loaded!(RawMLDSA65)
    :erlang.trace_pattern({RawMLDSA65, :sign, 2}, true, [:call_count])
    on_exit(fn -> :erlang.trace_pattern({RawMLDSA65, :sign, 2}, false, [:call_count]) end)
    me = self()
    handler = "limited-signing-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        @prefix ++ [:stop],
        fn event, measurements, metadata, _ -> send(me, {event, measurements, metadata}) end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  for kind <- ["descriptor", "acceptance", "termination", "receipt"] do
    @kind kind
    test "#{kind} refuses an unsupported substrate before custody and emits its class" do
      kind = @kind
      row = Enum.find(@table["cases"], &(&1["id"] == "ml-#{kind}-ok"))
      key = @table["keys"][row["key"]]
      public = Base.url_decode64!(key["public_key"], padding: false)
      seed = Base.url_decode64!(key["seed"], padding: false)
      handle = {RawMLDSA65, {key["kid"], public, {:seed, seed}}}
      context = context(row["context"])
      options = [algorithm: "ML-DSA-65"]

      result =
        case kind do
          "descriptor" ->
            CharterAgreementSigner.sign_descriptor(row["claims"], handle, options)

          "acceptance" ->
            CharterAgreementSigner.sign_acceptance(row["claims"], handle, context, options)

          "termination" ->
            CharterAgreementSigner.sign_termination(row["claims"], handle, context, options)

          "receipt" ->
            CharterAgreementSigner.sign_receipt(row["claims"], handle, context, options)
        end

      assert result == {:error, :algorithm_unsupported_on_substrate}
      assert {:call_count, 0} = :erlang.trace_info({RawMLDSA65, :sign, 2}, :call_count)

      assert_receive {@prefix ++ [:stop], %{duration: duration},
                      %{object: object, result_class: :unsupported_substrate}}

      assert Atom.to_string(object) == kind
      assert is_integer(duration) and duration >= 0
    end
  end

  defp context(nil), do: nil

  defp context(name) do
    case @table["contexts"][name] do
      %{"type" => "revision", "text" => text} ->
        {:ok, revision} = CAP.decode_charter_revision(text, Limits.default())
        revision

      %{"type" => "set"} = input ->
        {:ok, set} =
          CAP.build_set(
            input["revisions"],
            input["acceptances"],
            input["terminations"],
            input["descriptors"]
          )

        set
    end
  end
end
