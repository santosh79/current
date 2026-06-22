defmodule Current.Mode do
  @type t :: :plan | :apply

  @spec valid?(term()) :: boolean()
  def valid?(arg) do
    case arg do
      :plan -> true
      :apply -> true
      _ -> false
    end
  end

  @spec default() :: t()
  def default, do: :apply
end
