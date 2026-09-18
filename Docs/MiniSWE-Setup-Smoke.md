# MiniSWE-Setup-Smoke — mini-swe-agent + Ollama Cloud DeepSeek V4.1 Flash

**Status: MINI_SWE_SMOKE_PASS** — 2026-09-15

Isolated install, configuration, and bounded end-to-end smoke test of
[mini-swe-agent](https://github.com/SWE-agent/mini-swe-agent) driving
DeepSeek V4.1 Flash through the existing Ollama Cloud provider, plus a
reusable launcher for a later frozen-snapshot Attic review. All tooling
lives outside the repo at `/Users/taha/Developer/attic-miniswe-tools`
(no Attic source, tests, or reviewer files were read or modified; no
commits made).

## Versions

| component | version |
| --- | --- |
| mini-swe-agent (pinned PyPI release) | 2.4.6 (released 2026-07-23) |
| litellm | 1.101.0 |
| openai python sdk | 2.54.0 |
| pydantic | 2.13.5 |
| interpreter | uv-managed CPython 3.12.13 |
| uv | 0.11.7 |

Install: `uv venv venv --python 3.12 && uv pip install --python ./venv/bin/python "mini-swe-agent==2.4.6"`
inside `/Users/taha/Developer/attic-miniswe-tools`. No global packages,
no dependency upgrades, no model weights downloaded (cloud model).

## Endpoint and model

- Endpoint: `https://ollama.com/v1` (Ollama Cloud, OpenAI-compatible chat
  completions) — matches OpenCode's `ollama-cloud` provider
  (`models.dev` registry entry: `api: https://ollama.com/v1`,
  `env: OLLAMA_API_KEY`).
- litellm model string: `openai/deepseek-v4.1-flash` with
  `api_base: https://ollama.com/v1`.
- Auth: existing OpenCode `ollama-cloud` API key, read at launch time from
  `~/.local/share/opencode/auth.json` and exported as `OPENAI_API_KEY`
  into the launcher process only. The overlay config sets
  `environment.env.OPENAI_API_KEY: ""` so the key is scrubbed from the
  agent's own subshells. Verified: no run artifact contains the key.
  No OpenCode/Synara/Ollama configuration was changed.

## Reasoning: requested vs confirmed

- `models.dev` advertises for this model: `reasoning: true`, effort
  values `low | high | max`. **Configured: `reasoning_effort: "max"`
  (the maximum supported value).**
- **Serialized request verified** (offline localhost capture,
  `probes/capture_evidence.txt`): litellm sends literal top-level
  `"reasoning_effort": "max"` in the `POST /v1/chat/completions` body,
  alongside `tools: [bash]` — even with `drop_params: true` (litellm
  treats it as a supported param for the `openai` provider, so it is
  not stripped).
- **Confirmed server behavior**: real calls return HTTP 200 and every
  assistant message carries non-empty `reasoning_content`. Caveat: the
  endpoint accepts `max` without error and reasons visibly, but does not
  echo the applied effort level, so the distinction between `high` and
  `max` is taken on the provider's contract, not independently verified.

## Cost/limits plumbing

`config/litellm_registry.json` registers real pricing
($0.15/$0.60 per 1M tokens in/out, $0.003 cache-read — from models.dev)
so `agent.cost_limit` is a real bound. Per-run bounds:
`agent.step_limit` (default 20), `agent.wall_time_limit_seconds`
(default 600), `agent.cost_limit` (default $0.50),
`MSWEA_GLOBAL_CALL_LIMIT` (step_limit+5), 120s per-request HTTP timeout,
`environment.timeout` 60s per command.

## Smoke test (run `smoke1`, all artifacts under `attic-miniswe-tools/runs/smoke1/`)

Disposable fixture: `calc.py` with a planted bug (`add` returns `a - b`)
+ `test_calc.py` (dependency-free, deterministic; fails with exit 1).
Run against a copied workspace; pristine fixture untouched.

Command:

```bash
bin/run_miniswe.sh runs/smoke1/workspace runs/smoke1/workspace/TASK.txt smoke1
```

Result:

- exit code 0, `exit_status: Submitted`, **elapsed 19s**, 4 API calls,
  `instance_cost` $0.00084 (all within bounds: 20 steps / 600s / $0.50)
- trajectory `runs/smoke1/trajectory.traj.json`
  (`trajectory_format: mini-swe-agent-1.1`, 12 messages) + `console.log`
- observed behavior: `ls`/`cat` reads → ran `python3 test_calc.py`
  (saw TEST FAIL) → read TASK.txt → `sed -i ''` fix (`a - b` → `a + b`)
  → re-ran test (TEST PASS, exit 0) plus extra edge-case asserts →
  issued `echo COMPLETE_TASK_AND_SUBMIT_FINAL_OUTPUT` alone → Submitted
- edit was confined to the run workspace; `diff` vs pristine fixture
  shows exactly the one-line fix
- non-interactive throughout: `--agent-class default` (no prompts possible)

## Synara integration — findings (read-only)

- `synara_capabilities` lists exactly nine thread providers:
  codex, claudeAgent, cursor, antigravity, grok, droid, opencode, pi,
  devin. **There is no mini-swe-agent provider, no ACP/custom-agent
  target, and no subprocess-launcher facility** in thread creation.
- mini-swe-agent 2.4.6 itself ships no ACP/server mode — only the
  `mini` CLI, batch evaluators (swebench/programbench), the inspector,
  and Python bindings.
- **Honest option**: a visible Synara supervisor thread (any supported
  provider) launches `bin/run_miniswe.sh` as a real subprocess and
  reports from the saved trajectory/console log. The work is genuinely
  performed by mini-swe-agent; Synara supervises rather than impersonates.
  Reusable bounded command:

  ```bash
  /Users/taha/Developer/attic-miniswe-tools/bin/run_miniswe.sh \
      <frozen_snapshot_dir> <review_prompt_file> <run_name> \
      [step_limit=20] [wall_seconds=600] [cost_limit=0.50]
  ```

  Artifacts land in `attic-miniswe-tools/runs/<run_name>/`
  (`trajectory.traj.json`, `console.log`, `result.log`).
  No Attic review has been run; awaits the root-assigned frozen snapshot
  and identical review prompt.

## Recovery

See `attic-miniswe-tools/RECOVERY.md` (rebuild, auth refresh, rerun,
failure modes). All artifacts are nonsecret.

## Known limitations

- Cost limit enforcement depends on the local registry prices; if
  Ollama changes pricing, update `config/litellm_registry.json`.
- A single in-flight model call can outlive the wall limit by up to the
  120s request timeout; the launcher has no external kill watchdog.
- Effort level `max` is sent and accepted; per-request effort is not
  echoed back by the server (see reasoning caveat above).
