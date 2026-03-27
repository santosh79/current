defmodule Current do
  alias Current.{Request, Id}

  def submit_task(%Request{} = req, caller_pid)
      when is_pid(caller_pid) do
    task_id = Id.generate()
    {:ok, task_id}
  end
end
