# These tagged regressions stay runnable against the read-only CAP build.
excluded = [:requires_cap_profile_fix, :requires_cap_limits_fix]

excluded =
  if CharterAgreementProtocol.Capability.kat_verifies?("ML-DSA-65"),
    do: [:requires_limited_substrate | excluded],
    else: excluded

ExUnit.start(exclude: excluded)
