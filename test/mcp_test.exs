defmodule Current.MCPTest do
  @moduledoc "Protocol-level tests of `Current.MCP.handle/1`: no HTTP, no workflow."
  use ExUnit.Case, async: true

  alias Current.MCP

  @version "2025-06-18"

  defp rpc(method, params \\ %{}, id \\ 1),
    do: %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}

  defp reply!(message) do
    assert {:reply, reply} = MCP.handle(message)
    reply
  end

  defp tool(name, arguments),
    do: reply!(rpc("tools/call", %{"name" => name, "arguments" => arguments}))

  describe "initialize" do
    test "answers with the one protocol version it implements" do
      assert MCP.protocol_version() == @version
      reply = reply!(rpc("initialize", %{"protocolVersion" => @version}))
      assert reply.result.protocolVersion == @version
      assert reply.result.capabilities == %{tools: %{listChanged: false}}
      assert reply.result.serverInfo.name == "current"
    end

    test "a client asking for another version is told which one this server speaks" do
      for asked <- ["2024-11-05", "2025-03-26", "2026-07-28", "1999-01-01"] do
        reply = reply!(rpc("initialize", %{"protocolVersion" => asked}))
        assert reply.result.protocolVersion == @version
      end
    end

    test "needs a protocolVersion string" do
      assert %{error: %{code: -32602}} = reply!(rpc("initialize", %{}))
      assert %{error: %{code: -32602}} = reply!(rpc("initialize", %{"protocolVersion" => 20}))
    end
  end

  describe "JSON-RPC validation" do
    test "notifications and client responses are accepted without a body" do
      assert MCP.handle(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"}) ==
               :accepted

      assert MCP.handle(%{"jsonrpc" => "2.0", "id" => 7, "result" => %{}}) == :accepted

      assert MCP.handle(%{"jsonrpc" => "2.0", "id" => "x", "error" => %{"code" => 1}}) ==
               :accepted
    end

    test "a request method without an id is invalid, not a silent notification" do
      assert {:invalid, %{error: %{code: -32600, message: message}}} =
               MCP.handle(%{"jsonrpc" => "2.0", "method" => "tools/call", "params" => %{}})

      assert message =~ "needs an id"
    end

    test "ids must be strings or integers" do
      for bad <- [nil, 1.5, true, %{"a" => 1}, [1]] do
        assert {:invalid, %{error: %{code: -32600}}} =
                 MCP.handle(%{"jsonrpc" => "2.0", "id" => bad, "method" => "ping"})
      end

      assert {:reply, %{id: "abc"}} = MCP.handle(rpc("ping", %{}, "abc"))
      assert {:reply, %{id: 0}} = MCP.handle(rpc("ping", %{}, 0))
    end

    test "params, when present, must be an object" do
      for bad <- [[], [1, 2], "x", 5, true, nil] do
        assert {:reply, %{error: %{code: -32602}}} =
                 MCP.handle(%{
                   "jsonrpc" => "2.0",
                   "id" => 1,
                   "method" => "initialize",
                   "params" => bad
                 })
      end

      # Absent params are fine.
      assert {:reply, %{result: %{}}} =
               MCP.handle(%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})
    end

    test "a notification with bad params is invalid, not silently dropped" do
      assert {:invalid, %{error: %{code: -32600}}} =
               MCP.handle(%{"jsonrpc" => "2.0", "method" => "notifications/x", "params" => [1]})
    end

    test "not an object, wrong version tag, no method, bad method are invalid requests" do
      for bad <- [
            [],
            [%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"}],
            "ping",
            5,
            nil,
            %{},
            %{"hello" => "world"},
            %{"jsonrpc" => "1.0", "id" => 1, "method" => "ping"},
            %{"jsonrpc" => "2.0", "id" => 1},
            %{"jsonrpc" => "2.0", "id" => 1, "method" => 7},
            %{"jsonrpc" => "2.0", "id" => 1, "result" => 1, "error" => %{}},
            %{"jsonrpc" => "2.0", "id" => nil, "result" => 1}
          ] do
        assert {:invalid, %{jsonrpc: "2.0", id: nil, error: %{code: -32600}}} = MCP.handle(bad),
               "expected #{inspect(bad)} to be an invalid request"
      end
    end

    test "unknown method and unknown tool are protocol errors" do
      assert %{error: %{code: -32601}} = reply!(rpc("nope"))
      assert %{error: %{code: -32601}} = reply!(rpc("server/discover"))
      assert %{error: %{code: -32602}} = reply!(rpc("tools/call", %{"name" => "nope"}))
      assert %{error: %{code: -32602}} = reply!(rpc("tools/call", %{}))

      assert %{error: %{code: -32602}} =
               reply!(rpc("tools/call", %{"name" => "health", "arguments" => [1]}))
    end
  end

  describe "tools" do
    test "tools/list names every tool with an object schema" do
      %{result: %{tools: tools}} = reply!(rpc("tools/list"))
      names = Enum.map(tools, & &1.name)

      for expected <- ~w(submit_task get_workflow get_proposal review_proposal get_artifact
                         approve_proposal reject_proposal request_revision apply_proposal
                         list_models health) do
        assert expected in names
      end

      assert Enum.all?(tools, &(&1.inputSchema.type == "object"))
      assert length(names) == length(Enum.uniq(names))
    end

    test "review_proposal advertises the runtime's max_lines bound" do
      %{result: %{tools: tools}} = reply!(rpc("tools/list"))
      review = Enum.find(tools, &(&1.name == "review_proposal"))

      assert review.inputSchema.properties.max_lines.maximum ==
               Current.Inspector.max_review_lines()
    end

    test "bad arguments are tool errors, not protocol errors" do
      reply = tool("review_proposal", %{})
      assert reply.result.isError == true
      assert [%{type: "text", text: text}] = reply.result.content
      assert text =~ "invalid_arguments"
    end

    test "non-string optional arguments are refused rather than dropped" do
      reply = tool("approve_proposal", %{"id" => "deadbeef", "message" => 5})
      assert reply.result.isError == true
      assert [%{text: "invalid_arguments: message must be a string"}] = reply.result.content
    end

    test "an id nothing matches comes back as a not_found tool error" do
      reply = tool("get_workflow", %{"id" => "deadbeef"})
      assert reply.result.isError == true
      assert [%{text: "not_found" <> _}] = reply.result.content
    end

    test "max_lines outside the runtime's range is a tool error, whatever the proposal" do
      for bad <- [0, -1, Current.Inspector.max_review_lines() + 1, 10_000_000_000_000] do
        reply = tool("review_proposal", %{"id" => "deadbeef", "max_lines" => bad})
        assert reply.result.isError == true
        assert [%{text: text}] = reply.result.content
        # Rejected on the range, before the (nonexistent) proposal is looked up.
        assert text =~ "bad_request", "max_lines #{bad}: #{text}"
      end
    end

    test "health returns the runtime's status as JSON text" do
      reply = tool("health", %{})
      assert reply.result.isError == false
      assert [%{text: text}] = reply.result.content
      assert %{"status" => "ready"} = JSON.decode!(text)
    end
  end
end
