# Using self-hosted models

Current supports one self-hosted, OpenAI-compatible endpoint as provider
`local`. Its models are named `local:<model-id>` and appear in `current models`
next to the hosted ones. It uses `GET /models` and `POST /chat/completions`, not
the Responses API, which Ollama, vLLM, llama.cpp, LM Studio and gateways such as
LiteLLM all serve.

The review, approval, revision, and application steps are identical to those for
hosted models; only the model that writes the proposal changes. Current does not
start or install a model server.

Set the variables below in the **runtime server's environment**, not just the
CLI's. They are read on every call, so a change takes effect without a restart.
With no `CURRENT_LOCAL_LLM_BASE_URL` the provider is off and contributes no
models.

## Ollama

Start Ollama and pull a model:

```sh
ollama serve
# In another terminal:
ollama pull qwen2.5-coder:32b
```

Ollama gives models a 4096-token context window unless told otherwise, and it
silently cuts a longer prompt. Current's prompt carries a schema, the project
layout and the files the model asked to see, so raise it. Set it for the
server:

```sh
OLLAMA_CONTEXT_LENGTH=32768 ollama serve
```

or build a model with the size baked in, with a Modelfile containing
`FROM qwen2.5-coder:32b` and `PARAMETER num_ctx 32768`, and use that model's id
in Current. Ollama's OpenAI-compatible endpoint may ignore native request
fields such as `num_ctx`, so do not rely on `CURRENT_LOCAL_LLM_EXTRA_FIELDS` for
this.

Start Current with Ollama's OpenAI-compatible URL (include `/v1`):

```sh
export CURRENT_LOCAL_LLM_BASE_URL=http://127.0.0.1:11434/v1
export CURRENT_LOCAL_LLM_PROPOSAL_TIMEOUT_MS=600000
export CURRENT_LOCAL_LLM_TASK_TIMEOUT_MS=1800000
bin/current-server
```

Then, from another terminal:

```sh
current models
current plan "Explain the error and propose a fix" --model local:qwen2.5-coder:32b
```

## vLLM

```sh
vllm serve Qwen/Qwen2.5-Coder-32B-Instruct --host 127.0.0.1 --port 8000 --max-model-len 32768
export CURRENT_LOCAL_LLM_BASE_URL=http://127.0.0.1:8000/v1
bin/current-server
```

Use the exact model id `current models` prints, for example
`local:Qwen/Qwen2.5-Coder-32B-Instruct`. If the server needs a key, set
`CURRENT_LOCAL_LLM_API_KEY`; it is sent as a Bearer token. A gateway such as
LiteLLM can put several backends behind this one endpoint.

## Discovery

Current discovers models in the background once at startup. `current models`
reads the current snapshot without making network requests. After starting a
model server or adding/removing a model, explicitly refresh the catalog:

```sh
current models --refresh
```

Only successful provider discoveries replace that provider's models; temporary
connection failures retain the previous snapshot. Unsetting
`CURRENT_LOCAL_LLM_BASE_URL` and refreshing clears the `local:*` entries.
The HTTP API also accepts `GET /v1/models?refresh=true` for an explicit refresh.

## Output compatibility and limits

All variables below start with `CURRENT_LOCAL_LLM_`:

| Suffix | Default | Purpose |
| --- | --- | --- |
| `BASE_URL` | unset (off) | API root including `/v1` |
| `API_KEY` | unset | Optional Bearer token |
| `RESPONSE_FORMAT` | `auto` | `auto`, `json_schema`, `json`, or `none` |
| `JSON_SCHEMA_STRICT` | `false` | `true` only if the server supports the whole schema strictly |
| `MAX_TOKENS` | `16000` | Output-token limit per model call |
| `PROPOSAL_TIMEOUT_MS` | runtime's per-call limit | Limit on one model call |
| `TASK_TIMEOUT_MS` | runtime's per-task limit | Limit on the whole proposal conversation |
| `EXTRA_FIELDS` | `{}` | JSON object merged into every request, for server-specific options |
| `ALLOW_HTTP_HOSTNAMES` | unset | `true` permits unencrypted HTTP to a trusted hostname |

An empty variable counts as unset. A malformed one, such as `MAX_TOKENS=0` or
`RESPONSE_FORMAT=typo`, fails the call with the name of the setting before any
request is sent.

`auto` sends Current's canonical proposal schema first, as `json_schema`. If the
server rejects that, it falls back to JSON-object mode and then to no
response-format field. It does so only for HTTP 400 or 422 errors that name
`response_format` or `json_schema`. Context-window errors, authentication
failures, timeouts and unrelated errors are never retried. Every attempt may use
all the time that is left of the call's limit, and a retry never extends it.
The explicit modes do not negotiate. Each call probes from the first format;
no response-format cache is maintained.

`none` removes even a `response_format` supplied in `EXTRA_FIELDS`. The fields
that belong to the protocol (model, messages, streaming, the output limit and
the response format) cannot be overridden by it. A server that documents
native options on its compatible endpoint can take them through it, for example
`CURRENT_LOCAL_LLM_EXTRA_FIELDS='{"options":{"num_ctx":32768}}'`; check the
server's documentation, because unsupported fields may be ignored or rejected.

A task's explicit `--timeout-minutes` still overrides the whole-task limit. The
CLI waits for as long as the runtime reports for a task; if you set a local
default beyond that, pass `--timeout-minutes` too so the CLI keeps waiting.

## Model quality and context

The schema, project layout, observed file contents, earlier turns and the
generated output must all fit in the model's context window. A reply cut off by
the output limit (`finish_reason: length`) fails with a message saying so; Current
never tries to decode partial JSON. Leading `<think>` blocks of reasoning models
are removed, and the usage reported by the server, including reasoning tokens,
is recorded.

Instruction-tuned coding models such as Qwen2.5-Coder-Instruct are reasonable
starting points, not a guarantee of schema compliance. Small models often need
schema-constrained decoding and narrow tasks. Try both kinds of reply, a request
to see files and a proposal, with your server and model: support for strict
schemas varies, because Current's schema has references, unions and
conditionals.

## Transport safety

Hosted providers stay HTTPS-only. For `local`, plain HTTP is allowed by default
only to a literal loopback, RFC 1918 or IPv6 unique-local address, or to
`localhost`, which is pinned to `127.0.0.1`. IPv6 loopback is written `[::1]`.
Public IP addresses need HTTPS.

A Docker or LAN hostname (`http://ollama:11434/v1`,
`http://host.docker.internal:11434/v1`) needs an explicit
`CURRENT_LOCAL_LLM_ALLOW_HTTP_HOSTNAMES=true`. That trusts your DNS and sends
prompts, including your source code, and any API key unencrypted; do not enable
it on a network you do not trust. Redirects are never followed. Credentials,
queries and fragments in the base URL are refused. For an internal HTTPS
endpoint with a private CA, the `cacerts` application setting of
`Current.LLMClient.HTTP` is supported without disabling certificate or hostname
verification.
