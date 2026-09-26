#!/usr/bin/env bash
# runner.sh — launch a headless Claude Code agent unattended (cron, systemd timer, CI)
# and refuse to call it a success until its side effect is verified.
#
# Usage:  runner.sh <agent-name>
#
# Layout:
#   $AGENTS_DIR/<agent-name>/prompt.md     the task (required)
#   $AGENTS_DIR/<agent-name>/config.env    per-agent overrides (optional), any of:
#       MODEL=sonnet                        default: sonnet
#       ALLOWED_TOOLS="Bash,Read,Glob,Grep" default: read-only set
#       DISALLOWED_TOOLS="Edit,Write,NotebookEdit"
#       TIMEOUT_SECONDS=900                 default: 900
#       EXTRA_CLAUDE_ARGS=""                passthrough to `claude -p`
#       VERIFY_CMD='...'                    shell that exits 0 only if the agent's
#                                           observable side effect actually happened
#       RETRY_ON_VERIFY_FAIL=1              re-run once with RETRY_PROMPT_SUFFIX appended
#       RETRY_PROMPT_SUFFIX='...'           text appended to the prompt on retry
#
# Runner-level environment (all optional):
#   AGENTS_DIR      default $HOME/.claude/agents
#   LOG_DIR         default $HOME/logs        -> $LOG_DIR/claude-<agent>.log
#   WORK_DIR        default $HOME             cwd for the agent
#   SECRETS_FILE    if set, sourced (exported) before the agent runs
#   HC_PING_URL     Healthchecks.io-style URL; pinged /start, then /<exit-code>
#   NOTIFY_CMD      command invoked as: $NOTIFY_CMD "<title>" "<message>" on failure
#   USE_SUBSCRIPTION_LOGIN=1  (default) unset ANTHROPIC_API_KEY so `claude -p`
#                   uses the claude.ai login in ~/.claude rather than a metered key
#
# Exit codes:  0 ok | 2 missing prompt | 3 agent exited 0 but VERIFY_CMD failed
#              | anything else: claude's own exit (124 = timeout)

set -eo pipefail

AGENT="${1:?usage: runner.sh <agent-name>}"
AGENTS_DIR="${AGENTS_DIR:-$HOME/.claude/agents}"
AGENT_DIR="$AGENTS_DIR/$AGENT"
PROMPT="$AGENT_DIR/prompt.md"
CONFIG="$AGENT_DIR/config.env"
LOG_DIR="${LOG_DIR:-$HOME/logs}"
LOG="$LOG_DIR/claude-$AGENT.log"
WORK_DIR="${WORK_DIR:-$HOME}"
mkdir -p "$LOG_DIR"

[ -f "$PROMPT" ] || { echo "missing prompt: $PROMPT" >&2; exit 2; }

# Defaults — a read-only tool set. An agent that needs to write must say so in its
# config.env, so the blast radius of every agent is a deliberate, reviewable choice.
MODEL="sonnet"
ALLOWED_TOOLS="Bash,Read,Glob,Grep"
DISALLOWED_TOOLS="Edit,Write,NotebookEdit"
TIMEOUT_SECONDS=900
EXTRA_CLAUDE_ARGS=""

# Secrets and per-agent overrides are exported so the agent's *tools* can see them.
set -a +u
# shellcheck disable=SC1090  # paths are runtime configuration by design
[ -n "${SECRETS_FILE:-}" ] && [ -f "$SECRETS_FILE" ] && source "$SECRETS_FILE" || true
# shellcheck disable=SC1090
[ -f "$CONFIG" ] && source "$CONFIG" || true
set +a

# Prefer the subscription login over a pay-as-you-go key. If a secrets file exports
# ANTHROPIC_API_KEY and that key runs out of credit, every agent dies with a quiet
# "credit balance is too low" and nothing else looks wrong. Unsetting it makes
# `claude -p` fall back to the OAuth login in ~/.claude — the same auth as an
# interactive session. Other secrets stay exported for the agent's tools.
if [ "${USE_SUBSCRIPTION_LOGIN:-1}" = "1" ]; then
    unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN
fi

# cron ships a minimal PATH; make sure the claude binary and user tools resolve.
export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

# ── Dead-man's switch ────────────────────────────────────────────────────────
# If HC_PING_URL is set, Healthchecks (or anything with the same URL contract)
# learns about starts, successes, and failures — including the "ran but did not
# deliver" case below, which is the one a plain cron-exit check would miss.
hc_ping() {  # $1 = "" | "/start" | "/fail" | "/<exit-code>"
    [ -n "${HC_PING_URL:-}" ] || return 0
    curl -fsS -m 10 --retry 3 -o /dev/null "${HC_PING_URL}${1:-}" || true
}

notify() {   # $1 = title, $2 = message
    [ -n "${NOTIFY_CMD:-}" ] || return 0
    $NOTIFY_CMD "$1" "$2" || true
}

TS_START=$(date +%Y-%m-%dT%H:%M:%S)
echo "===== $TS_START START $AGENT =====" >> "$LOG"
hc_ping /start
cd "$WORK_DIR"

# Exported so VERIFY_CMD can ask "did the side effect happen AFTER this run began?"
# rather than "does a side effect exist somewhere" — yesterday's delivery must not
# satisfy today's check.
RUN_START_EPOCH=$(date +%s); export RUN_START_EPOCH

run_agent() {   # $1 = prompt file
    # shellcheck disable=SC2086  # EXTRA_CLAUDE_ARGS is intentionally word-split
    timeout "${TIMEOUT_SECONDS}s" claude -p \
        --model "$MODEL" \
        --output-format text \
        --permission-mode bypassPermissions \
        --allowedTools "$ALLOWED_TOOLS" \
        --disallowedTools "$DISALLOWED_TOOLS" \
        $EXTRA_CLAUDE_ARGS \
        < "$1" \
        >> "$LOG" 2>&1
}

set +e
run_agent "$PROMPT"
EXIT=$?

# ── Delivery verification ────────────────────────────────────────────────────
# A model can read a task as a specification, reply "shall I proceed?", and exit 0.
# The process succeeded; the job did not happen. Exit status is not proof an agent
# did its work — an observable side effect is. VERIFY_CMD is where you assert that
# side effect (a row in a feed, a file with mtime >= RUN_START_EPOCH, a 200 from a
# webhook you control). On failure, optionally retry once with a suffix that makes
# the unattended contract explicit, then escalate.
if [ -n "${VERIFY_CMD:-}" ]; then
    if ! bash -c "$VERIFY_CMD"; then
        echo "----- VERIFY FAILED (no delivery detected) -----" >> "$LOG"
        if [ "${RETRY_ON_VERIFY_FAIL:-0}" = "1" ]; then
            RETRY_PROMPT=$(mktemp)
            { cat "$PROMPT"; printf '%s\n' "${RETRY_PROMPT_SUFFIX:-}"; } > "$RETRY_PROMPT"
            echo "----- RETRY $(date +%Y-%m-%dT%H:%M:%S) -----" >> "$LOG"
            run_agent "$RETRY_PROMPT"; EXIT=$?
            rm -f "$RETRY_PROMPT"
            if ! bash -c "$VERIFY_CMD"; then
                echo "----- VERIFY FAILED AFTER RETRY -----" >> "$LOG"
                notify "Agent ran but did not deliver: $AGENT" "$(tail -25 "$LOG")"
                [ $EXIT -eq 0 ] && EXIT=3   # distinct code: ran fine, delivered nothing
            else
                echo "----- VERIFY OK after retry -----" >> "$LOG"
            fi
        else
            [ $EXIT -eq 0 ] && EXIT=3
        fi
    else
        echo "----- VERIFY OK -----" >> "$LOG"
    fi
fi
set -e

TS_END=$(date +%Y-%m-%dT%H:%M:%S)
echo "===== $TS_END END $AGENT exit=$EXIT =====" >> "$LOG"

# Report the REAL exit code. EXIT=3 means "ran but never delivered", so a
# silently-useless run still trips the dead-man's switch.
hc_ping "/$EXIT"

if [ $EXIT -ne 0 ]; then
    notify "Agent run failed: $AGENT (exit $EXIT)" "$(tail -40 "$LOG")"
fi

exit $EXIT
