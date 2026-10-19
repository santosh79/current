defmodule Current.HTTP.RouterTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Current.HTTP.{Encode, Router}

  defp call(method, path, body \\ nil) do
    conn = conn(method, path, body && JSON.encode!(body))
    conn = if body, do: put_req_header(conn, "content-type", "application/json"), else: conn
    Router.call(conn, Router.init([]))
  end

  defp decoded(conn), do: JSON.decode!(conn.resp_body)

  describe "access" do
    test "requests are accepted without credentials" do
      assert call(:get, "/v1/health").status == 200
    end
  end

  describe "routes" do
    test "health mirrors API.status" do
      body = call(:get, "/v1/health") |> decoded()
      assert body["status"] == "ready"
      assert is_integer(body["wal_head"])
    end

    test "models" do
      assert %{"models" => models} = call(:get, "/v1/models") |> decoded()
      assert is_list(models)
    end

    test "unknown route is 404" do
      assert call(:get, "/v1/nope").status == 404
    end

    test "unknown workflow is 404" do
      conn = call(:get, "/v1/workflows/abcdef")
      assert conn.status == 404
      assert decoded(conn)["error"]["code"] == "not_found"
    end

    test "too-short prefix is 400" do
      assert call(:get, "/v1/proposals/ab").status == 400
    end
  end

  describe "POST /v1/tasks" do
    test "rejects a missing prompt" do
      conn = call(:post, "/v1/tasks", %{"model" => "x:y", "dir" => "/tmp"})
      assert conn.status == 400
    end

    test "rejects a bad mode" do
      conn =
        call(:post, "/v1/tasks", %{
          "prompt" => "p",
          "model" => "x:y",
          "dir" => "/tmp",
          "mode" => "yolo"
        })

      assert conn.status == 400
    end

    test "an unknown model is 422" do
      conn =
        call(:post, "/v1/tasks", %{"prompt" => "p", "model" => "nope:nope", "dir" => "/tmp"})

      assert conn.status == 422
      assert decoded(conn)["error"]["code"] == "unknown_model"
    end
  end

  describe "Encode" do
    test "structs carry their type, atoms become strings, tuples become lists" do
      intent = %Current.Intent.ReadFile{id: "i", proposal_id: "p", path: "/a"}

      assert Encode.to_json({intent, :ok}) == [
               %{"id" => "i", "proposal_id" => "p", "path" => "/a", "type" => "ReadFile"},
               "ok"
             ]
    end

    test "datetimes are ISO 8601, nil and booleans are kept" do
      {:ok, dt, _} = DateTime.from_iso8601("2026-10-15T12:00:00Z")

      assert Encode.to_json(%{at: dt, a: nil, b: true}) == %{
               "at" => "2026-10-15T12:00:00Z",
               "a" => nil,
               "b" => true
             }
    end

    test "non-UTF-8 binaries fall back to inspect" do
      assert Encode.to_json(<<255, 254>>) == "<<255, 254>>"
    end
  end
end
