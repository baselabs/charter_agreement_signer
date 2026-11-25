# Load the module without running the standalone CLI entry point.
script = Path.expand("../../scripts/hex_upload.exs", __DIR__)

{:__block__, _, [module, _entrypoint]} =
  Code.string_to_quoted!(File.read!(script), file: script)

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
    "approval_checksum" => @docs_checksum,
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
    assert HexUpload.docs_steps(:staged) == [
             :read_stage,
             :check_stage,
             :read_release,
             :check_release,
             :post_docs,
             :check_receipt
           ]

    assert HexUpload.docs_steps(:live) == [
             :read_stage,
             :check_stage,
             :read_docs_stage,
             :check_docs_stage,
             :read_release,
             :check_release,
             :post_docs,
             :check_receipt
           ]
  end

  test "the production dispatcher can invoke only the operation returned by the decision step" do
    interpreter =
      quote do
        case next_docs_step!(steps, state) do
          {:request, step, remaining} ->
            response = Map.fetch!(requests, step).()
            run_docs!(remaining, Map.put(state, :response, response), requests)

          result ->
            result
        end
      end

    assert normalize(body(:run_docs!)) == normalize(interpreter)

    assert {:__block__, _, operations} = normalize(body(:upload_docs!))

    setup =
      quote do
        requests = %{
          read_stage: fn -> read_stage(state, "release", publish_auth) end,
          read_docs_stage: fn -> read_stage(state, "docs", publish_auth) end,
          read_release: fn -> read_release(repo, name, version, read_auth) end,
          post_docs: fn -> post_docs(state, docs, publish_auth) end
        }

        state = Map.merge(state, %{target: target, package_receipt: package_result})
        run_docs!(docs_steps(target), state, requests)
      end

    assert {:__block__, _, expected} = normalize(setup)
    assert Enum.take(operations, -3) == expected

    {_, calls} =
      Macro.prewalk(operations, [], fn
        {:post_docs, _, args} = node, calls when is_list(args) -> {node, [node | calls]}
        node, calls -> {node, calls}
      end)

    assert length(calls) == 1
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

  test "the upload paths call Hex's own clients" do
    assert has_ast?(
             body(:upload_package!),
             quote(
               do:
                 Release.publish(state.repo, package, publish_auth, fn _ -> :ok end,
                   replace: false
                 )
             )
           )

    assert has_ast?(
             body(:post_docs),
             quote(do: ReleaseDocs.publish(state.repo, state.name, state.version, docs, auth))
           )
  end

  # Hexpm 5e638200 responds with a bare 201 and Location on the live branch,
  # and a rendered stage with Location on the staged branches.
  # https://github.com/hexpm/hexpm/blob/5e638200/lib/hexpm_web/controllers/api/docs_controller.ex#L86-L119
  # https://github.com/hexpm/hexpm/blob/5e638200/lib/hexpm/utils.ex#L387-L400
  test "a bare live receipt must name the exact tarball for the target repository" do
    public = "https://repo.hex.pm/docs/release_fixture-1.0.0.tar.gz"
    private = "https://repo.hex.pm/repos/example/docs/release_fixture-1.0.0.tar.gz"
    assert receipt(:live, {:ok, {201, %{"location" => public}, nil}}) == :accepted
    assert receipt(:live, {:ok, {201, %{"location" => private}, nil}}, "example") == :accepted

    assert receipt(
             :live,
             {:ok, {201, %{"location" => public, "content-type" => "text/html"}, nil}}
           ) ==
             :accepted

    for response <- [
          {200, %{"location" => public}, nil},
          {201, %{}, ""},
          {201, %{"location" => private}, nil},
          {201, %{"location" => public <> "?unexpected=1"}, nil},
          {201, %{"location" => public}, "<html>"}
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

  test "the package preflight skips only an exact served archive" do
    assert HexUpload.package_preflight!(:missing, response(404, nil), state(:live)) == :upload
    assert HexUpload.package_preflight!(:missing, response(200, @release), state(:live)) == :skip

    assert_raise RuntimeError, ~r/other package bytes/, fn ->
      other = response(200, Map.put(@release, "checksum", @docs_checksum))
      HexUpload.package_preflight!(:missing, other, state(:live))
    end
  end

  test "only lost package responses and explicit conflicts can reconcile" do
    state = state(:live)

    replace_refusal = %{
      "inserted_at" => "must include the --replace flag to update an existing release"
    }

    duplicate = %{"version" => "has already been published"}

    for failure <- [
          {:error, :timeout},
          {:error, :socket_closed_remotely},
          response(409, nil),
          response(422, %{"errors" => replace_refusal}),
          response(422, %{"errors" => duplicate})
        ] do
      assert HexUpload.package_receipt!(failure, state) == :reconcile
      assert HexUpload.reconcile_package!(failure, response(200, @release), state) == :live

      assert_raise RuntimeError, ~r/other package bytes/, fn ->
        other = response(200, Map.put(@release, "checksum", @docs_checksum))
        HexUpload.reconcile_package!(failure, other, state)
      end
    end

    assert_raise RuntimeError, ~r/package upload refused \(HTTP 409\)/, fn ->
      HexUpload.reconcile_package!(response(409, nil), response(404, nil), state)
    end

    assert_raise RuntimeError, ~r/package upload failed/, fn ->
      HexUpload.reconcile_package!({:error, :timeout}, response(404, nil), state)
    end

    for failure <- [
          :upload_error,
          {:error, :bad_term},
          response(403, nil),
          response(422, %{"errors" => %{"version" => "invalid"}}),
          response(500, nil)
        ] do
      assert_raise RuntimeError, ~r/package upload (failed|refused)/, fn ->
        HexUpload.package_receipt!(failure, state)
      end
    end
  end

  test "private docs output must already be writable before the upload can start" do
    path = Path.join(System.tmp_dir!(), "hex-upload-output-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm(path) end)

    for unavailable <- [nil, "", path, System.tmp_dir!()] do
      assert_raise RuntimeError, ~r/writable GITHUB_OUTPUT/, fn ->
        HexUpload.with_docs_output!(unavailable, fn _ -> flunk("upload started") end)
      end
    end

    File.write!(path, "existing=value\n")
    assert :ok = HexUpload.with_docs_output!(path, &IO.binwrite(&1, "docs=served\n"))
    assert File.read!(path) == "existing=value\ndocs=served\n"
  end

  test "existing pending stages and their docs are kept" do
    assert {:__block__, _, operations} = normalize(body(:upload_package!))

    expected =
      quote do
        stage = read_stage(state, "release", publish_auth) |> pending_stage!("release", state)
        release = read_release(state.repo, state.name, state.version, read_auth)
      end

    assert {:__block__, _, reads} = normalize(expected)
    assert Enum.take(operations, 2) == reads

    live = state(:live)
    stage = HexUpload.pending_stage!(response(200, @stage), "release", live)
    assert stage == :pending
    assert HexUpload.package_preflight!(stage, response(404, nil), live) == :pending
    assert next_request(:live, %{read_stage: response(200, @stage)}) == :staged

    changed = Map.put(@stage, "approval_checksum", @checksum)
    assert next_request(:staged, %{read_stage: response(200, changed)}) == :staged

    {:ok, {201, _, stage}} =
      staged_receipt(Map.merge(@stage, %{"kind" => "docs", "checksum" => @docs_checksum}))

    assert next_request(:live, %{read_docs_stage: response(200, stage)}) == :staged

    different = response(200, Map.put(@stage, "checksum", @docs_checksum))

    assert_raise RuntimeError, ~r/active stage/, fn ->
      HexUpload.pending_stage!(different, "release", live)
    end
  end

  test "package receipts require the exact created release or stage" do
    path = "/api/packages/#{@name}/releases/#{@version}"
    release = Map.put(@release, "url", "https://hex.pm" <> path)
    headers = %{"content-type" => @media, "location" => path}
    state = state(:live)

    assert HexUpload.package_receipt!({:ok, {201, headers, release}}, state) == {:ok, :live}
    assert HexUpload.package_receipt!(staged_receipt(@stage), state) == {:ok, {:staged, @stage}}
  end

  test "malformed package success stops before reconciliation or docs upload" do
    path = "/api/packages/#{@name}/releases/#{@version}"
    release = Map.put(@release, "url", "https://hex.pm" <> path)
    headers = %{"content-type" => @media, "location" => path}
    state = state(:live)

    for {code, headers, body} <- [
          {200, headers, release},
          {201, Map.delete(headers, "location"), release},
          {201, headers, nil},
          {201, headers, Map.put(release, "checksum", @docs_checksum)},
          {201, headers, Map.put(release, "url", "https://hex.pm/api/other")},
          {201, Map.put(headers, "location", path <> "/other"), release},
          {201, Map.put(headers, "content-type", "text/html"), release}
        ] do
      assert_raise RuntimeError, ~r/invalid package upload receipt/, fn ->
        HexUpload.package_receipt!({:ok, {code, headers, body}}, state)
      end
    end

    assert has_ast?(
             body(:upload_package!),
             quote do
               case package_receipt!(response, state) do
                 {:ok, result} ->
                   result

                 :reconcile ->
                   release = read_release(state.repo, state.name, state.version, read_auth)
                   reconcile_package!(response, release, state)
               end
             end
           )
  end

  defp body(name) do
    script = Path.expand("../../scripts/hex_upload.exs", __DIR__)

    {:__block__, _, [{:defmodule, _, [_, [do: {:__block__, _, forms}]]}, _]} =
      Code.string_to_quoted!(File.read!(script), file: script)

    Enum.find_value(Enum.reverse(forms), fn
      {:defp, _, [{^name, _, _}, [do: body]]} -> body
      _ -> nil
    end)
  end

  defp has_ast?(ast, target) do
    target = normalize(target)

    {_, found} =
      Macro.prewalk(normalize(ast), false, fn node, found -> {node, found or node == target} end)

    found
  end

  defp normalize(ast) do
    Macro.prewalk(ast, fn
      {name, meta, context} when is_atom(name) and is_list(meta) and is_atom(context) ->
        {name, [], nil}

      {name, meta, args} when is_list(meta) and is_list(args) ->
        {name, [], args}

      node ->
        node
    end)
  end

  defp next_request(target, responses) do
    reads =
      Map.merge(%{read_stage: response(404, nil), read_docs_stage: response(404, nil)}, responses)

    follow(HexUpload.docs_steps(target), state(target), reads)
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
      package_receipt: {:staged, @stage},
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
