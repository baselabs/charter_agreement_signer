# Use a real second toolchain whose linked OpenSSL cannot verify ML-DSA.
limited_path = System.get_env("CAS_LIMITED_PATH")

unless is_binary(limited_path) and limited_path != "",
  do: raise("set CAS_LIMITED_PATH to the PATH for a capability-limited Elixir/OTP toolchain")

unless CharterAgreementProtocol.Capability.kat_verifies?("ML-DSA-65"),
  do: raise("the standard coverage lane must verify ML-DSA-65")

for path <- Path.wildcard("cover/*.coverdata"), do: File.rm!(path)

run = fn args, env ->
  {_, status} = System.cmd("mix", args, env: env, into: IO.stream(:stdio, :line))
  if status != 0, do: raise("coverage command failed (#{status}): mix #{Enum.join(args, " ")}")
end

run.(["test", "--cover", "--export-coverage", "standard"], [])

limited_env = [
  {"PATH", limited_path},
  {"MIX_BUILD_ROOT", "_build_limited"}
]

run.(["run", "--no-start", "scripts/assert_limited_substrate.exs"], limited_env)

run.(
  ["test", "--exclude", "requires_mldsa_substrate", "--cover", "--export-coverage", "limited"],
  limited_env
)

for name <- ["standard", "limited"] do
  unless File.regular?("cover/#{name}.coverdata"), do: raise("missing #{name} coverage export")
end

run.(["test.coverage"], [])
