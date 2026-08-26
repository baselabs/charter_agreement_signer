defmodule CharterLifecycle.MixProject do
  use Mix.Project

  @version "0.1.0"

  # A runnable bilateral-charter reference app — the proof the signer works
  # in a real two-party flow. TWO hosts live here for a self-contained loop:
  # the ISSUER host (descriptors, revision, its acceptance, the receipt) and
  # the ACCEPTOR host (its countersignature, the termination), each with its
  # own DEMO-ONLY custody. A third module — CharterLifecycle.Counterparty —
  # is the receiving side: it verifies every artifact depending ONLY on
  # charter_agreement_protocol, exactly as a real counterparty would (the
  # dependency-direction wall; enforced mechanically by
  # test/counterparty_isolation_test.exs, not prose).
  #
  # DEMO-ONLY custodies: both key handles hold in-process seeded key pairs.
  # That is an illustrative fiction — a real deployment's custody is an
  # HSM/KMS/key server behind each host's own handle module (see the
  # library's docs/recipes.md). Nothing here teaches production custody.
  #
  # This is its OWN mix project: the signer dep is `path: "../.."`, so the
  # library's dependency wall (which scans the library's mix.exs/lib) stays
  # green; this project's own lock parity is gated by
  # test/lock_parity_test.exs.
  def project do
    [
      app: :charter_lifecycle,
      version: @version,
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:crypto]
    ]
  end

  defp deps do
    [
      # The signing glue. Path-relative so the example tracks the working
      # tree of this repo; transitively resolves charter_agreement_protocol.
      {:charter_agreement_signer, path: "../.."},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end
end
