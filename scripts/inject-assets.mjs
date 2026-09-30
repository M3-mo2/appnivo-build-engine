#!/usr/bin/env node
/**
 * Inject AppNivo inputs into the Android template (blueprint §9.5).
 *
 * Replaces the `__PLACEHOLDER__` tokens in `app/build.gradle.kts`,
 * `AndroidManifest.xml` and `strings.xml`, then copies the sanitized web source
 * into `app/src/main/assets`.
 *
 * User-controlled values are substituted in a single pass and XML-escaped for
 * the XML resources, so an app name such as `Tom & Jerry` (or one containing
 * `<`, `>`, `"`, `'`) cannot break the Gradle build or inject XML into the
 * merged manifest.
 */
import { cp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import process from "node:process";

const root = path.resolve(process.cwd(), "android-template");
const appDir = path.join(root, "app");
const assetsDir = path.join(appDir, "src", "main", "assets");
const stageDir = path.resolve(process.cwd(), "work", "staged");

function required(name) {
  const value = process.env[name];
  if (!value) {
    console.error(`Missing required environment variable ${name}`);
    process.exit(1);
  }
  return value;
}

const values = {
  __PACKAGE_NAME__: required("PACKAGE_NAME"),
  __APP_NAME__: required("APP_NAME"),
  __VERSION_NAME__: process.env.VERSION_NAME ?? "1.0.0",
  __VERSION_CODE__: process.env.VERSION_CODE ?? "1",
  __MIN_SDK__: process.env.MIN_SDK ?? "24",
  __TARGET_SDK__: process.env.TARGET_SDK ?? "34",
  __CLEARTEXT__: process.env.CLEARTEXT_TRAFFIC === "true" ? "true" : "false",
};

const TOKEN_PATTERN = new RegExp(`(${Object.keys(values).join("|")})`, "g");

/** Escape a value for use inside XML text or attribute values. */
function escapeXml(value) {
  return String(value)
    // Drop characters XML 1.0 forbids outright (NUL and most C0 controls).
    .replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\ufffe\uffff]/g, "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&apos;");
}

/**
 * One-pass token substitution: inserted values are never re-scanned, so a value
 * that itself contains a `__TOKEN__` cannot trigger a second replacement.
 * `escape` is applied to each value when the target is an XML resource.
 */
function applyTokens(contents, escape = null) {
  return contents.replace(TOKEN_PATTERN, (token) =>
    escape ? escape(values[token]) : values[token],
  );
}

async function replaceInFile(file, { xml }) {
  const contents = await readFile(file, "utf8");
  await writeFile(file, applyTokens(contents, xml ? escapeXml : null), "utf8");
}

await replaceInFile(path.join(appDir, "build.gradle.kts"), { xml: false });
await replaceInFile(path.join(appDir, "src", "main", "AndroidManifest.xml"), { xml: true });
await replaceInFile(path.join(appDir, "src", "main", "res", "values", "strings.xml"), { xml: true });

// Replace the placeholder assets with the user's site.
await rm(assetsDir, { recursive: true, force: true });
await mkdir(assetsDir, { recursive: true });
await cp(stageDir, assetsDir, { recursive: true });

console.log(`Injected ${values.__PACKAGE_NAME__} assets from ${stageDir}`);
