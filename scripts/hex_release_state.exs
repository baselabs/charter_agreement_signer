# Read Hex 2.7.0's signed registry with its existing read login, never a publish key.
# Run from a directory without mix.exs:
#   mix run --no-mix-exs PATH/hex_release_state.exs (--plan | --served) [--organization ORG] NAME VERSION PACKAGE_TAR DOCS_TAR
defmodule HexReleaseState do
  @moduledoc false

  @pending "held for approval or not yet served: after the owner approves, dispatch publish.yml again on this same commit; it uploads only what is missing"

  def main(argv) do
    if Mix.Project.get() do
      raise "a Mix project is loaded; run from a directory without mix.exs"
    end

    case OptionParser.parse(argv,
           strict: [plan: :boolean, served: :boolean, organization: :string]
         ) do
      {opts, [name, version, package_tar, docs_tar], []} ->
        unless {opts[:plan], opts[:served]} in [{true, nil}, {nil, true}] do
          raise "choose exactly one of --plan or --served"
        end

        Hex.start()
        Code.ensure_loaded!(Hex.Repo)
        repo = if opts[:organization], do: "hexpm:" <> opts[:organization], else: "hexpm"
        package = package_state(repo, name, version, File.read!(package_tar))
        docs = docs_state(repo, name, version, File.read!(docs_tar))

        if docs == "served" and package != "served" do
          raise "#{name} #{version}: docs served while the package is not; publication refused"
        end

        finish(opts[:plan], package, docs)

      _ ->
        raise "usage: hex_release_state.exs (--plan | --served) [--organization ORG] NAME VERSION PACKAGE_TAR DOCS_TAR"
    end
  end

  defp package_state(repo, name, version, tar) do
    case read(fn -> Hex.Repo.get_package(repo, name, nil) end) do
      {:ok, {200, _headers, %{releases: releases}}} when is_list(releases) ->
        releases |> Enum.find(&(&1.version == version)) |> release_state(name, version, tar)

      {:ok, {404, _headers, _body}} ->
        raise "#{repo} has no package #{name}; a first publication is the owner's decision"

      result ->
        refuse_read(result, "#{repo} package #{name}")
    end
  end

  defp release_state(nil, _name, _version, _tar), do: "upload"

  defp release_state(release, name, version, tar) do
    if Map.has_key?(release, :retired) do
      raise "#{name} #{version} is retired; publication refused"
    end

    unless release[:outer_checksum] == :crypto.hash(:sha256, tar) do
      raise "#{name} #{version}: registry outer checksum differs from package archive; publication refused"
    end

    "served"
  end

  defp docs_state(repo, name, version, tar) do
    case read(fn -> Hex.Repo.get_docs(repo, name, version) end) do
      {:ok, {200, _headers, ^tar}} ->
        "served"

      {:ok, {200, _headers, _body}} ->
        raise "#{name} #{version}: served docs differ from docs archive; publication refused"

      {:ok, {404, _headers, _body}} ->
        "upload"

      result ->
        refuse_read(result, "#{repo} docs #{name} #{version}")
    end
  end

  defp read(request) do
    request.()
  rescue
    _ -> :read_error
  catch
    _, _ -> :read_error
  end

  defp refuse_read({:ok, {code, _headers, _body}}, label) do
    raise "#{label}: registry answered HTTP #{code} or an invalid response; publication refused"
  end

  defp refuse_read(_result, label),
    do: raise("#{label}: registry read failed; publication refused")

  defp finish(true, package, docs) do
    output = "package=#{package}\ndocs=#{docs}\n"
    File.write!(System.fetch_env!("GITHUB_OUTPUT"), output, [:append])
    IO.write(output)
  end

  defp finish(nil, "served", "served"), do: IO.puts("package=served\ndocs=served")
  defp finish(nil, _package, _docs), do: raise(@pending)
end

HexReleaseState.main(System.argv())
