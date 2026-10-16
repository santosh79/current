defmodule Current.HTTP.Router do
  @moduledoc """
  The HTTP/JSON face of `Current.RPC`: one route per RPC function, no
  logic of its own. Like the CLI, it is a client of the runtime that
  happens to live in the same VM -- everything it does goes through
  `Current.RPC`, so the two cannot drift apart.

      POST /v1/tasks                       submit_task
      GET  /v1/workflows/:id               workflow
      GET  /v1/workflows/:id/activity      activity   (?epoch=&after_seq=)
      GET  /v1/proposals/:id               proposal
      GET  /v1/proposals/:id/review        review     (?max_lines=&raw=true)
      POST /v1/proposals/:id/approve       approve
      POST /v1/proposals/:id/reject        reject
      POST /v1/proposals/:id/apply         apply_proposal
      GET  /v1/artifacts/:id               artifact   (raw bytes)
      GET  /v1/models                      models
      GET  /v1/health                      health

  There is no authentication. Control who can reach the port with your own
  gateway or network rules; see `Current.HTTP.Server`.

  Responses are JSON, encoded by `Current.HTTP.Encode`, except `review`
  (the versioned `current.review/v1` document, exactly what
  `current review --json` prints) and `artifact` (the exact bytes, as
  `application/octet-stream`). Errors are `{"error": {"code": ..., "message": ...}}`
  with a matching status: 400 bad request, 404 not found, 409 conflict (ambiguous prefix, wrong workflow state),
  422 unprocessable (unknown model, bad directory), 502 for anything else.

  ### POST /v1/tasks

      {"prompt": "...", "model": "anthropic:claude-opus-5-5",
       "dir": "/abs/path/to/project",
       "mode": "plan" | "apply",          // default "apply"
       "timeout_ms": 600000}              // optional

  Answers `202 {"task_id": "..."}`. Poll `GET /v1/workflows/:task_id`
  until `terminal` is true (or `status` is `waiting_for_approval`).
  `dir` must be an absolute path on the machine the runtime runs on.

  ### POST /v1/proposals/:id/approve and /reject

      {"message": "looks right", "reviewed_by": "santosh"}   // both optional

  Recorded verbatim on the event, with `"via": "http"`.
  """

  use Plug.Router
  use Plug.ErrorHandler

  alias Current.CLI.ReviewJSON
  alias Current.HTTP.Encode
  alias Current.{Request, RPC}

  @default_review_max_lines 200

  plug(:match)
  plug(:reject_browsers)

  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: JSON,
    length: 1_000_000
  )

  plug(:dispatch)

  ## Browser guard

  # Browsers attach an Origin header to every cross-origin POST, and
  # nothing that is a client of this API does. Refusing them stops a web
  # page you happen to have open from driving a local runtime.
  defp reject_browsers(conn, _opts) do
    case get_req_header(conn, "origin") do
      [] ->
        conn

      _ ->
        conn
        |> error(403, "forbidden", "browser requests are not accepted")
        |> halt()
    end
  end

  ## Tasks

  post "/v1/tasks" do
    params = conn.body_params

    with {:ok, prompt} <- required_string(params, "prompt"),
         {:ok, model} <- required_string(params, "model"),
         {:ok, dir} <- required_string(params, "dir"),
         {:ok, mode} <- mode(params),
         {:ok, timeout_ms} <- optional_integer(params, "timeout_ms") do
      request = %Request{
        input: prompt,
        context: %{},
        model: model,
        mode: mode,
        timeout_ms: timeout_ms
      }

      # RPC.submit_task/2 registers the calling process as the task's
      # listener. A connection process outlives the request and would
      # collect every notification for the task in its mailbox, so the
      # call is made from a process that exits straight away; its
      # notifications are dropped, as they are for the CLI's RPC calls.
      case Task.async(fn -> RPC.submit_task(request, dir) end) |> Task.await(30_000) do
        {:ok, task_id} -> json(conn, 202, %{task_id: task_id})
        {:error, reason} -> respond_error(conn, reason)
      end
    else
      {:error, message} -> error(conn, 400, "bad_request", message)
    end
  end

  ## Workflows

  get "/v1/workflows/:id" do
    case RPC.workflow(id) do
      {:ok, view} -> json(conn, 200, view)
      {:error, reason} -> respond_error(conn, reason)
    end
  end

  # RPC.activity/3 wants a full workflow id; workflow/1 resolves prefixes
  # and task ids, so go through it.
  get "/v1/workflows/:id/activity" do
    with {:ok, epoch} <- optional_query_integer(conn, "epoch"),
         {:ok, after_seq} <- optional_query_integer(conn, "after_seq"),
         {:ok, %{workflow_id: workflow_id}} <- RPC.workflow(id) do
      json(conn, 200, RPC.activity(workflow_id, epoch, after_seq || 0))
    else
      {:error, reason} -> respond_error(conn, reason)
    end
  end

  ## Proposals

  get "/v1/proposals/:id" do
    case RPC.proposal(id) do
      {:ok, view} -> json(conn, 200, view)
      {:error, reason} -> respond_error(conn, reason)
    end
  end

  get "/v1/proposals/:id/review" do
    with {:ok, max_lines} <- optional_query_integer(conn, "max_lines"),
         true <- is_nil(max_lines) or max_lines >= 1 do
      opts = %{
        max_lines: max_lines || @default_review_max_lines,
        raw: conn.query_params["raw"] in ["true", "1"]
      }

      case RPC.review(id, opts) do
        # Already a JSON-ready, versioned document; not run through Encode.
        {:ok, review} -> send_json(conn, 200, ReviewJSON.to_map(review))
        {:error, reason} -> respond_error(conn, reason)
      end
    else
      _ -> error(conn, 400, "bad_request", "max_lines must be a whole number, at least 1")
    end
  end

  post "/v1/proposals/:id/approve" do
    decide(conn, id, &RPC.approve/2)
  end

  post "/v1/proposals/:id/reject" do
    decide(conn, id, &RPC.reject/2)
  end

  post "/v1/proposals/:id/apply" do
    case RPC.apply_proposal(id) do
      {:ok, workflow_id} -> json(conn, 202, %{workflow_id: workflow_id})
      {:error, reason} -> respond_error(conn, reason)
    end
  end

  ## Artifacts

  get "/v1/artifacts/:id" do
    case RPC.artifact(id) do
      {:ok, full_id, contents} ->
        conn
        |> put_resp_header("x-current-artifact-id", full_id)
        |> put_resp_content_type("application/octet-stream")
        |> send_resp(200, contents)

      {:error, reason} ->
        respond_error(conn, reason)
    end
  end

  ## Runtime

  get "/v1/models" do
    case RPC.models() do
      models when is_list(models) -> json(conn, 200, %{models: models})
      {:error, reason} -> respond_error(conn, reason)
    end
  end

  get "/v1/health" do
    json(conn, 200, RPC.health())
  end

  match _ do
    error(conn, 404, "not_found", "no such route")
  end

  # Anything that escapes a route is a bug here, not the caller's fault.
  # The details go to the log (Plug.ErrorHandler-style), not the response.
  @impl Plug.ErrorHandler
  def handle_errors(conn, %{kind: kind, reason: reason}) do
    require Logger

    Logger.error(
      "HTTP #{conn.method} #{conn.request_path}: " <> Exception.format_banner(kind, reason)
    )

    error(conn, 500, "internal_error", "the runtime raised; see its log")
  end

  ## approve / reject

  defp decide(conn, id, rpc) do
    params = conn.body_params

    with {:ok, message} <- optional_string(params, "message"),
         {:ok, reviewed_by} <- optional_string(params, "reviewed_by") do
      metadata = %{message: message, reviewed_by: reviewed_by, via: :http}

      case rpc.(id, metadata) do
        {:ok, workflow_id} -> json(conn, 200, %{workflow_id: workflow_id})
        {:error, reason} -> respond_error(conn, reason)
      end
    else
      {:error, message} -> error(conn, 400, "bad_request", message)
    end
  end

  ## Parameters

  defp required_string(params, key) do
    case params do
      %{^key => value} when is_binary(value) ->
        if String.trim(value) == "",
          do: {:error, "#{key} can't be blank"},
          else: {:ok, value}

      _ ->
        {:error, "#{key} is required and must be a string"}
    end
  end

  defp optional_string(params, key) do
    case params do
      %{^key => value} when is_binary(value) -> {:ok, value}
      %{^key => nil} -> {:ok, nil}
      %{^key => _} -> {:error, "#{key} must be a string"}
      _ -> {:ok, nil}
    end
  end

  defp optional_integer(params, key) do
    case params do
      %{^key => value} when is_integer(value) -> {:ok, value}
      %{^key => nil} -> {:ok, nil}
      %{^key => _} -> {:error, "#{key} must be an integer"}
      _ -> {:ok, nil}
    end
  end

  defp optional_query_integer(conn, key) do
    case conn.query_params[key] do
      nil ->
        {:ok, nil}

      value ->
        case Integer.parse(value) do
          {int, ""} -> {:ok, int}
          _ -> {:error, {:bad_request, "#{key} must be a whole number"}}
        end
    end
  end

  # Strings only, so no atoms are minted from request data.
  defp mode(%{"mode" => "plan"}), do: {:ok, :plan}
  defp mode(%{"mode" => "apply"}), do: {:ok, :apply}
  defp mode(%{"mode" => _}), do: {:error, ~s(mode must be "plan" or "apply")}
  defp mode(_params), do: {:ok, Current.Mode.default()}

  ## Responses

  defp json(conn, status, data), do: send_json(conn, status, Encode.to_json(data))

  defp send_json(conn, status, document) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode!(document))
  end

  defp error(conn, status, code, message) do
    send_json(conn, status, %{error: %{code: code, message: message}})
  end

  # Maps what Current.RPC returns to a status and a stable code.
  defp respond_error(conn, reason) do
    {status, code, message} = describe_error(reason)
    error(conn, status, code, message)
  end

  defp describe_error(:not_found), do: {404, "not_found", "no match for that id"}

  defp describe_error(:prefix_too_short),
    do: {400, "prefix_too_short", "an id prefix needs at least 4 hex digits"}

  defp describe_error({:ambiguous, ids}),
    do: {409, "ambiguous_id", "the prefix matches #{length(ids)} ids: " <> Enum.join(ids, ", ")}

  defp describe_error({:bad_request, message}), do: {400, "bad_request", message}

  defp describe_error(:model_required), do: {422, "model_required", "a model is required"}

  defp describe_error({:unknown_model, model}),
    do: {422, "unknown_model", "#{model} is not in the model catalog"}

  defp describe_error({:invalid_timeout, value}),
    do: {422, "invalid_timeout", "invalid timeout: #{inspect(value)}"}

  defp describe_error({:invalid_project_dir, path, reason}),
    do: {422, "invalid_project_dir", "#{path}: #{reason}"}

  defp describe_error({:not_apply_mode, mode}),
    do: {409, "not_apply_mode", "the proposal is from a #{mode}-mode workflow"}

  defp describe_error({:invalid_transition, status, _event}),
    do: {409, "invalid_transition", "the workflow is #{status}, which doesn't allow that"}

  defp describe_error(other),
    do: {502, "runtime_error", inspect(other)}
end
