# claude-agent-runner

Run headless [Claude Code](https://docs.claude.com/en/docs/claude-code) agents unattended —
from cron, a systemd timer, CI — and **refuse to call a run successful until its side effect
is verified**.

One bash script, no dependencies beyond `claude` and `curl`.

## The problem it solves

An LLM agent can read a task as a *specification*, reply "shall I proceed?", and exit 0.
The process succeeded. The job did not happen. Nothing in your cron log looks wrong.

This runner adds one idea on top of `claude -p`: **exit status is not proof an agent did
its work — an observable side effect is.** Each agent can declare a `VERIFY_CMD` that asserts
the side effect actually occurred *after this run started*. If it didn't, the runner retries
once with a blunter contract, then escalates — and reports a distinct exit code so your
dead-man's switch trips on a run that was silently useless.

## Layout

```
$AGENTS_DIR/
  <agent-name>/
    prompt.md       the task — piped to `claude -p` on stdin
    config.env      per-agent overrides: model, tools, timeout, VERIFY_CMD, retry
```

Logs land in `$LOG_DIR/claude-<agent-name>.log`, appended per run with START/END markers.

## Quick start

```bash
git clone https://github.com/gordontechai/claude-agent-runner
cd claude-agent-runner

# Point the runner at the bundled example and run it once.
AGENTS_DIR="$PWD/agents" ./runner.sh example-briefing
echo "exit=$?"
cat ~/briefings/latest.md
```

Then schedule it:

```cron
7 7 * * *  AGENTS_DIR=/path/to/agents /path/to/runner.sh example-briefing
```

## Delivery verification

`VERIFY_CMD` is a shell snippet that exits 0 only if the agent's job is visibly done.
The runner exports `RUN_START_EPOCH` so you can insist the evidence is from *this* run —
yesterday's output must not satisfy today's check.

```bash
# agents/example-briefing/config.env
VERIFY_CMD='f="$HOME/briefings/latest.md"; [ -f "$f" ] && [ "$(stat -c %Y "$f")" -ge "$RUN_START_EPOCH" ]'
RETRY_ON_VERIFY_FAIL=1
RETRY_PROMPT_SUFFIX='

REMINDER: this is an unattended cron run. Do NOT ask anything. Execute every step above and write the file NOW.'
```

Other things worth verifying with it: a row appeared in a feed, a webhook you control
returned 200, a message ID exists in a delivery log. Pick the side effect that *is* the job.

## Exit codes

| code | meaning |
|---|---|
| `0` | agent ran and (if configured) verification passed |
| `2` | prompt file missing |
| `3` | agent exited 0 but **VERIFY_CMD failed** — ran fine, delivered nothing |
| `124` | timeout |
| other | claude's own exit code |

`3` is the one that matters. It is the difference between "cron says fine" and "the thing happened."

## Design choices

**Read-only by default.** Every agent starts with `Bash,Read,Glob,Grep` and `Edit,Write,NotebookEdit`
disallowed. An agent that needs to write must say so in its own `config.env`, so the blast
radius of each agent is a deliberate, reviewable decision rather than an inherited default.

**Subscription login over metered key.** If a secrets file exports `ANTHROPIC_API_KEY` and
that key runs out of credit, every agent dies with a quiet "credit balance is too low" and
nothing else looks wrong. By default the runner unsets it so `claude -p` falls back to the
claude.ai login in `~/.claude`. Set `USE_SUBSCRIPTION_LOGIN=0` to keep the key.

**Dead-man's switch that understands "useless."** Set `HC_PING_URL` to a
[Healthchecks.io](https://healthchecks.io)-style URL and the runner pings `/start`, then
`/<exit-code>`. Because exit `3` is reported honestly, a run that executed but never delivered
still fails the check.

**Escalation is pluggable.** `NOTIFY_CMD "<title>" "<message>"` is called on any non-zero
exit. Point it at whatever you already use — a Slack webhook wrapper, `ntfy`, mail.

## Companion pattern: tool-scoped subagents

`agents/risk-reviewer.md` is a Claude Code subagent definition restricted at the tool layer to
`Read, Grep, Glob`. It audits code that moves money or touches production and is
**structurally incapable** of editing, running shell, or executing anything — not because
the prompt asks nicely, but because the tools aren't there.

That is the same principle as the runner's read-only default, applied one level down:
**permissions are the safety control; the prompt is just guidance.** Drop it in
`~/.claude/agents/` to use it.

## Configuration reference

Runner-level (environment):

| var | default | purpose |
|---|---|---|
| `AGENTS_DIR` | `~/.claude/agents` | where `<agent>/prompt.md` lives |
| `LOG_DIR` | `~/logs` | per-agent append logs |
| `WORK_DIR` | `~` | cwd for the agent |
| `SECRETS_FILE` | *(unset)* | sourced + exported before the run |
| `HC_PING_URL` | *(unset)* | dead-man's switch URL |
| `NOTIFY_CMD` | *(unset)* | escalation command |
| `USE_SUBSCRIPTION_LOGIN` | `1` | unset `ANTHROPIC_API_KEY` for the run |

Per-agent (`config.env`): `MODEL`, `ALLOWED_TOOLS`, `DISALLOWED_TOOLS`, `TIMEOUT_SECONDS`,
`EXTRA_CLAUDE_ARGS`, `VERIFY_CMD`, `RETRY_ON_VERIFY_FAIL`, `RETRY_PROMPT_SUFFIX`.

## What this is not

Not a framework. No queue, no DAG, no dashboard. It runs one agent, checks that it did the
thing, and tells you if it didn't. If you need more than that, this is a reasonable thing to
grow it from — the whole script is short enough to read in one sitting.

## License

MIT
