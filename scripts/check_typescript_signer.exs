# Cross-implementation gate: artifacts signed by the TypeScript signer must
# verify under the Elixir reference implementation. The TS side signs with a
# deterministic Ed25519 seed handle; the Elixir side cold-verifies from raw
# bytes. Run: mix run --no-start scripts/check_typescript_signer.exs

alias CharterAgreementProtocol.{Limits, PartyDescriptor}

der_seed = :binary.copy(<<6>>, 32)

{public, _private} = :crypto.generate_key(:eddsa, :ed25519, der_seed)

handle_script = """
const { createPrivateKey, createPublicKey, sign } = require("node:crypto");
const der = Buffer.concat([Buffer.from("302e020100300506032b657004220420", "hex"), Buffer.from(process.env.CAP_SEED_HEX, "hex")]);
const priv = createPrivateKey({ key: der, format: "der", type: "pkcs8" });
const spki = createPublicKey(priv).export({ format: "der", type: "spki" });
const pub = Buffer.from(spki.subarray(spki.length - 32)).toString("base64url");
const handle = {
  keyIdentity: () => ({ kid: "xgate-key", publicKey: pub }),
  sign: (msg) => new Uint8Array(sign(null, Buffer.from(msg), priv)),
};
const claims = {
  protocol_revision: 2,
  descriptor_number: 1,
  verification_keys: [{ key_id: "xgate-key", algorithm: "Ed25519", public_key: pub, status: "active" }],
  attestation_hints: [],
  extensions: { critical: {}, optional: {} },
  effective_from: "2026-08-25T10:00:00Z",
};
import("./dist/index.js").then(async (m) => {
  const result = await m.signDescriptor(claims, handle);
  if (!result.ok) { console.error(result); process.exit(1); }
  process.stdout.write(result.result.descriptor);
});
"""

env = [{"CAP_SEED_HEX", Base.encode16(der_seed, case: :lower)}]

{output, status} =
  System.cmd("node", ["--experimental-strip-types", "--no-warnings", "-e", handle_script],
    cd: Path.absname("typescript"),
    stderr_to_stdout: true,
    env: env
  )

if status != 0, do: raise("TypeScript signer harness failed\n#{output}")

compact = String.trim_trailing(output)
{:ok, facts} = PartyDescriptor.verify(compact, nil, Limits.default())

# The snapshot public key must be the one declared in the signed claims —
# the Elixir side resolved and verified it over the exact compact bytes.
declared =
  facts.descriptor.verification_keys
  |> Enum.find(&(&1.key_id == "xgate-key"))

if declared == nil or Base.url_encode64(declared.public_key, padding: false) != Base.url_encode64(public, padding: false),
  do: raise("TypeScript-signed descriptor key mismatch")

IO.puts("typescript signer gate: Elixir reference verifies the TS-signed descriptor (#{facts.descriptor_digest})")
