# Load the module without running the standalone CLI entry point.
script = Path.expand("../../scripts/hex_upload.exs", __DIR__)
{:__block__, _, [module, _entrypoint]} = Code.string_to_quoted!(File.read!(script), file: script)
Code.eval_quoted(module, [], file: script)

defmodule HexUploadTest do
  use ExUnit.Case, async: true

  @name "release_fixture"
  @version "1.0.0"
  @checksum String.duplicate("a", 64)
  @docs_checksum String.duplicate("b", 64)
  @media "application/vnd.hex+erlang; charset=utf-8"

  # Fields consumed from Hexpm 5e638200's release view (lines 14–24):
  # https://github.com/hexpm/hexpm/blob/5e638200/lib/hexpm_web/views/api/release_view.ex#L14-L24
  @release %{
    "version" => @version,
    "checksum" => @checksum,
    "retirement" => nil,
    "has_docs" => false
  }

  # Fields consumed from the staged release view (lines 6–16):
  # https://github.com/hexpm/hexpm/blob/5e638200/lib/hexpm_web/views/api/staged_release_view.ex#L6-L16
  @stage %{
    "name" => @name,
    "version" => @version,
    "status" => "staged",
    "kind" => "release",
    "checksum" => @checksum,
    "url" => "https://hex.pm/api/packages/#{@name}/releases/#{@version}/staged"
  }

  test "private release reads require established access to the organization package" do
    # Both package and release reads require api:read and organization access.
    # https://github.com/hexpm/hexpm/blob/5e638200/lib/hexpm_web/controllers/api/package_controller.ex#L4-L7
    assert HexUpload.confirm_org_read!(response(200, %{"name" => @name}), @name) == :ok

    for result <- [response(404, nil), response(403, nil), response(200, %{"name" => "other"})] do
      assert_raise RuntimeError, ~r/read access; upload refused/, fn ->
        HexUpload.confirm_org_read!(result, @name)
      end
    end
  end

  test "the production docs upload uses the step order with release GET last before POST" do
    script = File.read!(Path.expand("../../scripts/hex_upload.exs", __DIR__))
    assert script =~ "run_docs!(docs_steps(target), state, requests)"

    assert HexUpload.docs_steps(:staged) == [
             :read_stage,
             :check_stage,
             :read_release,
             :check_release,
             :post_docs,
             :check_receipt
           ]

    assert HexUpload.docs_steps(:live) == [
             :read_release,
             :check_release,
             :post_docs,
             :check_receipt
           ]
  end

  test "a live upload stops before POST unless the package matches and docs are absent" do
    assert next_request(:live, %{read_release: response(200, @release)}) == :post_docs

    with_docs = Map.put(@release, "has_docs", true)
    assert next_request(:live, %{read_release: response(200, with_docs)}) == :skipped

    for result <- [
          response(404, nil),
          response(200, Map.put(@release, "checksum", @docs_checksum)),
          response(200, Map.delete(@release, "has_docs")),
          response(200, Map.put(@release, "retirement", %{"reason" => "other"})),
          response(200, Map.put(@release, "version", "2.0.0")),
          response(403, nil)
        ] do
      assert_raise RuntimeError, ~r/docs were not posted/, fn ->
        next_request(:live, %{read_release: result})
      end
    end
  end

  test "a matching stage may still exist after approval, so a live release stops the POST" do
    reads = %{read_stage: response(200, @stage), read_release: response(404, nil)}
    assert next_request(:staged, reads) == :post_docs

    assert_raise RuntimeError, ~r/already serves/, fn ->
      next_request(:staged, %{reads | read_release: response(200, @release)})
    end

    assert_raise RuntimeError, ~r/docs were not posted/, fn ->
      next_request(:staged, %{reads | read_release: response(403, nil)})
    end
  end

  test "an invalid stage stops before the release GET and the POST" do
    invalid =
      for {field, value} <- [
            {"name", "other_package"},
            {"version", "2.0.0"},
            {"status", "approved"},
            {"kind", "docs"},
            {"checksum", @docs_checksum}
          ],
          do: response(200, Map.put(@stage, field, value))

    for result <- [response(404, nil) | invalid] do
      assert_raise RuntimeError, ~r/active stage/, fn ->
        next_request(:staged, %{read_stage: result})
      end
    end
  end

  test "the docs POST uses Hex's httpc adapter without redirects" do
    script = File.read!(Path.expand("../../scripts/hex_upload.exs", __DIR__))
    assert script =~ "|> Map.put(:http_adapter, http_adapter())"
    assert script =~ "|> :mix_hex_http.request(:post"

    assert {:mix_hex_http_httpc, %{http_options: options}} = HexUpload.http_adapter()
    assert options[:autoredirect] == false

    for code <- [301, 302, 303, 307, 308] do
      assert_raise RuntimeError, ~r/docs upload refused \(HTTP #{code}\)/, fn ->
        receipt(:live, {:ok, {code, %{"location" => "https://hex.pm/api/elsewhere"}, ""}})
      end
    end
  end

  # Hexpm 5e638200 responds with a bare 201 and Location on the live branch,
  # and a rendered stage with Location on the staged branches.
  # https://github.com/hexpm/hexpm/blob/5e638200/lib/hexpm_web/controllers/api/docs_controller.ex#L86-L119
  # https://github.com/hexpm/hexpm/blob/5e638200/lib/hexpm/utils.ex#L387-L400
  test "a bare live receipt must name the exact tarball for the target repository" do
    public = "https://repo.hex.pm/docs/release_fixture-1.0.0.tar.gz"
    private = "https://repo.hex.pm/repos/example/docs/release_fixture-1.0.0.tar.gz"
    assert receipt(:live, {:ok, {201, %{"location" => public}, ""}}) == :accepted
    assert receipt(:live, {:ok, {201, %{"location" => private}, ""}}, "example") == :accepted

    for response <- [
          {200, %{"location" => public}, ""},
          {201, %{}, ""},
          {201, %{"location" => private}, ""},
          {201, %{"location" => public <> "?unexpected=1"}, ""},
          {201, %{"location" => public, "content-type" => "text/html"}, ""},
          {201, %{"location" => public}, "<html>"},
          {201, %{"location" => public}, nil}
        ] do
      assert_raise RuntimeError, fn -> receipt(:live, {:ok, response}) end
    end
  end

  test "a staged receipt must match the target, kind, checksum, location and Hex media type" do
    assert receipt(:staged, staged_receipt(@stage)) == :staged
    docs_stage = Map.merge(@stage, %{"kind" => "docs", "checksum" => @docs_checksum})
    assert receipt(:live, staged_receipt(docs_stage)) == :staged

    for {target, body} <- [
          {:live, @stage},
          {:staged, docs_stage},
          {:live, Map.put(docs_stage, "checksum", @checksum)},
          {:live, Map.put(docs_stage, "name", "other_package")},
          {:live, Map.put(docs_stage, "version", "2.0.0")},
          {:staged, Map.put(@stage, "status", "approved")}
        ] do
      assert_raise RuntimeError, ~r/unexpected docs upload receipt/, fn ->
        receipt(target, staged_receipt(body))
      end
    end

    {:ok, {201, headers, body}} = staged_receipt(docs_stage)

    for bad_headers <- [
          Map.put(headers, "content-type", "text/html"),
          Map.delete(headers, "content-type"),
          Map.put(headers, "location", headers["location"] <> "/unexpected")
        ] do
      assert_raise RuntimeError, ~r/unexpected docs upload receipt/, fn ->
        receipt(:live, {:ok, {201, bad_headers, body}})
      end
    end
  end

  defp next_request(target, responses) do
    follow(HexUpload.docs_steps(target), state(target), responses)
  end

  defp follow(steps, state, responses) do
    case HexUpload.next_docs_step!(steps, state) do
      {:request, :post_docs, _remaining} ->
        :post_docs

      {:request, read, remaining} ->
        follow(remaining, Map.put(state, :response, Map.fetch!(responses, read)), responses)

      result ->
        result
    end
  end

  defp receipt(target, response, repo \\ nil) do
    state = state(target) |> Map.merge(%{repo: repo, response: response})
    HexUpload.next_docs_step!([:check_receipt], state)
  end

  defp state(target) do
    %{
      target: target,
      name: @name,
      version: @version,
      checksum: @checksum,
      docs_checksum: @docs_checksum,
      api_url: "https://hex.pm/api",
      repo: nil,
      secrets: []
    }
  end

  defp staged_receipt(stage) do
    docs_path = if stage["kind"] == "docs", do: "/docs/staged", else: "/staged"
    url = "https://hex.pm/api/packages/#{@name}/releases/#{@version}" <> docs_path

    {:ok, {201, %{"content-type" => @media, "location" => url}, Map.put(stage, "url", url)}}
  end

  defp response(code, body), do: {:ok, {code, %{"content-type" => @media}, body}}
end
