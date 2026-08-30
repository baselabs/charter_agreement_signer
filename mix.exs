defmodule CharterAgreementSigner.MixProject do
  use Mix.Project

  @version "0.2.0"
  @source_url "https://github.com/baselabs/charter_agreement_signer"

  def project do
    [
      app: :charter_agreement_signer,
      version: @version,
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      # The coverage floor is the MEASURED total, re-pinned at every slice
      # that moves it (never aspirational; pinned just under the measured
      # number — Mix compares the RAW ratio, whose hidden decimals round up
      # for display, so an exact display-value pin can flake).
      test_coverage: [summary: [threshold: 87.0]],
      # PLT lives under _build (gitignored, cache-friendly) — the BARA
      # sibling's shape.
      dialyzer: [
        plt_core_path: "_build/plts",
        plt_local_path: "_build/plts"
      ],
      deps: deps(),
      package: package(),
      docs: docs(),
      name: "Charter Agreement Signer",
      description:
        "Holder-side companion signer for the Charter Agreement Protocol — signs charter " <>
          "artifacts (party descriptors, acceptances, terminations, receipts) through a local " <>
          "key handle over the protocol's deterministic RFC 7515 signing inputs. The private " <>
          "key never enters the library.",
      source_url: @source_url,
      homepage_url: @source_url,
      aliases: aliases()
    ]
  end

  def application do
    [
      extra_applications: [:crypto]
    ]
  end

  # `mix ci` — local CI parity: reproduces .github/workflows/ci.yml step-for-step
  # (the five library steps + the gate battery + the shipped-artifact gates) with
  # zero GitHub Actions spend. The workflow exports MIX_ENV: test at the JOB
  # level, so every step here re-execs mix under MIX_ENV=test via env(1) — a
  # bare local `mix ci` would otherwise boot in :dev, and a :dev compile skips
  # test/support (the warnings trap). `mix cmd` aborts on the first non-zero
  # step, like a failed CI job. Not reproduced locally: checkout/setup-beam
  # (asdf here).
  defp aliases do
    [
      ci: [
        "cmd env MIX_ENV=test mix deps.get",
        "cmd env MIX_ENV=test mix format --check-formatted",
        "cmd env MIX_ENV=test mix compile --warnings-as-errors",
        "cmd env MIX_ENV=test mix credo --strict",
        "cmd env MIX_ENV=test mix test",
        # The gate battery (parity with the sibling-standard batteries): coverage
        # floor, dialyzer (PLT + analysis under :test so test/support/ is in the
        # paths — the RA7 lesson), doc warnings, and the library's own advisory
        # audits.
        "cmd env MIX_ENV=test mix test --cover",
        "cmd env MIX_ENV=test mix dialyzer",
        "cmd env MIX_ENV=test mix docs --warnings-as-errors",
        "cmd env MIX_ENV=test mix hex.audit",
        "cmd env MIX_ENV=test mix deps.audit",
        # The shipped-artifact gate: builds the exact Hex archive, proves its
        # census/metadata, and compiles + smoke-runs a consumer against the
        # UNPACKED package (scripts/check_package.exs; scratch-cleaned).
        "cmd env MIX_ENV=test mix run --no-start scripts/check_package.exs",
        # Two cache-isolated builds of the exact archive must agree byte for
        # byte (the release-candidate reproducibility gate).
        "cmd env MIX_ENV=test mix run --no-start scripts/check_reproducible.exs",
        # job: example (the workflow's working-directory: examples/charter_lifecycle)
        "cmd --cd examples/charter_lifecycle env MIX_ENV=test mix deps.get",
        "cmd --cd examples/charter_lifecycle env MIX_ENV=test mix hex.audit",
        "cmd --cd examples/charter_lifecycle env MIX_ENV=test mix format --check-formatted",
        "cmd --cd examples/charter_lifecycle env MIX_ENV=test mix compile --warnings-as-errors",
        "cmd --cd examples/charter_lifecycle env MIX_ENV=test mix credo --strict",
        "cmd --cd examples/charter_lifecycle env MIX_ENV=test mix test"
      ]
    ]
  end

  # test/support/ holds the reference key-handle impl (Keys.RawKey, the rogue
  # wrong-key probe Keys.RogueKey) + the charter-artifact fixtures — compiled
  # ONLY in :test so no key material or fixture builder ships in the artifact
  # (the BARA ADR-0014 posture: a key-in-process-memory impl in lib/ would
  # pave a road to the failure the separate repo exists to prevent).
  defp elixirc_paths(:test), do: ["lib/", "test/support/"]
  defp elixirc_paths(_env), do: ["lib/"]

  # The signer depends ONLY on the public charter_agreement_protocol package
  # (the dependency-direction wall, BARA ADR-0003's shape) plus :telemetry
  # for the closed, value-free sign-span surface (ADR-0003; the one sanctioned
  # seam — zero transitive deps, no custody, no transport). CAP is consumed
  # from its Hex release, pinned to the three-part "~> 0.2.1" per CAP's own
  # dependent guidance (README §Installation): package semver carries no
  # compatibility promise in CAP's governance, so the pin admits exactly the
  # tested 0.2.x line (the 0.1.0 → 0.2.1 move was ADR-0002's deliberate,
  # reviewed bump for CAP's revision-2 alg-name bundle). No install task
  # ships yet — adding one grows scripts/check_package.exs's
  # @runtime_dep_allowlist in the same commit.
  defp deps do
    [
      {:charter_agreement_protocol, "~> 0.2.1"},
      {:telemetry, "~> 1.4"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.40", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      # CycloneDX SBOM generation for the tag-push supply-chain workflow.
      {:sbom, "~> 0.10", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      maintainers: ["rjpalermo"],
      files: [
        "lib",
        ".formatter.exs",
        "mix.exs",
        "README.md",
        "CHANGELOG.md",
        "CODE_OF_CONDUCT.md",
        "CONTRIBUTING.md",
        "LICENSE",
        "NOTICE",
        "SECURITY.md",
        "usage-rules.md",
        "docs/consumer-integration.md",
        "docs/errors.md",
        "docs/getting-started.md",
        "docs/recipes.md",
        "docs/security.md",
        "docs/telemetry.md",
        "docs/upgrading.md"
      ],
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/master/CHANGELOG.md"
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: [
        "README.md",
        "usage-rules.md",
        "CHANGELOG.md",
        "CODE_OF_CONDUCT.md",
        "CONTRIBUTING.md",
        "LICENSE",
        "NOTICE",
        "SECURITY.md",
        "docs/consumer-integration.md",
        "docs/errors.md",
        "docs/getting-started.md",
        "docs/recipes.md",
        "docs/security.md",
        "docs/telemetry.md",
        "docs/upgrading.md"
      ]
    ]
  end
end
