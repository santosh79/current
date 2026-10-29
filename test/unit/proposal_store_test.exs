defmodule Current.ProposalStoreTest do
  use ExUnit.Case, async: false

  import Current.TestHelpers

  alias Current.{EventStore, ProposalStore}

  test "produced_after/2 follows commit positions and respects cursor and limit" do
    baseline = EventStore.latest_position()

    {_task1, workflow1, proposal1} =
      submit_and_await_valid_proposal(input: "first ordered proposal")

    {_task2, workflow2, proposal2} =
      submit_and_await_valid_proposal(input: "second ordered proposal")

    refute workflow1 == workflow2

    rows = ProposalStore.produced_after(baseline)
    assert Enum.map(rows, &elem(&1, 1)) == [proposal1.id, proposal2.id]

    [{first_position, _}, {second_position, _}] = rows
    assert first_position < second_position

    assert ProposalStore.produced_after(first_position) == [
             {second_position, proposal2.id}
           ]

    assert ProposalStore.produced_after(baseline, 1) == [
             {first_position, proposal1.id}
           ]
  end
end
