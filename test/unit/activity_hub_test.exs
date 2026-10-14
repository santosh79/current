defmodule Current.ActivityHubTest do
  @moduledoc """
  The hub's own promises: pollers resume where they left off, a restarted
  hub is noticed, and memory stays bounded. Uses the runtime's hub with
  workflow ids of its own, so nothing else is in the way.
  """

  use ExUnit.Case, async: false

  alias Current.{ActivityHub, Intent, Observation}

  defp wf, do: "sha256:test-#{System.unique_integer([:positive])}"

  defp request(wf, round \\ 1) do
    intent = %Intent.ReadFile{id: "i", proposal_id: nil, path: "lib/a.ex"}
    ActivityHub.observe_requested(wf, round, [%Observation{id: "o", intent: intent}])
  end

  test "a subscriber hears what is reported, tagged with its workflow" do
    wf = wf()
    :ok = ActivityHub.subscribe(wf)

    request(wf)

    assert_receive {:activity, ^wf,
                    %{
                      type: :requested,
                      round: 1,
                      seq: 1,
                      entries: [%{label: "read_file lib/a.ex"}]
                    }}
  end

  test "a poller gets only what came after the sequence number it last saw" do
    wf = wf()
    request(wf, 1)
    request(wf, 2)

    assert %{epoch: epoch, items: [%{seq: 1}, %{seq: 2}], last_seq: 2} = ActivityHub.activity(wf)
    assert %{items: [%{seq: 2}]} = ActivityHub.activity(wf, epoch, 1)
    assert %{items: [], last_seq: 2} = ActivityHub.activity(wf, epoch, 2)
  end

  test "a poller that last spoke to another hub (another epoch) is given everything" do
    wf = wf()
    request(wf)
    request(wf)

    %{epoch: epoch} = ActivityHub.activity(wf)

    assert %{items: [%{seq: 1}, %{seq: 2}]} = ActivityHub.activity(wf, epoch + 1, 2)
  end

  test "each workflow keeps only its newest 100 items" do
    wf = wf()
    for round <- 1..150, do: request(wf, round)

    assert %{items: items, last_seq: 150} = ActivityHub.activity(wf)
    assert length(items) == 100
    assert hd(items).seq == 51
    assert List.last(items).seq == 150
  end

  test "only the 100 most recently active workflows are kept" do
    ids = for _ <- 1..101, do: wf()
    Enum.each(ids, &request/1)

    assert %{items: []} = ActivityHub.activity(hd(ids))
    assert %{items: [_]} = ActivityHub.activity(List.last(ids))
  end
end
