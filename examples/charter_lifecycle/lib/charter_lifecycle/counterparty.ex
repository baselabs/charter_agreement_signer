# The receiving side — a real counterparty's verify kit. This module depends
# ONLY on charter_agreement_protocol (CAP): never on the signer (the
# dependency-direction wall; enforced mechanically by
# test/counterparty_isolation_test.exs). It re-verifies every artifact from
# scratch — the signer's own post-sign verification is its discipline, not
# something a counterparty can observe.
defmodule CharterLifecycle.Counterparty do
  @moduledoc false

  alias CharterAgreementProtocol, as: CAP
  alias CharterAgreementProtocol.Limits

  # Closed, value-free failures at THIS boundary — the obligation every
  # verifying host owes its callers (docs/consumer-integration.md §3).
  @type verdict :: :ok | {:error, :bad_artifact | :bad_signature}

  @spec verify_descriptor(binary()) :: verdict()
  def verify_descriptor(compact) do
    collapse(CAP.verify_descriptor(compact, nil, Limits.default()))
  end

  @spec verify_chain_view(
          revisions :: [binary()],
          acceptances :: [binary()],
          descriptors :: [binary()],
          terminations :: [binary()]
        ) ::
          {:ok, CAP.ChainFacts.t()} | {:error, :bad_artifact}
  def verify_chain_view(revisions, acceptances, descriptors, terminations) do
    case CAP.verify_chain(revisions, acceptances, descriptors, terminations, Limits.default()) do
      {:ok, facts} -> {:ok, facts}
      {:error, %CAP.Error{}} -> {:error, :bad_artifact}
    end
  end

  @spec governing_revision(CAP.ChainFacts.t(), DateTime.t()) ::
          {:ok, binary() | :contested | :none} | {:error, :bad_artifact}
  def governing_revision(facts, at) do
    case CAP.governing_revision(facts, at) do
      {:ok, result} -> {:ok, result}
      {:error, %CAP.Error{}} -> {:error, :bad_artifact}
    end
  end

  @spec verify_receipt(binary(), CAP.CharterRevision.t()) :: verdict()
  def verify_receipt(compact, revision) do
    collapse(CAP.verify_receipt(compact, revision, Limits.default()))
  end

  defp collapse({:ok, _facts}), do: :ok
  defp collapse({:error, %CAP.Error{code: :signature_invalid}}), do: {:error, :bad_signature}
  defp collapse({:error, %CAP.Error{}}), do: {:error, :bad_artifact}
end
