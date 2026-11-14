#!/usr/bin/env bash
set -u

QUESTIONS=(
  "A|Làm sao để validate email là duy nhất?"
  "B|Cách cấu hình Active Job với Sidekiq?"
  "C|Django ORM dùng migration thế nào?"
)
RUNS=2
OUT=docs/experiments/test_results_rerun.txt
: > "$OUT"

for item in "${QUESTIONS[@]}"; do
  label="${item%%|*}"
  q="${item#*|}"
  for run in $(seq 1 "$RUNS"); do
    echo "=== Case $label, run $run: $q" | tee -a "$OUT"
    jq -n --rawfile ctx docs/experiments/ctx.txt --rawfile sys docs/experiments/sys_v2.txt --arg q "$q" '{
      model: "qwen3:1.7b", stream: false, think: false, keep_alive: "10m",
      options: { num_ctx: 4096, temperature: 0.2, num_predict: 300 },
      messages: [
        { role: "system", content: $sys },
        { role: "user", content: ("Context:\n" + $ctx + "\n\nQuestion: " + $q) }
      ]
    }' | curl -s http://localhost:11434/api/chat -d @- \
      | jq -r '.message.content, "--- prompt_tokens=\(.prompt_eval_count) gen_tokens=\(.eval_count) total_s=\((.total_duration/1e9)|floor)"' \
      | tee -a "$OUT"
    echo | tee -a "$OUT"
  done
done
