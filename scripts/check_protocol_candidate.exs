# Run the signer and lifecycle suites against a real unpacked CAP candidate.
# The source lock remains the published baseline; no candidate is published.
[archive, expected_sha256] = System.argv()

archive_bytes = File.read!(Path.expand(archive))
actual_sha256 = :crypto.hash(:sha256, archive_bytes) |> Base.encode16(case: :lower)

unless actual_sha256 == expected_sha256, do: raise("candidate archive checksum mismatch")
IO.puts("CAP candidate archive SHA-256: #{actual_sha256}")
root = Path.expand("..", __DIR__)
scratch = Path.join(System.tmp_dir!(), "cas-cap-candidate-#{System.unique_integer([:positive])}")
cap = Path.join(scratch, "protocol")
cas = Path.join(scratch, "signer")
File.mkdir_p!(cap)
File.mkdir_p!(cas)
archive = Path.join(scratch, "protocol.tar")
File.write!(archive, archive_bytes)

run! = fn args, dir ->
  case System.cmd("mix", args,
         cd: dir,
         env: [{"MIX_ENV", "test"}],
         into: IO.stream(:stdio, :line),
         stderr_to_stdout: true
       ) do
    {_, 0} -> :ok
    {_, status} -> raise("candidate check failed (#{status}): mix #{Enum.join(args, " ")}")
  end
end

try do
  {:ok, outer} = :erl_tar.extract(String.to_charlist(archive), [:memory])
  {_, contents} = List.keyfind(outer, ~c"contents.tar.gz", 0)
  :ok = :erl_tar.extract({:binary, contents}, [:compressed, {:cwd, String.to_charlist(cap)}])

  for path <- [
        "README.md",
        "CHANGELOG.md",
        "CONTRIBUTING.md",
        "SECURITY.md",
        "CODE_OF_CONDUCT.md",
        "LICENSE",
        "NOTICE",
        "usage-rules.md",
        "docs",
        "lib",
        "test",
        "scripts",
        "priv",
        "config",
        "examples/charter_signing_roundtrip.livemd",
        "examples/charter_lifecycle/lib",
        "examples/charter_lifecycle/test",
        "examples/charter_lifecycle/config",
        "examples/charter_lifecycle/mix.exs",
        "examples/charter_lifecycle/mix.lock",
        "mix.exs",
        "mix.lock",
        ".tool-versions",
        ".formatter.exs",
        ".credo.exs"
      ] do
    source = Path.join(root, path)

    if File.exists?(source) do
      target = Path.join(cas, path)
      File.mkdir_p!(Path.dirname(target))
      File.cp_r!(source, target)
    end
  end

  # Override resolution only in the disposable copies. The shipped dependency
  # requirement and the checked-in Hex lock are still tested by the main gate.
  for dir <- [cas, Path.join(cas, "examples/charter_lifecycle")] do
    project = Path.join(dir, "mix.exs")
    source = File.read!(project)

    replacement =
      "deps: Enum.map(deps(), fn " <>
        "{:charter_agreement_protocol, req} -> " <>
        "{:charter_agreement_protocol, req, path: #{inspect(cap)}, override: true}; dep -> dep end)"

    unless source =~ "deps: deps()", do: raise("candidate check: dependency seam missing")
    File.write!(project, String.replace(source, "deps: deps()", replacement))
  end

  cached_plts = Path.join(root, "_build/plts")

  if File.dir?(cached_plts) do
    File.mkdir_p!(Path.join(cas, "_build"))
    File.cp_r!(cached_plts, Path.join(cas, "_build/plts"))
  end

  run!.(["deps.get"], cas)
  run!.(["compile", "--warnings-as-errors"], cas)

  run!.(
    [
      "run",
      "--no-start",
      "-e",
      "unless to_string(Application.spec(:charter_agreement_protocol, :vsn)) == \"1.0.0\", " <>
        "do: raise(\"candidate version mismatch\")"
    ],
    cas
  )

  if System.get_env("CAS_LIMITED_COVERAGE") do
    run!.(["run", "--no-start", "scripts/check_merged_coverage.exs"], cas)
  else
    run!.(["test"], cas)
  end

  run!.(["credo", "--strict"], cas)
  run!.(["dialyzer"], cas)
  run!.(["docs", "--warnings-as-errors"], cas)
  interop = Path.join(root, "scripts/typescript_interop.exs")
  signer_source = Path.join(root, "_build/signer-source")
  verifier_source = Path.join(root, "_build/verifier-source")

  run!.(
    [
      "run",
      "--no-start",
      "-e",
      "Code.require_file(#{inspect(interop)}); " <>
        "CharterAgreementSigner.TypeScriptInterop.run!(#{inspect(signer_source)}, #{inspect(verifier_source)})"
    ],
    cas
  )

  example = Path.join(cas, "examples/charter_lifecycle")
  run!.(["deps.get"], example)
  run!.(["test"], example)

  run!.(
    [
      "run",
      "--no-start",
      "--no-deps-check",
      "--no-compile",
      "scripts/check_package.exs",
      archive,
      expected_sha256
    ],
    root
  )

  run!.(
    ["run", "--no-start", "--no-deps-check", "--no-compile", "scripts/check_reproducible.exs"],
    root
  )

  IO.puts("CAP 1.0.0 archive: signer and lifecycle suites passed; publication_authorized=false")
after
  File.rm_rf!(scratch)
end
