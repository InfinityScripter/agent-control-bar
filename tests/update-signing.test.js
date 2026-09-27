const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { execFileSync, spawnSync } = require("node:child_process");
const test = require("node:test");

const tool = path.resolve(__dirname, "../tools/update-signing/sign.js");
const { keygen, sign, verify, rawPublic, privateKey } = require(tool);

const hexToB64 = (hex) => Buffer.from(hex, "hex").toString("base64");

// RFC 8032 §7.1, TEST 2: the one-byte message 0x72. Ed25519 signatures are deterministic, so a
// published vector pins the key and signature encodings the app's CryptoKit check reads
// (tests/model/main.swift verifies the same vector on the Swift side).
const rfc = {
  seed: hexToB64("4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb"),
  pub: hexToB64("3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c"),
  msg: Buffer.from("72", "hex"),
  sig: hexToB64("92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da"
    + "085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00"),
};

test("raw keys and signatures match the RFC 8032 vector", () => {
  assert.equal(rawPublic(privateKey(rfc.seed)), rfc.pub);
  assert.equal(sign(rfc.msg, rfc.seed), rfc.sig);
  assert.equal(verify(rfc.msg, rfc.sig, rfc.pub), true);
});

test("a changed file, a foreign key or a malformed signature does not verify", () => {
  const other = keygen();
  assert.equal(verify(Buffer.from("73", "hex"), rfc.sig, rfc.pub), false);
  assert.equal(verify(rfc.msg, rfc.sig, other.publicKey), false);
  assert.equal(verify(rfc.msg, "not base64 at all", rfc.pub), false);
  assert.equal(verify(rfc.msg, rfc.sig.slice(0, 40), rfc.pub), false);
});

test("keygen produces a pair that signs and verifies", () => {
  const k = keygen();
  assert.equal(Buffer.from(k.privateKey, "base64").length, 32);
  assert.equal(Buffer.from(k.publicKey, "base64").length, 32);
  assert.equal(rawPublic(privateKey(k.privateKey)), k.publicKey);
  const sig = sign(Buffer.from("dmg bytes"), k.privateKey);
  assert.equal(verify(Buffer.from("dmg bytes"), sig, k.publicKey), true);
});

test("the CLI reads the private key from the environment only and round-trips a file", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "ccb-sign-"));
  try {
    const file = path.join(dir, "a.dmg");
    fs.writeFileSync(file, "image");
    const env = { ...process.env, UPDATE_SIGNING_KEY: rfc.seed };
    const sig = execFileSync(process.execPath, [tool, "sign", file], { env, encoding: "utf8" });
    fs.writeFileSync(file + ".sig", sig);
    const ok = spawnSync(process.execPath, [tool, "verify", file, file + ".sig", rfc.pub]);
    assert.equal(ok.status, 0);
    fs.writeFileSync(file, "tampered");
    const bad = spawnSync(process.execPath, [tool, "verify", file, file + ".sig", rfc.pub]);
    assert.equal(bad.status, 1);
    const { UPDATE_SIGNING_KEY, ...bare } = env;
    const missing = spawnSync(process.execPath, [tool, "sign", file], { env: bare });
    assert.equal(missing.status, 2);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
