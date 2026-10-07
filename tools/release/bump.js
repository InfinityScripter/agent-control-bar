#!/usr/bin/env node
// Prepares a release commit: the next version in both manifests, and the CHANGELOG's
// `## [Unreleased]` section renamed to that version and today's date.
//
//   node tools/release/bump.js <patch|minor|major> [--date YYYY-MM-DD] [--root <dir>]
//
// Prints the new version on stdout and nothing else, so the "Release bump" workflow can read it.
// Merging the commit is what releases: release.yml sees the manifest's version change on main.
//
// Refuses — exit 1, files untouched — when there is no Unreleased section, or it is empty.
// release.yml would publish an empty section as the release notes, and the in-app "What's new"
// window would show the same nothing; a release worth cutting has something to say.
//
// The manifests are edited as text, not re-serialised: JSON.stringify would reflow the files and
// turn a one-line version bump into a diff nobody can review at a glance.
"use strict";
const fs = require("node:fs");
const path = require("node:path");

const MANIFESTS = [".claude-plugin/plugin.json", ".claude-plugin/marketplace.json"];
const UNRELEASED = /^## \[Unreleased\][^\n]*\n/m;

function next(version, part) {
  const m = /^(\d+)\.(\d+)\.(\d+)$/.exec(version);
  if (!m) throw new Error(`plugin.json version "${version}" is not x.y.z`);
  let [major, minor, patch] = m.slice(1).map(Number);
  if (part === "major") { major += 1; minor = 0; patch = 0; }
  else if (part === "minor") { minor += 1; patch = 0; }
  else if (part === "patch") { patch += 1; }
  else throw new Error(`bump must be patch, minor or major, not "${part}"`);
  return `${major}.${minor}.${patch}`;
}

// The body of the Unreleased section: up to the next `## [` heading or the end of the file.
function unreleasedBody(text) {
  const m = UNRELEASED.exec(text);
  if (!m) return null;
  const rest = text.slice(m.index + m[0].length);
  const end = rest.search(/^## \[/m);
  return (end === -1 ? rest : rest.slice(0, end)).trim();
}

function bump(root, part, date) {
  const read = (rel) => fs.readFileSync(path.join(root, rel), "utf8");
  const current = JSON.parse(read(MANIFESTS[0])).version;
  const version = next(current, part);

  const changelog = read("CHANGELOG.md");
  const body = unreleasedBody(changelog);
  if (body === null) {
    throw new Error("CHANGELOG.md has no `## [Unreleased]` section: add what this release "
      + "changes under that heading first");
  }
  if (!body) throw new Error("CHANGELOG.md's Unreleased section is empty: nothing to release");

  // Every write is computed before the first one lands, so a refusal leaves no half-bumped tree.
  const writes = MANIFESTS.map((rel) => {
    const before = read(rel);
    const pattern = new RegExp(`("version"\\s*:\\s*")${current.replace(/\./g, "\\.")}(")`, "g");
    const after = before.replace(pattern, `$1${version}$2`);
    if (after === before) throw new Error(`${rel} does not carry version ${current}`);
    return [rel, after];
  });
  writes.push(["CHANGELOG.md", changelog.replace(UNRELEASED, `## [${version}] - ${date}\n`)]);
  for (const [rel, text] of writes) fs.writeFileSync(path.join(root, rel), text);
  return version;
}

if (require.main === module) {
  const args = process.argv.slice(2);
  const flag = (name, fallback) => {
    const i = args.indexOf(name);
    return i === -1 ? fallback : args[i + 1];
  };
  try {
    const date = flag("--date", new Date().toISOString().slice(0, 10));
    if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) throw new Error(`--date "${date}" is not YYYY-MM-DD`);
    const root = path.resolve(flag("--root", path.join(__dirname, "../..")));
    process.stdout.write(bump(root, args[0], date) + "\n");
  } catch (err) {
    process.stderr.write(`bump: ${err.message}\n`);
    process.exit(1);
  }
}

module.exports = { next, bump, unreleasedBody };
