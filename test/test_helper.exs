ExUnit.start(exclude: [:live_llm])

ExUnit.after_suite(fn _ ->
  File.rm_rf!(Application.fetch_env!(:current, :data_dir))
end)
