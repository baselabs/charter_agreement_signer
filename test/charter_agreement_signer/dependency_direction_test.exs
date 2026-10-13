defmodule CharterAgreementSigner.DependencyDirectionTest do
  @moduledoc """
  The dependency-direction wall (the BARA ADR-0003 shape): the shipped
  library depends ONLY on the public charter_agreement_protocol package and
  the standard library — no runtime, no custody, no other portfolio package —
  and contains no filesystem, environment, network, or clock access.
  """

  use ExUnit.Case, async: true

  @lib_dir Path.expand("../../lib", __DIR__)
  @repo_root Path.expand("../..", __DIR__)

  test "every aliased module in lib is this package or the protocol package" do
    aliases =
      lib_sources()
      |> Enum.flat_map(fn {path, source} ->
        Regex.scan(~r/^\s*alias\s+([A-Z][\w.]*)/m, source)
        |> Enum.map(fn [_, full] -> {path, full} end)
      end)

    assert aliases != []

    for {path, full} <- aliases do
      root = full |> String.split(".") |> List.first()

      assert root in ["CharterAgreementSigner", "CharterAgreementProtocol"],
             "#{path} aliases #{full} — lib may depend only on this package and the protocol package"
    end
  end

  test "lib contains no filesystem, environment, network, or clock access" do
    for {path, source} <- lib_sources() do
      refute source =~ ~r/\bFile\./, "#{path} touches the filesystem"

      if telemetry_module?(path) do
        # The telemetry seam's ONE sanctioned clock read: the monotonic
        # duration measurement. Everything else System-shaped stays banned
        # there too — the negative lookahead admits exactly this function.
        refute source =~ ~r/\bSystem\.(?!monotonic_time\b)/,
               "#{path} touches the system environment or a non-monotonic clock"
      else
        refute source =~ ~r/\bSystem\./, "#{path} touches the system environment or clock"
      end

      refute source =~ ~r/\bPort\./, "#{path} opens a port"

      refute source =~ ~r/:os\.|:net\.|:httpc|:ssl|:gen_tcp|:gen_udp/,
             "#{path} touches OS or network services"

      refute source =~ ~r/\bApplication\./, "#{path} reads application config"
      refute source =~ ~r/:crypto\.strong_rand_bytes|:rand\./, "#{path} is not deterministic"
    end
  end

  defp telemetry_module?(path), do: Path.basename(path) == "telemetry.ex"

  test "the protocol dependency resolves the tested local build" do
    {:charter_agreement_protocol, options} =
      List.keyfind(Mix.Project.config()[:deps], :charter_agreement_protocol, 0)

    assert options[:path] == "../cap-060-fix"
    assert Application.spec(:charter_agreement_protocol, :vsn) == ~c"0.6.0"
    refute File.read!(Path.join(@repo_root, "mix.lock")) =~ "\"charter_agreement_protocol\""
  end

  test "runtime dependencies are exactly the protocol package and telemetry" do
    names =
      Mix.Project.config()[:deps]
      |> Enum.reject(fn dependency ->
        dependency
        |> Tuple.to_list()
        |> List.last()
        |> then(fn
          options when is_list(options) -> Keyword.has_key?(options, :only)
          _requirement -> false
        end)
      end)
      |> Enum.map(&elem(&1, 0))

    assert names == [:charter_agreement_protocol, :telemetry]
  end

  test "no sibling portfolio package appears anywhere in lib" do
    for {path, source} <- lib_sources() do
      refute source =~ "BoundedAuthority",
             "#{path} references the BAP family — out of the signer's dependency wall"

      refute source =~ "AgentBlueprint",
             "#{path} references ABP — out of the signer's dependency wall"

      refute source =~ "CommercePlatform",
             "#{path} references the commerce platform — out of the signer's dependency wall"
    end
  end

  test "the public surface is documented in README and usage rules" do
    readme = File.read!(Path.join(@repo_root, "README.md"))
    usage_rules = File.read!(Path.join(@repo_root, "usage-rules.md"))

    for function <- ["sign_descriptor", "sign_receipt", "sign_acceptance", "sign_termination"] do
      assert readme =~ function, "README.md does not document #{function}/"
      assert usage_rules =~ function, "usage-rules.md does not name #{function}/"
    end
  end

  defp lib_sources do
    @lib_dir
    |> Path.join("**/*.ex")
    |> Path.wildcard()
    |> Enum.map(&{&1, File.read!(&1)})
  end
end
