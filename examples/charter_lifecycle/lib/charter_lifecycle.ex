# The runnable bilateral lifecycle. `run/0` forms a complete charter — both
# party descriptors, the genesis revision, the dual acceptances (offer +
# countersignature), a receipt, and a mutual termination — verifying every
# artifact through the CAP-only Counterparty, and proving the wrong-key
# rejection fires. Run: `mix run -e 'CharterLifecycle.run()'`.
defmodule CharterLifecycle do
  @moduledoc false

  alias CharterAgreementSigner, as: Signer

  alias CharterLifecycle.{
    Charter,
    Counterparty,
    Exchange,
    Keys,
    Keys.Handle
  }

  alias CharterAgreementProtocol, as: CAP

  def run do
    issuer = Keys.issuer()
    acceptor = Keys.acceptor()
    issuer_handle = {Handle, issuer}
    acceptor_handle = {Handle, acceptor}

    # 1. Each party publishes its descriptor (pinning its verification key),
    #    signs it, and hands it across the exchange; the counterparty
    #    verifies each from scratch.
    {:ok, issuer_descriptor} = publish_descriptor(issuer_handle, "2026-08-26T10:00:00Z")
    {:ok, acceptor_descriptor} = publish_descriptor(acceptor_handle, "2026-08-26T10:00:01Z")

    # 2. The genesis revision (unsigned canonical bytes binding both
    #    parties by their descriptor digests).
    {:ok, issuer_digest} = Charter.descriptor_digest(issuer_descriptor)
    {:ok, acceptor_digest} = Charter.descriptor_digest(acceptor_descriptor)

    revision =
      Charter.genesis_revision_claims(issuer_digest, acceptor_digest) |> Charter.build_revision()

    descriptors = [issuer_descriptor, acceptor_descriptor]

    # 3. The dual acceptances: the issuer's offer-acceptance and the
    #    acceptor's countersignature, each signed against the signer's own
    #    retained view.
    {:ok, issuer_acceptance} =
      sign_acceptance(revision, issuer_digest, "issuer", issuer_handle, descriptors)

    {:ok, acceptor_acceptance} =
      sign_acceptance(revision, acceptor_digest, "acceptor", acceptor_handle, descriptors)

    # 4. The counterparty's verified view of the accepted charter.
    {:ok, facts} =
      Counterparty.verify_chain_view(
        [revision.bytes],
        [issuer_acceptance, acceptor_acceptance],
        descriptors,
        []
      )

    {:ok, governing} = Counterparty.governing_revision(facts, ~U[2026-08-26 13:00:00Z])

    # The governing revision at that instant is the genesis itself — exactly
    # what the receipt and termination anchor to below.
    ^governing = revision.digest

    # 5. An effect receipt over the governing revision.
    {:ok, receipt} = sign_receipt(revision, issuer_handle)

    # 6. A mutual termination from the acceptor side — signed against the
    #    ACCEPTED view (the producer's governing rule refuses every revision
    #    that does not govern at the notice's effective time; an unaccepted
    #    set governs nothing).
    {:ok, termination} =
      sign_termination(
        revision,
        acceptor_digest,
        "acceptor",
        acceptor_handle,
        descriptors,
        [issuer_acceptance, acceptor_acceptance]
      )

    # 7. The wrong-key negative: a custody that advertises key A and signs
    #    with key B is refused LOUDLY — the artifact never crosses the
    #    exchange.
    {:error, :signing_failed} =
      Signer.sign_descriptor(
        Charter.descriptor_claims(issuer, "2026-08-26T10:00:00Z"),
        {Handle, Keys.rogue_issuer()}
      )

    %{
      issuer_descriptor: issuer_descriptor,
      acceptor_descriptor: acceptor_descriptor,
      revision: revision.bytes,
      issuer_acceptance: issuer_acceptance,
      acceptor_acceptance: acceptor_acceptance,
      receipt: receipt,
      termination: termination,
      governing: governing,
      wrong_key: :refused_loudly
    }
  end

  defp publish_descriptor({_, raw} = handle, effective_from) do
    claims = Charter.descriptor_claims(raw, effective_from)

    with {:ok, %{descriptor: compact}} <- Signer.sign_descriptor(claims, handle),
         :ok <- Counterparty.verify_descriptor(compact),
         {:ok, delivered} <- Exchange.deliver(compact) do
      {:ok, delivered}
    else
      {:error, reason} -> {:error, Exchange.deliver_result({:error, reason}) |> elem(1)}
    end
  end

  defp sign_acceptance(revision, party_digest, role, handle, descriptors) do
    claims = Charter.acceptance_claims(revision, party_digest, role)

    with {:ok, set} <-
           CAP.build_set([revision.bytes], [], [], descriptors),
         {:ok, %{acceptance: compact}} <- Signer.sign_acceptance(claims, handle, set) do
      Exchange.deliver(compact)
    end
  end

  defp sign_receipt(revision, handle) do
    claims = Charter.receipt_claims(revision)

    with {:ok, revision_struct} <-
           CAP.decode_charter_revision(revision.bytes, CAP.Limits.default()),
         {:ok, %{receipt: compact}} <- Signer.sign_receipt(claims, handle, revision_struct),
         :ok <- Counterparty.verify_receipt(compact, revision_struct) do
      Exchange.deliver(compact)
    end
  end

  defp sign_termination(revision, party_digest, role, handle, descriptors, acceptances) do
    claims = Charter.termination_claims(revision, party_digest, role)

    with {:ok, set} <-
           CAP.build_set([revision.bytes], acceptances, [], descriptors),
         {:ok, %{termination: compact}} <- Signer.sign_termination(claims, handle, set) do
      Exchange.deliver(compact)
    end
  end
end
