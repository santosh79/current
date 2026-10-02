defmodule Current.TestHelpers do
  @moduledoc """
  What the end-to-end tests share: one place that knows how to build a
  request, submit it through `Current.submit_task/3`, and wait for the
  events the submitting process is sent as the workflow moves on.

  A new required field on `Current.Request` is a change to `request/1`
  here, not to every test file.

      import Current.TestHelpers

      workflow_id = submit!(mode: :plan) |> await_workflow_created()
      await(:workflow_completed, workflow_id)
  """

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Current.{Event, Request}

  @model "openai:gpt-5.6"
  @receive_timeout 5_000

  @doc """
  A model the test catalog lists (see Current.TestOpenAIModelCatalogClient).
  Its completions come from Current.FakeLLMClient.
  """
  def model, do: @model

  @doc "A valid request. `overrides` replace fields, e.g. `request(mode: :plan)`."
  def request(overrides \\ []) do
    struct!(%Request{input: "add email validation", context: %{}, model: @model}, overrides)
  end

  @doc """
  Submits `request(overrides)` with the test process as listener and
  returns the task id.
  """
  def submit!(overrides \\ [], project_dir \\ System.tmp_dir!()) do
    assert {:ok, task_id} = Current.submit_task(request(overrides), self(), project_dir)
    task_id
  end

  @doc "Waits for the task's workflow and returns its id."
  def await_workflow_created(task_id) do
    receive do
      {:workflow_created, %Event.WorkflowCreated{task_id: ^task_id, workflow_id: workflow_id}} ->
        workflow_id
    after
      @receive_timeout -> flunk("did not receive workflow_created for task #{task_id}")
    end
  end

  @doc """
  Waits for the workflow's next `tag` notification (`:proposal_produced`,
  `:workflow_completed`, ...) and returns its event.
  """
  def await(tag, workflow_id) when is_atom(tag) do
    receive do
      {^tag, %{workflow_id: ^workflow_id} = event} -> event
    after
      @receive_timeout -> flunk("did not receive #{tag} for workflow #{workflow_id}")
    end
  end

  @doc "Waits until the workflow ends either way and returns the closing event."
  def await_finished(workflow_id) do
    receive do
      {:workflow_completed, %Event.WorkflowCompleted{workflow_id: ^workflow_id} = event} -> event
      {:workflow_failed, %Event.WorkflowFailed{workflow_id: ^workflow_id} = event} -> event
    after
      @receive_timeout -> flunk("workflow #{workflow_id} did not finish")
    end
  end

  @doc """
  Submits a request and waits until its proposal has been validated.
  In apply mode (the default) the workflow is then waiting for approval.
  """
  def submit_and_await_valid_proposal(overrides \\ []) do
    task_id = submit!(overrides)
    workflow_id = await_workflow_created(task_id)
    %Event.ProposalProduced{proposal: proposal} = await(:proposal_produced, workflow_id)
    await(:proposal_validated, workflow_id)

    {task_id, workflow_id, proposal}
  end

  @doc "Approves the proposal, waits for the approval to be projected, then applies it."
  def approve_and_apply(proposal) do
    assert :ok = Current.TestApproval.approve_and_apply(proposal.id, %{reviewed_by: :test_user})
  end

  @doc "The workflow's committed events, in order."
  def events(workflow_id), do: Current.EventStore.list_by_workflow_id(workflow_id)

  @doc "Whether any of `events` is a `module` event."
  def any?(events, module), do: Enum.any?(events, &is_struct(&1, module))

  @doc "Sets a `:current` application env key for this test and restores it afterwards."
  def put_env(key, value) do
    previous = Application.fetch_env(:current, key)
    :ok = Application.put_env(:current, key, value)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:current, key, value)
        :error -> Application.delete_env(:current, key)
      end
    end)

    :ok
  end

  @doc "Runs this test's workflows with `builder` instead of the configured proposal builder."
  def use_proposal_builder(builder), do: put_env(:proposal_builder, builder)
end
