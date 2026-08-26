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
      refute source =~ ~r/\bSystem\./, "#{path} touches the system environment or clock"
      refute source =~ ~r/\bPort\./, "#{path} opens a port"

      refute source =~ ~r/:os\.|:net\.|:httpc|:ssl|:gen_tcp|:gen_udp/,
             "#{path} touches OS or network services"

      refute source =~ ~r/\bApplication\./, "#{path} reads application config"
      refute source =~ ~r/:crypto\.strong_rand_bytes|:rand\./, "#{path} is not deterministic"
    end
  end

  test "the only runtime dependency in mix.exs is the protocol package" do
    mix_source = File.read!(Path.join(@repo_root, "mix.exs"))

    runtime_deps =
      Regex.scan(~r/\{:(\w+),\s*"~>/, mix_source)
      |> Enum.map(&Enum.at(&1, 1))
      |> Enum.uniq()

    # :credo/:dialyxir/:ex_doc/:mix_audit/:sbom are dev/test-only in the
    # declared dep list; this textual scan is the coarse first layer — the
    # package census gate in scripts/check_package.exs pins the shipped
    # metadata exactly.
    assert "charter_agreement_protocol" in runtime_deps

    for dep <- runtime_deps do
      assert dep in [
               "charter_agreement_protocol",
               "credo",
               "dialyxir",
               "ex_doc",
               "mix_audit",
               "sbom"
             ],
             "unexpected dependency :#{dep} — the wall allows only the protocol package at runtime"
    end
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
