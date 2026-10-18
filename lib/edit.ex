defmodule Current.Edit do
  @moduledoc """
  The text replacement behind an `edit_file` intent.

  `old` must occur in `contents` exactly once, byte for byte -- whitespace
  and indentation included -- unless `replace_all` is set, in which case it
  must occur at least once and every occurrence is replaced. Pure: no
  files, no blobs.

  IntentValidator calls this to refuse an edit that cannot apply before a
  human is asked to approve it, and EffectApplicator calls it to apply the
  edit, so the two cannot disagree about what a valid edit is.
  """

  @spec replace(binary(), binary(), binary(), boolean()) ::
          {:ok, binary(), pos_integer()} | {:error, String.t()}
  def replace(_contents, "", _new, _replace_all),
    do: {:error, "old_string must not be empty; create a file with write_file"}

  def replace(contents, old, new, replace_all) do
    case :binary.matches(contents, old) do
      [] ->
        {:error,
         "old_string was not found in the file; it must match exactly, " <>
           "whitespace and indentation included"}

      [_one] ->
        {:ok, :binary.replace(contents, old, new), 1}

      matches when replace_all ->
        {:ok, :binary.replace(contents, old, new, [:global]), length(matches)}

      matches ->
        {:error,
         "old_string matches #{length(matches)} places; include more surrounding " <>
           "lines so that it matches exactly one, or set replace_all"}
    end
  end
end
