defmodule Current.E2E.SubmitTaskTest do
  @moduledoc """
  `Current.submit_task/3` itself: what it accepts, what it refuses up
  front, and what it records.
  """

  use ExUnit.Case, async: false

  import Current.TestHelpers

  doctest Current

  defp task_project_dir(task_id) do
    assert {:ok, %Current.Task{project_dir: project_dir}} = Current.Task.get(task_id)
    project_dir
  end

  defp tmp_path(name),
    do: Path.join(Current.TestTmp.dir(), "#{name}_#{System.unique_integer([:positive])}")

  test "creates a workflow that is queryable by task id" do
    task_id = submit!()
    workflow_id = await_workflow_created(task_id)

    assert {:ok, workflow} = Current.get_workflow(task_id)
    assert workflow.id == workflow_id
    assert workflow.task_id == task_id

    assert {:ok, status} = Current.get_status(task_id)
    assert status in [:created, :planning, :validating, :waiting_for_approval]
  end

  test "an unknown task id is not found" do
    assert {:error, :not_found} = Current.get_status("sha256:" <> String.duplicate("a", 64))
  end

  describe "model" do
    test "the request's model is recorded on the task" do
      task_id = submit!()
      await_workflow_created(task_id)

      assert {:ok, %Current.Task{model: model}} = Current.Task.get(task_id)
      assert model == model()
    end

    test "a model the catalog doesn't list is rejected without recording anything" do
      for model <- ["openai:nope", "nope:gpt-5.6", "gpt-5.6", ""] do
        assert {:error, {:unknown_model, ^model}} =
                 Current.submit_task(request(model: model), self(), System.tmp_dir!())
      end

      refute_receive {:workflow_created, _}, 200
    end

    test "a request without a model is rejected" do
      assert {:error, :model_required} =
               Current.submit_task(request(model: nil), self(), System.tmp_dir!())

      refute_receive {:workflow_created, _}, 200
    end
  end

  describe "timeout" do
    test "defaults to none, meaning the runtime's own bound" do
      task_id = submit!()
      await_workflow_created(task_id)

      assert {:ok, %Current.Task{timeout_ms: nil}} = Current.Task.get(task_id)
    end

    test "a task's own timeout is recorded on it" do
      task_id = submit!(timeout_ms: 90_000)
      await_workflow_created(task_id)

      assert {:ok, %Current.Task{timeout_ms: 90_000}} = Current.Task.get(task_id)
    end

    test "one that isn't a sensible number of milliseconds is rejected, recording nothing" do
      for bad <- [0, -1, 999, 3_600_001, 1.5, "60000"] do
        assert {:error, {:invalid_timeout, ^bad}} =
                 Current.submit_task(request(timeout_ms: bad), self(), System.tmp_dir!())
      end

      refute_receive {:workflow_created, _}, 200
    end
  end

  describe "project_dir" do
    test "defaults to the working directory, recorded canonically" do
      {:ok, task_id} = Current.submit_task(request(), self())
      await_workflow_created(task_id)

      assert {:ok, task_project_dir(task_id)} == Current.IntentPaths.realpath(File.cwd!())
    end

    test "a relative one is resolved at submission time" do
      task_id = submit!([], "lib")
      await_workflow_created(task_id)

      assert {:ok, task_project_dir(task_id)} ==
               Current.IntentPaths.realpath(Path.join(File.cwd!(), "lib"))
    end

    test "the physical directory is recorded, not the symlink used to name it" do
      base = tmp_path("current_link")
      real = Path.join(base, "real_project")
      link = Path.join(base, "app")
      File.mkdir_p!(real)
      File.ln_s!(real, link)
      on_exit(fn -> File.rm_rf!(base) end)

      task_id = submit!([], link)
      await_workflow_created(task_id)

      assert task_project_dir(task_id) == real

      # Repointing the symlink afterwards changes nothing about the task.
      other = Path.join(base, "other_project")
      File.mkdir_p!(other)
      File.rm!(link)
      File.ln_s!(other, link)

      assert task_project_dir(task_id) == real
    end

    test "one that doesn't exist or isn't a directory is rejected" do
      missing = tmp_path("current_missing")

      assert {:error, {:invalid_project_dir, ^missing, :not_a_directory}} =
               Current.submit_task(request(), self(), missing)

      file = missing <> ".txt"
      File.write!(file, "")
      on_exit(fn -> File.rm(file) end)

      assert {:error, {:invalid_project_dir, ^file, :not_a_directory}} =
               Current.submit_task(request(), self(), file)

      refute_receive {:workflow_created, _}, 200
    end

    test "a symlink loop is rejected" do
      base = tmp_path("current_loop")
      File.mkdir_p!(base)
      File.ln_s!("b", Path.join(base, "a"))
      File.ln_s!("a", Path.join(base, "b"))
      on_exit(fn -> File.rm_rf!(base) end)

      loop = Path.join(base, "a")

      assert {:error, {:invalid_project_dir, ^loop, :too_many_links}} =
               Current.submit_task(request(), self(), loop)
    end

    test "one containing '..' is rejected without recording anything" do
      for dir <- ["..", "../../etc", "lib/../..", "/srv/app/../../etc", "lib/.."] do
        assert {:error, {:invalid_project_dir, ^dir, :parent_segment}} =
                 Current.submit_task(request(), self(), dir)
      end

      refute_receive {:workflow_created, _}, 200
    end

    test "a name that merely contains dots is not mistaken for '..'" do
      dir = Path.join(System.tmp_dir!(), "current..dots_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      assert {:ok, _task_id} = Current.submit_task(request(), self(), dir)
    end
  end
end
