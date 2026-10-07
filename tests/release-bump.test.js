const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { execFileSync } = require("node:child_process");
const test = require("node:test");

const scriptPath = path.resolve(__dirname, "../tools/release/bump.js");
const { next, bump } = require(scriptPath);

const changelog = (unreleased) => [
  "# Changelog", "",
  ...(unreleased === undefined ? [] : ["## [Unreleased]", "", unreleased, ""]),
  "## [0.24.0] - 2026-10-06", "", "### Added", "- The agent selector.", "",
].join("\n");

const tree = (unreleased) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "bump-"));
  fs.mkdirSync(path.join(root, ".claude-plugin"));
  fs.writeFileSync(path.join(root, ".claude-plugin/plugin.json"),
    '{\n  "name": "x",\n  "version": "0.24.0",\n  "description": "y"\n}\n');
  fs.writeFileSync(path.join(root, ".claude-plugin/marketplace.json"),
    '{\n  "plugins": [\n    {\n      "name": "x",\n      "version": "0.24.0"\n    }\n  ]\n}\n');
  fs.writeFileSync(path.join(root, "CHANGELOG.md"), changelog(unreleased));
  return root;
};
const read = (root, rel) => fs.readFileSync(path.join(root, rel), "utf8");

test("each part bumps and resets the parts below it", () => {
  assert.equal(next("0.24.3", "patch"), "0.24.4");
  assert.equal(next("0.24.3", "minor"), "0.25.0");
  assert.equal(next("0.24.3", "major"), "1.0.0");
  assert.throws(() => next("0.24.3", "huge"), /patch, minor or major/);
  assert.throws(() => next("0.24", "patch"), /not x\.y\.z/);
});

test("a bump moves both manifests and names the Unreleased section", () => {
  const root = tree("### Fixed\n- A thing.");
  assert.equal(bump(root, "minor", "2026-10-07"), "0.25.0");
  assert.match(read(root, ".claude-plugin/plugin.json"), /"version": "0\.25\.0"/);
  assert.match(read(root, ".claude-plugin/marketplace.json"), /"version": "0\.25\.0"/);
  const log = read(root, "CHANGELOG.md");
  assert.match(log, /^## \[0\.25\.0\] - 2026-10-07\n\n### Fixed\n- A thing\.$/m);
  assert.doesNotMatch(log, /Unreleased/);
  assert.match(log, /^## \[0\.24\.0\] - 2026-10-06$/m, "earlier sections are left alone");
  assert.equal(read(root, ".claude-plugin/plugin.json"),
    '{\n  "name": "x",\n  "version": "0.25.0",\n  "description": "y"\n}\n',
    "the manifest keeps its formatting: only the number changes");
});

test("no Unreleased section, or an empty one, is refused with the tree untouched", () => {
  for (const unreleased of [undefined, ""]) {
    const root = tree(unreleased);
    const before = read(root, "CHANGELOG.md");
    assert.throws(() => bump(root, "patch", "2026-10-07"), /Unreleased/);
    assert.equal(read(root, "CHANGELOG.md"), before);
    assert.match(read(root, ".claude-plugin/plugin.json"), /"version": "0\.24\.0"/);
  }
});

test("the command line prints only the version, and fails loudly", () => {
  const root = tree("- Something.");
  const out = execFileSync(process.execPath,
    [scriptPath, "patch", "--date", "2026-10-07", "--root", root], { encoding: "utf8" });
  assert.equal(out, "0.24.1\n");
  assert.throws(() => execFileSync(process.execPath, [scriptPath, "patch", "--root", root],
    { stdio: "pipe" }), "a second bump finds no Unreleased section left");
});
