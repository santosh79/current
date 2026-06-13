defmodule Current.IntentValidator do
  alias Current.{Intent, Proposal, Error.ValidationError}

  @spec validate(Proposal.t()) :: :ok | {:error, ValidationError.t()}
  def validate(%Proposal{intents: intents}) when is_list(intents) do
    case Enum.find_value(intents, &validate_intent/1) do
      nil -> :ok
      error -> {:error, error}
    end
  end

  def validate(_proposal) do
    {:error,
     %ValidationError{
       intent_id: nil,
       reason: "invalid proposal",
       details: %{}
     }}
  end

  defp validate_intent(%Intent.ReadFile{id: id, path: path}) do
    if File.regular?(path) do
      nil
    else
      %ValidationError{
        intent_id: id,
        reason: "read_file path does not exist",
        details: %{path: path}
      }
    end
  end

  defp validate_intent(%Intent.Grep{id: id, paths: paths}) do
    case Enum.find(paths, &(not File.regular?(&1))) do
      nil ->
        nil

      path ->
        %ValidationError{
          intent_id: id,
          reason: "grep path does not exist",
          details: %{path: path}
        }
    end
  end

  defp validate_intent(%Intent.Glob{id: id, pattern: pattern, base_dir: base_dir}) do
    cond do
      Path.type(pattern) == :absolute ->
        %ValidationError{
          intent_id: id,
          reason: "glob pattern must be relative",
          details: %{pattern: pattern}
        }

      not File.dir?(base_dir) ->
        %ValidationError{
          intent_id: id,
          reason: "glob base_dir does not exist",
          details: %{base_dir: base_dir}
        }

      true ->
        nil
    end
  end

  defp validate_intent(_intent), do: nil
end
