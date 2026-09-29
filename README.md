# claude-handoff-control

A Stop hook for [Claude Code](https://code.claude.com). It returns the turn when the agent hands
it back with an excuse instead of doing work it could do itself.

- *"Want me to run the tests?"*
- *"👉 Next: adding unit tests."*
- *"You may want to check whether the service is running."*

Each of these ends a turn while the next step was obvious, reversible and in reach.
If you are away from the terminal, that is an hour of nothing.

## TL;DR

- **What** — at every turn end an LLM judge reads the final message. An excuse gets the turn back.
- **What it is not** — not a code reviewer. It never judges whether the work is right.
- **Cost** — about $0.89 per 1 000 judged turns in 16 days of real use.
- **Safe by default** — one return per chain; any judge failure lets the turn end normally.
- **Setup** — mine: Claude Opus as the agent, `deepseek-flash` as the judge. Adapt it to yours.

## Quick start

Requires `bash`, `jq`, `curl`, `python3`, `perl`.

```bash
git clone https://github.com/mkdir-username/claude-handoff-control.git
cd claude-handoff-control && ./install.sh
export DEEPSEEK_API_KEY=sk-...   # or HANDOFF_CTL_API_KEY; put it in your shell profile
```

Restart Claude Code afterwards. `./uninstall.sh` removes everything the installer added.

<details>
<summary>What <code>install.sh</code> changes</summary>

- **Files** — copies hooks and rubrics to `~/.claude/handoff-control/`.
- **Settings** — backs up `~/.claude/settings.json`, then registers three hooks:
  Stop, and two on UserPromptSubmit.
- **Your hooks** — left alone. Running it twice adds nothing new.
- **Uninstall** — removes exactly those three entries and the directory.

</details>

---

## What it catches

The judge answers one question: *was the turn handed back with work, or with an excuse?*

- **DUMB_QUESTION** — a question where one option clearly wins.
  Also a named default not taken, or "do step N+1?" right after step N.
- **MISSED_ACTION** — no question, but an announced or obvious action was not done.
  A failed command left unfixed counts too.
- **DELAYED_ANSWER** — you asked a question and the answer sat behind long foreground waits.
  Never returns the turn; it becomes a lesson for the next one.
- **UNFLAGGED_RISK** — code, a guard or a test deleted, or a contract changed.
  Reported as routine, without evidence and a rollback line.

## What it leaves alone

A verdict of **OK** means the work is done or the stop is legitimate:

- **Irreversible step, direction unclear** — asking first is right.
- **Equal fork** — put to you through AskUserQuestion, or a scope-creep stop.
- **Human-only or banned step** — a policy ban, or a step visible to other people.
- **Flagged risky change** — see the `RESPONSIBLE ZONE` guard below.

💡 The judge sees the final message, your request, tool names and failed-call errors.
It never sees call arguments or successful output. That keeps it cheap and its false positives low.

---

## How a turn is judged

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

- **One return per chain** — `stop_hook_active` prevents loops.
  The continued turn is judged again and may be returned once more, not more.
- **Obligations** — a returned MISSED_ACTION leaves an obligation behind.
  When the agent resumes on its own, the next Stop asks: *is the named action closed?*
- **Deterministic guards** — rules around the LLM that override it (details below).
- **Fail-open** — no key, a timeout or garbage instead of JSON ends the turn normally.
  From the second failure in a row you see a warning naming the error, at most every 30 min.

<details>
<summary>Obligation outcomes and deterministic guards</summary>

Obligation outcomes:

- **met** — the action is done.
- **impossible** — a ban or a human step, proven by the transcript.
- **stalled** — 3 returns without progress.
- **expired** — 1 hour passed. A new message from you supersedes it at any time.

Guards:

- **Background work** — a running background agent or command suppresses MISSED_ACTION.
  Waiting for its notification is legitimate.
- **Responsible zone** — a `⚠️ RESPONSIBLE ZONE` block with `Evidence:` (command → result)
  and `Rollback:` lines makes "Ok / not ok?" a legitimate question.
- **Deletions** — a push that demands deleting something always carries a spike-first protocol.
  It never becomes an obligation.

</details>

---

## My setup, as it runs

This is my personal setup, published as-is. It is not a product tuned for every stack.

- **Main agent** — Claude Opus in Claude Code.
- **Judge** — `deepseek-flash` through DeepSeek's Anthropic-compatible endpoint
  (`https://api.deepseek.com/anthropic/v1/messages`). The rubrics were tuned on this pair.
- **Another judge** — any Anthropic Messages–compatible model plugs in with
  `HANDOFF_CTL_API_URL`, `HANDOFF_CTL_API_KEY` and `HANDOFF_CTL_MODEL`.
  Expect to retune `rubrics/handoff-control.md` yourself; I have not.

## What it costs

16 days of my own work (14–29 Sep 2026): **2 309 judged turns for about $2.06**
(range $0.58–$3.04). That is **$0.89 per 1 000 turns**, about a third of the account's
DeepSeek bill ($6.68).

![Daily spend: whole DeepSeek account vs. the controller](docs/spend.svg)

- **Grey** — DeepSeek's billing export. The same key also pays for other tools.
- **Green** — the controller's share, estimated (method below).
- **Where the money goes** — almost all of it is output tokens: thinking plus the verdict.
  The cached rubric is nearly free.

<details>
<summary>How the numbers were measured</summary>

Per call, on the bundled fixture corpus (7 cases × 2):

- **Input** — about 2 700 tokens. After the first call ~2 450 of them (the rubric)
  come from DeepSeek's prompt cache.
- **Output** — 200–1 700 tokens, mostly thinking before the verdict.
- **Latency** — adds 2–10 s to the end of the turn, typically 3–4 s.
- **Calibrator** — evasion verdicts add one tiny call (4 output tokens).

The judge runs once per turn end, plus once for a continuation after a block.
Multiply by your DeepSeek rate for the price.

The green bars: controller calls per day, counted from a local proxy log,
times the per-call profile above, times that day's billed token prices.

</details>

---

## Limitations

- ⚠️ **Current turn only** — work done a turn earlier is invisible to the judge.
  That is why obligations have a ceiling and a TTL.
- ⚠️ **Nondeterministic** — on the fixture corpus `deepseek-flash` matched 13 of 14 runs.
  The miss: a legitimate irreversible fork judged DUMB_QUESTION at 0.82.
  That is below the block threshold, so it became a lesson, not a returned turn.
- ⚠️ **Thinking can eat the budget** — now and then it uses all 4 000 `max_tokens`
  and no verdict comes back (1 of 7 extra calls on the hardest fixture).
  That turn passes unchecked, silently. Raise `max_tokens` in the hook if you see it often.
- ⚠️ **Generic policies only** — the rubric knows no push, publish, merge or prod deploy
  without your command. Add your own rules to `rubrics/handoff-control.md`.

A false block costs you one Escape. The rubric leans towards blocking when in doubt;
raise `HANDOFF_CTL_THRESHOLD` if that is too eager for you.

## Configuration

- **`HANDOFF_CTL_API_URL` · `HANDOFF_CTL_API_KEY` · `HANDOFF_CTL_MODEL`** — which judge to call.
  Defaults: DeepSeek's endpoint, `$DEEPSEEK_API_KEY`, `deepseek-flash`.
- **`HANDOFF_CTL_THRESHOLD`** — confidence needed to return the turn, default `0.90`.
- **Bypass** — `touch ~/.claude/handoff-control/skip` skips the next check.
  Valid 30 min, consumed on use.
- **Tuning** — every verdict lands in `verdicts.jsonl` with the transcript path and line range.
  When the judge is wrong, fix the rubric (`rubrics/handoff-control.md`), not the hook.

<details>
<summary>All variables</summary>

| Variable | Default | Meaning |
|---|---|---|
| `HANDOFF_CTL_API_KEY` | `$DEEPSEEK_API_KEY` | Key for the judge |
| `HANDOFF_CTL_API_URL` | `https://api.deepseek.com/anthropic/v1/messages` | Any Anthropic Messages–compatible endpoint |
| `HANDOFF_CTL_MODEL` | `deepseek-flash` | Judge model |
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
| `HANDOFF_CTL_CALIB` | `1` | Logprob calibrator on evasion verdicts (logged only, never changes a verdict); `0` turns it off |
| `HANDOFF_CTL_CALIB_URL` | `https://api.deepseek.com/v1/chat/completions` | OpenAI-compatible endpoint returning `top_logprobs` |
| `HANDOFF_CTL_CALIB_KEY` · `HANDOFF_CTL_CALIB_MODEL` · `HANDOFF_CTL_CALIB_TIMEOUT` | judge key · judge model · `10` | Calibrator overrides |
| `HANDOFF_CTL_CMD` · `HANDOFF_CTL_CALIB_CMD` | — | Replace the judge/calibrator with a command (tests, custom transports) |
| `HANDOFF_CTL_DOWN_FILE` | `$HANDOFF_CTL_HOME/state/ctl-down` | Consecutive-failure counter |

</details>

## What leaves your machine

On every Stop the judge endpoint receives the rubric plus:

- **Final message** — its last ~3 000 characters.
- **Your prompt** — its first 1 500 characters.
- **Tool names** — the list of tools called in the turn.
- **Errors** — for failed calls, the first 120 characters of the error text.
  They pass through a secret mask first: API keys, GitHub/Slack/AWS tokens, JWTs, `key=value`.

Tool arguments and successful tool output are never sent. Nothing else leaves the machine.

---

## Related, not included: `/goal`

A task-goal system pairs well with this hook. It is a **separate setup, installed manually**,
and not part of this package: a session goal in the status line, plus a PreToolUse gate
that blocks work until a goal is set.

The two do not talk to each other. They cover the two ends of a task:
a stated goal before work starts, and work instead of excuses at every turn end.

## Tests

```bash
bats tests/   # judge stubbed via HANDOFF_CTL_CMD, no API calls
HANDOFF_CTL_LIVE=1 HANDOFF_CTL_LIVE_KEY="$DEEPSEEK_API_KEY" bats tests/stop-handoff-control.bats -f 'live judge'
```

## License

MIT
