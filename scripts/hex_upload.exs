# Upload only verified archives with Hex 2.7.0, with no project loaded or rebuilt.
# Run from a directory without mix.exs:
#   mix run --no-mix-exs PATH/hex_upload.exs [--package] [--docs] [--organization ORG] NAME VERSION PACKAGE_TAR DOCS_TAR
defmodule HexUpload do
  @moduledoc false

  alias Hex.API.{Release, ReleaseDocs}

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
    Enum.each([Hex.Tar, Release, ReleaseDocs], &Code.ensure_loaded!/1)
    package = if opts[:package], do: File.read!(package_tar)
    docs = if opts[:docs], do: File.read!(docs_tar)

    if package do
      %{metadata: metadata} = Hex.Tar.unpack!({:binary, package}, :memory)

      unless metadata["name"] == name and metadata["version"] == version do
        raise "package metadata name or version differs from the requested release; upload refused"
      end
    end

    key = System.get_env("HEX_API_KEY", "")
    if String.trim(key) == "", do: raise("HEX_API_KEY is empty; upload refused")
    repo = opts[:organization]
    auth = [key: key]

    if package do
      accepted!(
        request(fn -> Release.publish(repo, package, auth, &progress/1, []) end),
        "package",
        key
      )
    end

    if docs do
      accepted!(
        request(fn -> ReleaseDocs.publish(repo, name, version, docs, auth) end),
        "docs",
        key
      )
    end
  end

  defp progress(_bytes), do: :ok

  defp request(upload) do
    upload.()
  rescue
    _ -> :upload_error
  catch
    _, _ -> :upload_error
  end

  defp accepted!({:ok, {code, _headers, body}}, label, _key) when code in 200..299 do
    state = if is_map(body) and body["status"] == "staged", do: "staged", else: "accepted"
    IO.puts("#{label}=#{state}")
  end

  defp accepted!({:ok, {code, _headers, body}}, label, key) do
    message = if is_map(body), do: body["message"]

    if is_binary(message) do
      safe_message = message |> String.replace(key, "[REDACTED]") |> Hex.Utils.escape_terminal()
      raise "#{label} upload refused (HTTP #{code}): #{safe_message}"
    end

    raise "#{label} upload refused (HTTP #{code})"
  end

  defp accepted!(_result, label, _key),
    do: raise("#{label} upload failed; no response body logged")
end

HexUpload.main(System.argv())
