defmodule Current.TestTmp do
  @moduledoc """
  The system tmp dir as a canonical path -- exactly what
  Current.submit_task/3 records when given System.tmp_dir!().

  They differ wherever the tmp dir is reached through a symlink: on macOS
  System.tmp_dir!() is under /var, a symlink to /private/var. Fixtures
  that must be inside a task's project_dir have to be spelled this way,
  because IntentValidator compares paths against the recorded directory
  lexically.
  """

  @spec dir() :: Path.t()
  def dir do
    {:ok, dir} = Current.IntentPaths.realpath(Path.expand(System.tmp_dir!()))
    dir
  end
end
