# Upload only verified archives with Hex 2.7.0, with no project loaded or rebuilt.
# Run from a directory without mix.exs:
#   mix run --no-mix-exs PATH/hex_upload.exs [--package] [--docs] [--organization ORG] NAME VERSION PACKAGE_TAR DOCS_TAR
defmodule HexUpload do
  @moduledoc false

  alias Hex.API.{Client, Release, ReleaseDocs}

  # The standalone uploader loads the pinned Hex archive. The pure tests need no Hex client.
  @compile {:no_warn_undefined, [Client, Release, ReleaseDocs, Hex.Tar, :mix_hex_api_release]}

  def main(argv) do
    if Mix.Project.get() do
      raise "a Mix project is loaded; run from a directory without mix.exs"
    end

    case OptionParser.parse(argv,
           strict: [package: :boolean, docs: :boolean, organization: :string]
         ) do
      {opts, [name, version, package_tar, docs_tar], []} ->
        unless opts[:package] || opts[:docs], do: raise("choose --package, --docs, or both")
        upload(opts, name, version, package_tar, docs_tar)

      _ ->
        raise "usage: hex_upload.exs [--package] [--docs] [--organization ORG] NAME VERSION PACKAGE_TAR DOCS_TAR"
    end
  end

  defp upload(opts, name, version, package_tar, docs_tar) do
    Hex.start()
    Enum.each([Hex.Tar, Client, Release, ReleaseDocs], &Code.ensure_loaded!/1)
    package = File.read!(package_tar)
    docs = if opts[:docs], do: File.read!(docs_tar)
    checksum = digest(package)
    %{metadata: metadata} = Hex.Tar.unpack!({:binary, package}, :memory)

    unless metadata["name"] == name and metadata["version"] == version do
      raise "package metadata name or version differs from the requested release; upload refused"
    end

    key = System.get_env("HEX_API_KEY", "")
    if String.trim(key) == "", do: raise("HEX_API_KEY is empty; upload refused")
    repo = opts[:organization]
    auth = [key: key]

    package_result =
      if opts[:package], do: upload_package!(repo, package, auth), else: :live

    if docs do
      result = upload_docs!(repo, name, version, docs, checksum, auth, package_result)
      IO.puts("docs=#{result}")
    end
  end

  defp upload_package!(repo, package, auth) do
    {_code, _headers, body} =
      request(fn -> Release.publish(repo, package, auth, &progress/1, replace: false) end)
      |> successful!("package", auth[:key])

    case body do
      %{"status" => "staged"} ->
        IO.puts("package=staged")
        {:staged, body}

      _ ->
        IO.puts("package=accepted")
        :live
    end
  end

  defp upload_docs!(repo, name, version, docs, checksum, auth, {:staged, package_receipt}) do
    url = stage_url!(package_receipt, checksum)
    unpublished!(read_release(repo, name, version, auth), version, checksum)

    # Hex can still approve the release between this check and its unconditional docs POST.
    request(fn -> Release.get_staged(url, auth) end)
    |> confirm_stage!(name, version, checksum)

    post_docs!(repo, name, version, docs, auth)
    |> staged_docs_receipt!(checksum)
  end

  defp upload_docs!(repo, name, version, docs, checksum, auth, :live) do
    docs_checksum = digest(docs)

    case live_docs!(read_release(repo, name, version, auth), version, checksum) do
      :skip ->
        :skipped

      :upload ->
        post_docs!(repo, name, version, docs, auth)
        |> live_docs_receipt!(docs_checksum)
    end
  end

  defp read_release(repo, name, version, auth) do
    request(fn ->
      # The public release endpoint can cache its response for 60 seconds.
      read_auth = if repo, do: auth, else: []

      config =
        Client.build_config(repo, read_auth)
        |> Map.update!(:http_headers, &Map.put(&1, "cache-control", "no-cache"))

      :mix_hex_api_release.get(config, name, version)
    end)
  end

  def live_docs!(result, version, checksum) do
    case served_release!(result, version, checksum) do
      {:served, false} -> :upload
      {:served, true} -> :skip
      :missing -> raise "Hex does not serve this package yet; docs were not posted"
    end
  end

  def unpublished!(result, version, checksum) do
    case served_release!(result, version, checksum) do
      :missing -> :ok
      {:served, _} -> raise "Hex already serves this release; staged docs were not posted"
    end
  end

  defp served_release!({:ok, {404, _headers, _body}}, _version, _checksum), do: :missing

  defp served_release!(
         {:ok, {200, _headers, %{"version" => version, "retirement" => nil} = release}},
         version,
         checksum
       ) do
    unless release["checksum"] == checksum do
      raise "Hex serves this release with other package bytes; docs were not posted"
    end

    has_docs = release["has_docs"]

    unless is_boolean(has_docs) do
      raise "Hex returned no definite documentation state; docs were not posted"
    end

    {:served, has_docs}
  end

  defp served_release!(_result, _version, _checksum),
    do: raise("Could not confirm an unretired Hex release; docs were not posted")

  defp stage_url!(%{"kind" => "release", "checksum" => checksum, "url" => url}, checksum)
       when is_binary(url) and byte_size(url) > 0,
       do: url

  defp stage_url!(_receipt, _checksum),
    do: raise("Hex did not return a stage URL for this package archive; docs were not posted")

  def confirm_stage!(
        {:ok,
         {200, _headers,
          %{
            "name" => name,
            "version" => version,
            "status" => "staged",
            "kind" => "release",
            "checksum" => checksum
          }}},
        name,
        version,
        checksum
      ),
      do: :ok

  def confirm_stage!(_result, _name, _version, _checksum),
    do:
      raise("Hex did not confirm an active stage for this package archive; docs were not posted")

  defp post_docs!(repo, name, version, docs, auth) do
    request(fn -> ReleaseDocs.publish(repo, name, version, docs, auth) end)
    |> successful!("docs", auth[:key])
  end

  def staged_docs_receipt!(
        {code, _headers, %{"status" => "staged", "kind" => "release", "checksum" => checksum}},
        checksum
      )
      when code in 200..299,
      do: :staged

  def staged_docs_receipt!(_result, _checksum),
    do: raise("Hex did not attach docs to the staged package archive")

  def live_docs_receipt!(
        {201, _headers, %{"status" => "staged", "kind" => "docs", "checksum" => checksum}},
        checksum
      ),
      do: :staged

  def live_docs_receipt!({201, %{"location" => url}, nil}, _checksum)
      when is_binary(url) and byte_size(url) > 0,
      do: :accepted

  def live_docs_receipt!(_result, _checksum),
    do: raise("Hex returned an unexpected docs upload receipt")

  defp digest(archive), do: :crypto.hash(:sha256, archive) |> Base.encode16(case: :lower)

  defp progress(_bytes), do: :ok

  defp request(upload) do
    upload.()
  rescue
    _ -> :upload_error
  catch
    _, _ -> :upload_error
  end

  defp successful!({:ok, {code, _headers, _body} = receipt}, _label, _key)
       when code in 200..299,
       do: receipt

  defp successful!({:ok, {code, _headers, body}}, label, key) do
    message = if is_map(body), do: body["message"]

    if is_binary(message) do
      safe_message = message |> String.replace(key, "[REDACTED]") |> Hex.Utils.escape_terminal()
      raise "#{label} upload refused (HTTP #{code}): #{safe_message}"
    end

    raise "#{label} upload refused (HTTP #{code})"
  end

  defp successful!(_result, label, _key),
    do: raise("#{label} upload failed; no response body logged")
end

HexUpload.main(System.argv())
