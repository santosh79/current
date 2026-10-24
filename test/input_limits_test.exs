defmodule Current.InputLimitsTest do
  use ExUnit.Case, async: false

  alias Current.InputLimits

  setup do
    previous = Application.get_env(:current, :input_limits)
    on_exit(fn -> restore(previous) end)
    :ok
  end

  defp restore(nil), do: Application.delete_env(:current, :input_limits)
  defp restore(value), do: Application.put_env(:current, :input_limits, value)

  test "a value at the limit passes, one byte over fails with sizes" do
    max = InputLimits.max(:prompt)
    assert :ok = InputLimits.check(:prompt, String.duplicate("a", max))

    assert {:error, {:too_large, :prompt, size, ^max}} =
             InputLimits.check(:prompt, String.duplicate("a", max + 1))

    assert size == max + 1
  end

  test "limits are measured in bytes, not characters" do
    Application.put_env(:current, :input_limits, prompt: 4)
    # Two characters, six bytes.
    assert {:error, {:too_large, :prompt, 6, 4}} = InputLimits.check(:prompt, "éé" <> "é")
    assert :ok = InputLimits.check(:prompt, "éé")
  end

  test "nil is not this module's concern" do
    assert :ok = InputLimits.check(:model, nil)
  end

  test "a non-string input is measured by its encoded size" do
    Application.put_env(:current, :input_limits, prompt: 10)

    assert {:error, {:too_large, :prompt, _, 10}} =
             InputLimits.check(:prompt, %{"k" => String.duplicate("a", 100)})
  end

  test "config overrides one field and leaves the others at their defaults" do
    Application.put_env(:current, :input_limits, model: 8)
    assert InputLimits.max(:model) == 8
    assert InputLimits.max(:prompt) == 32_768
  end

  test "check_all stops at the first offender, in the order given" do
    Application.put_env(:current, :input_limits, model: 2, dir: 2)

    assert {:error, {:too_large, :model, 3, 2}} =
             InputLimits.check_all(prompt: "ok", model: "abc", dir: "abc")
  end

  test "check_metadata covers message and reviewed_by" do
    Application.put_env(:current, :input_limits, message: 3)
    assert :ok = InputLimits.check_metadata(%{message: "abc", reviewed_by: "me"})

    assert {:error, {:too_large, :message, 4, 3}} =
             InputLimits.check_metadata(%{message: "abcd", reviewed_by: "me"})

    assert :ok = InputLimits.check_metadata(%{via: :http})
  end

  test "check_metadata also covers a feedback key" do
    Application.put_env(:current, :input_limits, feedback: 3)

    assert {:error, {:too_large, :feedback, 4, 3}} =
             InputLimits.check_metadata(%{feedback: "abcd"})
  end

  test "check_metadata bounds the map as a whole, whatever the keys" do
    Application.put_env(:current, :input_limits, metadata: 200)

    assert :ok = InputLimits.check_metadata(%{via: :http, reviewed_by: "me"})

    # An oversized value under a key nobody checks individually.
    assert {:error, {:too_large, :metadata, size, 200}} =
             InputLimits.check_metadata(%{note: String.duplicate("a", 500)})

    assert size > 200

    # Many small keys add up too.
    many = Map.new(1..100, &{:"k#{&1}", "v"})
    assert {:error, {:too_large, :metadata, _, 200}} = InputLimits.check_metadata(many)
  end
end
