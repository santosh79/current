defmodule CurrentTest do
  use ExUnit.Case
  doctest Current

  alias Current.Request
  alias Current.Workflow
  alias Current.Proposal

  describe "workflow lifecycle" do
    test "request submission" do
      req = %Request{
        input: "add email validation to signup flow",
        context: %{}
      }

      {:ok, task_id} = Current.submit_task(req, self())

      receive do
        {:workflow_created, ^task_id, _workflow} ->
          assert {:ok, status} = Current.get_status(task_id)
          assert status != nil
      after
        1_000 ->
          flunk("did not receive workflow")
      end
    end

    test "get_status returns not_found for an unknown task id" do
      unknown_task_id =
        "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

      assert {:error, :not_found} = Current.get_status(unknown_task_id)
    end

    ## orchestrator drives workflow transitions
    ##
    ## workflow_created
    ## → orchestrator triggers planning
    ## → workflow emits planning
    ## → orchestrator triggers proposal
    ## → workflow emits proposal
    test "orchestrator drives workflow transitions" do
      req = %Request{
        input: "add email validation to signup flow",
        context: %{}
      }

      {:ok, task_id} = Current.submit_task(req, self())
      assert :ok = Current.Id.validate(task_id)

      created_workflow =
        receive do
          {:workflow_created, ^task_id, workflow} ->
            assert %Workflow{} = workflow
            assert :ok = Current.Id.validate(workflow.id)
            assert workflow.task_id == task_id
            assert workflow.status == :created
            assert workflow.proposal == nil
            workflow
        after
          1_000 ->
            flunk("did not receive workflow_created")
        end

      planning_workflow =
        receive do
          {:proposal_production_started, ^task_id, workflow} ->
            assert %Workflow{} = workflow
            assert workflow.id == created_workflow.id
            assert workflow.task_id == task_id
            assert workflow.status == :planning
            assert workflow.proposal == nil
            assert workflow.started_at != nil
            workflow
        after
          1_000 ->
            flunk("did not receive proposal_production_started")
        end

        receive do
          {:proposal_produced, ^task_id, workflow, proposal} ->
            assert %Workflow{} = workflow
            assert %Proposal{} = proposal

            assert workflow.id == created_workflow.id
            assert workflow.id == planning_workflow.id
            assert workflow.task_id == task_id
            assert workflow.status == :validating

            assert :ok = Current.Id.validate(proposal.id)
            assert proposal.workflow_id == workflow.id
            assert workflow.proposal.id == proposal.id

            assert is_list(proposal.intents)
            assert length(proposal.intents) > 0
        after
          1_000 ->
            flunk("did not receive proposal_produced")
        end
    end

    test "reviewing an unknown proposal returns not_found" do
      unknown_proposal_id =
        "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

      {:error, :not_found} =
        Current.review_proposal(unknown_proposal_id, {:approve, %{reviewed_by: :test_user}})
    end

    # submit task
    # receive workflow_created
    # receive proposal_production_started
    # receive proposal_produced
    # call Current.review_proposal/2 with approve
    # receive proposal_approved
    # fetch event log and assert ordered event types

    test "approving a proposal" do
      req = %Request{
        input: "add email validation to signup flow",
        context: %{}
      }

      {:ok, task_id} = Current.submit_task(req, self())

      workflow_id =
        receive do
          {:workflow_created, ^task_id, workflow} ->
            workflow.id
        after
          1_000 ->
            flunk("did not receive workflow_created")
        end

      receive do
        {:proposal_production_started, ^task_id, _workflow} ->
          :ok
      after
        1_000 ->
          flunk("did not receive proposal_production_started")
      end

      proposal_id =
        receive do
          {:proposal_produced, ^task_id, workflow, proposal} ->
            assert workflow.status == :validating
            proposal.id
        after
          1_000 ->
            flunk("did not receive proposal_produced")
        end

        assert :ok =
          Current.review_proposal(
            proposal_id,
            {:approve, %{reviewed_by: :test_user, note: "looks good"}}
          )

        receive do
          {:proposal_approved, ^task_id, workflow} ->
            assert workflow.status == :approved
        after
          1_000 ->
            flunk("did not receive proposal_approved")
        end

        events = Current.EventStore.list_by_workflow_id(workflow_id)

        assert Enum.map(events, & &1.type) |> Enum.take(4) == [
          :workflow_created,
          :proposal_production_started,
          :proposal_produced,
          :proposal_approved
        ]
    end

    # submit task
    # receive workflow_created
    # receive proposal_production_started
    # receive proposal_produced
    # call Current.review_proposal/2 with reject
    # receive proposal_rejected
    # fetch event log and assert ordered event types
    test "rejecting a proposal" do
      req = %Request{
        input: "add email validation to signup flow",
        context: %{}
      }

      {:ok, task_id} = Current.submit_task(req, self())

      workflow_id =
        receive do
          {:workflow_created, ^task_id, workflow} ->
            workflow.id
        after
          1_000 ->
            flunk("did not receive workflow_created")
        end

      receive do
        {:proposal_production_started, ^task_id, _workflow} ->
          :ok
      after
        1_000 ->
          flunk("did not receive proposal_production_started")
      end

      proposal_id =
        receive do
          {:proposal_produced, ^task_id, workflow, proposal} ->
            assert workflow.status == :validating
            proposal.id
        after
          1_000 ->
            flunk("did not receive proposal_produced")
        end

        assert :ok =
          Current.review_proposal(
            proposal_id,
            {:reject, %{reviewed_by: :test_user, note: "proposal is not acceptable"}}
          )

        receive do
          {:proposal_rejected, ^task_id, workflow} ->
            assert workflow.status == :rejected
        after
          1_000 ->
            flunk("did not receive proposal_rejected")
        end

        events = Current.EventStore.list_by_workflow_id(workflow_id)

        assert Enum.map(events, & &1.type) == [
          :workflow_created,
          :proposal_production_started,
          :proposal_produced,
          :proposal_rejected
        ]
    end

    test "event log entries carry the correct workflow snapshot at each stage" do
      req = %Request{
        input: "add email validation to signup flow",
        context: %{}
      }

      {:ok, task_id} = Current.submit_task(req, self())

      workflow_id =
        receive do
          {:workflow_created, ^task_id, workflow} ->
            workflow.id
        after
          1_000 ->
            flunk("did not receive workflow_created")
        end

      receive do
        {:proposal_production_started, ^task_id, _workflow} ->
          :ok
      after
        1_000 ->
          flunk("did not receive proposal_production_started")
      end

      proposal_id =
        receive do
          {:proposal_produced, ^task_id, workflow, proposal} ->
            assert workflow.status == :validating
            proposal.id
        after
          1_000 ->
            flunk("did not receive proposal_produced")
        end

        assert :ok =
          Current.review_proposal(
            proposal_id,
            {:approve, %{reviewed_by: :test_user, note: "looks good"}}
          )

        receive do
          {:proposal_approved, ^task_id, workflow} ->
            assert workflow.status == :approved
        after
          1_000 ->
            flunk("did not receive proposal_approved")
        end

        events = Current.EventStore.list_by_workflow_id(workflow_id)

        assert length(events) == 4

        [created, production_started, produced, approved] = events

        assert created.type == :workflow_created
        assert created.data.workflow.id == workflow_id
        assert created.data.workflow.task_id == task_id
        assert created.data.workflow.status == :created
        assert created.data.workflow.proposal == nil

        assert production_started.type == :proposal_production_started
        assert production_started.data.workflow.id == workflow_id
        assert production_started.data.workflow.task_id == task_id
        assert production_started.data.workflow.status == :planning
        assert production_started.data.workflow.proposal == nil
        assert production_started.data.workflow.started_at != nil

        assert produced.type == :proposal_produced
        assert produced.data.workflow.id == workflow_id
        assert produced.data.workflow.task_id == task_id
        assert produced.data.workflow.status == :validating
        assert produced.data.workflow.proposal != nil
        assert produced.data.workflow.proposal.id == proposal_id

        assert approved.type == :proposal_approved
        assert approved.data.workflow.id == workflow_id
        assert approved.data.workflow.task_id == task_id
        assert approved.data.workflow.status == :approved
        assert approved.data.workflow.proposal != nil
        assert approved.data.workflow.proposal.id == proposal_id
    end

    test "rejection event log entries carry the correct workflow snapshot at each stage" do
      req = %Request{
        input: "add email validation to signup flow",
        context: %{}
      }

      {:ok, task_id} = Current.submit_task(req, self())

      workflow_id =
        receive do
          {:workflow_created, ^task_id, workflow} ->
            workflow.id
        after
          1_000 ->
            flunk("did not receive workflow_created")
        end

      receive do
        {:proposal_production_started, ^task_id, _workflow} ->
          :ok
      after
        1_000 ->
          flunk("did not receive proposal_production_started")
      end

      proposal_id =
        receive do
          {:proposal_produced, ^task_id, workflow, proposal} ->
            assert workflow.status == :validating
            proposal.id
        after
          1_000 ->
            flunk("did not receive proposal_produced")
        end

        assert :ok =
          Current.review_proposal(
            proposal_id,
            {:reject, %{reviewed_by: :test_user, note: "proposal is not acceptable"}}
          )

        receive do
          {:proposal_rejected, ^task_id, workflow} ->
            assert workflow.status == :rejected
        after
          1_000 ->
            flunk("did not receive proposal_rejected")
        end

        events = Current.EventStore.list_by_workflow_id(workflow_id)

        assert length(events) == 4

        [created, production_started, produced, rejected] = events

        assert created.type == :workflow_created
        assert created.data.workflow.id == workflow_id
        assert created.data.workflow.task_id == task_id
        assert created.data.workflow.status == :created
        assert created.data.workflow.proposal == nil

        assert production_started.type == :proposal_production_started
        assert production_started.data.workflow.id == workflow_id
        assert production_started.data.workflow.task_id == task_id
        assert production_started.data.workflow.status == :planning
        assert production_started.data.workflow.proposal == nil
        assert production_started.data.workflow.started_at != nil

        assert produced.type == :proposal_produced
        assert produced.data.workflow.id == workflow_id
        assert produced.data.workflow.task_id == task_id
        assert produced.data.workflow.status == :validating
        assert produced.data.workflow.proposal != nil
        assert produced.data.workflow.proposal.id == proposal_id

        assert rejected.type == :proposal_rejected
        assert rejected.data.workflow.id == workflow_id
        assert rejected.data.workflow.task_id == task_id
        assert rejected.data.workflow.status == :rejected
        assert rejected.data.workflow.proposal != nil
        assert rejected.data.workflow.proposal.id == proposal_id
    end

    test "approved proposal advances through effect application, artifact production, assembly, and completion" do
      req = %Request{
        input: "add email validation to signup flow",
        context: %{}
      }

      {:ok, task_id} = Current.submit_task(req, self())

      workflow =
        receive do
          {:workflow_created, ^task_id, workflow} ->
            workflow
        after
          1_000 ->
            flunk("did not receive workflow_created")
        end

      receive do
        {:proposal_production_started, ^task_id, planning_workflow} ->
          assert planning_workflow.id == workflow.id
          assert planning_workflow.status == :planning
          assert planning_workflow.proposal == nil
      after
        1_000 ->
          flunk("did not receive proposal_production_started")
      end

      proposal =
        receive do
          {:proposal_produced, ^task_id, produced_workflow, proposal} ->
            assert produced_workflow.id == workflow.id
            assert produced_workflow.status == :validating
            assert produced_workflow.proposal.id == proposal.id
            assert length(proposal.intents) > 0
            proposal
        after
          1_000 ->
            flunk("did not receive proposal_produced")
        end

        assert :ok =
          Current.review_proposal(
            proposal.id,
            {:approve, %{reviewed_by: :test_user, note: "looks good"}}
          )

        receive do
          {:proposal_approved, ^task_id, approved_workflow} ->
            assert approved_workflow.id == workflow.id
            assert approved_workflow.status == :approved
            assert approved_workflow.proposal.id == proposal.id
        after
          1_000 ->
            flunk("did not receive proposal_approved")
        end

        receive do
          {:effect_applied, ^task_id, effect_workflow} ->
            assert effect_workflow.id == workflow.id
            assert effect_workflow.status == :applying
            assert effect_workflow.proposal.id == proposal.id
        after
          1_000 ->
            flunk("did not receive effect_applied")
        end

        _artifact =
          receive do
            {:artifact_produced, ^task_id, artifact_workflow, artifact} ->
              assert artifact_workflow.id == workflow.id
              assert artifact_workflow.status in [:applying, :assembling_result]
              assert artifact_workflow.proposal.id == proposal.id

              assert %Current.Artifact{} = artifact
              assert :ok = Current.Id.validate(artifact.id)
              assert artifact.workflow_id == workflow.id

              artifact
          after
            1_000 ->
              flunk("did not receive artifact_produced")
          end

          workflow_result =
            receive do
              {:workflow_result_assembled, ^task_id, assembled_workflow, workflow_result} ->
                assert assembled_workflow.id == workflow.id
                assert assembled_workflow.status in [:assembling_result, :completed]
                assert assembled_workflow.proposal.id == proposal.id

                assert %Current.WorkflowResult{} = workflow_result
                assert :ok = Current.Id.validate(workflow_result.id)
                assert workflow_result.workflow_id == workflow.id
                assert length(workflow_result.artifacts) > 0

                workflow_result
            after
              1_000 ->
                flunk("did not receive workflow_result_assembled")
            end

            receive do
              {:workflow_completed, ^task_id, completed_workflow} ->
                assert completed_workflow.id == workflow.id
                assert completed_workflow.status == :completed
                assert completed_workflow.proposal.id == proposal.id
                assert completed_workflow.result != nil
                assert completed_workflow.result.id == workflow_result.id
            after
              1_000 ->
                flunk("did not receive workflow_completed")
            end

            {:ok, final_workflow} = Current.get_workflow(task_id)
            assert final_workflow.id == workflow.id
            assert final_workflow.status == :completed
            assert final_workflow.proposal.id == proposal.id
            assert final_workflow.result != nil
            assert final_workflow.result.id == workflow_result.id

            events = Current.EventStore.list_by_workflow_id(workflow.id)

            assert Enum.map(events, & &1.type) == [
              :workflow_created,
              :proposal_production_started,
              :proposal_produced,
              :proposal_approved,
              :effect_applied,
              :artifact_produced,
              :workflow_result_assembled,
              :workflow_completed
            ]
    end

    test "artifact_produced event carries the produced artifact payload" do
      req = %Request{
        input: "add email validation to signup flow",
        context: %{}
      }

      {:ok, task_id} = Current.submit_task(req, self())

      workflow_id =
        receive do
          {:workflow_created, ^task_id, workflow} ->
            workflow.id
        after
          1_000 ->
            flunk("did not receive workflow_created")
        end

      receive do
        {:proposal_production_started, ^task_id, _workflow} ->
          :ok
      after
        1_000 ->
          flunk("did not receive proposal_production_started")
      end

      proposal_id =
        receive do
          {:proposal_produced, ^task_id, workflow, proposal} ->
            assert workflow.status == :validating
            proposal.id
        after
          1_000 ->
            flunk("did not receive proposal_produced")
        end

        assert :ok =
          Current.review_proposal(
            proposal_id,
            {:approve, %{reviewed_by: :test_user, note: "looks good"}}
          )

        receive do
          {:proposal_approved, ^task_id, _workflow} ->
            :ok
        after
          1_000 ->
            flunk("did not receive proposal_approved")
        end

        produced_artifact =
          receive do
            {:artifact_produced, ^task_id, workflow, artifact} ->
              assert workflow.id == workflow_id
              assert %Current.Artifact{} = artifact
              artifact
          after
            1_000 ->
              flunk("did not receive artifact_produced")
          end

          events = Current.EventStore.list_by_workflow_id(workflow_id)

          artifact_event =
            Enum.find(events, fn event -> event.type == :artifact_produced end) ||
              flunk("did not find artifact_produced event in event log")

          assert artifact_event.workflow_id == workflow_id
          assert artifact_event.data.task_id == task_id
          assert %Current.Workflow{} = artifact_event.data.workflow
          assert artifact_event.data.workflow.id == workflow_id

          assert %Current.Artifact{} = artifact_event.data.artifact
          assert artifact_event.data.artifact.id == produced_artifact.id
          assert artifact_event.data.artifact.workflow_id == workflow_id
          assert artifact_event.data.artifact.type == produced_artifact.type
          assert artifact_event.data.artifact.storage == produced_artifact.storage
    end

    test "workflow_result_assembled event carries the assembled result payload" do
      req = %Request{
        input: "add email validation to signup flow",
        context: %{}
      }

      {:ok, task_id} = Current.submit_task(req, self())

      workflow_id =
        receive do
          {:workflow_created, ^task_id, workflow} ->
            workflow.id
        after
          1_000 ->
            flunk("did not receive workflow_created")
        end

      receive do
        {:proposal_production_started, ^task_id, _workflow} ->
          :ok
      after
        1_000 ->
          flunk("did not receive proposal_production_started")
      end

      proposal_id =
        receive do
          {:proposal_produced, ^task_id, workflow, proposal} ->
            assert workflow.status == :validating
            proposal.id
        after
          1_000 ->
            flunk("did not receive proposal_produced")
        end

        assert :ok =
          Current.review_proposal(
            proposal_id,
            {:approve, %{reviewed_by: :test_user, note: "looks good"}}
          )

        receive do
          {:proposal_approved, ^task_id, _workflow} ->
            :ok
        after
          1_000 ->
            flunk("did not receive proposal_approved")
        end

        assembled_result =
          receive do
            {:workflow_result_assembled, ^task_id, workflow, result} ->
              assert workflow.id == workflow_id
              assert %Current.WorkflowResult{} = result
              result
          after
            1_000 ->
              flunk("did not receive workflow_result_assembled")
          end

          events = Current.EventStore.list_by_workflow_id(workflow_id)

          result_event =
            Enum.find(events, fn event -> event.type == :workflow_result_assembled end) ||
              flunk("did not find workflow_result_assembled event in event log")

          assert result_event.workflow_id == workflow_id
          assert result_event.data.task_id == task_id
          assert %Current.Workflow{} = result_event.data.workflow
          assert result_event.data.workflow.id == workflow_id

          assert %Current.WorkflowResult{} = result_event.data.result
          assert result_event.data.result.id == assembled_result.id
          assert result_event.data.result.workflow_id == workflow_id
          assert result_event.data.result.type == assembled_result.type
          assert result_event.data.result.artifacts == assembled_result.artifacts
    end
  end
end
