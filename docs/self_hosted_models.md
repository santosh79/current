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

## Discovery and settings

Current discovers models once at startup. Restart Current after starting the
model server or changing its models. `current models` reads the resulting
snapshot without making network requests.

The supported runtime settings are:

| Variable | Default | Purpose |
| --- | --- | --- |
| `CURRENT_LOCAL_LLM_BASE_URL` | unset (off) | API root including `/v1` |
| `CURRENT_LOCAL_LLM_API_KEY` | unset | Optional Bearer token |
| `CURRENT_LOCAL_LLM_MAX_TOKENS` | `16000` | Output-token limit per model call |

Empty values count as unset. Current sends ordinary non-streaming Chat
Completions requests without a `response_format`; the proposal schema is already
included in the prompt and malformed replies use the normal repair loop.
Use the runtime-wide timeout configuration or `--timeout-minutes` for slow
models.

## Model quality and context

The schema, project layout, observed file contents, earlier turns and the
generated output must all fit in the model's context window. A reply cut off by
the output limit (`finish_reason: length`) fails with a message saying so; Current
never tries to decode partial JSON. Leading `<think>` blocks of reasoning models
are removed, and the usage reported by the server, including reasoning tokens,
is recorded.

Instruction-tuned coding models such as Qwen2.5-Coder-Instruct are reasonable
starting points, not a guarantee of schema compliance. Small models benefit from narrow tasks. Test both kinds of reply—a request to
see files and a proposal—with your chosen server and model.

## Transport safety

Hosted providers stay HTTPS-only. The `local` provider also permits HTTP
because its base URL is trusted operator configuration. HTTP sends prompts,
source code and any API key in cleartext, so use it only on a network you trust.
Redirects are not followed, and credentials, queries and fragments in the base
URL are refused. Internal HTTPS endpoints may configure the `cacerts`
application setting of `Current.LLMClient.HTTP` without disabling certificate
or hostname verification.
