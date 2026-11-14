# Chat model experiments

- Model: qwen3:1.7b (Q4_K_M) via Ollama, CPU only. Settings: think=false, num_ctx=4096, temperature=0.2.
- Prompts: sys_v1.txt, sys_v2.txt.
- Results: test_results_v2.txt was reconstructed from terminal output (the original file was lost). Model outputs are verbatim.
- ctx.txt is not committed. Regenerate it from the repo root with:

```bash
bin/rails runner '
  q = "Làm sao để validate email là duy nhất?"
  puts Rag::Retriever.new(k: 5).call(q).map { |r| r.chunk.content }.join("\n\n---\n\n")
' > docs/experiments/ctx.txt
```

- Re-run from the repo root: `docs/experiments/run_tests.sh` (output goes to test_results_rerun.txt).
- Results vary between runs (sampling), and a regenerated ctx.txt may differ slightly from the original, so a re-run is not directly comparable to test_results_v2.txt.
