# Load the module without running the standalone CLI entry point.
script = Path.expand("../../scripts/hex_upload.exs", __DIR__)
{:__block__, _, [module, _entrypoint]} = Code.string_to_quoted!(File.read!(script), file: script)
Code.eval_quoted(module, [], file: script)

defmodule HexUploadTest do
  use ExUnit.Case, async: true

  @name "release_fixture"
  @version "1.0.0"
  @checksum String.duplicate("a", 64)
  @other_checksum String.duplicate("b", 64)
  @release %{
    "version" => @version,
    "checksum" => @checksum,
    "retirement" => nil,
    "has_docs" => false
  }
  @stage %{
    "name" => @name,
    "version" => @version,
    "status" => "staged",
    "kind" => "release",
    "checksum" => @checksum
  }

  test "a live docs upload requires the served archive checksum and explicit docs absence" do
    assert HexUpload.live_docs!(response(200, @release), @version, @checksum) == :upload

    with_docs = Map.put(@release, "has_docs", true)
    assert HexUpload.live_docs!(response(200, with_docs), @version, @checksum) == :skip

    changed = Map.put(@release, "checksum", @other_checksum)

    assert_raise RuntimeError, ~r/other package bytes/, fn ->
      HexUpload.live_docs!(response(200, changed), @version, @checksum)
    end

    for result <- [
          response(404, nil),
          response(200, Map.delete(@release, "has_docs")),
          response(200, Map.put(@release, "retirement", %{})),
          response(200, Map.put(@release, "version", "2.0.0")),
          response(403, nil)
        ] do
      assert_raise RuntimeError, fn -> HexUpload.live_docs!(result, @version, @checksum) end
    end
  end

  test "the staged docs path refuses a release approved since the package upload" do
    assert HexUpload.unpublished!(response(404, nil), @version, @checksum) == :ok

    assert_raise RuntimeError, ~r/already serves/, fn ->
      HexUpload.unpublished!(response(200, @release), @version, @checksum)
    end
  end

  test "the active stage must identify this release and this package archive" do
    assert HexUpload.confirm_stage!(response(200, @stage), @name, @version, @checksum) == :ok

    for {field, value} <- [
          {"name", "other_package"},
          {"version", "2.0.0"},
          {"status", "approved"},
          {"kind", "docs"},
          {"checksum", @other_checksum}
        ] do
      assert_raise RuntimeError, ~r/active stage/, fn ->
        HexUpload.confirm_stage!(
          response(200, Map.put(@stage, field, value)),
          @name,
          @version,
          @checksum
        )
      end
    end

    assert_raise RuntimeError, ~r/active stage/, fn ->
      HexUpload.confirm_stage!(response(404, nil), @name, @version, @checksum)
    end
  end

  test "a successful POST must prove docs joined this package's release stage" do
    assert HexUpload.staged_docs_receipt!({201, %{}, @stage}, @checksum) == :staged

    invalid = [
      nil,
      Map.put(@stage, "status", "approved"),
      Map.put(@stage, "kind", "docs"),
      Map.put(@stage, "checksum", @other_checksum)
    ]

    for body <- invalid do
      assert_raise RuntimeError, ~r/did not attach docs/, fn ->
        HexUpload.staged_docs_receipt!({201, %{}, body}, @checksum)
      end
    end
  end

  test "a live target returns a publish receipt or a stage for these docs alone" do
    assert HexUpload.live_docs_receipt!(
             {201, %{"location" => "https://repo.hex.pm/docs/archive"}, nil},
             @other_checksum
           ) ==
             :accepted

    docs_stage = Map.merge(@stage, %{"kind" => "docs", "checksum" => @other_checksum})
    assert HexUpload.live_docs_receipt!({201, %{}, docs_stage}, @other_checksum) == :staged

    for receipt <- [
          {200, %{}, nil},
          {201, %{}, nil},
          {201, %{}, @stage},
          {201, %{}, Map.put(docs_stage, "checksum", @checksum)}
        ] do
      assert_raise RuntimeError, ~r/docs upload receipt/, fn ->
        HexUpload.live_docs_receipt!(receipt, @other_checksum)
      end
    end
  end

  defp response(code, body), do: {:ok, {code, %{}, body}}
end
