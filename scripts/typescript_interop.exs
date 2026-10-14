defmodule CharterAgreementSigner.TypeScriptInterop do
  @moduledoc false

  alias CharterAgreementProtocol, as: CAP
  alias CharterAgreementProtocol.Limits
  alias CharterAgreementSigner.Keys.{RawKey, RawMLDSA65}

  @table Path.expand("../test/fixtures/signer_cases.json", __DIR__)

  def run!(signer, verifier) do
    unless Mix.env() == :test, do: raise("typescript interop requires MIX_ENV=test")
    table = @table |> File.read!() |> :json.decode()

    for {id, module} <- [{"ed-descriptor-ok", RawKey}, {"ml-descriptor-ok", RawMLDSA65}] do
      row = Enum.find(table["cases"], &(&1["id"] == id))
      key = Map.fetch!(table["keys"], row["key"])
      algorithm = key["algorithm"]
      public = Base.url_decode64!(key["public_key"], padding: false)
      seed = Base.url_decode64!(key["seed"], padding: false)
      private = if module == RawKey, do: seed, else: {:seed, seed}
      handle = {module, {key["kid"], public, private}}

      compact =
        node!(signer, sign_script(), [
          {"CAS_INTEROP_KEY", JSON.encode!(key)},
          {"CAS_INTEROP_CLAIMS", JSON.encode!(row["claims"])}
        ])

      {:ok, facts} = CAP.verify_descriptor(compact, nil, Limits.default())
      true = facts.descriptor.envelope.alg == algorithm
      true = facts.descriptor.protocol_revision == row["claims"]["protocol_revision"]
      declared = Enum.find(facts.descriptor.verification_keys, &(&1.key_id == key["kid"]))
      true = declared.public_key == public
      IO.puts("typescript interop: TS -> CAP #{algorithm} verified")

      {:ok, %{descriptor: compact}} =
        CharterAgreementSigner.sign_descriptor(row["claims"], handle, algorithm: algorithm)

      "verified" =
        node!(verifier, verify_script(), [
          {"CAS_INTEROP_COMPACT", compact},
          {"CAS_INTEROP_ALGORITHM", algorithm},
          {"CAS_INTEROP_REVISION", Integer.to_string(row["claims"]["protocol_revision"])}
        ])

      IO.puts("typescript interop: Elixir -> TS #{algorithm} verified")
    end
  end

  defp node!(directory, script, env) do
    case System.cmd("node", ["--input-type=module", "-e", script],
           cd: directory,
           env: env,
           stderr_to_stdout: true
         ) do
      {output, 0} -> String.trim(output)
      {output, status} -> raise("typescript interop: node failed (#{status})\n#{output}")
    end
  end

  defp sign_script do
    """
    import { createPrivateKey, createPublicKey, sign } from "node:crypto";
    const { signDescriptor } = await import("./dist/index.js");
    const key = JSON.parse(process.env.CAS_INTEROP_KEY);
    const claims = JSON.parse(process.env.CAS_INTEROP_CLAIMS);
    const prefix = key.algorithm === "Ed25519"
      ? "302e020100300506032b657004220420"
      : "3034020100300b060960864801650304031204228020";
    const priv = createPrivateKey({
      key: Buffer.concat([Buffer.from(prefix, "hex"), Buffer.from(key.seed, "base64url")]),
      format: "der", type: "pkcs8",
    });
    const length = key.algorithm === "Ed25519" ? 32 : 1952;
    const pub = createPublicKey(priv).export({ format: "der", type: "spki" })
      .subarray(-length).toString("base64url");
    if (pub !== key.public_key) throw new Error("interop public key differs from the seed");
    const handle = {
      keyIdentity: () => ({ kid: key.kid, publicKey: pub }),
      sign: (message) => new Uint8Array(sign(null, Buffer.from(message), priv)),
    };
    const result = await signDescriptor(claims, handle, { algorithm: key.algorithm });
    if (!result.ok) throw new Error(JSON.stringify(result));
    process.stdout.write(result.result.descriptor);
    """
  end

  defp verify_script do
    """
    const { verifyDescriptor } = await import("./dist/index.js");
    const compact = process.env.CAS_INTEROP_COMPACT;
    const result = verifyDescriptor(compact, null);
    if (!result.ok) throw new Error(JSON.stringify(result));
    const [header, payload] = compact.split(".").slice(0, 2)
      .map((segment) => JSON.parse(Buffer.from(segment, "base64url").toString("utf8")));
    if (header.alg !== process.env.CAS_INTEROP_ALGORITHM ||
        payload.protocol_revision !== Number(process.env.CAS_INTEROP_REVISION)) {
      throw new Error("interop emission differs from the selected algorithm and revision");
    }
    process.stdout.write("verified");
    """
  end
end
