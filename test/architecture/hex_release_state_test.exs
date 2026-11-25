Code.require_file("../../scripts/hex_release_state.ex", __DIR__)

defmodule HexReleaseStateTest do
  use ExUnit.Case, async: true

  @package "release_fixture"
  @version "1.0.0"
  @unknown String.duplicate("a", 40)

  setup_all do
    clone = temporary_directory()
    git!(clone, ["init", "--initial-branch=main"])
    git!(clone, ["config", "maintenance.auto", "false"])
    git!(clone, ["config", "user.name", "Release test"])
    git!(clone, ["config", "user.email", "release-test@example.invalid"])
    git!(clone, ["commit", "--allow-empty", "-m", "ancestor"])
    ancestor = git!(clone, ["rev-parse", "HEAD"])
    git!(clone, ["commit", "--allow-empty", "-m", "dispatched"])
    dispatched = git!(clone, ["rev-parse", "HEAD"])
    git!(clone, ["checkout", "--orphan", "unrelated"])
    git!(clone, ["commit", "--allow-empty", "-m", "unrelated"])
    unrelated = git!(clone, ["rev-parse", "HEAD"])
    git!(clone, ["checkout", "main"])
    %{clone: clone, ancestor: ancestor, dispatched: dispatched, unrelated: unrelated}
  end

  setup do
    %{scratch: temporary_directory()}
  end

  test "plan needs no provenance options and remains presence-only" do
    assert {[plan: true], @package, @version, "package.tar"} =
             HexReleaseState.parse!(["--plan", @package, @version, "package.tar"])
  end

  test "public planning requires the release API to report explicit docs state" do
    checksum = String.duplicate("a", 64)
    release = %{"version" => @version, "checksum" => checksum, "retirement" => nil}

    assert HexReleaseState.docs_state!(
             [plan: true],
             {:ok, {404, %{}, nil}},
             "upload",
             @version,
             checksum
           ) ==
             "upload"

    for {has_docs, expected} <- [{false, "upload"}, {true, "served"}] do
      result = {:ok, {200, %{}, Map.put(release, "has_docs", has_docs)}}

      assert HexReleaseState.docs_state!([plan: true], result, "served", @version, checksum) ==
               expected
    end

    served = Map.put(release, "has_docs", false)

    for {result, package} <- [
          {{:ok, {404, %{}, nil}}, "served"},
          {{:ok, {200, %{}, release}}, "served"},
          {{:ok, {200, %{}, Map.put(served, "checksum", String.duplicate("b", 64))}}, "served"},
          {{:ok, {200, %{}, served}}, "upload"}
        ] do
      assert_raise RuntimeError, ~r/publication refused/, fn ->
        HexReleaseState.docs_state!([plan: true], result, package, @version, checksum)
      end
    end
  end

  test "private planning delegates docs state to the upload step" do
    script = File.read!(Path.expand("../../scripts/hex_release_state.ex", __DIR__))
    assert script =~ "docs = docs_state!(opts, release, package, version, checksum)"
    opts = [organization: "example", plan: true]

    assert script =~
             "release = if organization, do: :upload_step, else: read_public_release(name, version)"

    for package <- ["served", "upload"] do
      assert HexReleaseState.docs_state!(opts, :upload_step, package, @version, nil) == "check"

      assert_raise RuntimeError, ~r/held for approval or not yet served/, fn ->
        HexReleaseState.docs_state!(
          [organization: "example", served: true, docs_state: "staged"],
          :upload_step,
          package,
          @version,
          nil
        )
      end
    end

    opts = [organization: "example", served: true, docs_state: "served"]
    assert HexReleaseState.docs_state!(opts, :upload_step, "served", @version, nil) == "served"

    assert_raise RuntimeError, ~r/held for approval or not yet served/, fn ->
      HexReleaseState.docs_state!(opts, :upload_step, "upload", @version, nil)
    end
  end

  test "the private read-back CLI requires the upload result", context do
    args = served_args(context) ++ ["--organization", "example"]

    assert_raise RuntimeError, ~r/--docs-state/, fn ->
      HexReleaseState.parse!(args)
    end

    assert {opts, @package, @version, "package.tar"} =
             HexReleaseState.parse!(args ++ ["--docs-state", "served"])

    assert opts[:docs_state] == "served"
  end

  test "served requires a full commit, repository clone and output file", context do
    args = served_args(context)
    assert {opts, @package, @version, "package.tar"} = HexReleaseState.parse!(args)
    assert opts[:commit] == context.dispatched
    assert opts[:clone] == context.clone
    assert opts[:docs_output] == output_path(context)

    for option <- ["--commit", "--clone", "--docs-output"] do
      value = Enum.at(args, Enum.find_index(args, &(&1 == option)) + 1)
      missing = List.delete(args, option) |> List.delete(value)

      assert_raise RuntimeError, ~r/publication refused/, fn ->
        HexReleaseState.parse!(missing)
      end
    end
  end

  test "malformed or ambiguous served options are refused", context do
    args = served_args(context)

    for commit <- ["HEAD", String.upcase(context.dispatched), "abc", @unknown <> "\n"] do
      invalid = Enum.map(args, &if(&1 == context.dispatched, do: commit, else: &1))

      assert_raise RuntimeError, ~r/publication refused/, fn ->
        HexReleaseState.parse!(invalid)
      end
    end

    for {old, replacement} <- [
          {context.clone, ""},
          {context.clone, context.scratch},
          {output_path(context), context.scratch},
          {output_path(context), ""}
        ] do
      invalid = Enum.map(args, &if(&1 == old, do: replacement, else: &1))

      assert_raise RuntimeError, ~r/publication refused/, fn ->
        HexReleaseState.parse!(invalid)
      end
    end

    for invalid <- [
          args ++ ["--commit", context.dispatched],
          args ++ ["--plan"],
          ["--plan", "--commit", context.dispatched, @package, @version, "package.tar"]
        ] do
      assert_raise RuntimeError, ~r/publication refused/, fn ->
        HexReleaseState.parse!(invalid)
      end
    end
  end

  test "root entries with and without dot prefixes are readable", context do
    for prefix <- ["", "./", "././"] do
      archive =
        archive!(context, [
          {prefix <> "index.html", "<html>release</html>"},
          {prefix <> "release.json", record(context.dispatched)}
        ])

      assert HexReleaseState.inspect_docs!(archive, @package, @version) == context.dispatched
    end
  end

  test "unreadable archives and missing root files are refused", context do
    for archive <- ["not a gzip tar", :zlib.gzip("not a tar")] do
      assert_raise RuntimeError, ~r/readable gzip tar.*publication refused/, fn ->
        HexReleaseState.inspect_docs!(archive, @package, @version)
      end
    end

    for entries <- [
          [{"index.html", "html"}],
          [{"release.json", record(context.dispatched)}],
          [{"nested/index.html", "html"}, {"nested/release.json", record(context.dispatched)}]
        ] do
      archive = archive!(context, entries)

      assert_raise RuntimeError, ~r/no root.*publication refused/, fn ->
        HexReleaseState.inspect_docs!(archive, @package, @version)
      end
    end
  end

  test "ambiguous normalized root entries are refused", context do
    archive =
      archive!(context, [
        {"index.html", "html"},
        {"release.json", record(context.dispatched)},
        {"./release.json", record(context.ancestor)}
      ])

    assert_raise RuntimeError, ~r/ambiguous root release.json.*publication refused/, fn ->
      HexReleaseState.inspect_docs!(archive, @package, @version)
    end
  end

  test "release record must be readable JSON with exactly the expected members", context do
    valid = JSON.decode!(record(context.dispatched))

    for bytes <- [
          "{",
          "null",
          "[]",
          ~s|{"package":"wrong","package":"release_fixture","version":"1.0.0","commit":"#{context.dispatched}"}|,
          JSON.encode!(Map.put(valid, "package", "other_package")),
          JSON.encode!(Map.put(valid, "version", "2.0.0")),
          JSON.encode!(Map.put(valid, "extra", true)),
          JSON.encode!(Map.delete(valid, "commit"))
        ] do
      archive = archive!(context, [{"index.html", "html"}, {"release.json", bytes}])

      assert_raise RuntimeError, ~r/publication refused/, fn ->
        HexReleaseState.inspect_docs!(archive, @package, @version)
      end
    end
  end

  test "release record refuses malformed commit values", context do
    for commit <- [nil, 1, "HEAD", "abc", String.upcase(context.dispatched), @unknown <> "\n"] do
      archive = archive!(context, [{"index.html", "html"}, {"release.json", record(commit)}])

      assert_raise RuntimeError, ~r/40 lowercase.*publication refused/, fn ->
        HexReleaseState.inspect_docs!(archive, @package, @version)
      end
    end
  end

  test "the dispatched commit and its ancestor are accepted and replace built docs", context do
    for commit <- [context.dispatched, context.ancestor] do
      archive = archive!(context, [{"./index.html", "html"}, {"./release.json", record(commit)}])
      File.write!(output_path(context), "built docs")
      {opts, _, _, _} = HexReleaseState.parse!(served_args(context))
      assert HexReleaseState.readback_docs!(archive, @package, @version, opts) == commit
      assert File.read!(output_path(context)) == archive
    end
  end

  test "an unrelated commit is refused without replacing built docs", context do
    archive =
      archive!(context, [
        {"index.html", "html"},
        {"release.json", record(context.unrelated)}
      ])

    File.write!(output_path(context), "built docs")
    {opts, _, _, _} = HexReleaseState.parse!(served_args(context))

    assert_raise RuntimeError,
                 ~r/not the dispatched commit or its ancestor.*publication refused/,
                 fn ->
                   HexReleaseState.readback_docs!(archive, @package, @version, opts)
                 end

    assert File.read!(output_path(context)) == "built docs"
  end

  test "unknown commits have a distinct refusal, even when both names are equal", context do
    for {published, dispatched} <- [
          {@unknown, context.dispatched},
          {context.ancestor, @unknown},
          {@unknown, @unknown}
        ] do
      assert_raise RuntimeError, ~r/missing from the clone.*publication refused/, fn ->
        HexReleaseState.verify_ancestry!(published, dispatched, context.clone)
      end
    end
  end

  test "Git errors are refused distinctly from off-history commits", context do
    assert_raise RuntimeError,
                 ~r/git could not open the repository clone.*publication refused/,
                 fn ->
                   HexReleaseState.verify_ancestry!(
                     context.ancestor,
                     context.dispatched,
                     context.scratch
                   )
                 end
  end

  defp temporary_directory do
    path = Path.join(System.tmp_dir!(), "hex-release-#{System.unique_integer([:positive])}")
    File.mkdir!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp git!(clone, args) do
    {output, status} = System.cmd("git", ["-C", clone | args], stderr_to_stdout: true)
    assert status == 0, output
    String.trim(output)
  end

  defp output_path(context), do: Path.join(context.scratch, "served-docs.tar.gz")

  defp served_args(context) do
    [
      "--served",
      "--commit",
      context.dispatched,
      "--clone",
      context.clone,
      "--docs-output",
      output_path(context),
      @package,
      @version,
      "package.tar"
    ]
  end

  defp record(commit) do
    JSON.encode!(%{"package" => @package, "version" => @version, "commit" => commit})
  end

  defp archive!(context, entries) do
    path = Path.join(context.scratch, "fixture.tar.gz")
    entries = Enum.map(entries, fn {name, bytes} -> {String.to_charlist(name), bytes} end)
    :ok = :erl_tar.create(String.to_charlist(path), entries, [:compressed])
    File.read!(path)
  end
end
