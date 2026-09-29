# claude-handoff-control

A Stop hook for [Claude Code](https://code.claude.com) that returns the turn when the agent hands
it back with an excuse instead of doing work it could do itself.

"Want me to run the tests?" · "👉 Next: adding unit tests." · "You may want to check whether the
service is running." — each of these ends a turn while the next step was obvious, reversible and
within the agent's reach. If you are away from the terminal, that is an hour of nothing.

This hook is about **controlled proactivity**: push the agent to finish what it can, while keeping
legitimate stops — irreversible actions, real forks, a human-only step, a policy ban — intact.

## What it is — and what it is not

It is a **turn-handoff controller, not a reviewer**. It asks exactly one question — *was the turn
handed back with work, or with an excuse?* — and never judges whether the work itself is right.
That keeps it cheap and keeps false positives low: the judge sees the final message, the user's
request, the names of the tools called and the error text of failed calls, but not call
arguments and not the output of successful calls.

## Verdicts

- **OK** — the work is done, or the stop is legitimate (irreversible with unclear direction, an
  equal fork put to the user via AskUserQuestion, scope-creep stop, a human-only or policy-banned
  step, a flagged risky change, a step visible to other people).
- **DUMB_QUESTION** — a question where one option strictly dominates, a named default that was not
  taken, or "do step N+1?" after step N.
- **MISSED_ACTION** — no question, but an announced or obviously available action was not done,
  including a failed command left unfixed.
- **DELAYED_ANSWER** — the user asked a question and the agent held the answer behind long
  foreground waits. Never returns the turn; becomes a lesson for the next one.
- **UNFLAGGED_RISK** — the agent deleted code, a guard or a test, or changed a contract, and
  reported it as routine, without evidence and a rollback line.

## How it works

```
Stop ─▶ stop-handoff-control.sh ─▶ LLM judge (rubric) ─▶ verdict + confidence
          │                                                │
          │   ≥ 0.90 evasion ────────────────────────────▶ {"decision":"block","reason":…}
          │                                                  Claude Code continues the same turn
          │   0.80–0.90, cooldown, background work ───────▶ lesson file
          │                                                  └▶ lesson-surface.sh injects it
          │                                                     into the next turn's context
          └── every verdict ─▶ ~/.claude/handoff-control/verdicts.jsonl
```

- **One return per chain, plus one on the continuation.** `stop_hook_active` prevents loops; the
  turn that continues after a block is judged again and may be returned once more, not more.
- **Obligations.** A returned MISSED_ACTION leaves an obligation. When the agent resumes on its
  own (for example after a background task reports back), the next Stop asks a narrower question:
  *is the named action closed?* Outcomes: met, impossible (a ban or a human step, proven by the
  transcript), stalled (3 returns without progress), expired (1 h). A new user message
  supersedes it.
- **Deterministic guards around the LLM.** A running background agent/command suppresses
  MISSED_ACTION (waiting for its notification is legitimate). A `⚠️ RESPONSIBLE ZONE` block with
  `Evidence:` (command → result) and `Rollback:` lines makes "Ok / not ok?" a legitimate question.
  A push that demands deleting something always carries a spike-first protocol and never becomes
  an obligation.
- **Fail-open.** No key, a timeout, garbage instead of JSON → the turn ends normally. From the
  second failure in a row you get a visible warning (at most every 30 min) naming the error.

## Install

Requires `bash`, `jq`, `curl`, `python3`, `perl`.

```bash
git clone https://github.com/mkdir-username/claude-handoff-control.git
cd claude-handoff-control
./install.sh
export HANDOFF_CTL_API_KEY=sk-ant-...     # or ANTHROPIC_API_KEY; put it in your shell profile
```

`install.sh` copies the hooks and rubrics to `~/.claude/handoff-control/`, backs up
`~/.claude/settings.json` and registers three hooks (Stop, and two on UserPromptSubmit). It is
idempotent and leaves your other hooks alone. Restart Claude Code afterwards.
`./uninstall.sh` removes exactly those three entries and the directory.

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `HANDOFF_CTL_API_KEY` | `$ANTHROPIC_API_KEY` | Key for the judge |
| `HANDOFF_CTL_API_URL` | `https://api.anthropic.com/v1/messages` | Any Anthropic Messages–compatible endpoint |
| `HANDOFF_CTL_MODEL` | `claude-haiku-4-5` | Judge model |
| `HANDOFF_CTL_TIMEOUT` | `40` | Judge request timeout, seconds |
| `HANDOFF_CTL_THRESHOLD` | `0.90` | Confidence needed to return the turn |
| `HANDOFF_CTL_SOFT_THRESHOLD` | `0.80` | Confidence needed for a next-turn lesson |
| `HANDOFF_CTL_DELAYED_THRESHOLD` | `0.70` | Confidence needed for a DELAYED_ANSWER lesson |
| `HANDOFF_CTL_COOLDOWN` | `600` | Seconds MISSED_ACTION stays a lesson after an "impossible" |
| `HANDOFF_CTL_OBLIGATION_TTL` | `3600` | Obligation lifetime, seconds |
| `HANDOFF_CTL_OBLIGATION_MAX_ITER` | `3` | Returns before an obligation is closed as stalled |
| `HANDOFF_CTL_BG_WINDOW` | `3600` | How long a background launch counts as "in flight" |
| `HANDOFF_CTL_DELIVER_MAX` | `900` | Max age of a lesson that is still delivered |
| `HANDOFF_CTL_COMMIT_IN_DIALOG` | `0` | `1` if your policy is that the agent hands you commits as a command |
| `HANDOFF_CTL_HOME` | `~/.claude/handoff-control` | State, prompt cache and verdict log |
| `HANDOFF_CTL_LOG` | `$HANDOFF_CTL_HOME/verdicts.jsonl` | Verdict log |
| `HANDOFF_CTL_RUBRIC_DIR` | `<install>/rubrics` | Directory with the three rubrics |
| `HANDOFF_CTL_RUBRIC` · `HANDOFF_CTL_OBLIGATION_RUBRIC` · `HANDOFF_CTL_CALIB_PROMPT` | files in the rubric dir | Override one rubric |
| `HANDOFF_CTL_CALIB` | `0` | `1` enables the logprob calibrator (logged only, never changes a verdict) |
| `HANDOFF_CTL_CALIB_URL` · `HANDOFF_CTL_CALIB_KEY` · `HANDOFF_CTL_CALIB_MODEL` · `HANDOFF_CTL_CALIB_TIMEOUT` | — | OpenAI-compatible endpoint returning `top_logprobs` |
| `HANDOFF_CTL_CMD` · `HANDOFF_CTL_CALIB_CMD` | — | Replace the judge/calibrator with a command (tests, custom transports) |
| `HANDOFF_CTL_DOWN_FILE` | `$HANDOFF_CTL_HOME/state/ctl-down` | Consecutive-failure counter |

**Bypass:** `touch ~/.claude/handoff-control/skip` — skips the next check (valid 30 min, consumed on use).

**Tuning:** every verdict lands in `verdicts.jsonl` with the transcript path and the turn's line
range. Adjust the rubric (`rubrics/handoff-control.md`), not the hook, when the judge is wrong.

## Privacy

On every Stop the following is sent to the judge endpoint: the rubric, the last ~3 000 characters
of the agent's final message, the first 1 500 characters of your last prompt, the list of tool
names called in the turn, and for failed calls the first 120 characters of the error text passed
through a secret mask (API keys, GitHub/Slack/AWS tokens, JWTs, `key=value` secrets). Tool
arguments and successful tool output are never sent. Nothing else leaves the machine.

## Cost and latency

Measured on the bundled fixture corpus with `claude-haiku-4-5`: about 2 800 input and 115 output
tokens per judged turn, 2.5–6 s added to the end of the turn. At $1 / $5 per million tokens that
is roughly **$0.0034 per turn, about $0.34 per 100 turns**. The judge runs once per turn end,
plus once for a continuation after a block.

## Limitations

- The judge sees only the current turn. Work done a turn earlier is invisible to it — hence the
  obligation ceiling and TTL.
- Verdicts are LLM output: nondeterministic, and the two evasion classes blur with small models
  (on Haiku a bare "👉 Next: …" announcement tends to come back as DUMB_QUESTION rather than
  MISSED_ACTION). The turn is returned either way; only MISSED_ACTION opens an obligation.
- A false block costs you one Escape. The rubric deliberately leans towards blocking when in doubt;
  raise `HANDOFF_CTL_THRESHOLD` if that is too eager for you.
- The rubric knows nothing about your project's policies beyond the common ones (no push, publish,
  merge or production deploy without your command). Add yours to `rubrics/handoff-control.md`.

## Related, not included: `/goal`

A task-goal system pairs well with this hook but is a **separate setup, installed manually and not
part of this package**: a session goal shown in the status line, plus a PreToolUse gate that blocks
work until a goal is set. The two do not talk to each other; they cover the two ends of a task —
a stated goal before work starts, and work instead of excuses at the end of every turn.

## Tests

```bash
bats tests/                                   # judge stubbed via HANDOFF_CTL_CMD, no API calls
HANDOFF_CTL_LIVE=1 HANDOFF_CTL_LIVE_KEY=sk-ant-... bats tests/stop-handoff-control.bats -f 'live judge'
```

## License

MIT
