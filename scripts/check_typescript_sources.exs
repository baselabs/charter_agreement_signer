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

# Interop: a descriptor the pinned TypeScript signer signs with a real
# Ed25519 key must verify under CAP.
alias CharterAgreementProtocol.{Limits, PartyDescriptor}

seed = :binary.copy(<<6>>, 32)
{public, _private} = :crypto.generate_key(:eddsa, :ed25519, seed)

sign_script = """
const { createPrivateKey, createPublicKey, sign } = require("node:crypto");
const der = Buffer.concat([Buffer.from("302e020100300506032b657004220420", "hex"), Buffer.from(process.env.CAS_SEED_HEX, "hex")]);
const priv = createPrivateKey({ key: der, format: "der", type: "pkcs8" });
const spki = createPublicKey(priv).export({ format: "der", type: "spki" });
const pub = Buffer.from(spki.subarray(spki.length - 32)).toString("base64url");
const handle = {
  keyIdentity: () => ({ kid: "interop-key", publicKey: pub }),
  sign: (msg) => new Uint8Array(sign(null, Buffer.from(msg), priv)),
};
const claims = {
  protocol_revision: 2,
  descriptor_number: 1,
  verification_keys: [{ key_id: "interop-key", algorithm: "Ed25519", public_key: pub, status: "active" }],
  attestation_hints: [],
  extensions: { critical: {}, optional: {} },
  effective_from: "2026-08-25T10:00:00Z",
};
import("./dist/index.js").then(async (m) => {
  const result = await m.signDescriptor(claims, handle);
  if (!result.ok) { console.error(JSON.stringify(result)); process.exit(1); }
  process.stdout.write(result.result.descriptor);
});
"""

{compact, sign_status} =
  System.cmd("node", ["-e", sign_script],
    cd: signer,
    env: [{"CAS_SEED_HEX", Base.encode16(seed, case: :lower)}]
  )

if sign_status != 0, do: raise("typescript source check: the pinned signer failed\n#{compact}")

case PartyDescriptor.verify(String.trim_trailing(compact), nil, Limits.default()) do
  {:ok, facts} ->
    declared = Enum.find(facts.descriptor.verification_keys, &(&1.key_id == "interop-key"))

    unless declared && declared.public_key == public,
      do: raise("typescript source check: the TS-signed descriptor declares another key")

    IO.puts(
      "typescript source check: #{tests} signer tests passed (minimum #{minimum}); " <>
        "CAP verifies the TS-signed descriptor #{facts.descriptor_digest}"
    )

  {:error, error} ->
    raise("typescript source check: CAP rejected the TS-signed descriptor: #{inspect(error)}")
end
