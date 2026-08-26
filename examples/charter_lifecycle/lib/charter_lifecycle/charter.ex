# The charter's claim material: descriptor claims (each pinning its party's
# verification key) and the genesis revision's canonical bytes. Everything
# byte-shaped flows through CAP's public canonicalization/digest modules —
# this example never re-implements canonical bytes.
defmodule CharterLifecycle.Charter do
  @moduledoc false

  alias CharterAgreementProtocol.{Base64Url, Canonicalization, Digest}

  def descriptor_claims(handle, effective_from) do
    {kid, public, _private} = handle

    %{
      "protocol_revision" => 1,
      "descriptor_number" => 1,
      "verification_keys" => [
        %{
          "key_id" => kid,
          "algorithm" => "Ed25519",
          "public_key" => Base64Url.encode(public),
          "status" => "active"
        }
      ],
      "attestation_hints" => [],
      "extensions" => %{"critical" => %{}, "optional" => %{}},
      "effective_from" => effective_from
    }
  end

  def genesis_revision_claims(issuer_descriptor_digest, acceptor_descriptor_digest) do
    %{
      "protocol_revision" => 1,
      "revision_number" => 1,
      "parties" => [
        %{"party_descriptor_digest" => issuer_descriptor_digest, "role" => "issuer"},
        %{"party_descriptor_digest" => acceptor_descriptor_digest, "role" => "acceptor"}
      ],
      "legal_text" => %{
        "content_digest" =>
          Digest.hash(:legal_text, "Demo charter terms\n") |> Digest.to_tagged(),
        "media_type" => "text/plain",
        "uri_hint" => "https://example.com/charter.txt"
      },
      "precedence_declaration" => "legal_text_governs",
      "attribution_declaration" => %{"basis" => "bound_deployments"},
      "effective_from" => "2026-08-26T12:00:00Z",
      "termination_rules" => %{"reason_codes" => ["mutual", "breach"]},
      "abp_bindings" => [
        %{
          "party_role" => "issuer",
          "blueprint_id" => "example.demo/echo",
          "release_number" => 1,
          "content_digest" => "sha-256:b1Aw4cU5AbV9k8bdbZkRCsySDHGpTAwB-aQm57Wh7B8",
          "deployment_digest" => "sha-256:tWFr0caS0AWFJd2UcB9gZv3kNjIUP8xZ08WWM_h8xgo"
        }
      ],
      "receipt_profile" => "com.example.charter/default",
      "extensions" => %{"critical" => %{}, "optional" => %{}}
    }
  end

  def acceptance_claims(revision, party_digest, role) do
    %{
      "protocol_revision" => 1,
      "charter_id" => revision.charter_id,
      "revision_number" => revision.claims["revision_number"],
      "revision_digest" => revision.digest,
      "party_descriptor_digest" => party_digest,
      "party_role" => role,
      "accepted_at" => "2026-08-26T13:00:00Z"
    }
  end

  def termination_claims(revision, party_digest, role) do
    %{
      "protocol_revision" => 1,
      "charter_id" => revision.charter_id,
      "governing_revision_digest" => revision.digest,
      "party_descriptor_digest" => party_digest,
      "party_role" => role,
      "reason_code" => "mutual",
      "effective_at" => "2026-08-26T14:00:00Z",
      "issued_at" => "2026-08-26T13:30:00Z"
    }
  end

  def receipt_claims(revision) do
    %{
      "protocol_revision" => 1,
      "charter_id" => revision.charter_id,
      "revision_number" => revision.claims["revision_number"],
      "revision_digest" => revision.digest,
      "issuing_party_role" => "issuer",
      "agent_party_role" => "issuer",
      "deployment_digest" => "sha-256:tWFr0caS0AWFJd2UcB9gZv3kNjIUP8xZ08WWM_h8xgo",
      "grant" => %{
        "scheme" => "bap",
        "id" => "demo-grant-001",
        "grant_digest" => "sha-256:5k224cZ_lMI9VoUZ_fYM31ZJAcnJiht0GYEpnhes_ZI"
      },
      "invocation_id" => "demo-invocation-001",
      "decision" => "accepted",
      "outcome" => "effect_committed",
      "occurred_at" => "2026-08-26T13:00:00Z",
      "recorded_at" => "2026-08-26T13:00:01Z",
      "extensions" => %{"critical" => %{}, "optional" => %{}}
    }
  end

  # A built genesis revision: canonical bytes + its content digest + the
  # charter_id (the revision digest itself, per CAP's genesis convention).
  def build_revision(claims) do
    bytes = canonical!(claims)

    %{
      bytes: bytes,
      claims: claims,
      digest: Digest.hash(:charter_revision_content, bytes) |> Digest.to_tagged(),
      charter_id: Digest.hash(:charter_revision_content, bytes) |> Digest.to_tagged()
    }
  end

  def descriptor_digest(compact) do
    [_protected_segment, payload_segment, _signature] = String.split(compact, ".")

    # The descriptor content digest covers the PAYLOAD bytes (the claims);
    # recovering them from the compact is byte-exact because base64url
    # segments are canonical.
    case Base64Url.decode(payload_segment) do
      {:ok, payload_bytes} ->
        {:ok, Digest.hash(:party_descriptor_content, payload_bytes) |> Digest.to_tagged()}

      _ ->
        {:error, :bad_compact}
    end
  end

  defp canonical!(plain) do
    {:ok, bytes} = Canonicalization.encode(tagged(plain))
    bytes
  end

  defp tagged(value) when is_map(value),
    do: {:object, Enum.map(value, fn {name, item} -> {name, tagged(item)} end)}

  defp tagged(value) when is_list(value), do: {:array, Enum.map(value, &tagged/1)}
  defp tagged(value) when is_binary(value), do: {:string, value}
  defp tagged(value) when is_integer(value), do: {:integer, value}
end
