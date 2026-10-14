# Build both pinned sources and run the signer's own locked test suite.
Code.require_file("typescript_sources.exs", __DIR__)

alias CharterAgreementSigner.TypeScriptSources

for kind <- [:signer, :verifier], do: TypeScriptSources.current!(kind)

root = Path.expand("..", __DIR__)
signer = Path.join(root, TypeScriptSources.path(:signer))
verifier = Path.join(root, TypeScriptSources.path(:verifier))

run! = fn dir, args ->
  case System.cmd("npm", args, cd: dir, into: IO.stream(:stdio, :line), stderr_to_stdout: true) do
    {_out, 0} ->
      :ok

    {_out, status} ->
      raise("typescript source check: npm #{Enum.join(args, " ")} failed (#{status})")
  end
end

run!.(verifier, ["ci"])
run!.(verifier, ["run", "build"])
run!.(signer, ["ci"])

run!.(signer, ["run", "build"])

# The signer's own suite must run at least the pin's recorded number of
# tests with none failing, so a pin whose test script runs nothing fails.
%{"minimum_tests" => minimum} = TypeScriptSources.pin!(:signer)

{output, status} = System.cmd("npm", ["test"], cd: signer, stderr_to_stdout: true)
IO.write(output)
if status != 0, do: raise("typescript source check: npm test failed (#{status})")

count = fn label ->
  case Regex.run(~r/^\S+ #{label} (\d+)$/m, output) do
    [_line, value] -> String.to_integer(value)
    nil -> raise("typescript source check: npm test printed no #{label} count")
  end
end

{tests, passed, failed} = {count.("tests"), count.("pass"), count.("fail")}

unless tests >= minimum and passed == tests and failed == 0 do
  raise(
    "typescript source check: expected at least #{minimum} tests, all passing; " <>
      "got tests #{tests}, pass #{passed}, fail #{failed}"
  )
end

Code.require_file("typescript_interop.exs", __DIR__)
CharterAgreementSigner.TypeScriptInterop.run!(signer, verifier)
IO.puts("typescript source check: #{tests} signer tests passed (minimum #{minimum})")
