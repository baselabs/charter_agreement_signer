excluded =
  if CharterAgreementProtocol.Capability.kat_verifies?("ML-DSA-65"),
    do: [:requires_limited_substrate],
    else: []

ExUnit.start(exclude: excluded)
