# Rails Guides Q&A Assistant (RAG)

A small question-answering assistant over the [Rails Guides](https://guides.rubyonrails.org/).
You ask in Vietnamese, it retrieves the most relevant guide sections and a local LLM answers from them.

Built from scratch (no LangChain or other RAG framework) as a learning project:
chunking, embedding, retrieval, prompt assembly and generation are all plain Ruby.

- **Zero running cost:** everything runs locally (Ollama + Postgres). No paid API is called.
- **Stack:** Rails 8, PostgreSQL + pgvector (via the `neighbor` gem), Ollama.
- **Models:** `bge-m3` for embeddings (1024 dimensions), `qwen3:1.7b` (Q4_K_M) for chat, CPU only.
- **Corpus:** TODO: number of guide files (25-30), 2110 chunks.

## How it works

```
question
  -> embed (bge-m3 via Ollama)
  -> Rag::Retriever    cosine nearest neighbors in pgvector, top k chunks
  -> Rag::PromptBuilder  numbered excerpts + rules -> system/user messages
  -> Rag::OllamaClient#chat   qwen3:1.7b, think: false, low temperature
  -> answer + retrieved sources (sources are printed by code, not by the model)
```

Key parameters (see `app/services/rag/`):

| Parameter | Value |
|---|---|
| Distance | cosine |
| Default k | 5 |
| `num_ctx` | 4096 |
| `num_predict` | 512 |
| `temperature` | 0.2 |
| `think` | false |
| `keep_alive` | 10m |

If the excerpts do not contain the answer, the model is instructed to reply with the sentinel
`NO_ANSWER`; the code then prints a fixed Vietnamese refusal message instead.

## Requirements

- Ruby and Rails as specified in `.ruby-version` / `Gemfile`
- PostgreSQL with the `pgvector` extension
- [Ollama](https://ollama.com/) with the two models pulled:
  ```bash
  ollama pull bge-m3
  ollama pull qwen3:1.7b
  ```
- About 2.5 GB of free RAM for the chat model (measured: 1.9 GB loaded, 2.4 GB with `num_ctx` 8192)

## Setup

TODO: replace with the real commands from the repo.

```bash
bundle install
bin/rails db:create db:migrate
# TODO: task that loads the guides into the database
# TODO: task that chunks documents
# TODO: task that embeds chunks (TODO: measured time for 2110 chunks on this machine)
```

Environment variables (all optional):

| Variable | Default |
|---|---|
| `OLLAMA_URL` | `http://localhost:11434` |
| `OLLAMA_EMBED_MODEL` | `bge-m3` |
| `OLLAMA_CHAT_MODEL` | `qwen3:1.7b` |

## Usage

```bash
bin/rails rag:ask Q="Làm sao để validate uniqueness theo scope trong Active Record?"
bin/rails rag:ask Q="Cách deploy Rails lên Kubernetes bằng Helm?" K=3
```

A `[debug]` line is printed to stderr with `top1_distance`, token counts and elapsed time.

### Docker Compose

TODO: fill in after the Compose setup is verified on a clean machine
(Ollama on the host vs. an `ollama` service, how models are pulled, how the database is seeded).

## Measurements

Observed on a CPU-only machine (manual runs, small sample, not a benchmark):

| Item | Value |
|---|---|
| Generation speed | about 9-13 tokens/s |
| Prompt processing | about 90 tokens/s |
| RAG prompt size (k=5) | about 1200-1600 tokens |
| Time per answer | about 6-53 s |

Sample runs of `rag:ask`:

| Question | top-1 distance | Result |
|---|---|---|
| uniqueness with scope (answerable) | 0.268 | answered, with errors (see below) |
| Kubernetes + Helm (not in docs) | 0.354 | refused correctly |
| "Thủ đô của Pháp là gì?" (unrelated) | 0.627 | refused correctly |

Three data points are not enough to pick a distance threshold, so none is used.
Refusal currently relies on the model following the prompt.

## Known limitations

- **Small model, unreliable details.** `qwen3:1.7b` sometimes invents code (for example options or
  examples that are not in the excerpts), mislabels a method name, or distorts a caveat.
  In a few runs on the same question the unique-index caveat was correct once and distorted in others.
  Answers vary between runs even at low temperature. Treat the answer as a summary and check the sources.
- **Refusal is only lightly tested.** 2 out-of-context questions were refused correctly after a fix;
  the model often adds an explanation around `NO_ANSWER`, so the code treats any occurrence of the token as a refusal.
  If the model ever writes a real answer and also includes the token, the user sees the refusal message.
- **Retrieval is not systematically evaluated.** TODO: number of pilot questions and results.
  One known miss (Q2) fails at retrieval.
- **Low-value chunks.** Some chunks contain only link definitions and take a context slot.
- **"Retrieved from" is not "used".** The listed sources are the retrieved chunks, not necessarily the ones the model used.
- **Prompt injection.** Excerpts are marked as untrusted data in the prompt, and the closing context tag is stripped
  from chunks, but a small model can still be steered by text inside excerpts. The corpus is the official Rails Guides,
  so the risk here is low.
- **CPU only.** Answers take tens of seconds.

## Experiments

Prompt experiments (`sys_v1`, `sys_v2`) and their results are in [`docs/experiments/`](docs/experiments/).

## License and attribution

The Rails Guides content is by the Rails contributors and is licensed under
[CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/).
TODO: record the Rails Guides source version/commit used and what was changed (chunking, light cleanup of link syntax).
Answers produced by this project are derived from that content.

TODO: license for the code in this repository.
