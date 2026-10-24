defmodule Current.MCPIntegrationTest do
  @moduledoc """
  `POST /mcp` end to end: the real router, the real `Current.MCP`, the real
  runtime (with the fake proposal builder from config/test.exs).

  Where it matters the proof is the WAL, not the response: a refused
  request must leave nothing committed.

  Not async: it reads the shared WAL and workflow projections, and sets
  tight input limits for its own duration only.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias Current.HTTP.Router

  @limits [prompt: 256, feedback: 128, message: 64, reviewed_by: 32, model: 256, dir: 4_096]

  setup do
    previous = Application.get_env(:current, :input_limits)
    Application.put_env(:current, :input_limits, @limits)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:current, :input_limits)
        value -> Application.put_env(:current, :input_limits, value)
      end
    end)

    :ok
  end

  ## Helpers

  # `body` is encoded as JSON, whatever it is; `{:raw, string}` sends the
  # string as it is, for bodies that aren't JSON.
  defp post(body, headers \\ [{"content-type", "application/json"}]) do
    payload =
      case body do
        {:raw, string} -> string
        other -> JSON.encode!(other)
      end

    conn =
      Enum.reduce(headers, conn(:post, "/mcp", payload), fn {k, v}, c ->
        put_req_header(c, k, v)
      end)

    Router.call(conn, Router.init([]))
  end

  defp rpc(method, params \\ %{}, id \\ 1),
    do: %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}

  # Returns {is_error?, text} of a tools/call.
  defp call_tool(name, arguments) do
    conn = post(rpc("tools/call", %{"name" => name, "arguments" => arguments}))
    assert conn.status == 200, "#{name}: HTTP #{conn.status}: #{conn.resp_body}"

    assert %{"result" => %{"isError" => error?, "content" => [%{"text" => text}]}} =
             JSON.decode!(conn.resp_body)

    {error?, text}
  end

  defp tool!(name, arguments) do
    assert {false, text} = call_tool(name, arguments)
    JSON.decode!(text)
  end

  defp a_model do
    Enum.find_value(1..100, fn _ ->
      case Current.API.models() do
        [model | _] -> model
        [] -> Process.sleep(50) && nil
      end
    end) || flunk("the model catalog stayed empty; check the test catalog clients")
  end

  # Unique per call, so a test finds exactly its own events in the WAL.
  defp unique_prompt(label), do: "mcp-it #{label} #{System.unique_integer([:positive])}"

  defp submit!(prompt) do
    tool!("submit_task", %{"prompt" => prompt, "model" => a_model(), "dir" => System.tmp_dir!()})[
      "task_id"
    ]
  end

  defp wal_events, do: Current.Consensus.Log.complete_log() |> Enum.flat_map(& &1.events)

  defp task_created?(prompt),
    do:
      Enum.any?(wal_events(), &(match?(%Current.Event.TaskCreated{}, &1) and &1.input == prompt))

  defp revision_requested?(workflow_id, feedback) do
    Enum.any?(wal_events(), fn
      %Current.Event.ProposalRevisionRequested{workflow_id: ^workflow_id, feedback: ^feedback} ->
        true

      _ ->
        false
    end)
  end

  defp poll(attempts \\ 100, fun) do
    case fun.() do
      {:ok, value} ->
        value

      :retry when attempts > 0 ->
        Process.sleep(50)
        poll(attempts - 1, fun)

      other ->
        flunk("condition never held (last: #{inspect(other)})")
    end
  end

  # The workflow is created asynchronously once TaskCreated commits, so
  # right after submit the task id may not resolve yet: not_found means
  # "not yet", anything else that fails is a real failure.
  defp workflow_view(task_id) do
    case call_tool("get_workflow", %{"id" => task_id}) do
      {false, text} -> JSON.decode!(text)
      {true, "not_found" <> _} -> :not_yet
      {true, text} -> flunk("get_workflow failed: #{text}")
    end
  end

  # Waits, through the MCP tool itself, for a status; returns the view.
  defp await_status(task_id, status) do
    poll(fn ->
      case workflow_view(task_id) do
        %{"status" => ^status} = view -> {:ok, view}
        _ -> :retry
      end
    end)
  end

  defp await_terminal(task_id) do
    poll(fn ->
      case workflow_view(task_id) do
        %{"terminal" => true} = view -> {:ok, view}
        _ -> :retry
      end
    end)
  end

  # An :apply workflow parked at waiting_for_approval, via MCP. Returns
  # {task_id, workflow, proposal}.
  defp waiting do
    task_id = submit!(unique_prompt("waiting"))
    await_status(task_id, "waiting_for_approval")
    {:ok, workflow} = Current.WorkflowStore.get_by_task_id(task_id)
    {task_id, workflow, Current.Workflow.current_proposal(workflow)}
  end

  ## The whole path

  describe "the full path through MCP" do
    test "submit -> workflow -> review -> approve -> apply" do
      {task_id, workflow, proposal} = waiting()

      assert {false, review} =
               call_tool("review_proposal", %{"id" => proposal.id, "max_lines" => 5})

      assert review =~ "current.review/v1"

      assert %{"workflow_id" => workflow_id} =
               tool!("approve_proposal", %{
                 "id" => proposal.id,
                 "message" => "ok",
                 "reviewed_by" => "tester"
               })

      assert workflow_id == workflow.id

      # approve returns once the approval is visible, so apply may follow at once.
      assert %{"status" => "approved"} = tool!("get_workflow", %{"id" => task_id})

      # Recorded as the MCP client's decision, with only the fields it may set.
      assert Enum.any?(wal_events(), fn
               %Current.Event.ProposalApproved{proposal_id: id, metadata: md} ->
                 id == proposal.id and md.via == :mcp and md.reviewed_by == "tester" and
                   md.message == "ok" and
                   Map.keys(md) |> Enum.sort() == [:message, :reviewed_by, :via]

               _ ->
                 false
             end)

      assert %{"workflow_id" => ^workflow_id} = tool!("apply_proposal", %{"id" => proposal.id})
      assert %{"terminal" => true} = await_terminal(task_id)
    end

    test "apply before approval is refused and the workflow keeps waiting" do
      {task_id, workflow, proposal} = waiting()

      assert {true, text} = call_tool("apply_proposal", %{"id" => proposal.id})
      assert is_binary(text) and text != ""

      assert %{"status" => "waiting_for_approval"} = tool!("get_workflow", %{"id" => task_id})
      assert {:ok, %{status: :waiting_for_approval}} = Current.WorkflowStore.get(workflow.id)
    end

    test "a superseded proposal can be neither approved nor applied" do
      {task_id, workflow, old} = waiting()

      assert %{"workflow_id" => _} =
               tool!("request_revision", %{
                 "id" => old.id,
                 "feedback" => "try again",
                 "reviewed_by" => "t"
               })

      # Wait for the replacement.
      new =
        poll(fn ->
          with {:ok, %{status: :waiting_for_approval} = wf} <-
                 Current.WorkflowStore.get(workflow.id),
               %{id: id} = current when id != old.id <- Current.Workflow.current_proposal(wf) do
            {:ok, current}
          else
            _ -> :retry
          end
        end)

      assert {true, approve_text} = call_tool("approve_proposal", %{"id" => old.id})
      assert approve_text =~ "stale_proposal"

      assert {true, _} = call_tool("apply_proposal", %{"id" => old.id})

      # The latest one is still reviewable.
      assert %{"status" => "waiting_for_approval"} = tool!("get_workflow", %{"id" => task_id})
      assert {false, _} = call_tool("review_proposal", %{"id" => new.id})
    end
  end

  ## Limits, with proof from the WAL

  describe "input limits through MCP" do
    test "an oversized prompt is refused and never committed" do
      prompt = String.duplicate("p", @limits[:prompt] + 1)

      assert {true, text} =
               call_tool("submit_task", %{
                 "prompt" => prompt,
                 "model" => a_model(),
                 "dir" => System.tmp_dir!()
               })

      assert text =~ "too_large"
      refute task_created?(prompt)
    end

    test "oversized feedback is refused, no revision event is committed, the workflow keeps waiting" do
      {task_id, workflow, proposal} = waiting()
      feedback = String.duplicate("f", @limits[:feedback] + 1)

      assert {true, text} =
               call_tool("request_revision", %{"id" => proposal.id, "feedback" => feedback})

      assert text =~ "too_large"

      refute revision_requested?(workflow.id, feedback)
      assert %{"status" => "waiting_for_approval"} = tool!("get_workflow", %{"id" => task_id})
    end

    test "an oversized approval message or reviewer is refused" do
      {_task_id, workflow, proposal} = waiting()

      assert {true, text} =
               call_tool("approve_proposal", %{
                 "id" => proposal.id,
                 "message" => String.duplicate("m", 65)
               })

      assert text =~ "too_large"

      assert {true, text} =
               call_tool("reject_proposal", %{
                 "id" => proposal.id,
                 "reviewed_by" => String.duplicate("r", 33)
               })

      assert text =~ "too_large"
      assert {:ok, %{status: :waiting_for_approval}} = Current.WorkflowStore.get(workflow.id)
    end

    test "unknown arguments are never copied into the recorded decision" do
      {_task_id, _workflow, proposal} = waiting()

      tool!("approve_proposal", %{
        "id" => proposal.id,
        "message" => "ok",
        "feedback" => String.duplicate("x", 100_000),
        "smuggled" => String.duplicate("y", 100_000)
      })

      assert Enum.any?(wal_events(), fn
               %Current.Event.ProposalApproved{proposal_id: id, metadata: md} ->
                 id == proposal.id and
                   Map.keys(md) |> Enum.sort() == [:message, :reviewed_by, :via]

               _ ->
                 false
             end)
    end

    test "a huge max_lines is refused by the runtime, over MCP and over plain HTTP" do
      {_task_id, _workflow, proposal} = waiting()
      max = Current.Inspector.max_review_lines()

      for bad <- [max + 1, 1_000_000_000, 0, -5] do
        assert {true, text} =
                 call_tool("review_proposal", %{"id" => proposal.id, "max_lines" => bad})

        assert text =~ "bad_request"
      end

      assert {false, _} = call_tool("review_proposal", %{"id" => proposal.id, "max_lines" => max})

      for bad <- ["#{max + 1}", "1000000000", "0", "-5"] do
        conn =
          Router.call(
            conn(:get, "/v1/proposals/#{proposal.id}/review?max_lines=#{bad}"),
            Router.init([])
          )

        assert conn.status == 400, "max_lines=#{bad}: #{conn.status}"
        assert %{"error" => %{"code" => "bad_request"}} = JSON.decode!(conn.resp_body)
      end
    end
  end

  ## Transport

  describe "Origin" do
    test "a foreign origin is refused with 403 before anything is read, and commits nothing" do
      prompt = unique_prompt("evil-origin")

      conn =
        post(
          rpc("tools/call", %{
            "name" => "submit_task",
            "arguments" => %{"prompt" => prompt, "model" => a_model(), "dir" => System.tmp_dir!()}
          }),
          [{"content-type", "application/json"}, {"origin", "https://evil.example.com"}]
        )

      assert conn.status == 403
      assert %{"error" => %{"code" => -32600}} = JSON.decode!(conn.resp_body)
      refute task_created?(prompt)
    end

    test "a loopback origin and no origin both work" do
      for headers <- [
            [{"content-type", "application/json"}, {"origin", "http://localhost:3000"}],
            [{"content-type", "application/json"}]
          ] do
        assert post(rpc("ping"), headers).status == 200
      end
    end

    test "GET with a foreign origin is 403, not 405" do
      conn =
        conn(:get, "/mcp")
        |> put_req_header("origin", "https://evil.example.com")
        |> Router.call(Router.init([]))

      assert conn.status == 403
    end
  end

  describe "protocol" do
    test "an unsupported MCP-Protocol-Version is 400" do
      conn =
        post(rpc("ping"), [
          {"content-type", "application/json"},
          {"mcp-protocol-version", "2025-03-26"}
        ])

      assert conn.status == 400
    end

    test "the implemented version is accepted" do
      headers = [
        {"content-type", "application/json"},
        {"mcp-protocol-version", Current.MCP.protocol_version()}
      ]

      assert post(rpc("ping"), headers).status == 200
    end

    test "initialize over HTTP" do
      conn = post(rpc("initialize", %{"protocolVersion" => Current.MCP.protocol_version()}))
      assert conn.status == 200
      assert %{"result" => %{"protocolVersion" => version}} = JSON.decode!(conn.resp_body)
      assert version == Current.MCP.protocol_version()
    end

    test "a notification is 202 with no body" do
      conn = post(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"})
      assert conn.status == 202
      assert conn.resp_body == ""
    end

    test "a client response is 202 with no body" do
      conn = post(%{"jsonrpc" => "2.0", "id" => 3, "result" => %{}})
      assert conn.status == 202
      assert conn.resp_body == ""
    end

    test "a batch is refused: 400, one error, no replies" do
      conn = post([rpc("ping", %{}, 1), rpc("ping", %{}, 2)])
      assert conn.status == 400
      assert %{"error" => %{"code" => -32600}, "id" => nil} = JSON.decode!(conn.resp_body)
    end

    test "invalid JSON-RPC is 400 and never crashes the request" do
      for bad <- [
            %{},
            [],
            "just a string",
            5,
            nil,
            %{"jsonrpc" => "2.0", "id" => 1},
            %{"jsonrpc" => "2.0", "method" => "tools/call"}
          ] do
        conn = post(bad)
        assert conn.status == 400, "#{inspect(bad)} -> #{conn.status}"
        assert %{"error" => %{"code" => -32600}} = JSON.decode!(conn.resp_body)
      end
    end

    test "invalid params are an error reply, not a crash" do
      for params <- [[], [1], "x", 5] do
        conn =
          post(%{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize", "params" => params})

        assert conn.status == 200
        assert %{"error" => %{"code" => -32602}} = JSON.decode!(conn.resp_body)
      end

      conn = post(rpc("tools/call", %{"name" => "health", "arguments" => "oops"}))
      assert %{"error" => %{"code" => -32602}} = JSON.decode!(conn.resp_body)
    end

    test "a body that is not JSON is 400 with a parse error (and the request process raises, as Plug.ErrorHandler does)" do
      conn =
        conn(:post, "/mcp", "{not json")
        |> put_req_header("content-type", "application/json")

      assert_raise Plug.Parsers.ParseError, fn -> Router.call(conn, Router.init([])) end

      assert {400, _headers, body} = sent_resp(conn)
      assert %{"error" => %{"code" => -32700}} = JSON.decode!(body)
    end

    test "a body over the parser limit is 413" do
      big =
        JSON.encode!(
          rpc("tools/call", %{
            "name" => "health",
            "arguments" => %{"pad" => String.duplicate("a", 300_000)}
          })
        )

      conn =
        conn(:post, "/mcp", big)
        |> put_req_header("content-type", "application/json")

      assert_raise Plug.Parsers.RequestTooLargeError, fn -> Router.call(conn, Router.init([])) end
      assert {413, _headers, _body} = sent_resp(conn)
    end

    test "a non-JSON content type is 415" do
      assert post({:raw, JSON.encode!(rpc("ping"))}, [{"content-type", "text/plain"}]).status ==
               415
    end

    test "GET /mcp is 405 and advertises POST" do
      conn = Router.call(conn(:get, "/mcp"), Router.init([]))
      assert conn.status == 405
      assert get_resp_header(conn, "allow") == ["POST"]
    end
  end

  ## submit_task_isolated

  describe "Current.API.submit_task_isolated/3" do
    test "returns the task id, leaves no stray messages, and passes errors through" do
      request = %Current.Request{
        input: unique_prompt("isolated"),
        context: %{},
        model: a_model(),
        mode: :apply
      }

      assert {:ok, task_id} = Current.API.submit_task_isolated(request, System.tmp_dir!())
      assert is_binary(task_id)

      assert {:error, {:unknown_model, "nope:nope"}} =
               Current.API.submit_task_isolated(
                 %{request | model: "nope:nope"},
                 System.tmp_dir!()
               )

      assert {:error, {:too_large, :prompt, _, _}} =
               Current.API.submit_task_isolated(
                 %{request | input: String.duplicate("p", @limits[:prompt] + 1)},
                 System.tmp_dir!()
               )

      # The helper's process is gone and nothing from it (or from the task's
      # notifications) reached the caller's mailbox.
      refute_received _
    end
  end
end
