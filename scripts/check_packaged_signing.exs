# Exercise signing from the unpacked release archive through a real consumer.

defmodule CharterAgreementSigner.PackagedSigning do
  @moduledoc false

  # The consumer smoke's pinned key seeds.
  @holder_seed <<1::256>>
  @rogue_seed <<9::256>>
  @kid "consumer-handle-key-001"

  def run! do
    source_root = Path.expand("..", __DIR__)
    version = Mix.Project.config()[:version]

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

      check_build_metadata!(Path.join(outer_root, "metadata.config"))
      bind_protocol_candidate!(package_root, scratch_root)
      compile_package!(package_root)
      compile_consumer!(consumer_root, package_root)

      IO.puts("packaged signing smoke passed")
    after
      best_effort_rm_rf!(scratch_root)
    end
  end

  # Cleanup is hygiene, never the gate's verdict: File.rm_rf! would raise
  # AFTER a passed gate. One bounded retry absorbs a transient removal
  # failure; a genuine leak warns and the ephemeral runner temp dir reaps it.
  defp best_effort_rm_rf!(path) do
    case File.rm_rf(path) do
      {:ok, _} ->
        :ok

      # File.rm_rf/1 fails as a THREE-tuple: {:error, reason, file}.
      {:error, _reason, _file} ->
        Process.sleep(500)

        case File.rm_rf(path) do
          {:ok, _} ->
            :ok

          # File.rm_rf/1 fails as a THREE-tuple: {:error, reason, file}.
          {:error, reason, _file} ->
            IO.puts("warning: scratch cleanup left behind #{path}: #{inspect(reason)}")
        end
    end
  end

  defp check_build_metadata!(path) do
    case :file.consult(String.to_charlist(path)) do
      {:ok, terms} ->
        metadata = Map.new(terms)

        unless metadata["build_tools"] == ["mix"] and metadata["licenses"] == ["Apache-2.0"] do
          fail!("package must declare Mix as its build tool and the expected license")
        end

      {:error, reason} ->
        fail!("cannot read Hex metadata: #{inspect(reason)}")
    end
  end

  # Before CAP publication, resolve its exact reviewed archive in the
  # disposable package copy. Census and Hex dependency metadata were checked
  # against the unmodified CAS archive before applying this build override.
  defp bind_protocol_candidate!(package_root, scratch_root) do
    case System.argv() do
      [] ->
        :ok

      [archive, expected_sha256] ->
        actual = :crypto.hash(:sha256, File.read!(archive)) |> Base.encode16(case: :lower)
        unless actual == expected_sha256, do: fail!("CAP candidate checksum mismatch")
        outer = Path.join(scratch_root, "protocol-outer")
        protocol = Path.join(scratch_root, "protocol")
        File.mkdir_p!(outer)
        File.mkdir_p!(protocol)
        extract_tar!(archive, outer)
        extract_tar!(Path.join(outer, "contents.tar.gz"), protocol)

        %{"package" => "charter_agreement_protocol", "package_version" => version} =
          protocol |> Path.join("priv/release-metadata.json") |> File.read!() |> JSON.decode!()

        requirement = "== #{version}"
        project = Path.join(package_root, "mix.exs")
        source = File.read!(project)
        unless source =~ "deps: deps()", do: fail!("dependency seam missing")

        replacement =
          "deps: Enum.map(deps(), fn " <>
            "{:charter_agreement_protocol, _req} -> " <>
            "{:charter_agreement_protocol, #{inspect(requirement)}, " <>
            "path: #{inspect(protocol)}, override: true}; dep -> dep end)"

        File.write!(project, String.replace(source, "deps: deps()", replacement))
        IO.puts("package consumer: CAP candidate SHA-256 #{actual}")

      _ ->
        fail!("expected an optional CAP archive and its SHA-256")
    end
  end

  defp consumer_lock do
    fixture =
      if System.argv() == [],
        do: "package-consumer/mix.lock",
        else: "protocol-candidate/consumer.lock"

    Path.expand("../test/fixtures/" <> fixture, __DIR__)
  end

  defp compile_package!(package_root) do
    File.cp!(consumer_lock(), Path.join(package_root, "mix.lock"))

    environment = [{"MIX_ENV", "prod"}]
    run!("mix", ["deps.get", "--check-locked", "--only", "prod"], package_root, environment)
    run!("mix", ["compile", "--warnings-as-errors"], package_root, environment)
  end

  # The smoke consumer's floor tracks the RUNNING Elixir line. A hardcoded
  # floor went stale the moment the library's supported range widened past it
  # (the consumer refused to boot on the 1.19 lane); the consumer exists to
  # compile the unpacked package on THIS lane, not to assert a floor — the
  # CI lanes assert floors.
  defp running_elixir_line do
    version = Version.parse!(System.version())
    "#{version.major}.#{version.minor}"
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
            elixir: "~> #{running_elixir_line()}",
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

    File.cp!(consumer_lock(), Path.join(consumer_root, "mix.lock"))

    environment = [{"MIX_ENV", "prod"}]
    run!("mix", ["deps.get", "--check-locked"], consumer_root, environment)
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
          "protocol_revision" => 2,
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

  defp extract_tar!(archive, target) do
    case :erl_tar.extract(String.to_charlist(archive), [
           :compressed,
           {:cwd, String.to_charlist(target)}
         ]) do
      :ok -> :ok
      {:error, reason} -> fail!("cannot extract #{archive}: #{inspect(reason)}")
    end
  end

  # Temp root: a unique name under the system temp dir serves this gate's
  # purpose (scratch isolation, not collision-hardening against adversaries).
  defp unique_tmp_root! do
    path =
      Path.join(
        System.tmp_dir!(),
        "charter-agreement-signer-package.#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)
    path
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

  defp fail!(message), do: raise("packaged signing smoke failed: #{message}")
end

CharterAgreementSigner.PackagedSigning.run!()
