#!/usr/bin/env python3
"""Reads one statusLine payload from stdin and keeps two facts out of it.

Runs detached in the background from statusline.sh, so it must never print and never raise
in a way that reaches the terminal: whatever it does, the user's status line has already
been drawn by then.

1. Rate limits (5h / 7d). Claude Code holds these in memory and hands them to statusLine
   alone — no file, no CLI flag. They are per account, not per session, so one terminal
   session keeps the figure fresh for every window the app shows.

2. The real context window of the model that just answered. The scraped model table is
   incomplete by nature (a transcript records the served model name, which may not exist in
   the local registry at all — claude-opus-5 does not), and this payload states the size
   outright. An observed size beats a scraped one and beats a guess, so it is remembered.

3. This session's context percentage, as Claude Code itself computes it. The size of the
   window belongs to the SESSION, not to the model — the same claude-opus-5 answers with a
   200k window in one place and a 1M one in another — so recomputing from the transcript has
   to guess which, and a wrong guess moves the figure by a factor of five. Here the number is
   simply read. Per session, because that is the scope it is true for.
"""

import json
import os
import sys
import time

# CONTROL_BAR_ROOT is a test seam for this script and its wrapper only: the app and the other
# hooks use the fixed path. Setting it for real would split the state directory.
ROOT = os.environ.get("CONTROL_BAR_ROOT") or os.path.expanduser("~/.claude/control-bar")
LIMITS = os.path.join(ROOT, "limits.json")
WINDOWS = os.path.join(ROOT, "model-windows.json")
CONTEXT_DIR = os.path.join(ROOT, "context.d")


def read_json(path, default=None):
    # Форма сверяется с default, как в mcpbar.py (обёртка statusLine — самостоятельный скрипт,
    # общего модуля нет — три строки дублируются осознанно): битый или правленый руками файл
    # с массивом наверху не должен ронять захват, которому запрещено падать.
    try:
        with open(path) as fh:
            parsed = json.load(fh)
    except Exception:
        return default
    if default is not None and not isinstance(parsed, type(default)):
        return default
    return parsed


def atomic_write(path, data):
    # 0700/0600, а не umask: здесь лежат проценты лимитов аккаунта и таблица окон, а домашний
    # каталог на macOS открыт группе staff — то есть каждому локальному пользователю машины.
    # Дескриптор открывается сразу с правами: chmod после записи оставил бы окно, в котором
    # файл читаем всем.
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    tmp = "%s.%d.tmp" % (path, os.getpid())
    with os.fdopen(os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as fh:
        json.dump(data, fh, ensure_ascii=False)
    os.replace(tmp, path)


def parse_reset(value):
    """resets_at -> epoch int, or None. Mirrors parse_reset() in mcpbar.py: the app reads the
    field with `as? Double`, so an ISO string passed through unchanged blanked the reset time
    while the other writer of the same file produced a number."""
    if isinstance(value, (int, float)):
        return int(value)
    if isinstance(value, str):
        from datetime import datetime

        try:
            return int(datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp())
        except ValueError:
            return None
    return None


def capture_limits(payload):
    """rate_limits -> limits.json, in the shape mcpbar.py and the app already read."""
    limits = payload.get("rate_limits")
    # The block ships only to subscribers, and only after the first API response of a session.
    # Writing an empty record on the early redraws would wipe the last good figures with
    # nothing, and the menu would flap between "68%" and no limits section at all.
    if not isinstance(limits, dict) or not limits:
        return
    record = {"ts": int(time.time()), "source": "statusline"}
    # Iterated rather than named: 2.1.205 also emits seven_day_opus, seven_day_sonnet and
    # seven_day_overage_included, and a plan that gains another window should not need a patch.
    for name, block in limits.items():
        if not isinstance(block, dict) or block.get("used_percentage") is None:
            continue
        # A window named after a reserved key would overwrite the timestamp, and mcpbar.py's
        # report() then dies on `time.time() - limits["ts"]`. Same skip as usage_record() there:
        # two writers, one file, one rule.
        if name in ("ts", "source"):
            continue
        # int(round(...)) is load-bearing. The payload reports fractional percentages, and the
        # app reads this with `as? Int` — which returns nil for 4.2, so the limits silently
        # disappear from the menu bar while the file looks perfectly healthy. OverflowError is
        # Infinity, which json.loads lets through and round() refuses: one such window used to
        # abort the whole capture. Same skip as usage_record() in mcpbar.py — the two writers are
        # held to one record by LimitsWriters in tests/test_statusline.py.
        try:
            pct = int(round(float(block["used_percentage"])))
        except (TypeError, ValueError, OverflowError):
            continue
        record[name] = {"used_percentage": pct, "resets_at": parse_reset(block.get("resets_at"))}
    if len(record) <= 2:
        return
    # Unchanged values are not rewritten while the file is fresh. The status line can redraw
    # every second with refreshInterval set, and the figures move on the scale of minutes —
    # rewriting an identical record each redraw is pure disk churn. The timestamp is allowed
    # to age up to a minute, so "measured N min ago" stays honest without a write per redraw.
    previous = read_json(LIMITS, {})
    same = all(previous.get(k) == v for k, v in record.items() if k not in ("ts", "source"))
    if same and record["ts"] - (previous.get("ts") or 0) < 60:
        return
    atomic_write(LIMITS, record)


def learn_window(payload):
    """Remember the context window this model actually has.

    Kept under its own key so a rescrape of the Claude Code binary (which happens on every
    upgrade) merges observations back in rather than dropping them.
    """
    window = payload.get("context_window") or {}
    size = window.get("context_window_size")
    model = ((payload.get("model") or {}).get("id") or "").lower()
    if not model or not isinstance(size, (int, float)) or size <= 0:
        return
    cache = read_json(WINDOWS, {})
    observed = cache.get("observed") or {}
    if observed.get(model) == int(size):
        return
    observed[model] = int(size)
    cache["observed"] = observed
    # Observation wins over the scraped table: it came from the model that just answered.
    cache["models"] = {**(cache.get("models") or {}), **observed}
    atomic_write(WINDOWS, cache)


def capture_context(payload):
    """This session's context usage, straight from Claude Code, into context.d/<session>.json.

    used_percentage is the figure the CLI shows; it counts input + cache creation + cache read
    against the window and leaves output tokens out. It is null before the first API response
    and again right after /compact — in both cases the last good record is left alone rather
    than replaced with a blank, which would read as "context freed".
    """
    session = payload.get("session_id")
    window = payload.get("context_window")
    if not isinstance(session, str) or not session or not isinstance(window, dict):
        return
    percent = window.get("used_percentage")
    tokens = window.get("total_input_tokens")
    size = window.get("context_window_size")
    # All three or none. A record carrying a percentage but no token count would render in the
    # row's tooltip as "19% — 0 of 1 000 000 tokens"; falling back to the recomputation is the
    # honest answer while the payload is still filling in.
    if not all(isinstance(v, (int, float)) for v in (percent, tokens, size)) or not size > 0:
        return
    # session_id arrives from outside and becomes a file name: anything that is not a plain
    # identifier character goes, or "../../x" writes wherever it likes. Spelled the same way as
    # safeId() in update.js — ASCII only — because that is the reader looking these files up.
    safe = "".join(c for c in session if (c.isascii() and c.isalnum()) or c in "_.-")[:64]
    if not safe.strip("."):
        return
    record = {
        # Rounded here for the same reason the limits are: the app reads these with `as? Int`,
        # which returns nil for 19.4 — the number would vanish from a file that looks healthy.
        "pct": max(0, min(100, int(round(float(percent))))),
        "tokens": int(tokens),
        "window": int(size),
        "model": ((payload.get("model") or {}).get("id") or ""),
        "ts": int(time.time()),
    }
    # Session cost, wall time and lines changed travel in the same record: like the context
    # figure they exist nowhere but this payload, and the app shows them on the session card.
    # Cents and whole seconds — the card never needs finer, and coarser values keep the
    # "identical record" check below from rewriting the file on every redraw while a second
    # ticks by.
    path = os.path.join(CONTEXT_DIR, safe + ".json")
    previous = read_json(path, {})
    cost = payload.get("cost")
    if not isinstance(cost, dict):
        cost = {}
    usd, ms = cost.get("total_cost_usd"), cost.get("total_duration_ms")
    lines = [cost.get("total_lines_added"), cost.get("total_lines_removed")]
    if all(isinstance(v, (int, float)) for v in [usd, ms] + lines):
        record["cost"] = round(float(usd), 2)
        record["duration"] = int(ms // 1000)
        record["linesAdded"], record["linesRemoved"] = int(lines[0]), int(lines[1])
    else:
        # A payload without a usable cost block does not unlearn the totals already captured:
        # they only ever grow, so the last figure stays true until a fuller payload arrives.
        for k in ("cost", "duration", "linesAdded", "linesRemoved"):
            if k in previous:
                record[k] = previous[k]
    # Same rule as the limits: an identical record is not rewritten on every redraw, but the
    # timestamp is allowed to age only a minute — the reader treats a stale record as no
    # record, and a session sitting at one percentage would otherwise expire while still true.
    # The duration alone never counts as a change: it moves on every redraw by definition, and
    # a minute of lag on the card is cheaper than a write per second.
    same = all(previous.get(k) == v for k, v in record.items() if k not in ("ts", "duration"))
    if same and record["ts"] - (previous.get("ts") or 0) < 60:
        return
    atomic_write(path, record)


def log_problem(text):
    # Same file mcpbar.py and the app write to: a background script with stdout and stderr
    # closed has no other place to leave a trace.
    try:
        os.makedirs(ROOT, mode=0o700, exist_ok=True)
        with open(os.path.join(ROOT, "problems.log"), "a") as fh:
            fh.write(text + "\n")
    except OSError:
        pass


def capture(payload, steps=(capture_limits, learn_window, capture_context)):
    """One step failing must not cost the others their write, and must not cost the user
    their status line — but it must leave a trace. Before this, a genuine bug in a step
    looked exactly like "no subscription": limits forever `not measured yet`, no signal."""
    for step in steps:
        try:
            step(payload)
        except Exception as exc:
            log_problem("statusline.py: %s failed: %r" % (step.__name__, exc))


def main():
    try:
        payload = json.loads(sys.stdin.read() or "{}")
    except Exception:
        return 0
    if not isinstance(payload, dict):
        return 0
    capture(payload)
    return 0


if __name__ == "__main__":
    sys.exit(main())
