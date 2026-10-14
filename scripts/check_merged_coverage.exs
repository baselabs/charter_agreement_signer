# Use a real limited toolchain or its coverage export from a separate CI job.
limited_path = System.get_env("CAS_LIMITED_PATH")

limited_export = System.get_env("CAS_LIMITED_COVERAGE")

limited_source =
  cond do
    is_binary(limited_path) and limited_path != "" ->
      {:toolchain, limited_path}

    is_binary(limited_export) and limited_export != "" ->
      {:export, File.read!(limited_export)}

    true ->
      raise("set CAS_LIMITED_PATH to a limited toolchain or CAS_LIMITED_COVERAGE to its export")
  end

unless CharterAgreementProtocol.Capability.kat_verifies?("ML-DSA-65"),
  do: raise("the standard coverage lane must verify ML-DSA-65")

for path <- Path.wildcard("cover/*.coverdata"), do: File.rm!(path)

run = fn args, env ->
  {_, status} = System.cmd("mix", args, env: env, into: IO.stream(:stdio, :line))
  if status != 0, do: raise("coverage command failed (#{status}): mix #{Enum.join(args, " ")}")
end

run.(["test", "--cover", "--export-coverage", "standard"], [])

case limited_source do
  {:toolchain, path} ->
    limited_env = [{"PATH", path}, {"MIX_BUILD_ROOT", "_build_limited"}]
    run.(["run", "--no-start", "scripts/assert_limited_substrate.exs"], limited_env)

    run.(
      [
        "test",
        "--exclude",
        "requires_mldsa_substrate",
        "--cover",
        "--export-coverage",
        "limited"
      ],
      limited_env
    )

  {:export, bytes} ->
    File.write!("cover/limited.coverdata", bytes)
    IO.puts("Loaded coverage from the capability-limited job")
end

for name <- ["standard", "limited"] do
  unless File.regular?("cover/#{name}.coverdata"), do: raise("missing #{name} coverage export")
end

run.(["test.coverage"], [])
