defmodule CharterAgreementSigner.TelemetryTest do
  @moduledoc """
  The telemetry surface suite: the closed event pair, the value-free metadata
  invariant (exact-key assertions + the shape validator's refusal), the
  full class × object coverage driven through the REAL signing entry points,
  and the docs/telemetry.md table parity (the acceptance tie, bidirectional).

  The real-entry-point drivers are the load-bearing half: a docs-table tie
  proves docs == module, never module == truth — only driving each failure
  class through an actual sign path proves the classify axis matches the
  signer's real vocabulary (the adversarial finding this suite exists for).
  """

  # async: false — the capture handler observes EVERY emission in the VM, so
  # concurrent suites' sign calls would land in the capture (indistinguishable
  # by design: the surface is value-free). Serializing the module scopes the
  # capture to this suite's own calls.
  use ExUnit.Case, async: false

  alias CharterAgreementSigner.{ChainFixture, Keys.RawKey, Keys.RogueKey, Telemetry}

  @prefix [:charter_agreement_signer, :sign]

  # --- capture handler ---------------------------------------------------------

  defp capture_events(fun) do
    handler_id = "telemetry-test-#{System.unique_integer([:positive])}"
    me = self()

    :ok =
      :telemetry.attach_many(
        handler_id,
        [@prefix ++ [:start], @prefix ++ [:stop]],
        fn event, measurements, metadata, _config ->
          send(me, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

    try do
      result = fun.()
      {result, drain_events([])}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_events(acc) do
    receive do
      {:telemetry_event, event, measurements, metadata} ->
        drain_events([{event, measurements, metadata} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # --- the happy path ----------------------------------------------------------

  test "a successful descriptor span emits the closed start/stop pair" do
    setup = ChainFixture.base()

    {result, events} =
      capture_events(fn ->
        CharterAgreementSigner.sign_descriptor(setup.issuer.claims, {RawKey, setup.issuer_handle})
      end)

    assert {:ok, %{descriptor: _compact}} = result

    assert [
             {@prefix ++ [:start], %{count: 1}, %{object: :descriptor}},
             {@prefix ++ [:stop], %{duration: duration},
              %{object: :descriptor, result_class: :ok}}
           ] = events

    assert is_integer(duration) and duration >= 0
  end

  # --- failure classes driven through the REAL entry points --------------------
  #
  # Each public error shape gets a driver that produces it for real; the stop
  # event's class is asserted against the shape the docs promise. This is the
  # axis-proof: a wrong classify clause reds HERE, not merely in the docs tie.

  test ":invalid_input class fires for malformed opts through the real entry point" do
    setup = ChainFixture.base()

    {_result, events} =
      capture_events(fn ->
        CharterAgreementSigner.sign_descriptor(
          setup.issuer.claims,
          {RawKey, setup.issuer_handle},
          :bad_opts
        )
      end)

    assert [{_start, _, _}, {@prefix ++ [:stop], _, %{result_class: :invalid_input}}] = events
  end

  test ":invalid_key_handle class fires for a crashing handle through the real entry point" do
    setup = ChainFixture.base()

    {_result, events} =
      capture_events(fn ->
        CharterAgreementSigner.sign_descriptor(setup.issuer.claims, {:NoSuchCustodyModule, :ref})
      end)

    assert [{_start, _, _}, {@prefix ++ [:stop], _, %{result_class: :invalid_key_handle}}] =
             events
  end

  test ":signing_failed class fires for a wrong-key handle through the real entry point" do
    setup = ChainFixture.base()
    rogue_private = :crypto.generate_key(:eddsa, :ed25519, <<9::256>>) |> elem(1)
    rogue = {elem(setup.issuer_handle, 0), elem(setup.issuer_handle, 1), rogue_private}

    {_result, events} =
      capture_events(fn ->
        CharterAgreementSigner.sign_descriptor(setup.issuer.claims, {RogueKey, rogue})
      end)

    assert [{_start, _, _}, {@prefix ++ [:stop], _, %{result_class: :signing_failed}}] = events
  end

  test ":verification_failed class fires for an unpinned snapshot key through the real entry point" do
    setup = ChainFixture.base()
    stranger = RawKey.generate("stranger-key-001", <<7::256>>)

    {_result, events} =
      capture_events(fn ->
        CharterAgreementSigner.sign_descriptor(setup.issuer.claims, {RawKey, stranger})
      end)

    assert [{_start, _, _}, {@prefix ++ [:stop], _, %{result_class: :verification_failed}}] =
             events
  end

  test ":refused class fires for false revision coordinates through the real entry point" do
    setup = ChainFixture.base()
    {:ok, set} = ChainFixture.raw_set(setup, [setup.genesis], [], [])

    false_claims =
      CharterAgreementSigner.AcceptanceFixture.claims(setup.genesis, setup.issuer, "issuer", %{
        "revision_digest" =>
          CharterAgreementSigner.CharterRevisionFixture.tagged(
            :charter_revision_content,
            "not-retained"
          )
      })

    {_result, events} =
      capture_events(fn ->
        CharterAgreementSigner.sign_acceptance(false_claims, {RawKey, setup.issuer_handle}, set)
      end)

    assert [
             {_start, _, %{object: :acceptance}},
             {@prefix ++ [:stop], _, %{result_class: :refused}}
           ] =
             events
  end

  # --- the value-free invariant ------------------------------------------------

  test "the value-free invariant holds on every real emission" do
    setup = ChainFixture.base()

    {_result, events} =
      capture_events(fn ->
        CharterAgreementSigner.sign_descriptor(setup.issuer.claims, {RawKey, setup.issuer_handle})
      end)

    private = elem(setup.issuer_handle, 2)

    for {_event, measurements, metadata} <- events do
      assert map_size(metadata) <= 2
      assert Map.keys(metadata) |> Enum.all?(&(&1 in [:object, :result_class]))
      assert Map.keys(measurements) |> Enum.all?(&(&1 in [:count, :duration]))

      refute inspect(metadata) =~ inspect(private)
      refute inspect(measurements) =~ inspect(setup.issuer.claims)
    end
  end

  test "the shape validators refuse anything outside the closed axes" do
    assert {:error, :telemetry_invalid} = Telemetry.emit_start(:not_an_object)
    assert {:error, :telemetry_invalid} = Telemetry.emit_stop(:descriptor, -1, :ok)
    assert {:error, :telemetry_invalid} = Telemetry.emit_stop(:descriptor, 1, :not_a_class)
    assert {:error, :telemetry_invalid} = Telemetry.emit_stop(:not_an_object, 1, :ok)
    assert {:error, :telemetry_invalid} = Telemetry.emit_stop(:descriptor, :not_integer, :ok)
  end

  test "the closed axes are exactly the four objects and six classes" do
    assert Telemetry.objects() == [:descriptor, :receipt, :acceptance, :termination]

    assert Telemetry.classes() == [
             :ok,
             :invalid_input,
             :invalid_key_handle,
             :signing_failed,
             :verification_failed,
             :refused
           ]
  end

  # --- the docs-table acceptance tie (bidirectional) ----------------------------

  test "docs/telemetry.md documents exactly the closed axes and events" do
    docs = File.read!(Path.expand("../../docs/telemetry.md", __DIR__))

    for object <- Telemetry.objects() do
      assert docs =~ ":#{object}", "docs/telemetry.md misses the object :#{object}"
    end

    for class <- Telemetry.classes() do
      assert docs =~ ":#{class}", "docs/telemetry.md misses the class :#{class}"
    end

    assert docs =~ "[:charter_agreement_signer, :sign, :start]"
    assert docs =~ "[:charter_agreement_signer, :sign, :stop]"

    # The phantom direction: a documented axis value the module does not emit
    # (docs naming e.g. :invalid_report would tie-green one-way). Scoped to
    # the doc's "## The closed axes" section — every backticked atom THERE
    # must be a live axis member, while prose elsewhere may mention
    # :telemetry.attach and friends freely.
    [_, axis_section_and_rest] = String.split(docs, "## The closed axes", parts: 2)
    axis_section = axis_section_and_rest |> String.split("\n## ") |> List.first()

    for match <- Regex.scan(~r/`:(\w+)`/, axis_section) do
      atom = match |> Enum.at(1) |> String.to_atom()

      assert atom in (Telemetry.objects() ++ Telemetry.classes()),
             "docs name :#{atom} outside the closed axes"
    end
  end
end
