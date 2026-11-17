defmodule Current.LLMProposalBuilderNew do
  use GenServer

  @max_observe_rounds 8
  @max_repairs 2
  @context_budget_bytes 400_000

  def init(:ok) do
    state = %{
      :observe_rounds_left => @max_observe_rounds,
      :calls => 0,
      :budget => @context_budget_bytes,
      :project => nil,
      :repairs_left => @max_repairs
    }

    {:ok, state}
  end

  def handle_cast(
        {:build,
         %{
           :ref => ref,
           :request => request,
           :workflow_id => workflow_id,
           :model => model,
           :timeout_ms => timeout_ms,
           :project_dir => project_dir,
           :from_pid => from_pid,
           :client_pid => client_pid
         } = orig_msg},
        %{:observe_rounds_left => observe_rounds_left} = state
      ) do
    cond do
      Map.get(state, :project, nil) == nil ->
        case project_layout(project_dir) do
          {:error, project_error} ->
            :ok = respond_to_caller(from_pid, ref, project_error)
            {:noreply, state}

          {:ok, project} ->
            state = Map.put(state, :project, project)
            :ok = GenServer.cast(self(), orig_msg)
            {:noreply, state}
        end

      timeout_ms <= 0 ->
        error = timeout_error(timeout_ms)
        :ok = respond_to_caller(from_pid, ref, error)
        {:noreply, state}

      state.budget <= 0 ->
        error = context_budget_exceeded_error()
        :ok = respond_to_caller(from_pid, ref, error)
        {:noreply, state}

      observe_rounds_left <= 0 ->
        error = observe_limits_error()
        :ok = GenServer.cast(from_pid, {:builder_result, ref, error})
        {:noreply, state}

      true ->
        prompt = Map.get(orig_msg, :prompt, nil)

        {:ok, prompt} =
          case prompt do
            nil ->
              Current.LLM.PromptBuilder.build_initial_prompt(
                request,
                state.project,
                project_dir,
                @max_observe_rounds
              )

            _ ->
              {:ok, prompt}
          end

        complete_request = {:complete, prompt, timeout_ms, model}
        {res, time_taken_for_call} = timed_call(client_pid, complete_request, timeout_ms)

        case res do
          {:error, :timeout} ->
            error = timeout_error(timeout_ms)
            :ok = respond_to_caller(from_pid, ref, error)
            {:noreply, state}

          {:ok, genserver_response} ->
            state = %{state | calls: state.calls + 1}

            case genserver_response do
              {:error, reason} ->
                error = connection_error(reason)
                :ok = respond_to_caller(from_pid, ref, error)
                {:noreply, state}

              {:ok, %{text: raw_llm_response, usage: usage}} ->
                {:ok, raw_output_blob_id} = Current.BlobStore.put(raw_llm_response)
                cumulative_usage = add_usage(state.cumulative_usage, usage)

                state = Map.put(state, :cumulative_usage, cumulative_usage)

                :ok =
                  notify_activity_hub(state, state.calls, usage, cumulative_usage)

                case Current.ProposalDecoder.decode_reply(raw_llm_response, workflow_id) do
                  {:error, _reason} when state.repairs_left > 0 ->
                    updated_timeout = timeout_ms - time_taken_for_call
                    :ok = GenServer.cast(self(), %{orig_msg | timeout_ms: updated_timeout})
                    rlf = Map.get(state, :repairs_left)
                    {:noreply, %{state | repairs_left: rlf - 1}}

                  {:error, reason} ->
                    error = decode_error(reason, raw_output_blob_id)
                    :ok = respond_to_caller(from_pid, ref, error)
                    {:noreply, state}

                  {:ok, {:observe, requested}} ->
                    {:ok, observe_response, state} =
                      handle_observe_request(state, requested, raw_output_blob_id)

                    updated_timeout = timeout_ms - time_taken_for_call

                    :ok =
                      GenServer.cast(self(), %{
                        orig_msg
                        | prompt: observe_response,
                          timeout_ms: updated_timeout
                      })

                    {:noreply, state}

                  {:ok, {:proposal, %Current.Proposal{} = proposal}} ->
                    proposal = %Current.Proposal{
                      proposal
                      | observations: attach(state.observations, proposal)
                    }

                    result = {:ok, proposal, raw_output_blob_id}
                    :ok = respond_to_caller(from_pid, ref, result)
                    {:noreply, state}
                end
            end
        end
    end

    {:noreply, state}
  end

  defp handle_observe_request(%{:observe_rounds_left => oblf} = state, requested, raw_output_blob_id) do
    cur_round = @max_observe_rounds - oblf + 1
    state = %{state | observe_rounds_left: oblf - 1}

    requested =
      Enum.map(
        requested,
        &%{&1 | round: cur_round, reply_artifact_id: raw_output_blob_id}
      )

    :ok = Current.ActivityHub.observe_requested(state.workflow_id, cur_round, requested)
    {made, budget} = Current.Observer.observe(requested, state.project.root, state.budget)
    state = %{state | budget: budget}
    {observations, texts} = Enum.unzip(made)
    :ok = Current.ActivityHub.observe_settled(state.workflow_id, cur_round, made)
    state = %{state | observations: state.observations ++ observations}

    {:ok, Current.LLM.PromptBuilder.observation_message(texts, oblf), state}
  end

  defp timed_call(server, request, timeout) do
    started = System.monotonic_time()

    result =
      try do
        {:ok, GenServer.call(server, request, timeout)}
      catch
        :exit, {:timeout, {GenServer, :call, _args}} ->
          {:error, :timeout}
      end

    elapsed_ms =
      System.convert_time_unit(
        System.monotonic_time() - started,
        :native,
        :millisecond
      )

    {result, elapsed_ms}
  end

  defp decode_error(reason, raw_output_blob_id) do
    {:error,
     %Current.Error.ProposalProductionError{
       stage: :decode,
       reason: reason,
       raw_output_blob_id: raw_output_blob_id
     }}
  end

  defp timeout_error(orig_timeout_ms) do
    {:error,
     %Current.Error.ProposalProductionError{
       stage: :timeout,
       reason: "no proposal after #{orig_timeout_ms}ms"
     }}
  end

  defp connection_error(reason) do
    {:error,
     %Current.Error.ProposalProductionError{
       stage: :connection,
       reason: reason
     }}
  end

  defp context_budget_exceeded_error() do
    {:error,
     %Current.Error.ProposalProductionError{
       stage: :context_budget,
       reason: "exceed max context budget of #{@context_budget_bytes} bytes"
     }}
  end

  defp observe_limits_error() do
    {:error,
     %Current.Error.ProposalProductionError{
       stage: :context_budget,
       reason: "still asking for context after #{@max_observe_rounds} requests"
     }}
  end

  defp respond_to_caller(pid, ref, result) do
    :ok = GenServer.cast(pid, {:builder_result, ref, result})
    :ok
  end

  defp notify_activity_hub(state, calls, usage, cumulative_usage) do
    :ok =
      Current.ActivityHub.llm_responded(
        state.workflow_id,
        calls,
        usage,
        cumulative_usage
      )

    :ok
  end

  defp add_usage(cumulative, nil), do: cumulative
  defp add_usage(nil, usage), do: usage

  defp add_usage(left, right) do
    %{
      input_tokens: left.input_tokens + right.input_tokens,
      output_tokens: left.output_tokens + right.output_tokens,
      total_tokens: left.total_tokens + right.total_tokens
    }
    |> add_optional_usage(left, right, :cache_creation_input_tokens)
    |> add_optional_usage(left, right, :cache_read_input_tokens)
  end

  # The observations now belong to the proposal they led to, and their
  # intents say so, like every other intent in it.
  defp attach(observations, %Current.Proposal{id: proposal_id}) do
    Enum.map(observations, fn observation ->
      %{observation | intent: %{observation.intent | proposal_id: proposal_id}}
    end)
  end

  defp add_optional_usage(cumulative, left, right, key) do
    cond do
      Map.has_key?(left, key) or Map.has_key?(right, key) ->
        sum = Map.get(left, key, 0) + Map.get(right, key, 0)
        Map.put(cumulative, key, sum)

      true ->
        cumulative
    end
  end

  defp project_layout(nil) do
    {:error,
     %Current.Error.ProposalProductionError{stage: :project_context, reason: :no_project_dir}}
  end

  defp project_layout(project_dir) do
    case Current.ProjectContext.layout(project_dir) do
      {:ok, project} ->
        {:ok, project}

      {:error, reason} ->
        {:error, %Current.Error.ProposalProductionError{stage: :project_context, reason: reason}}
    end
  end
end
