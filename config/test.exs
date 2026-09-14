import Config

config :current,
  consensus_log_path:
    Path.join([System.tmp_dir!(), "current_test_#{System.os_time(:millisecond)}", "commit_log"])
