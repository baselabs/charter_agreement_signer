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

  # The library-side protocol double-pin (the BARA ADR-0010 discipline): the
  # shipped requirement must name EXACTLY the locked version's tested line —
  # a three-part "~> 0.1.0" pin admitting only 0.1.x, per CAP's own dependent
  # guidance (CAP's package semver carries no compatibility promise, so the
  # dependent pins conservatively and bumps deliberately). A silent
  # `mix deps.update` or a loosened requirement reds here.
  @protocol_requirement "~> 0.1.0"
  @protocol_locked_version "0.1.0"

  test "the protocol dependency is double-pinned to the tested release line" do
    mix_source = File.read!(Path.join(@repo_root, "mix.exs"))

    assert mix_source =~ "{:charter_agreement_protocol, \"#{@protocol_requirement}\"}",
           "the CAP requirement must be exactly \"#{@protocol_requirement}\" — a two-part " <>
             "\"~> 0.1\" admits every future pre-1.0 CAP that no gate has tested"

    refute mix_source =~ "{:charter_agreement_protocol, \"~> 0.1\"},",
           "the two-part pin must not appear alongside the three-part form"

    lock_source = File.read!(Path.join(@repo_root, "mix.lock"))

    assert lock_source =~
             ~r/"charter_agreement_protocol":\s*\{:hex,\s*:charter_agreement_protocol,\s*"#{@protocol_locked_version}"/,
           "the locked CAP version must be exactly #{@protocol_locked_version} — the " <>
             "requirement vouches for no span the lock has not tested"
  end

  test "the only runtime dependency in mix.exs is the protocol package" do
    mix_source = File.read!(Path.join(@repo_root, "mix.exs"))

    runtime_deps =
      Regex.scan(~r/\{:(\w+),\s*"~>/, mix_source)
      |> Enum.map(&Enum.at(&1, 1))
      |> Enum.uniq()

    # :telemetry is the one sanctioned runtime seam beyond the protocol
    # package (ADR-0003); :credo/:dialyxir/:ex_doc/:mix_audit/:sbom are
    # dev/test-only in the declared dep list; this textual scan is the coarse
    # first layer — the package census gate in scripts/check_package.exs pins
    # the shipped metadata exactly.
    assert "charter_agreement_protocol" in runtime_deps

    for dep <- runtime_deps do
      assert dep in [
               "charter_agreement_protocol",
               "telemetry",
               "credo",
               "dialyxir",
               "ex_doc",
               "mix_audit",
               "sbom"
             ],
             "unexpected dependency :#{dep} — the wall allows only the protocol package and telemetry at runtime"
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
