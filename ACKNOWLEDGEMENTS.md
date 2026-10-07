# Acknowledgements

Agent Control Bar is a fork of
**[claude-status-bar](https://github.com/m1ckc3s/claude-status-bar)** by
**[@m1ckc3s](https://github.com/m1ckc3s)** (Mick Cesanek), merged with
[claude-mcp-bar](https://github.com/InfinityScripter/claude-mcp-bar). The sessions model, the
animations, the self-launching lifecycle, the DMG pipeline and most of the Swift the app is
built on are his work.

Everyone credited below contributed to that upstream project; their work is in this one too.

---

Claude Status Bar's multi-session support grew out of several community contributions. Thank you to:

- **[@BrennenRocks](https://github.com/BrennenRocks)**, [PR #13](https://github.com/m1ckc3s/claude-status-bar/pull/13): the per-session / multi-session implementation. Major contributions here.
- **[@marcosarzuza](https://github.com/marcosarzuza)**, [PR #11](https://github.com/m1ckc3s/claude-status-bar/pull/11): the early multi-session precursor, plus multi-CLI testing and feedback.
- **[@angelo-swe](https://github.com/angelo-swe)**, [PR #17](https://github.com/m1ckc3s/claude-status-bar/pull/17): another take at multi-session and the priority-sorting menu design.
- **[@CXRommel](https://github.com/CXRommel)**, [PR #14](https://github.com/m1ckc3s/claude-status-bar/pull/14): multi-account support. More credit to come, this'll take things to the next level when we're ready for it.
- **[@nacalorea](https://github.com/nacalorea)**, [PR #18](https://github.com/m1ckc3s/claude-status-bar/pull/18): for the reminder to ship an Intel universal binary, not just Apple Silicon.
- **[@florianheysen](https://github.com/florianheysen)**, [PR #15](https://github.com/m1ckc3s/claude-status-bar/pull/15): suggested and provided the base for making Crab Walking follow the System color. Building on that, I tweaked it to add depth instead of the flat single-color approach. Thank you for this.
- **[@gingerbeardman](https://github.com/gingerbeardman)**, [issue #3](https://github.com/m1ckc3s/claude-status-bar/issues/3): an early supporter; an early bug report that pinned down the app quitting while Claude was still working.
- **[@ethan0905](https://github.com/ethan0905)**, [PR #37](https://github.com/m1ckc3s/claude-status-bar/pull/37): git branch names in the session rows and the parent-folder disambiguation for same-named projects, with a nicely cheap no-git-spawn HEAD read. I patched two edge cases after merging (a folder that becomes a repo mid-session stayed branchless until restart, and location-unknown sessions forced a bogus qualifier). Thank you for contributing.
- **[@moritzwendt](https://github.com/moritzwendt)**, [PR #34](https://github.com/m1ckc3s/claude-status-bar/pull/34): caught a build.sh bug where the signing-identity lookup aborted a from-source build under `set -eo pipefail` when no Developer ID cert is installed, instead of falling back to an ad-hoc build.

- **[@Bardin08](https://github.com/Bardin08)**, [issue #44](https://github.com/m1ckc3s/claude-status-bar/issues/44): a model bug report on the install-mid-session self-quit, complete with root cause, timing evidence, and fix options. It led to the 0.4.1 self-heal (hooks relaunch the app), which retired the whole "icon vanishes on first install" class of reports.
- **[@djalilmsk](https://github.com/djalilmsk)**, [issue #45](https://github.com/m1ckc3s/claude-status-bar/issues/45) + [PR #46](https://github.com/m1ckc3s/claude-status-bar/pull/46): found and fully diagnosed the one way the 0.4.0 rename transition could silently wedge a DMG upgrade (the old-named copy winning the launch forever), built and tested a fix for it, and exposed the real gap: my upgrade notes never said DMG users must launch the new copy once. The docs fix came straight from this report.
- **[@pedrol2b](https://github.com/pedrol2b)**, [PR #48](https://github.com/m1ckc3s/claude-status-bar/pull/48): found and fixed the Homebrew-Node time bomb (the installer pinned a version-specific Node path into the hooks, so a `brew upgrade node` silently killed the status bar), hardened it against minimal-PATH environments, and contributed the repo's first automated test suite along the way.
- **[@szhu](https://github.com/szhu)**, [homebrew-cask PR #274337](https://github.com/Homebrew/homebrew-cask/pull/274337): submitted Claude Status Bar to Homebrew unprompted, waited out the repo-age rule, and carried the cask through review to merge. `brew install --cask claude-status-bar` exists because of this.

Thanks as well to everyone who opened issues and pull requests along the way.
