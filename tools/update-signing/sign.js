#!/usr/bin/env node
// Ed25519 signatures for the one-click update (Sources/Model/UpdateFeed.swift, `signingKey`).
//
// The DMG's sha256 comes from the same releases API response as its download URL, so on its own
// it proves the download is the file GitHub advertised — not that the maintainer made it. A
// signature by a key that never leaves the repository's secrets is the part a compromised
// account or a leaked token cannot forge.
//
// Keys are raw 32-byte values in base64, the shape CryptoKit's Curve25519.Signing reads as
// rawRepresentation: the private key is the RFC 8032 seed, the public key the encoded point.
// Signatures are the standard 64 bytes, base64, one line.
//
//   node tools/update-signing/sign.js keygen
//       prints the private key (→ repository secret UPDATE_SIGNING_KEY) and the public key
//       (→ UpdateFeed.signingKey). Run it once, on a trusted machine.
//   UPDATE_SIGNING_KEY=… node tools/update-signing/sign.js sign <file>          > <file>.sig
//   node tools/update-signing/sign.js verify <file> <file.sig> <public key>
//   UPDATE_SIGNING_KEY=… node tools/update-signing/sign.js public
//
// The private key is read from the environment only, never from argv: argv is visible to every
// process on the machine and lands in shell history.
"use strict";
const crypto = require("node:crypto");
const fs = require("node:fs");

// PKCS#8 wrapping of a raw Ed25519 seed (RFC 8410): a fixed 16-byte prefix, then the 32 bytes.
const PKCS8_PREFIX = Buffer.from("302e020100300506032b657004220420", "hex");
// SubjectPublicKeyInfo wrapping of a raw Ed25519 public key: a fixed 12-byte prefix.
const SPKI_PREFIX = Buffer.from("302a300506032b6570032100", "hex");

function raw32(b64, what) {
  const buf = Buffer.from(String(b64 || "").trim(), "base64");
  if (buf.length !== 32) throw new Error(`${what} must be 32 bytes in base64, got ${buf.length}`);
  return buf;
}

function privateKey(b64) {
  return crypto.createPrivateKey({
    key: Buffer.concat([PKCS8_PREFIX, raw32(b64, "private key")]), format: "der", type: "pkcs8",
  });
}

function publicKey(b64) {
  return crypto.createPublicKey({
    key: Buffer.concat([SPKI_PREFIX, raw32(b64, "public key")]), format: "der", type: "spki",
  });
}

function rawPublic(priv) {
  return crypto.createPublicKey(priv).export({ format: "der", type: "spki" })
    .subarray(SPKI_PREFIX.length).toString("base64");
}

function keygen() {
  const { privateKey: priv } = crypto.generateKeyPairSync("ed25519");
  const seed = priv.export({ format: "der", type: "pkcs8" }).subarray(PKCS8_PREFIX.length);
  return { privateKey: seed.toString("base64"), publicKey: rawPublic(priv) };
}

function sign(data, privB64) {
  return crypto.sign(null, data, privateKey(privB64)).toString("base64");
}

function verify(data, sigB64, pubB64) {
  const sig = Buffer.from(String(sigB64 || "").trim(), "base64");
  if (sig.length !== 64) return false;
  return crypto.verify(null, data, publicKey(pubB64), sig);
}

module.exports = { keygen, sign, verify, rawPublic, privateKey };

if (require.main === module) {
  const [cmd, ...args] = process.argv.slice(2);
  const secret = () => {
    const key = process.env.UPDATE_SIGNING_KEY;
    if (!key) { console.error("UPDATE_SIGNING_KEY is not set"); process.exit(2); }
    return key;
  };
  try {
    if (cmd === "keygen") {
      const k = keygen();
      console.log(`private (secret UPDATE_SIGNING_KEY): ${k.privateKey}`);
      console.log(`public  (UpdateFeed.signingKey):     ${k.publicKey}`);
    } else if (cmd === "public") {
      console.log(rawPublic(privateKey(secret())));
    } else if (cmd === "sign" && args.length === 1) {
      console.log(sign(fs.readFileSync(args[0]), secret()));
    } else if (cmd === "verify" && args.length === 3) {
      const ok = verify(fs.readFileSync(args[0]), fs.readFileSync(args[1], "utf8"), args[2]);
      console.log(ok ? "signature ok" : "signature does NOT match");
      process.exit(ok ? 0 : 1);
    } else {
      console.error("usage: sign.js keygen | public | sign <file> | verify <file> <sig> <pubkey>");
      process.exit(2);
    }
  } catch (err) {
    console.error(err.message);
    process.exit(2);
  }
}
