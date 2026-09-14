#!/usr/bin/env python3
"""SessionStart, plugin channel: claim the hooks, converge the app, launch it.

Claude Code plugins have no postinstall step, so the assembly happens here. Idempotent and
cheap: with the right version already installed and running, it does almost nothing. The
expensive part — compiling the app — runs only when the plugin version changed, i.e. after
an upgrade.
"""

import json
import os
import plistlib
import subprocess
import sys
import time

PLUGIN_ROOT = os.environ.get("CLAUDE_PLUGIN_ROOT") or os.path.dirname(
    os.path.dirname(os.path.abspath(__file__))
)
HOME = os.path.expanduser("~")
ROOT = os.path.join(HOME, ".claude", "control-bar")
PATHS = os.path.join(ROOT, "paths.json")
OWNER = os.path.join(ROOT, "owner.json")
SETTINGS = os.path.join(HOME, ".claude", "settings.json")
# Written by the app's Quit menu item. lifecycle.js deletes it on a genuinely new session;
# this hook runs IN PARALLEL with lifecycle.js on the same SessionStart, so it applies the
# same source rule itself instead of relying on that deletion having happened yet.
QUIT_MARKER = os.path.join(ROOT, "quit-intent")


def may_launch(payload):
    """Whether this SessionStart is consent to bring the app up.

    SessionStart fires for brand-new sessions AND for resumes (--resume/--continue, wake
    after sleep, compaction). Only a new session (source startup/clear) voids an explicit
    Quit; a resume honors the marker — or the app "comes back on its own" the moment a
    laptop lid opens. No source at all is an old Claude Code: it keeps the pre-source
    behavior, else one Quit would leave the app permanently down there.

    The resumed-source list mirrors lifecycle.js — keep the two in step.
    """
    if not isinstance(payload, dict):
        return True
    if payload.get("source") in ("resume", "compact", "fork"):
        return not os.path.exists(QUIT_MARKER)
    return True


def identity():
    """Read identity.env — the one place the product's names are declared."""
    values = {}
    try:
        with open(os.path.join(PLUGIN_ROOT, "identity.env")) as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, value = line.partition("=")
                values[key.strip()] = value.strip().strip('"')
    except OSError:
        pass
    return values


ID = identity()
BUNDLE_ID = ID.get("BUNDLE_ID", "io.github.infinityscripter.claude-control-bar")
EXEC = ID.get("EXEC", "ClaudeControlBar")
APP_NAME = ID.get("APP_NAME", "Claude Control Bar")
USER_APP = os.path.join(HOME, "Applications", APP_NAME + ".app")
SYSTEM_APP = os.path.join("/Applications", APP_NAME + ".app")


def read_json(path, default=None):
    # Форма сверяется с default, как в mcpbar.py (хук и панель — разные исполняемые, общего
    # модуля нет — три строки дублируются осознанно): settings.json правится руками, и массив
    # наверху там, где ждали словарь, ронял бы AttributeError весь хук.
    try:
        with open(path) as fh:
            parsed = json.load(fh)
    except Exception:
        return default
    if default is not None and not isinstance(parsed, type(default)):
        return default
    return parsed


def write_json(path, data):
    # 0700/0600, а не umask: каталог общий с состоянием сессий, а домашний каталог на macOS
    # открыт группе staff — то есть каждому локальному пользователю машины.
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    tmp = f"{path}.{os.getpid()}.tmp"
    with os.fdopen(os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as fh:
        json.dump(data, fh, ensure_ascii=False)
    os.replace(tmp, path)


def plugin_version():
    manifest = read_json(os.path.join(PLUGIN_ROOT, ".claude-plugin", "plugin.json"), {})
    return manifest.get("version", "0.0.0")


def bundle_version(app):
    """Version of the bundle at `app`, or None when it is missing or is not ours."""
    try:
        with open(os.path.join(app, "Contents", "Info.plist"), "rb") as fh:
            info = plistlib.load(fh)
        if info.get("CFBundleIdentifier") != BUNDLE_ID:
            return None
        return info.get("CFBundleShortVersionString")
    except Exception:
        return None


def running():
    return subprocess.run(["/usr/bin/pgrep", "-x", EXEC], capture_output=True).returncode == 0


def version_key(name):
    """Newest-first ordering for nvm's directory names. Component-wise, like the app's own
    search: as text "v9.11.2" sorts above "v20.19.0", and the installer this runs uses APIs the
    older one does not have."""
    parts = []
    for chunk in name.lstrip("v").split("."):
        if not chunk.isdigit():
            break
        parts.append(int(chunk))
    return parts


def node_runs(path, timeout=3):
    """True when `path` is a Node that actually starts — mirror of StatusController.nodeRuns().

    Existence alone is not enough: after `brew upgrade llhttp` Homebrew's node can still be
    executable on disk yet die in dyld looking for a libllhttp.N.M.dylib the Cellar no longer
    has. A one-shot `process.exit(0)` catches that before we hand the path to uninstall.js.
    """
    try:
        result = subprocess.run(
            [path, "-e", "process.exit(0)"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=timeout,
        )
    except (subprocess.TimeoutExpired, OSError):
        return False
    return result.returncode == 0


def first_working_node(candidates):
    """First candidate that is executable *and* launches. Shared by find_node() so tests can
    feed a fixture list without touching /opt/homebrew."""
    homebrew = ("/opt/homebrew/bin/node", "/usr/local/bin/node")
    for path in candidates:
        if not os.access(path, os.X_OK):
            continue
        if node_runs(path):
            return path
        if path in homebrew:
            log_problem_once(
                f"skipping broken Homebrew node at {path} "
                f"(won't launch — try `brew reinstall node`); trying other candidates\n")
    return None


def find_node():
    """Node wherever it actually lives — the same places the app looks (see locateNode()).

    Three fixed paths cover a system or Homebrew install and nothing else. On a machine using
    nvm, volta or asdf there was no node here at all, so the app channel's hooks could not be
    removed — while the app itself, which does know those layouts, had installed them and kept
    them working. Both sets then fired on every event, forever: the exact duplication the lease
    below exists to prevent.

    Prefer the stable Homebrew symlink first, but smoke-test each candidate: a dyld-broken
    Homebrew node must not win over a working nvm/volta/system install.
    """
    candidates = [
        "/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node",
        os.path.join(HOME, ".volta", "bin", "node"),
        os.path.join(HOME, ".asdf", "shims", "node"),
    ]
    nvm = os.path.join(HOME, ".nvm", "versions", "node")
    try:
        versions = sorted(os.listdir(nvm), key=version_key, reverse=True)
    except OSError:
        versions = []
    candidates += [os.path.join(nvm, v, "bin", "node") for v in versions]
    return first_working_node(candidates)


def shell_quoted(value):
    """The exact spelling shellQuote() in install.js produces — NOT shlex.quote, which spells
    an apostrophe differently and leaves a plain path unquoted. The contract is set by the JS
    scripts that wrote the command; this predicate must recognise their bytes."""
    return "'" + value.replace("'", "'\\''") + "'"


def command_points_at(command, script):
    """Mirror of pointsAt() in install.js/uninstall.js — keep the three copies in step.

    The bare spelling is anchored on the right: without the boundary "update.js" is a prefix
    of a neighbour's "update.js.bak". The quoted spelling carries homes with an apostrophe,
    where the bare path never appears in the command at all.
    """
    at = command.find(script)
    while at != -1:
        if command[at + len(script):at + len(script) + 1] in ("", " ", "'", '"'):
            return True
        at = command.find(script, at + 1)
    return shell_quoted(script) in command


def app_hooks_present():
    """Whether settings.json still holds hooks pointing at our scripts.

    The exact scripts, not `ROOT in command`: the directory is also a prefix of a user's own
    "control-bar-extra", and a substring of any command that merely reads a file from our
    directory. A false positive here is not cosmetic — while one such "our" hook survives,
    clear_app_channel_hooks() keeps failing and the plugin never claims the lease.

    Both spellings, same as isOurs in install.js/uninstall.js (keep the three in step): with
    an apostrophe in the home path the bare path never appears in the command — the quoted
    spelling is the only one there is, and missing it flips the failure the other way, a lease
    claimed while the duplicate hooks are still installed.
    """
    scripts = (os.path.join(ROOT, "update.js"), os.path.join(ROOT, "lifecycle.js"))
    for entries in (read_json(SETTINGS, {}).get("hooks") or {}).values():
        for entry in entries or []:
            for hook in (entry or {}).get("hooks") or []:
                command = hook.get("command") or ""
                if any(command_points_at(command, s) for s in scripts):
                    return True
    return False


def clear_app_channel_hooks():
    """Remove the app channel's duplicate hooks. True when settings.json is free of them."""
    if not app_hooks_present():
        return True
    node, uninstall = find_node(), os.path.join(PLUGIN_ROOT, "hooks", "uninstall.js")
    if not node or not os.path.exists(uninstall):
        return False
    # TimeoutExpired is caught, not propagated: nothing above catches it, so a slow disk or a
    # load spike would kill the whole SessionStart hook with a traceback Claude Code surfaces
    # as a hook error — for a cleanup whose failure the lease logic already tolerates.
    try:
        subprocess.run([node, uninstall, "--hooks-only"], capture_output=True, timeout=20)
    except (subprocess.TimeoutExpired, OSError):
        pass
    return not app_hooks_present()


def claim_hooks():
    """Declare the plugin the owner of the hooks, once the app channel's duplicates are gone.

    Both channels install the same eight hooks, and Claude Code merges plugin hooks with the
    ones in settings.json and runs every match — there is no deduplication anywhere. Someone
    with both installed pays two node processes per tool call, forever. The plugin wins because
    Claude Code removes its own hooks on `plugin uninstall`, while hooks written into
    settings.json outlive an uninstall the app may never get the chance to run.

    Claimed after the removal, not before. Written first, the claim froze the duplication in
    place whenever the removal failed: install.js reads owner.json, sees the plugin, and returns
    without touching the hooks it would otherwise have reclaimed.
    """
    if clear_app_channel_hooks():
        write_json(OWNER, {"channel": "plugin", "pluginRoot": PLUGIN_ROOT,
                           "version": plugin_version()})


def write_paths():
    """Where the app finds its MCP backend.

    Rewritten on every start because the plugin directory carries the version in its path, so
    it moves with every upgrade and a remembered path goes stale immediately.
    """
    write_json(PATHS, {
        # Always the system python: the script uses nothing outside the standard library, and
        # pyenv/nvm are not on a GUI process's PATH — pointing at one of those would break the
        # launch on exactly the machines that have them.
        "python": "/usr/bin/python3",
        "script": os.path.join(PLUGIN_ROOT, "scripts", "mcpbar.py"),
        "pluginRoot": PLUGIN_ROOT,
        "version": plugin_version(),
    })


def log_problem(text):
    os.makedirs(ROOT, exist_ok=True)
    with open(os.path.join(ROOT, "problems.log"), "a") as fh:
        fh.write(text)


def log_problem_once(text):
    """Append only when the file does not already end with this exact text: a condition that
    holds on EVERY session start (no CLT installed) would otherwise grow the log by a line
    per terminal opened, forever."""
    try:
        with open(os.path.join(ROOT, "problems.log")) as fh:
            if fh.read().endswith(text):
                return
    except OSError:
        pass
    log_problem(text)


def toolchain_present():
    """Prompt-free probe for swiftc — mirror of probeToolchain() in main.swift.

    Never `xcrun --find` and never the bare /usr/bin/swiftc shim: on a Mac without the
    Command Line Tools both pop the system's "install the developer tools?" dialog — from a
    background SessionStart hook, out of nowhere, and again on every session start, because
    the failed build leaves the version gap in place. A missing toolchain must read as
    "cannot build", never as a prompt; the README lists CLT as the plugin channel's
    requirement, and problems.log gets the reason.
    """
    stock = ("/Library/Developer/CommandLineTools/usr/bin/swiftc",
             "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain"
             "/usr/bin/swiftc")
    if any(os.access(path, os.X_OK) for path in stock):
        return True
    try:
        probe = subprocess.run(["/usr/bin/xcode-select", "-p"],
                               capture_output=True, text=True, timeout=10)
    except (subprocess.TimeoutExpired, OSError):
        return False
    root = (probe.stdout or "").strip()
    if probe.returncode != 0 or not root:
        return False
    return any(os.access(root + suffix, os.X_OK) for suffix in
               ("/usr/bin/swiftc", "/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"))


def build(target, timeout=240):
    """timeout держит запас под внешним потолком хука (hooks.json: SessionStart timeout=300):
    равные потолки — гонка, в которой Claude Code убивает хук раньше, чем сюда доедут
    killpg и запись в problems.log, а start_new_session уводит детей сборки из группы,
    которую внешний kill вообще способен достать."""
    script = os.path.join(PLUGIN_ROOT, "build.sh")
    if not os.path.exists(script):
        return False
    # Своя группа процессов, и по таймауту умирает вся группа: subprocess.run(timeout=…)
    # убивал только непосредственного ребёнка (bash), а его swiftc/lipo/codesign жили дальше
    # без родителя. Сам TimeoutExpired никто не ловил — хук падал трейсбеком, который Claude
    # Code показывает как ошибку хука; затянувшаяся сборка — событие для problems.log.
    # stdout сборки не читается никем — в DEVNULL, не буферить зря.
    import signal

    proc = subprocess.Popen(["/bin/bash", script], stdout=subprocess.DEVNULL,
                            stderr=subprocess.PIPE, text=True,
                            env={**os.environ, "CONTROL_BAR_APP": target},
                            start_new_session=True)
    try:
        _, stderr = proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except OSError:
            pass
        # Слив ОГРАНИЧЕН по времени: communicate() ждёт EOF пайпов, а не смерти pid — потомок,
        # ушедший из группы (setsid внутри сборки), держал бы write-конец вечно, и хук висел
        # бы молча без следа в логе. Успевший слиться частичный stderr — последние слова
        # компилятора — идёт в лог, а не выбрасывается.
        try:
            _, stderr = proc.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            log_problem(f"build timed out after {timeout}s; SIGKILL sent but the tree did not "
                        f"exit within 5s — a descendant may have escaped the group\n")
            return False
        log_problem(f"build timed out after {timeout}s and was killed; last stderr:\n"
                    f"{(stderr or '')[-2000:]}\n")
        return False
    if proc.returncode != 0:
        log_problem(f"build failed:\n{stderr[-2000:]}\n")
        return False
    return True


def main():
    # The hook gets its event on stdin; `source` decides whether a launch is allowed below.
    # The pipe has to be drained either way; unreadable or unparseable both mean "no source".
    try:
        payload = json.loads(sys.stdin.read())
    except Exception:
        payload = {}

    if sys.platform != "darwin":
        return 0

    write_paths()
    claim_hooks()

    # A brew/DMG install owns /Applications. Building over it would corrupt a bundle Homebrew
    # believes it manages, and both copies would sit in the menu bar at once. The plugin defers
    # to it and builds its own copy only when that slot is empty.
    if bundle_version(SYSTEM_APP):
        if not running() and may_launch(payload):
            subprocess.Popen(["/usr/bin/open", "-g", "-b", BUNDLE_ID],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return 0

    if bundle_version(USER_APP) != plugin_version():
        if not toolchain_present():
            # No prompt-free swiftc anywhere: running build.sh would pop the system's
            # developer-tools dialog from a background hook (see toolchain_present). An older
            # resident build is still a working app — fall through and launch it instead of
            # leaving the menu bar empty until the tools appear.
            log_problem_once("cannot build the app: Xcode Command Line Tools are not "
                             "installed (run `xcode-select --install`); the plugin will "
                             "retry once they appear\n")
            if not bundle_version(USER_APP):
                return 0
        else:
            # One build at a time. Claude Code runs every matching SessionStart hook in
            # parallel, so two terminals opened together both notice the version gap and both
            # start a multi-minute compile of the same plugin directory. The loser of this
            # race skips: the winner's result is the same bundle it would have produced.
            import fcntl
            os.makedirs(ROOT, exist_ok=True)
            lock = open(os.path.join(ROOT, "build.lock"), "w")
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError:
                return 0
            try:
                if not build(USER_APP):
                    return 0
                # The previous version is still resident; a fresh build has to replace it.
                subprocess.run(["/usr/bin/pkill", "-x", EXEC], capture_output=True)
                # pkill returns on signal DELIVERY, not on exit: the dying process still
                # matches pgrep for a beat, and `not running()` below then skipped the
                # relaunch — the user's app was just killed and nothing brought it back
                # until the next event's self-heal.
                for _ in range(20):
                    if not running():
                        break
                    time.sleep(0.1)
            finally:
                lock.close()

    if not running() and may_launch(payload):
        subprocess.Popen(["/usr/bin/open", "-g", "-b", BUNDLE_ID],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return 0


if __name__ == "__main__":
    sys.exit(main())
