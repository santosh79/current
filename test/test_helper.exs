ExUnit.start()
{:ok, _} = Current.TaskStore.start_link([])
{:ok, _} = Current.start_link([])
