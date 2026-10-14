alias CharterAgreementProtocol, as: CAP

unless CAP.Capability.kat_verifies?("ML-DSA-65"),
  do: raise("building predecessor fixtures requires ML-DSA verification")

fixtures = Path.expand("../test/fixtures", __DIR__)
table = fixtures |> Path.join("signer_cases.json") |> File.read!() |> JSON.decode!()

facts =
  Map.new(["ml-predecessor", "ml-wrong-predecessor"], fn name ->
    %{"descriptors" => [compact]} = table["contexts"][name]
    {:ok, predecessor} = CAP.verify_descriptor(compact, nil, CAP.Limits.default())
    {name, predecessor}
  end)

File.write!(
  Path.join(fixtures, "mldsa_predecessors.etf"),
  :erlang.term_to_binary(facts, [:compressed])
)

IO.puts("retained two publicly verified ML-DSA predecessor fixtures")
