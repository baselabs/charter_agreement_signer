defmodule CharterAgreementSigner.MixProject do
  use Mix.Project

  @version "0.4.1"
  @source_url "https://github.com/baselabs/charter_agreement_signer"

  def project do
    [
      app: :charter_agreement_signer,
      version: @version,
      # SUPPORTED RANGE, not a single-version pin: the tested 1.19.x–1.20.x
      # lines on OTP 28/29 (1.19.x rides the OTP-28 lane; the protocol
      # package's source compiles and its suite passes there — probed before
      # this range moved). Anything outside the range refuses at compile — a
      # foreign toolchain never compiles silently (mixing toolchains poisons
      # shared _build/PLT state) — while every 1.19.x/1.20.x stays admitted.
      # LOCKSTEP: this range, config/config.exs's supported-OTP set,
      # .tool-versions (the dev lane), and CI's matrix lanes move together in
      # ONE commit — divergence between them is a defect. The OTP BUILD is
      # asserted separately in config/config.exs — System.version/0 does not
      # encode it.
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      # The coverage floor is the MEASURED total, re-pinned at every slice
      # that moves it (never aspirational; pinned just under the measured
      # number — Mix compares the RAW ratio, whose hidden decimals round up
      # for display, so an exact display-value pin can flake). At a measured
      # 100.0 the raw ratio is exactly 1.0, so the pin is exact — any future
      # uncovered line reds the battery immediately.
      test_coverage: [summary: [threshold: 100.0]],
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

  # `mix ci` runs the library and example batteries plus the pinned
  # TypeScript signer suite and the pinned verifier build. CI runs these
  # in separate Linux jobs. Setup, matrix breadth and the capability-limited
  # substrate check remain CI-specific. The first step requires MIX_ENV=test;
  # every later step shares that environment and aborts on failure.
  defp aliases do
    [
      "typescript.sources": "run --no-start scripts/materialize_typescript_sources.exs",
      "typescript.check": "run --no-start scripts/check_typescript_sources.exs",
      ci: [
        &enforce_test_env!/1,
        "deps.get",
        "format --check-formatted",
        "deps.compile",
        "compile --warnings-as-errors",
        "credo --strict",
        "test",
        # The gate battery (parity with the sibling-standard batteries): coverage
        # floor, dialyzer (PLT + analysis under :test so test/support/ is in the
        # paths — the RA7 lesson), doc warnings, the advisory audits, and the
        # dependency-currency gate (scripts/check_deps_current.exs).
        # A fresh process is required: Mix skips a second test invocation
        # in the same alias process after the plain test task has run.
        "cmd mix test --cover",
        "dialyzer",
        "docs --warnings-as-errors",
        "hex.audit",
        "deps.audit",
        "run --no-start scripts/check_deps_current.exs",
        # The shipped-artifact gate: builds the exact Hex archive, proves its
        # census/metadata, and compiles + smoke-runs a consumer against the
        # UNPACKED package (scripts/check_package.exs; scratch-cleaned).
        # Public source pins and the TypeScript signer's own test suite.
        "typescript.sources",
        "typescript.check",
        "run --no-start scripts/check_package.exs",
        # Two cache-isolated builds of the exact archive must agree byte for
        # byte (the release-candidate reproducibility gate).
        "run --no-start scripts/check_reproducible.exs",
        # job: example (the workflow's working-directory: examples/charter_lifecycle)
        "cmd --cd examples/charter_lifecycle mix deps.get",
        "cmd --cd examples/charter_lifecycle mix hex.audit",
        "cmd --cd examples/charter_lifecycle mix run --no-start ../../scripts/check_deps_current.exs",
        "cmd --cd examples/charter_lifecycle mix format --check-formatted",
        "cmd --cd examples/charter_lifecycle mix deps.compile",
        "cmd --cd examples/charter_lifecycle mix compile --warnings-as-errors",
        "cmd --cd examples/charter_lifecycle mix credo --strict",
        "cmd --cd examples/charter_lifecycle mix test"
      ]
    ]
  end

  # The replacement for the former `env MIX_ENV=test` re-exec: fail fast on a
  # :dev boot, with the invocation in the message. (The guard runs as the
  # first alias step, so every later step in the SAME mix process already
  # boots under :test.)
  defp enforce_test_env!(_args) do
    if Mix.env() != :test do
      Mix.raise("""
      `mix ci` runs under MIX_ENV=test — a :dev boot skips test/support and
      hides its warnings. Re-run as:

        MIX_ENV=test mix ci
      """)
    end
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
  # from its Hex release with a three-part "~> 0.5.0" requirement. Only the
  # tested 0.5.x line is admitted; both locks and the wall test move together
  # when the line changes (ADR-0002).
  # No install task ships yet — adding one grows scripts/check_package.exs's
  # @runtime_dep_allowlist in the same commit.
  defp deps do
    [
      {:charter_agreement_protocol, "~> 0.5.0"},
      {:telemetry, "~> 1.4"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.40", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      # CycloneDX SBOM generation for the tag-push supply-chain workflow.
      # At sbom 0.11.0 (latest), its own transitive requirements
      # (hex_core ~> 0.19.0, protobuf ~> 0.17.0, purl ~> 0.5.0) resolve
      # the previously-rejected rows; any residual resolver-rejected pin
      # the currency gate prints is sbom's own, recorded here.
      {:sbom, "~> 0.10", only: [:dev, :test], runtime: false},
      # EEF-CVE-2026-103502 (hex_core < 0.20.0: no TLS verification on OTP 24/25) is
      # fixed in hex_core 0.20.0, but sbom 0.11.0 still requires ~> 0.19.0. sbom calls
      # only hex_core.default_config/0, hex_api_package.get/2 and
      # hex_api_release.get/3, unchanged in 0.20.0. Drop this override once an sbom
      # release accepts hex_core 0.20.
      {:hex_core, "~> 0.20.0", only: [:dev, :test], runtime: false, override: true}
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
