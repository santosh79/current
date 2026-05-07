defmodule CurrentTest do
  use ExUnit.Case, async: false

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
      {:ok, task_id, workflow} = submit_simple_task()
      created_workflow = workflow

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
      {:ok, task_id, workflow} = submit_simple_task()
      workflow_id = workflow.id

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

      assert [
               %Current.Event.WorkflowCreated{},
               %Current.Event.ProposalProductionStarted{},
               %Current.Event.ProposalProduced{},
               %Current.Event.ProposalApproved{}
             ] = events |> Enum.take(4)
    end

    # submit task
    # receive workflow_created
    # receive proposal_production_started
    # receive proposal_produced
    # call Current.review_proposal/2 with reject
    # receive proposal_rejected
    # fetch event log and assert ordered event types
    test "rejecting a proposal" do
      {:ok, task_id, workflow} = submit_simple_task()
      workflow_id = workflow.id

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

      assert [
               %Current.Event.WorkflowCreated{},
               %Current.Event.ProposalProductionStarted{},
               %Current.Event.ProposalProduced{},
               %Current.Event.ProposalRejected{}
             ] = events
    end

    test "event log entries carry the correct workflow snapshot at each stage" do
      {:ok, task_id, workflow} = submit_simple_task()
      workflow_id = workflow.id

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

      assert length(events) >= 4

      [
        %Current.Event.WorkflowCreated{} = created,
        %Current.Event.ProposalProductionStarted{} = production_started,
        %Current.Event.ProposalProduced{} = produced,
        %Current.Event.ProposalApproved{} = approved
      ] = events

      assert created.workflow.id == workflow_id
      assert created.workflow.task_id == task_id
      assert created.workflow.status == :created
      assert created.workflow.proposal == nil

      assert production_started.workflow.id == workflow_id
      assert production_started.workflow.task_id == task_id
      assert production_started.workflow.status == :planning
      assert production_started.workflow.proposal == nil
      assert production_started.workflow.started_at != nil

      assert produced.workflow.id == workflow_id
      assert produced.workflow.task_id == task_id
      assert produced.workflow.status == :validating
      assert produced.workflow.proposal != nil
      assert produced.workflow.proposal.id == proposal_id

      assert approved.workflow.id == workflow_id
      assert approved.workflow.task_id == task_id
      assert approved.workflow.status == :approved
      assert approved.workflow.proposal != nil
      assert approved.workflow.proposal.id == proposal_id
    end

    test "rejection event log entries carry the correct workflow snapshot at each stage" do
      {:ok, task_id, workflow} = submit_simple_task()
      workflow_id = workflow.id

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

      [
        %Current.Event.WorkflowCreated{} = created,
        %Current.Event.ProposalProductionStarted{} = production_started,
        %Current.Event.ProposalProduced{} = produced,
        %Current.Event.ProposalRejected{} = rejected
      ] =
        events

      assert created.workflow.id == workflow_id
      assert created.workflow.task_id == task_id
      assert created.workflow.status == :created
      assert created.workflow.proposal == nil

      assert production_started.workflow.id == workflow_id
      assert production_started.workflow.task_id == task_id
      assert production_started.workflow.status == :planning
      assert production_started.workflow.proposal == nil
      assert production_started.workflow.started_at != nil

      assert produced.workflow.id == workflow_id
      assert produced.workflow.task_id == task_id
      assert produced.workflow.status == :validating
      assert produced.workflow.proposal != nil
      assert produced.workflow.proposal.id == proposal_id

      assert rejected.workflow.id == workflow_id
      assert rejected.workflow.task_id == task_id
      assert rejected.workflow.status == :rejected
      assert rejected.workflow.proposal != nil
      assert rejected.workflow.proposal.id == proposal_id
    end

    test "approved proposal advances through effect application, artifact production, assembly, and completion" do
      {:ok, task_id, workflow} = submit_simple_task()

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
        {:effects_applied, ^task_id, effect_workflow, _intent_results} ->
          assert effect_workflow.id == workflow.id
          assert effect_workflow.status == :applying
          assert effect_workflow.proposal.id == proposal.id
      after
        1_000 ->
          flunk("did not receive effects_applied")
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

      _artifacts =
        receive do
          {:artifacts_produced, ^task_id, artifact_workflow, artifacts} ->
            assert artifact_workflow.id == workflow.id
            assert artifact_workflow.status in [:applying, :assembling_result]
            assert artifact_workflow.proposal.id == proposal.id

            Enum.each(artifacts, fn artifact ->
              assert %Current.Artifact{} = artifact
              assert :ok = Current.Id.validate(artifact.id)
              assert artifact.workflow_id == workflow.id
            end)

            artifacts
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

      assert [
               %Current.Event.WorkflowCreated{},
               %Current.Event.ProposalProductionStarted{},
               %Current.Event.ProposalProduced{},
               %Current.Event.ProposalApproved{},
               %Current.Event.EffectApplicationStarted{},
               %Current.Event.EffectApplied{},
               %Current.Event.EffectsApplied{},
               %Current.Event.ArtifactProduced{},
               %Current.Event.ArtifactsProduced{},
               %Current.Event.WorkflowResultAssembled{},
               %Current.Event.WorkflowCompleted{}
             ] = events
    end

    test "artifact_produced event carries the produced artifact payload" do
      {:ok, task_id, workflow} = submit_simple_task()
      workflow_id = workflow.id

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

      %Current.Event.ArtifactProduced{} =
        artifact_event =
        Enum.find(events, &match?(%Current.Event.ArtifactProduced{}, &1))

      # Enum.find(events, fn event -> event.type == :artifact_produced end) ||
      #   flunk("did not find artifact_produced event in event log")

      assert artifact_event.workflow_id == workflow_id
      assert artifact_event.workflow.task_id == task_id
      assert %Current.Workflow{} = artifact_event.workflow
      assert artifact_event.workflow.id == workflow_id

      assert %Current.Artifact{} = artifact_event.artifact
      assert artifact_event.artifact.id == produced_artifact.id
      assert artifact_event.artifact.workflow_id == workflow_id
      assert artifact_event.artifact.storage == produced_artifact.storage
    end

    test "workflow_result_assembled event carries the assembled result payload" do
      {:ok, task_id, workflow} = submit_simple_task()
      workflow_id = workflow.id

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

      %Current.Event.WorkflowResultAssembled{} =
        result_event =
        Enum.find(events, &match?(%Current.Event.WorkflowResultAssembled{}, &1))

      assert result_event.workflow_id == workflow_id
      assert result_event.workflow.task_id == task_id
      assert %Current.Workflow{} = result_event.workflow
      assert result_event.workflow.id == workflow_id

      assert %Current.WorkflowResult{} = result_event.result
      assert result_event.result.id == assembled_result.id
      assert result_event.result.workflow_id == workflow_id
      assert result_event.result.artifacts == assembled_result.artifacts
    end

    test "approved proposal can fail during execution and the workflow fails" do
      :persistent_term.put(:proposal_builder, Current.FaultyProposalBuilder)
      on_exit(fn -> :persistent_term.put(:proposal_builder, Current.ProposalBuilder) end)

      {:ok, task_id, workflow} = submit_simple_task()

      receive do
        {:proposal_production_started, ^task_id, _workflow} -> :ok
      after
        1_000 -> flunk("did not receive proposal_production_started")
      end

      proposal =
        receive do
          {:proposal_produced, ^task_id, produced_workflow, proposal} ->
            assert produced_workflow.status == :validating
            proposal
        after
          1_000 -> flunk("did not receive proposal_produced")
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
      after
        1_000 -> flunk("did not receive proposal_approved")
      end

      receive do
        {:effect_failed, ^task_id, failed_workflow, _reason} ->
          assert failed_workflow.id == workflow.id
      after
        1_000 -> flunk("did not receive effect_failed")
      end

      receive do
        {:workflow_failed, ^task_id, failed_workflow} ->
          assert failed_workflow.id == workflow.id
          assert failed_workflow.status == :failed
          assert failed_workflow.proposal.id == proposal.id
          assert failed_workflow.result == nil
          assert failed_workflow.error != nil
      after
        1_000 -> flunk("did not receive workflow_failed")
      end

      {:ok, final_workflow} = Current.get_workflow(task_id)
      assert final_workflow.status == :failed
      assert final_workflow.result == nil
      assert final_workflow.error != nil

      events = Current.EventStore.list_by_workflow_id(workflow.id)

      assert [
               %Current.Event.WorkflowCreated{},
               %Current.Event.ProposalProductionStarted{},
               %Current.Event.ProposalProduced{},
               %Current.Event.ProposalApproved{},
               %Current.Event.EffectApplicationStarted{},
               %Current.Event.EffectFailed{},
               %Current.Event.WorkflowFailed{}
             ] = events
    end

    # This test does the following:
    # 1/ Submit a task to the system
    # 2/ Force creation of a proposal for the ask from step 1 that has 3 Intents
    # 3/ Run it through the usual flow
    # 4/ Assert there are 3 artifacts produced that map 1:1 with the intents
    # 5/ Assert the workflow completes successfully
    test "proposal with 3 intents produces 3 artifacts and completes" do
      :persistent_term.put(:proposal_builder, Current.MultiIntentProposalBuilder)
      on_exit(fn -> :persistent_term.put(:proposal_builder, Current.ProposalBuilder) end)

      {:ok, task_id, workflow} = submit_simple_task()

      receive do
        {:proposal_production_started, ^task_id, _workflow} ->
          :ok
      after
        1_000 ->
          flunk("did not receive proposal_production_started")
      end

      proposal =
        receive do
          {:proposal_produced, ^task_id, produced_workflow, proposal} ->
            assert produced_workflow.status == :validating
            assert length(proposal.intents) == 3
            proposal
        after
          1_000 ->
            flunk("did not receive proposal_produced")
        end

      proposal_intent_ids = Enum.map(proposal.intents, & &1.id)

      assert :ok =
               Current.review_proposal(
                 proposal.id,
                 {:approve, %{reviewed_by: :test_user, note: "looks good"}}
               )

      receive do
        {:proposal_approved, ^task_id, approved_workflow} ->
          assert approved_workflow.status == :approved
          assert approved_workflow.proposal.id == proposal.id
      after
        1_000 ->
          flunk("did not receive proposal_approved")
      end

      receive do
        {:effects_applied, ^task_id, effect_workflow, intent_results} ->
          assert effect_workflow.status == :applying
          assert effect_workflow.proposal.id == proposal.id
          assert length(intent_results) == 3
      after
        1_000 ->
          flunk("did not receive effects_applied")
      end

      artifacts =
        1..3
        |> Enum.map(fn _ ->
          receive do
            {:artifact_produced, ^task_id, artifact_workflow, %Current.Artifact{} = artifact} ->
              assert artifact_workflow.id == workflow.id
              assert artifact_workflow.proposal.id == proposal.id
              assert :ok = Current.Id.validate(artifact.id)
              assert artifact.workflow_id == workflow.id
              assert artifact.intent_id in proposal_intent_ids
              assert artifact.storage.backend == :filesystem
              assert is_binary(artifact.storage.path)
              assert File.exists?(artifact.storage.path)
              artifact
          after
            1_000 ->
              flunk("did not receive artifact_produced")
          end
        end)

      artifact_ids = Enum.map(artifacts, & &1.id)
      artifact_intent_ids = Enum.map(artifacts, & &1.intent_id)
      artifact_paths = Enum.map(artifacts, & &1.storage.path)

      assert Enum.sort(artifact_intent_ids) == Enum.sort(proposal_intent_ids)
      assert length(Enum.uniq(artifact_ids)) == 3
      assert length(Enum.uniq(artifact_paths)) == 3

      produced_artifacts =
        receive do
          {:artifacts_produced, ^task_id, artifact_workflow, produced_artifacts} ->
            assert artifact_workflow.id == workflow.id
            assert artifact_workflow.proposal.id == proposal.id
            assert length(produced_artifacts) == 3
            assert Enum.sort(Enum.map(produced_artifacts, & &1.id)) == Enum.sort(artifact_ids)
            produced_artifacts
        after
          1_000 ->
            flunk("did not receive artifacts_produced")
        end

      workflow_result =
        receive do
          {:workflow_result_assembled, ^task_id, assembled_workflow, workflow_result} ->
            assert assembled_workflow.id == workflow.id
            assert %Current.WorkflowResult{} = workflow_result
            assert length(workflow_result.artifacts) == 3
            assert Enum.sort(workflow_result.artifacts) == Enum.sort(artifact_ids)
            workflow_result
        after
          1_000 ->
            flunk("did not receive workflow_result_assembled")
        end

      receive do
        {:workflow_completed, ^task_id, completed_workflow} ->
          assert completed_workflow.status == :completed
          assert completed_workflow.result.id == workflow_result.id
      after
        1_000 ->
          flunk("did not receive workflow_completed")
      end

      {:ok, final_workflow} = Current.get_workflow(task_id)
      assert final_workflow.status == :completed
      assert length(final_workflow.result.artifacts) == 3
      assert Enum.sort(final_workflow.result.artifacts) == Enum.sort(artifact_ids)

      events = Current.EventStore.list_by_workflow_id(workflow.id)

      assert [
               %Current.Event.WorkflowCreated{},
               %Current.Event.ProposalProductionStarted{},
               %Current.Event.ProposalProduced{},
               %Current.Event.ProposalApproved{},
               %Current.Event.EffectApplicationStarted{},
               %Current.Event.EffectApplied{},
               %Current.Event.EffectApplied{},
               %Current.Event.EffectApplied{},
               %Current.Event.EffectsApplied{},
               %Current.Event.ArtifactProduced{},
               %Current.Event.ArtifactProduced{},
               %Current.Event.ArtifactProduced{},
               %Current.Event.ArtifactsProduced{},
               %Current.Event.WorkflowResultAssembled{},
               %Current.Event.WorkflowCompleted{}
             ] = events

      %Current.Event.ArtifactsProduced{} =
        artifacts_produced_event =
        Enum.find(events, &match?(%Current.Event.ArtifactsProduced{}, &1))

      event_artifact_ids = Enum.map(artifacts_produced_event.artifacts, & &1.id)

      assert Enum.sort(event_artifact_ids) == Enum.sort(artifact_ids)
      assert Enum.sort(Enum.map(produced_artifacts, & &1.id)) == Enum.sort(artifact_ids)
    end

    defp submit_simple_task do
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

      {:ok, task_id, workflow}
    end

    # proposal has 3 intents:
    #   → approval succeeds
    #   → effect application starts
    #   → intent 1 applies
    #   → intent 2 fails during application
    #   → intent 3 is never applied
    #   → no artifacts
    #   → no result
    #   → workflow_failed
    test "workflow fails when second intent fails during effect application" do
      :ok = :persistent_term.put(:proposal_builder, Current.SecondIntentFailsProposalBuilder)
      :ok = :persistent_term.put(:effect_applicator, Current.FaultyEffectApplicator)

      on_exit(fn ->
        :ok = :persistent_term.put(:proposal_builder, Current.ProposalBuilder)
        :ok = :persistent_term.put(:effect_applicator, Current.EffectApplicator)
      end)

      req = %Request{
        input: "add email validation to signup flow",
        context: %{}
      }

      {:ok, task_id} = Current.submit_task(req, self())

      workflow =
        receive do
          {:workflow_created, ^task_id, workflow} -> workflow
        after
          1_000 -> flunk("did not receive workflow_created")
        end

      receive do
        {:proposal_production_started, ^task_id, _workflow} -> :ok
      after
        1_000 -> flunk("did not receive proposal_production_started")
      end

      proposal =
        receive do
          {:proposal_produced, ^task_id, produced_workflow, proposal} ->
            assert produced_workflow.status == :validating
            assert length(proposal.intents) == 3

            assert Enum.map(proposal.intents, & &1.type) == [
                     :file_patch,
                     :file_patch,
                     :run_command
                   ]

            proposal
        after
          1_000 -> flunk("did not receive proposal_produced")
        end

      assert :ok =
               Current.review_proposal(
                 proposal.id,
                 {:approve, %{reviewed_by: :test_user, note: "looks good"}}
               )

      receive do
        {:proposal_approved, ^task_id, approved_workflow} ->
          assert approved_workflow.status == :approved
      after
        1_000 -> flunk("did not receive proposal_approved")
      end

      receive do
        {:effect_applied, ^task_id, effect_workflow, intent, _result} ->
          assert effect_workflow.status == :applying
          assert intent.type == :file_patch
      after
        1_000 -> flunk("did not receive first effect_applied")
      end

      receive do
        {:effect_failed, ^task_id, failed_workflow, reason} ->
          assert failed_workflow.status == :applying
          assert failed_workflow.result == nil
          assert is_binary(reason)
      after
        1_000 -> flunk("did not receive effect_failed")
      end

      receive do
        {:workflow_failed, ^task_id, failed_workflow} ->
          assert failed_workflow.id == workflow.id
          assert failed_workflow.status == :failed
          assert failed_workflow.proposal.id == proposal.id
          assert failed_workflow.result == nil
          assert failed_workflow.error != nil
      after
        1_000 -> flunk("did not receive workflow_failed")
      end

      refute_receive {:effects_applied, ^task_id, _, _}, 200
      refute_receive {:artifact_produced, ^task_id, _, _}, 200
      refute_receive {:artifacts_produced, ^task_id, _, _}, 200
      refute_receive {:workflow_result_assembled, ^task_id, _, _}, 200
      refute_receive {:workflow_completed, ^task_id, _}, 200

      {:ok, final_workflow} = Current.get_workflow(task_id)
      assert final_workflow.status == :failed
      assert final_workflow.result == nil
      assert final_workflow.error != nil

      events = Current.EventStore.list_by_workflow_id(workflow.id)

      assert [
               %Current.Event.WorkflowCreated{},
               %Current.Event.ProposalProductionStarted{},
               %Current.Event.ProposalProduced{},
               %Current.Event.ProposalApproved{},
               %Current.Event.EffectApplicationStarted{},
               %Current.Event.EffectApplied{},
               %Current.Event.EffectFailed{},
               %Current.Event.WorkflowFailed{}
             ] = events

      %Current.Event.WorkflowFailed{} =
        failed_event =
        Enum.find(events, &match?(%Current.Event.WorkflowFailed{}, &1))

      assert failed_event.workflow.status == :failed
      assert failed_event.workflow.error != nil
      assert failed_event.workflow.result == nil
      assert failed_event.workflow.proposal.id == proposal.id
    end

    test "run_command intent produces stdout and stderr as artifacts" do
      :persistent_term.put(:proposal_builder, Current.RunCommandProposalBuilder)
      on_exit(fn -> :persistent_term.put(:proposal_builder, Current.ProposalBuilder) end)

      {:ok, task_id, workflow} = submit_simple_task()

      receive do
        {:proposal_production_started, ^task_id, _workflow} -> :ok
      after
        1_000 -> flunk("did not receive proposal_production_started")
      end

      proposal =
        receive do
          {:proposal_produced, ^task_id, _produced_workflow, proposal} ->
            assert length(proposal.intents) == 1
            [intent] = proposal.intents
            assert intent.type == :run_command
            proposal
        after
          1_000 -> flunk("did not receive proposal_produced")
        end

      assert :ok =
               Current.review_proposal(
                 proposal.id,
                 {:approve, %{reviewed_by: :test_user, note: "looks good"}}
               )

      receive do
        {:proposal_approved, ^task_id, _workflow} -> :ok
      after
        1_000 -> flunk("did not receive proposal_approved")
      end

      receive do
        {:effects_applied, ^task_id, effect_workflow, intent_results} ->
          assert effect_workflow.status == :applying
          assert length(intent_results) == 1

          [{intent, result}] = intent_results

          assert intent.type == :run_command
          assert result.exit_code == 0

          # stdout and stderr are artifact ids, not raw strings
          assert is_binary(result.stdout_artifact_id)
          assert is_binary(result.stderr_artifact_id)
          assert :ok = Current.Id.validate(result.stdout_artifact_id)
          assert :ok = Current.Id.validate(result.stderr_artifact_id)

          # they are different artifacts
          assert result.stdout_artifact_id != result.stderr_artifact_id

          # stdout artifact exists on disk and contains the command output
          {:ok, stdout_artifact_path} = Current.ArtifactStore.path_for(result.stdout_artifact_id)
          assert File.exists?(stdout_artifact_path)
          stdout_contents = File.read!(stdout_artifact_path)
          assert stdout_contents =~ "hello from test"

          # stderr artifact exists on disk (may be empty but must exist)
          {:ok, stderr_artifact_path} = Current.ArtifactStore.path_for(result.stderr_artifact_id)
          assert File.exists?(stderr_artifact_path)
          stderr_contents = File.read!(stderr_artifact_path)
          assert stderr_contents =~ "error from test"

          assert byte_size(stdout_contents) > 0
          assert byte_size(stderr_contents) > 0

          refute stdout_artifact_path == stderr_artifact_path
      after
        1_000 -> flunk("did not receive effects_applied")
      end

      # the command_result artifact produced by ArtifactBuilder references both
      artifact =
        receive do
          {:artifact_produced, ^task_id, _workflow,
           %Current.Artifact{type: :command_result} = artifact} ->
            assert artifact.workflow_id == workflow.id
            assert artifact.metadata.exit_code == 0
            assert is_binary(artifact.metadata.stdout_artifact_id)
            assert is_binary(artifact.metadata.stderr_artifact_id)
            assert artifact.metadata.stdout_bytes > 0
            artifact
        after
          1_000 -> flunk("did not receive artifact_produced")
        end

      receive do
        {:artifacts_produced, ^task_id, _workflow, artifacts} ->
          assert length(artifacts) == 1
          assert hd(artifacts).id == artifact.id
      after
        1_000 -> flunk("did not receive artifacts_produced")
      end

      receive do
        {:workflow_result_assembled, ^task_id, _workflow, _result} -> :ok
      after
        1_000 -> flunk("did not receive workflow_result_assembled")
      end

      receive do
        {:workflow_completed, ^task_id, completed_workflow} ->
          assert completed_workflow.status == :completed
      after
        1_000 -> flunk("did not receive workflow_completed")
      end

      events = Current.EventStore.list_by_workflow_id(workflow.id)

      # event log carries summarized result, not raw output
      %Current.Event.EffectsApplied{} =
        effects_applied_event =
        Enum.find(events, &match?(%Current.Event.EffectsApplied{}, &1))

      effects_applied_event.intent_results
      |> Enum.each(fn ea ->
        {_intent, erc} = ea
        assert erc.exit_code == 0
        assert erc.stdout_artifact_id == artifact.metadata.stdout_artifact_id

        assert erc.stderr_artifact_id == artifact.metadata.stderr_artifact_id
      end)
    end
  end
end
