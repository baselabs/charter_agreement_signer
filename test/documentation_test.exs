defmodule CharterAgreementSigner.DocumentationTest do
  use ExUnit.Case, async: false

  @moduletag timeout: :timer.minutes(10)
  @root Path.expand("..", __DIR__)

  test "the quickstart runs with real Ed25519 signatures and the wrong-key refusal" do
    [install | blocks] = cells(File.read!(Path.join(@root, "docs/getting-started.md")))
    assert install =~ ~s({:charter_agreement_signer, "~> 1.0.0"})
    assert_roundtrip!(run!(blocks))
  end

  test "the Livebook has a current setup cell and executes from top to bottom" do
    source = File.read!(Path.join(@root, "examples/charter_signing_roundtrip.livemd"))
    [intro | _] = String.split(source, ~r/^## /m, parts: 2)
    [setup | blocks] = cells(source)
    assert String.starts_with?(source, "# Charter signing round-trip\n")
    assert intro =~ setup
    assert setup =~ ~s({:charter_agreement_protocol, "~> 1.0.0"})
    assert setup =~ ~s({:charter_agreement_signer, "~> 1.0.0"})
    assert_roundtrip!(run!(blocks))
  end

  test "custody adapter templates compile without undefined integration calls" do
    blocks = cells(File.read!(Path.join(@root, "docs/recipes.md")))
    assert run!(blocks) =~ "MyApp.Counterparty"
  end

  test "the telemetry recipe observes real signing spans without claim values" do
    [_install | quickstart] = cells(File.read!(Path.join(@root, "docs/getting-started.md")))
    telemetry = cells(File.read!(Path.join(@root, "docs/telemetry.md")))
    output = run!(telemetry ++ quickstart)
    assert output =~ "charter_signer [:charter_agreement_signer, :sign, :stop]"
    assert output =~ "result_class: :signing_failed"
  end

  defp assert_roundtrip!(output) do
    assert output =~ ~s(["issuer-demo", "acceptor-demo"])
    assert output =~ "DescriptorFacts<redacted>"
    assert output =~ "{:error, :signing_failed}"
  end

  defp run!(blocks) do
    work = Path.join(System.tmp_dir!(), "cas-docs-#{System.unique_integer([:positive])}")
    File.mkdir_p!(work)
    on_exit(fn -> File.rm_rf!(work) end)
    cap = Mix.Project.deps_paths()[:charter_agreement_protocol]

    setup = """
    Mix.install([
      {:charter_agreement_protocol, path: #{inspect(cap)}, override: true},
      {:charter_agreement_signer, path: #{inspect(@root)}}
    ])
    for app <- [:charter_agreement_protocol, :charter_agreement_signer] do
      unless to_string(Application.spec(app, :vsn)) == "1.0.0",
        do: raise("documentation dependency version drift")
    end
    """

    script = Path.join(work, "run.exs")

    File.write!(script, """
    #{setup}
    blocks = #{inspect(blocks, limit: :infinity)}
    Enum.reduce(blocks, {[], Code.env_for_eval([])}, fn block, {binding, env} ->
      quoted = Code.string_to_quoted!(block)
      {value, binding, env} = Code.eval_quoted_with_env(quoted, binding, env)
      IO.inspect(value, limit: :infinity, width: 120)
      {binding, env}
    end)
    """)

    {output, status} =
      System.cmd("elixir", [script], stderr_to_stdout: true, env: [{"MIX_ENV", nil}])

    assert status == 0, output
    refute output =~ "warning:", output
    output
  end

  defp cells(source) do
    Regex.scan(~r/^```elixir\n(.*?)^```$/ms, source, capture: :all_but_first)
    |> List.flatten()
  end
end
