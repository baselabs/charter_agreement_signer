# Package boundary check — proves the SHIPPED Hex artifact works, not the
# source tree (adapted from the BARA sibling's scripts/check_package.exs,
# read first-hand, which adapted the BAP sibling's before it).
#
# 1. `mix hex.build` the exact archive a consumer downloads.
# 2. Unpack it (two tar layers, via :erl_tar — Hex.Tar is not loadable in a
#    project's `mix run` context on this hex version).
# 3. Exact-set census of the payload against the expected file list — catches
#    BOTH a stale `files:` allowlist (missing) and an accidental inclusion
#    (unexpected).
# 4. Pin the outer metadata (name/version/requirements read from the LIVE
#    project config, so the gate never drifts on a bump).
# 5. Compile the unpacked package in :prod.
# 6. Compile a minimal consumer against the UNPACKED package (path dep) and
#    run a sign_descriptor -> CAP.verify_descriptor smoke (positive +
#    wrong-key negative) — the consumer implements its own key handle,
#    because the package ships none.
#
# Everything runs under a mktemp scratch root, removed in after — re-runnable
# clean, no tree residue.

defmodule CharterAgreementSigner.PackageCheck do
  @moduledoc false

  # The exact payload census (what contents.tar.gz must carry — the
  # consumer's actual file set). Keep in lockstep with mix.exs `files:`; the
  # exact-set check reds in BOTH directions the moment either side drifts.
  @expected_files MapSet.new([
                    ".formatter.exs",
                    "CHANGELOG.md",
                    "CODE_OF_CONDUCT.md",
                    "CONTRIBUTING.md",
                    "LICENSE",
                    "NOTICE",
                    "README.md",
                    "SECURITY.md",
                    "usage-rules.md",
                    "docs/consumer-integration.md",
                    "docs/errors.md",
                    "docs/getting-started.md",
                    "docs/recipes.md",
                    "docs/security.md",
                    "docs/telemetry.md",
                    "docs/upgrading.md",
                    "lib/charter_agreement_signer.ex",
                    "lib/charter_agreement_signer/telemetry.ex",
                    "mix.exs"
                  ])

  # The consumer smoke's pinned key seeds.
  @holder_seed <<1::256>>
  @rogue_seed <<9::256>>
  @kid "consumer-handle-key-001"

  def run! do
    source_root = Path.expand("..", __DIR__)
    config = Mix.Project.config()
    version = config[:version]
    requirements = prod_requirements!(config)

    scratch_root = unique_tmp_root!()

    try do
      archive_path = Path.join(scratch_root, "charter_agreement_signer-#{version}.tar")
      outer_root = Path.join(scratch_root, "outer")
      package_root = Path.join(scratch_root, "package")
      consumer_root = Path.join(scratch_root, "consumer")

      run!("mix", ["hex.build", "--output", archive_path], source_root, [])
      assert_regular_nonempty!(archive_path)

      File.mkdir_p!(outer_root)
      File.mkdir_p!(package_root)
      extract_tar!(archive_path, outer_root)
      extract_tar!(Path.join(outer_root, "contents.tar.gz"), package_root)

      check_exact_files!(package_root)
      check_metadata!(Path.join(outer_root, "metadata.config"), version, requirements)
      compile_package!(package_root)
      compile_consumer!(consumer_root, package_root)

      IO.puts("package archive boundary passed")
    after
      File.rm_rf!(scratch_root)
    end
  end

  ## checks

  defp check_exact_files!(package_root) do
    actual =
      package_root
      |> Path.join("**/*")
      |> Path.wildcard(match_dot: true)
      |> Enum.filter(&File.regular?/1)
      |> Enum.map(&Path.relative_to(&1, package_root))
      |> MapSet.new()

    unless actual == @expected_files do
      missing = @expected_files |> MapSet.difference(actual) |> Enum.sort()
      unexpected = actual |> MapSet.difference(@expected_files) |> Enum.sort()

      fail!(
        "package file census mismatch; missing=#{inspect(missing)} " <>
          "unexpected=#{inspect(unexpected)}"
      )
    end
  end

  defp check_metadata!(path, version, requirements) do
    metadata =
      case :file.consult(String.to_charlist(path)) do
        {:ok, terms} -> Map.new(terms)
        {:error, reason} -> fail!("cannot read Hex metadata: #{inspect(reason)}")
      end

    expected = %{
      "app" => "charter_agreement_signer",
      "build_tools" => ["mix"],
      "licenses" => ["Apache-2.0"],
      "name" => "charter_agreement_signer",
      # Derived from the LIVE project config's prod deps (no `only:`), in
      # declaration order — the pin covers exactly what ships, whatever the
      # runtime dep set grows to.
      "requirements" => requirements,
      "version" => version
    }

    Enum.each(expected, fn {key, expected_value} ->
      actual_value = metadata |> Map.get(key) |> decode_metadata()

      unless actual_value == expected_value do
        fail!(
          "Hex metadata #{key} must be #{inspect(expected_value)}, " <>
            "got #{inspect(actual_value)}"
        )
      end
    end)
  end

  defp decode_metadata(value) when is_binary(value), do: value
  defp decode_metadata(value) when is_list(value), do: Enum.map(value, &decode_metadata/1)
  defp decode_metadata({left, right}), do: {decode_metadata(left), decode_metadata(right)}
  defp decode_metadata(value), do: value

  defp compile_package!(package_root) do
    environment = [{"MIX_ENV", "prod"}]
    run!("mix", ["deps.get", "--only", "prod"], package_root, environment)
    run!("mix", ["compile", "--warnings-as-errors"], package_root, environment)
  end

  defp compile_consumer!(consumer_root, package_root) do
    File.mkdir_p!(Path.join(consumer_root, "lib"))

    File.write!(
      Path.join(consumer_root, "mix.exs"),
      """
      defmodule CharterAgreementSignerConsumer.MixProject do
        use Mix.Project

        def project do
          [
            app: :charter_agreement_signer_consumer,
            version: "0.0.0",
            elixir: "~> 1.20",
            deps: [
              {:charter_agreement_signer, path: #{inspect(package_root)}}
            ]
          ]
        end
      end
      """
    )

    File.write!(
      Path.join(consumer_root, "lib/consumer.ex"),
      consumer_source()
    )

    environment = [{"MIX_ENV", "prod"}]
    run!("mix", ["deps.get"], consumer_root, environment)
    run!("mix", ["compile", "--warnings-as-errors"], consumer_root, environment)

    run!(
      "mix",
      [
        "run",
        "--no-start",
        "-e",
        "unless CharterAgreementSignerConsumer.smoke?(), " <>
          "do: System.halt(1)"
      ],
      consumer_root,
      environment
    )
  end

  # The consumer implements its OWN key handle (the package ships none): a
  # seeded Ed25519 pair behind the full behaviour contract. The smoke is the
  # round-trip bar mirrored against the UNPACKED artifact: sign a genesis
  # descriptor through the handle, verify via the protocol package's own
  # verifier, and a wrong-key negative so a green can never be vacuous.
  defp consumer_source do
    """
    defmodule CharterAgreementSignerConsumer.Handle do
      @moduledoc false
      @behaviour CharterAgreementSigner

      @holder_seed #{inspect(@holder_seed)}
      @rogue_seed #{inspect(@rogue_seed)}
      @kid "#{@kid}"

      defp keypair(seed), do: :crypto.generate_key(:eddsa, :ed25519, seed)

      @impl true
      def sign(message, :honest) when is_binary(message) do
        {_pub, priv} = keypair(@holder_seed)
        {:ok, :crypto.sign(:eddsa, :none, message, [priv, :ed25519])}
      end

      def sign(message, :rogue) when is_binary(message) do
        {_pub, priv} = keypair(@rogue_seed)
        {:ok, :crypto.sign(:eddsa, :none, message, [priv, :ed25519])}
      end

      def sign(_message, _handle), do: {:error, :invalid_handle}

      @impl true
      def key_identity(:honest), do: {:ok, {@kid, elem(keypair(@holder_seed), 0)}}
      def key_identity(:rogue), do: {:ok, {@kid, elem(keypair(@holder_seed), 0)}}
      def key_identity(_handle), do: {:error, :invalid_handle}

      @impl true
      def public_key(_handle), do: {:ok, elem(keypair(@holder_seed), 0)}
    end

    defmodule CharterAgreementSignerConsumer do
      @moduledoc false

      alias CharterAgreementProtocol.Limits

      @kid "#{@kid}"
      @holder_public_key elem(:crypto.generate_key(:eddsa, :ed25519, #{inspect(@holder_seed)}), 0)

      defp claims do
        %{
          "protocol_revision" => 1,
          "descriptor_number" => 1,
          "verification_keys" => [
            %{
              "key_id" => @kid,
              "algorithm" => "Ed25519",
              "public_key" => Base.url_encode64(@holder_public_key, padding: false),
              "status" => "active"
            }
          ],
          "attestation_hints" => [],
          "extensions" => %{"critical" => %{}, "optional" => %{}},
          "effective_from" => "2026-08-26T10:00:00Z"
        }
      end

      def smoke? do
        handle = {CharterAgreementSignerConsumer.Handle, :honest}

        with {:ok, %{descriptor: compact}} <-
               CharterAgreementSigner.sign_descriptor(claims(), handle),
             {:ok, _facts} <-
               CharterAgreementProtocol.verify_descriptor(compact, nil, Limits.default()),
             {:error, :signing_failed} <-
               CharterAgreementSigner.sign_descriptor(claims(), {
                 CharterAgreementSignerConsumer.Handle,
                 :rogue
               }) do
          true
        else
          failure -> IO.inspect(failure, label: "consumer smoke failure") && false
        end
      end
    end
    """
  end

  ## plumbing

  # The runtime-dep NAME allowlist — the supply-chain half of the pin: adding a
  # runtime dependency to mix.exs reds the census here (an intentional addition
  # updates this set in the same commit). Requirement VALUES stay live-derived
  # so version bumps never drift.
  @runtime_dep_allowlist MapSet.new([:charter_agreement_protocol, :telemetry])

  defp prod_requirements!(config) do
    config
    |> Keyword.fetch!(:deps)
    |> Enum.filter(fn
      {_name, _requirement, opts} when is_list(opts) ->
        not Keyword.has_key?(opts, :only)

      {_name, _requirement} ->
        true

      _ ->
        false
    end)
    |> Enum.map(fn
      {name, requirement} when is_binary(requirement) ->
        assert_runtime_dep_allowed!(name)
        requirement_entry(name, requirement, false)

      {name, requirement, opts} when is_binary(requirement) and is_list(opts) ->
        assert_runtime_dep_allowed!(name)
        requirement_entry(name, requirement, Keyword.get(opts, :optional, false))

      _ ->
        fail!(
          "mix.exs must declare runtime deps in a form the package check recognizes " <>
            "(2-tuple or 3-tuple with a binary requirement)"
        )
    end)
  end

  defp assert_runtime_dep_allowed!(name) do
    unless MapSet.member?(@runtime_dep_allowlist, name) do
      fail!(
        "unexpected runtime dependency #{inspect(name)} — the shipped artifact's " <>
          "dependency set is a deliberate, reviewed surface; extend " <>
          "@runtime_dep_allowlist in the same commit that adds the dep"
      )
    end
  end

  defp requirement_entry(name, requirement, optional?) do
    [
      {"name", to_string(name)},
      {"app", to_string(name)},
      {"optional", optional?},
      {"requirement", requirement},
      {"repository", "hexpm"}
    ]
  end

  defp extract_tar!(archive, target) do
    case :erl_tar.extract(String.to_charlist(archive), [
           :compressed,
           {:cwd, String.to_charlist(target)}
         ]) do
      :ok -> :ok
      {:error, reason} -> fail!("cannot extract #{archive}: #{inspect(reason)}")
    end
  end

  defp unique_tmp_root! do
    template = Path.join(System.tmp_dir!(), "charter-agreement-signer-package.XXXXXX")

    case System.cmd("mktemp", ["-d", template], stderr_to_stdout: true) do
      {path, 0} ->
        path = String.trim(path)

        if File.dir?(path),
          do: path,
          else: fail!("mktemp returned a missing directory")

      {output, status} ->
        fail!("mktemp exited with status #{status}: #{String.trim(output)}")
    end
  end

  defp assert_regular_nonempty!(path) do
    unless File.regular?(path) and File.stat!(path).size > 0 do
      fail!("package archive is missing or empty")
    end
  end

  defp run!(command, arguments, directory, environment) do
    options = [
      cd: directory,
      env: environment,
      into: IO.stream(:stdio, :line),
      stderr_to_stdout: true
    ]

    case System.cmd(command, arguments, options) do
      {_output, 0} -> :ok
      {_output, status} -> fail!("#{command} exited with status #{status}")
    end
  end

  defp fail!(message), do: raise("package check failed: #{message}")
end

CharterAgreementSigner.PackageCheck.run!()
