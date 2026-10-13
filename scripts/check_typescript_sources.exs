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
run!.(signer, ["test"])
IO.puts("typescript source check: pinned verifier build and signer own suite passed")
