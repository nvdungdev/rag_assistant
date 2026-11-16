# Rails Guides Q&A Assistant (RAG)

A small question-answering assistant over the [Rails Guides](https://guides.rubyonrails.org/).
You ask in Vietnamese, it retrieves the most relevant guide sections and a local LLM answers from them.

Built from scratch (no LangChain or other RAG framework) as a learning project:
chunking, embedding, retrieval, prompt assembly and generation are all plain Ruby.

- **Zero running cost:** everything runs locally (Ollama + Postgres). No paid API is called.
- **Stack:** Rails 8.1, Ruby 3.4.1, PostgreSQL + pgvector (via the `neighbor` gem), Ollama.
- **Models:** `bge-m3` for embeddings (1024 dimensions), `qwen3:1.7b` (Q4_K_M) for chat, CPU only.
- **Corpus:** 28 Rails Guides documents, 2110 chunks.
- **Interface:** command line (`rake rag:ask`). There is no web UI.

## How it works

```
question
  -> embed (bge-m3 via Ollama)
  -> Rag::Retriever       cosine nearest neighbors in pgvector, top k chunks
  -> Rag::PromptBuilder   numbered excerpts + rules -> system/user messages
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
`NO_ANSWER`. If the reply contains that token, the code prints a fixed Vietnamese refusal message instead.

## Requirements

- Ruby 3.4.1 and Rails 8.1 (see `.ruby-version` and `Gemfile`)
- PostgreSQL with the `pgvector` extension
- [Ollama](https://ollama.com/) with the two models pulled:
  ```bash
  ollama pull bge-m3
  ollama pull qwen3:1.7b
  ```
- About 2.5 GB of free RAM for the chat model (measured: 1.9 GB loaded, 2.4 GB with `num_ctx` 8192)

Prefer Docker? Skip to [Docker Compose](#docker-compose).

## Setup (without Docker)

By default `config/database.yml` connects to `localhost:5433` as user `rag` / password `rag`.
The easiest way to get a matching database is the Compose `db` service: `docker compose up -d db`.
Otherwise set the `DB_*` variables below.

```bash
bundle install
bin/rails db:create db:migrate
```

The guides are not committed (`data/guides/` is git-ignored). To rebuild them from the Rails repository:

```bash
git clone --filter=blob:none --no-checkout https://github.com/rails/rails.git /tmp/rails-src
cd /tmp/rails-src
git sparse-checkout set guides/source
git checkout bdb3d960121e7eb73a61c04099d1eef3c821e397
cd -
mkdir -p data/guides
while read -r f; do cp "/tmp/rails-src/guides/source/$f" data/guides/; done < data/manifest.txt
```

Then run the pipeline:

```bash
bin/rails rag:load_documents   # loads the guides listed in data/manifest.txt (idempotent)
bin/rails rag:chunk            # idempotent
bin/rails rag:embed            # resumable; options: LIMIT=n BATCH=n
```

Embedding all 2110 chunks took about 2021 s (about 34 minutes) on CPU on the development machine.
The Docker section below restores a pre-embedded dump instead.

Environment variables (all optional):

| Variable | Default |
|---|---|
| `OLLAMA_URL` | `http://localhost:11434` |
| `OLLAMA_EMBED_MODEL` | `bge-m3` |
| `OLLAMA_CHAT_MODEL` | `qwen3:1.7b` |
| `DB_HOST` | `localhost` |
| `DB_PORT` | `5433` |
| `DB_USER` | `rag` |
| `DB_PASSWORD` | `rag` |

## Usage

```bash
bin/rails rag:ask Q="Làm sao để validate uniqueness theo scope trong Active Record?"
bin/rails rag:ask Q="Cách deploy Rails lên Kubernetes bằng Helm?" K=3
```

A `[debug]` line is printed to stderr with `top1_distance`, token counts and elapsed time.

## Docker Compose

Requirements: Docker with Compose v2.24+ (check with `docker compose version`).
The chat model alone needs about 2 GB of RAM when loaded (1.9 GB measured on the host), plus Postgres and Rails.
If Docker limits memory (for example Docker Desktop), raise the limit accordingly.

Restore the pre-embedded database first (the dump contains the 2110 embedded chunks),
so you do not have to run the embedding step on CPU:

```bash
docker compose up -d db
docker compose exec -T db createdb -U rag rag_assistant_development
docker compose exec -T db pg_restore -U rag -d rag_assistant_development --no-owner < db/dumps/rag_dev.dump
```

Start everything and pull the models (about 2.6 GB download, stored in the `ollama` volume):

```bash
docker compose up -d --build
docker compose exec ollama ollama pull bge-m3
docker compose exec ollama ollama pull qwen3:1.7b
```

Ask a question:

```bash
docker compose exec web bin/rails rag:ask Q="Làm sao để validate uniqueness theo scope trong Active Record?"
```

This setup was tested end to end on a fresh clone.

Notes:
- Compose uses `Dockerfile.dev`. The root `Dockerfile` is the Rails production image and is not used here.
- Ports `5433` (Postgres) and `3000` (Rails) are bound to `127.0.0.1` only, and Ollama is not published to the host.
  If those ports are already in use (for example by another copy of this project), stop the other stack first.
- The database credentials (`rag` / `rag`) are for local demo use only.
- `docker compose down -v` deletes the database volume. Restore the dump again afterwards.
- On Linux, files the `web` container creates under `tmp/` are owned by root on the host.
  If that gets in the way: `sudo chown -R "$USER:$USER" tmp`.
- The dump is derived from the Rails Guides (CC BY-SA 4.0), see [License and attribution](#license-and-attribution).

## Measurements

Observed on a CPU-only machine (manual runs, small sample, not a benchmark):

| Item | Value |
|---|---|
| Generation speed | about 9-13 tokens/s |
| Prompt processing | about 90 tokens/s |
| RAG prompt size (k=5) | about 1200-1600 tokens |
| Time per answer | about 6-60 s (the longest were in Docker, the first one including model load) |
| Embedding all 2110 chunks | about 2021 s |

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
  On the same question, across several runs, every run had a different mistake, and the unique-index
  caveat was correct in only some of them. Answers vary between runs even at low temperature,
  and some answers repeat themselves. Treat the answer as a summary and check the sources.
- **Refusal is only lightly tested.** 2 out-of-context questions were refused correctly after a fix.
  The model often adds an explanation around `NO_ANSWER`, so the code treats any occurrence of the token as a refusal.
  If the model ever writes a real answer and also includes the token, the user sees the refusal message.
- **Retrieval is only lightly evaluated.** It was checked on a pilot set of 8 hand-written Vietnamese questions
  (`data/eval_pilot.yml`, 204 chunks from 3 guides). Two questions hit rank 1; one (allowing other-domain clients
  to an Action Cable server) missed the top 8, with the right chunk at rank 26 of 2110.
  There is no larger evaluation and no recall@k measurement.
- **Low-value chunks.** Some chunks contain only link definitions and take a context slot.
- **"Retrieved from" is not "used".** The listed sources are the retrieved chunks, not necessarily the ones the model used.
- **Prompt injection.** Excerpts are marked as untrusted data in the prompt, and the closing context tag is stripped
  from chunks, but a small model can still be steered by text inside excerpts. The corpus is the official Rails Guides,
  so the risk here is low.
- **CPU only.** Answers take tens of seconds.

## Experiments

Prompt experiments (`sys_v1`, `sys_v2`) and their results are in [`docs/experiments/`](docs/experiments/).
`test_results_v2.txt` was reconstructed from terminal output.

## License and attribution

### Rails Guides content

The documents come from the Rails Guides by the Rails contributors, licensed under
[CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/).
Source: the markdown files in `guides/source` of https://github.com/rails/rails, commit
`bdb3d960121e7eb73a61c04099d1eef3c821e397`. 28 of the 76 files are used (see `data/manifest.txt`).
Links in the app point to the published guides at https://guides.rubyonrails.org.

Changes made by this project: the files are stored unchanged, then split into chunks and embedded.
At question time, reference-style link syntax (`[text][]`) is stripped from excerpts before they go into the prompt.

The database dump in `db/dumps/` and the answers produced by this assistant are derived from this content.

### Code

No license has been chosen yet for the code in this repository. All rights reserved by the author.
