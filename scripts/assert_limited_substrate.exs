# This lane must verify the classical rows and lack ML-DSA verification.
report = CharterAgreementProtocol.capabilities()
IO.puts(inspect(report, structs: false, width: 120))

{mldsa, classical} =
  Enum.split_with(report.algorithms, &String.starts_with?(&1.name, "ML-DSA-"))

unless length(mldsa) == 3 and Enum.all?(mldsa, &(&1.verifiable == false)),
  do: raise("capability-limited substrate gained ML-DSA verification; use a limited runtime")

unless length(classical) == 2 and Enum.all?(classical, &(&1.verifiable == true)),
  do: raise("capability-limited substrate cannot verify every classical row")

IO.puts("capability-limited substrate confirmed: ML-DSA unverifiable, classical verifiable")
