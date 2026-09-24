defmodule Current.ProposalDecoderTest do
  use ExUnit.Case, async: false

  alias Current.{BlobStore, Id, Intent, Proposal, ProposalDecoder, Test.MiniJsonSchema}

  @wire_schema_path Path.join([__DIR__, "..", "priv", "schema", "proposal_response.schema.json"])

  @well_formed_fixtures [
    ~s({
      "justification": "add email validation",
      "claims": ["emails are validated"],
      "dependencies": [],
      "intents": [
        {"ref": "cmd_1", "type": "run_command", "cmd": "mix", "args": ["test"]},
        {"type": "claim", "statement": "tests pass",
         "evidence": {"source_intent_ref": "cmd_1", "condition": "exit_code_equals", "value": 0}}
      ]
    }),
    ~s({
      "intents": [
        {"type": "write_file", "path": "lib/x.ex", "contents": "defmodule X do\\nend\\n"},
        {"type": "file_patch", "path": "lib/y.ex", "diff": "--- a\\n+++ b\\n"}
      ]
    }),
    ~s({"intents": [{"type": "run_command", "cmd": "echo"}]}),
    ~s({"intents": [{"type": "glob", "pattern": "*.ex"}]}),
    ~s({"intents": []}),
    ~s({
      "intents": [
        {"ref": "patch_1", "type": "file_patch", "path": "lib/signup.ex", "diff": "--- a\\n+++ b\\n"},
        {"ref": "cmd_1", "type": "run_command", "cmd": "mix", "args": ["test"]},
        {"type": "claim", "statement": "tests pass",
         "evidence": {"source_intent_ref": "cmd_1", "condition": "exit_code_equals", "value": 0}}
      ]
    })
  ]

  defp workflow_id, do: Id.generate()

  describe "decode/2 - well-formed input" do
    test "decodes a full proposal with multiple intent types and an ordered claim" do
      json = ~s({
        "justification": "add email validation",
        "claims": ["emails are validated"],
        "dependencies": [],
        "intents": [
          {"ref": "cmd_1", "type": "run_command", "cmd": "mix", "args": ["test"]},
          {"type": "claim", "statement": "tests pass",
           "evidence": {"source_intent_ref": "cmd_1", "condition": "exit_code_equals", "value": 0}}
        ]
      })

      assert {:ok, %Proposal{} = proposal} = ProposalDecoder.decode(json, workflow_id())

      assert proposal.justification == "add email validation"
      assert proposal.claims == ["emails are validated"]
      assert proposal.dependencies == []
      assert length(proposal.intents) == 2

      [cmd, claim] = proposal.intents
      assert %Intent.RunCommand{cmd: "mix", args: ["test"]} = cmd
      assert %Intent.Claim{statement: "tests pass", evidence: evidence} = claim
      assert evidence.source_intent_id == cmd.id
      assert evidence.condition == :exit_code_equals
      assert evidence.value == 0

      assert cmd.proposal_id == proposal.id
      assert claim.proposal_id == proposal.id
    end

    test "write_file and file_patch persist inline content to BlobStore" do
      json = ~s({
        "intents": [
          {"type": "write_file", "path": "lib/x.ex", "contents": "defmodule X do\\nend\\n"},
          {"type": "file_patch", "path": "lib/y.ex", "diff": "--- a\\n+++ b\\n"}
        ]
      })

      assert {:ok, %Proposal{intents: [write, patch]}} =
               ProposalDecoder.decode(json, workflow_id())

      assert {:ok, "defmodule X do\nend\n"} = BlobStore.read(write.contents_artifact_id)
      assert {:ok, "--- a\n+++ b\n"} = BlobStore.read(patch.diff_artifact_id)
    end

    test "run_command defaults args to [] when omitted" do
      json = ~s({"intents": [{"type": "run_command", "cmd": "echo"}]})

      assert {:ok, %Proposal{intents: [%Intent.RunCommand{args: []}]}} =
               ProposalDecoder.decode(json, workflow_id())
    end

    test "glob defaults base_dir to \".\" when omitted" do
      json = ~s({"intents": [{"type": "glob", "pattern": "*.ex"}]})

      assert {:ok, %Proposal{intents: [%Intent.Glob{base_dir: "."}]}} =
               ProposalDecoder.decode(json, workflow_id())
    end

    test "optional top-level fields default to nil when absent" do
      json = ~s({"intents": []})

      assert {:ok, %Proposal{justification: nil, claims: nil, dependencies: nil, intents: []}} =
               ProposalDecoder.decode(json, workflow_id())
    end

    test "sets the given workflow_id and generates a fresh proposal id each call" do
      wid = workflow_id()
      json = ~s({"intents": []})

      assert {:ok, %Proposal{id: id1, workflow_id: ^wid}} = ProposalDecoder.decode(json, wid)
      assert {:ok, %Proposal{id: id2, workflow_id: ^wid}} = ProposalDecoder.decode(json, wid)
      refute id1 == id2
    end
  end

  describe "decode/2 - malformed input" do
    test "invalid JSON" do
      assert {:error, reason} = ProposalDecoder.decode("not json at all {{{", workflow_id())
      assert reason =~ "not valid JSON"
    end

    test "top-level not an object" do
      assert {:error, reason} = ProposalDecoder.decode(~s(["just", "an", "array"]), workflow_id())
      assert reason =~ "must be a JSON object"
    end

    test "missing intents key" do
      assert {:error, reason} = ProposalDecoder.decode(~s({"justification": "x"}), workflow_id())
      assert reason =~ "must be a JSON array"
    end

    test "intents not an array" do
      assert {:error, reason} = ProposalDecoder.decode(~s({"intents": "nope"}), workflow_id())
      assert reason =~ "must be a JSON array"
    end

    test "an intent entry that is not an object" do
      assert {:error, reason} = ProposalDecoder.decode(~s({"intents": ["nope"]}), workflow_id())
      assert reason =~ "must be a JSON object"
    end

    test "unknown intent type" do
      json = ~s({"intents": [{"type": "teleport", "path": "x"}]})
      assert {:error, reason} = ProposalDecoder.decode(json, workflow_id())
      assert reason =~ "unknown intent type"
    end

    test "intent missing type" do
      json = ~s({"intents": [{"path": "x"}]})
      assert {:error, reason} = ProposalDecoder.decode(json, workflow_id())
      assert reason =~ "missing required field: type"
    end

    test "missing required field for a known type" do
      json = ~s({"intents": [{"type": "read_file"}]})
      assert {:error, reason} = ProposalDecoder.decode(json, workflow_id())
      assert reason =~ "path"
    end

    test "claim with no evidence decodes with evidence: nil, leaving rejection to IntentValidator" do
      json = ~s({"intents": [{"type": "claim", "statement": "x"}]})

      assert {:ok, %Proposal{intents: [%Intent.Claim{evidence: nil}]}} =
               ProposalDecoder.decode(json, workflow_id())
    end

    test "claim evidence referencing an unknown ref" do
      json = ~s({
        "intents": [
          {"type": "claim", "statement": "x",
           "evidence": {"source_intent_ref": "does_not_exist", "condition": "exit_code_equals", "value": 0}}
        ]
      })

      assert {:error, reason} = ProposalDecoder.decode(json, workflow_id())
      assert reason =~ "unknown ref"
    end

    test "two intents sharing a ref" do
      json = ~s({"intents": [
        {"ref": "cmd_1", "type": "run_command", "cmd": "mix", "args": ["test"]},
        {"ref": "cmd_1", "type": "run_command", "cmd": "npm", "args": ["test"]},
        {"type": "claim", "statement": "tests pass",
         "evidence": {"source_intent_ref": "cmd_1", "condition": "exit_code_equals", "value": 0}}
      ]})

      assert {:error, reason} = ProposalDecoder.decode(json, workflow_id())
      assert reason =~ ~s(duplicate intent ref "cmd_1")
    end

    test "a duplicate ref is rejected even when nothing cites it" do
      json = ~s({"intents": [
        {"ref": "r", "type": "read_file", "path": "a.ex"},
        {"ref": "r", "type": "read_file", "path": "b.ex"}
      ]})

      assert {:error, reason} = ProposalDecoder.decode(json, workflow_id())
      assert reason =~ "duplicate intent ref"
    end

    test "claim evidence with an unrecognized condition" do
      json = ~s({
        "intents": [
          {"ref": "cmd_1", "type": "run_command", "cmd": "echo"},
          {"type": "claim", "statement": "x",
           "evidence": {"source_intent_ref": "cmd_1", "condition": "made_up_condition", "value": 0}}
        ]
      })

      assert {:error, reason} = ProposalDecoder.decode(json, workflow_id())
      assert reason =~ "unknown claim condition"
    end

    test "a forward reference (claim before the intent it cites) still decodes -- ordering is IntentValidator's job" do
      json = ~s({
        "intents": [
          {"type": "claim", "statement": "x",
           "evidence": {"source_intent_ref": "cmd_1", "condition": "exit_code_equals", "value": 0}},
          {"ref": "cmd_1", "type": "run_command", "cmd": "echo"}
        ]
      })

      assert {:ok, %Proposal{intents: [claim, cmd]}} = ProposalDecoder.decode(json, workflow_id())
      assert claim.evidence.source_intent_id == cmd.id
    end
  end

  describe "wire schema conformance" do
    setup do
      schema = @wire_schema_path |> File.read!() |> :json.decode()
      %{schema: schema}
    end

    test "the published schema file parses and has the expected top-level shape", %{
      schema: schema
    } do
      assert %{"type" => "object", "required" => ["intents"], "definitions" => definitions} =
               schema

      assert is_map(definitions)
    end

    test "every well-formed fixture used in this file validates against the published schema", %{
      schema: schema
    } do
      for fixture <- @well_formed_fixtures do
        decoded = :json.decode(fixture)

        assert :ok = MiniJsonSchema.validate(schema, decoded),
               "fixture failed schema validation: #{fixture}"

        # Belt and suspenders: anything that validates against the schema
        # must also actually decode -- if these two ever disagree, either
        # the schema or the decoder has drifted from docs/wire_schema.md.
        assert {:ok, %Proposal{}} = ProposalDecoder.decode(fixture, workflow_id())
      end
    end

    test "a response missing the required top-level intents key fails schema validation", %{
      schema: schema
    } do
      decoded = :json.decode(~s({"justification": "x"}))
      assert {:error, _errors} = MiniJsonSchema.validate(schema, decoded)
    end

    test "an intent missing its type-specific required field fails schema validation", %{
      schema: schema
    } do
      decoded = :json.decode(~s({"intents": [{"type": "read_file"}]}))
      assert {:error, _errors} = MiniJsonSchema.validate(schema, decoded)
    end

    test "an unknown intent type fails schema validation", %{schema: schema} do
      decoded = :json.decode(~s({"intents": [{"type": "teleport", "path": "x"}]}))
      assert {:error, _errors} = MiniJsonSchema.validate(schema, decoded)
    end

    test "an unknown claim condition fails schema validation", %{schema: schema} do
      decoded =
        :json.decode(~s({
          "intents": [
            {"ref": "cmd_1", "type": "run_command", "cmd": "echo"},
            {"type": "claim", "statement": "x",
             "evidence": {"source_intent_ref": "cmd_1", "condition": "made_up", "value": 0}}
          ]
        }))

      assert {:error, _errors} = MiniJsonSchema.validate(schema, decoded)
    end
  end
end
