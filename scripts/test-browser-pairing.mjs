/**
 * 在隔离 VM 中验证 Chrome / Safari 扩展的配对与消息边界。
 * 替身不会启动浏览器、读取用户配置或连接 Starcat；真实扩展生命周期仍需人工验收。
 */
import assert from "node:assert/strict";
import { webcrypto } from "node:crypto";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import vm from "node:vm";

const workspace = fileURLToPath(new URL("../", import.meta.url));
const connectionKey = "starcatCompanionConnection";
let passed = 0;

/** 每次使用独立配置、凭据和网络替身，避免用共享状态掩盖设备隔离问题。 */
async function harness(browser, initial = {}, nativeHandler) {
  const storage = { ...initial };
  const credentials = new Map([["device-fixture", "fixture-token"]]);
  const calls = [];
  const control = {
    status: "pending",
    offline: false,
    failCredential: false,
    failMetadata: false,
    distinctInstances: false
  };
  let messageListener;
  let connectListener;
  let sequence = 0;
  const scheme = browser === "safari" ? "safari-web-extension" : "chrome-extension";
  const identifier = "a".repeat(32);
  const root = `${scheme}://${identifier}/`;
  const runtime = {
    id: identifier,
    getURL: (path) => root + path,
    onMessage: { addListener: (listener) => { messageListener = listener; } },
    onConnect: { addListener: (listener) => { connectListener = listener; } },
    ...(nativeHandler ? { sendNativeMessage: nativeHandler } : {})
  };
  const indexedDB = {
    open() {
      const opening = {};
      opening.result = {
        close() {},
        transaction() {
          const transaction = {};
          transaction.objectStore = () => ({
            get(key) {
              const request = { result: credentials.get(key) };
              queueMicrotask(() => transaction.oncomplete());
              return request;
            },
            put(value, key) {
              if (control.failCredential) queueMicrotask(() => transaction.onerror());
              else {
                credentials.set(key, value);
                queueMicrotask(() => transaction.oncomplete());
              }
              return {};
            },
            delete(key) {
              credentials.delete(key);
              queueMicrotask(() => transaction.oncomplete());
              return {};
            }
          });
          return transaction;
        }
      };
      queueMicrotask(() => opening.onsuccess());
      return opening;
    }
  };
  const api = {
    runtime,
    storage: { local: {
      async get(keys) {
        return Object.fromEntries((Array.isArray(keys) ? keys : [keys]).map((key) => [key, storage[key]]));
      },
      async set(values) {
        if (control.failMetadata && values[connectionKey]) throw new Error("fixture_write_failed");
        Object.assign(storage, values);
      },
      async remove(keys) {
        for (const key of Array.isArray(keys) ? keys : [keys]) delete storage[key];
      },
      async setAccessLevel() {}
    } }
  };
  const fetch = async (address, options = {}) => {
    calls.push({ address, options });
    if (control.offline) throw new Error("fixture_offline");
    const url = new URL(address);
    let body = { ok: true };
    if (url.pathname.endsWith("/discover")) body = {
      product: "starcat",
      protocol_version: "1",
      pairing: "numeric_comparison",
      instance_id: control.distinctInstances ? `app-${url.port}` : "app-fixture",
      channel: "appstore"
    };
    if (url.pathname.endsWith("/start")) body = {
      request_id: `request-${++sequence}`,
      code: "123456",
      claim_secret: "fixture-claim",
      expires_at: new Date(Date.now() + 120000).toISOString()
    };
    if (url.pathname.endsWith("/poll")) body = control.status === "approved"
      ? { status: "approved", token: "paired-token", device_id: "paired-device", scope: "companion" }
      : { status: control.status };
    if (url.pathname.endsWith("/cancel")) body = { status: "cancelled" };
    return { ok: true, status: 200, json: async () => body };
  };
  const context = vm.createContext({
    chrome: api, browser: browser === "safari" ? api : undefined, indexedDB, fetch,
    crypto: webcrypto, URL, URLSearchParams, AbortSignal, AbortController, TextDecoder, console
  });
  const source = await readFile(`${workspace}supports/extensions/starcat-${browser}-plugin/src/background/background.js`, "utf8");
  vm.runInContext(source, context);
  const sender = { id: identifier, url: root + "src/pairing/pairing.html", tab: { id: 1 } };
  const send = (message, from = sender) => new Promise((resolve, reject) => {
    if (!messageListener(message, from, resolve)) reject(new Error("message_not_handled"));
  });
  const pair = (action, more = {}, from = sender) => send({
    type: "starcat.pairing",
    action,
    ...(action === "start" ? { serviceURL: "http://127.0.0.1:5051" } : {}),
    ...more
  }, from);
  return { storage, credentials, calls, control, send, pair, sender, connect: (port) => connectListener(port) };
}

for (const browser of ["chrome", "safari"]) {
  const manualToken = ["legacy", "fixture"].join("-");
  const current = await harness(browser, { starcatCompanionPort: 5444, starcatCompanionToken: manualToken });
  const publicConfig = await current.send({ type: "starcat.publicConfig" });
  assert.equal(publicConfig.serviceURL, "http://127.0.0.1:5444");
  assert.equal(publicConfig.configured, true);
  assert.equal(JSON.stringify(publicConfig).includes(manualToken), false);
  passed++;
  assert.equal((await current.pair("start", {}, { ...current.sender, url: "https://github.com/a/b" })).error, "extension_page_required");
  assert.equal((await current.pair("start", { serviceURL: "http://example.com:5051" })).error, "invalid_service_url");
  assert.equal(current.calls.length, 0);
  passed++;
  assert.equal((await current.send({ type: "starcat.localRequest", path: "/plugin/v1/pairing/poll", method: "POST" })).error, "unsupported_local_request");
  passed++;
  const discovery = await current.pair("discover");
  assert.equal(discovery.body.candidates.length, 1);
  assert.equal(current.calls.length, 3);
  passed++;

  const multiple = await harness(browser);
  multiple.control.distinctInstances = true;
  assert.equal((await multiple.pair("discover")).body.candidates.length, 2);
  const probes = multiple.calls.length;
  assert.equal((await multiple.pair("start", { serviceURL: "" })).error, "service_selection_required");
  assert.equal(multiple.calls.length, probes);
  assert.equal((await multiple.pair("start", { serviceURL: "http://127.0.0.1:5001" })).body.code, "123456");
  assert.equal(new URL(multiple.calls.at(-1).address).port, "5001");
  passed++;

  const started = await current.pair("start");
  assert.equal(started.body.code, "123456");
  assert.equal("claim_secret" in started.body, false);
  assert.equal((await current.pair("start")).error, "pairing_pending");
  assert.equal((await current.pair("poll", {}, { ...current.sender, tab: { id: 2 } })).error, "pairing_expired");
  passed++;
  current.control.status = "approved";
  assert.equal((await current.pair("poll")).body.status, "approved");
  assert.equal(current.storage.starcatCompanionToken, undefined);
  assert.equal(JSON.stringify(current.storage).includes("paired-token"), false);
  assert.equal(current.credentials.get("paired-device"), "paired-token");
  assert.equal(JSON.stringify(await current.pair("poll")).includes("paired-token"), false);
  assert.equal((await current.pair("start")).error, "pairing_already_configured");
  passed++;
  await current.send({ type: "starcat.localRequest", path: "/plugin/v1/ping" });
  assert.equal(current.calls.at(-1).options.headers.Authorization, "Bearer paired-token");
  current.control.offline = true;
  assert.equal((await current.pair("disconnect")).body.status, "revoke_failed");
  assert.ok(current.storage[connectionKey]);
  assert.equal((await current.pair("disconnect", { localOnly: true })).body.status, "local_only");
  assert.equal(current.storage[connectionKey], undefined);
  assert.equal(current.credentials.has("paired-device"), false);
  passed++;
  for (const failure of ["failCredential", "failMetadata"]) {
    const failed = await harness(browser);
    await failed.pair("start");
    failed.control.status = "approved";
    failed.control[failure] = true;
    assert.equal((await failed.pair("poll")).error, "credential_storage_failed");
    assert.ok(failed.calls.some((call) => call.address.endsWith("/devices/revoke-current")));
    assert.equal(failed.storage[connectionKey], undefined);
    assert.equal(failed.credentials.has("paired-device"), false);
    passed++;
  }
  const independent = await harness(browser);
  assert.equal((await independent.send({ type: "starcat.publicConfig" })).configured, false);
  assert.notEqual(independent.storage.starcatCompanionInstanceID, current.storage.starcatCompanionInstanceID);
  passed++;
  const cancelled = await harness(browser);
  await cancelled.pair("start");
  assert.equal((await cancelled.pair("cancel")).body.status, "cancelled");
  assert.equal((await cancelled.pair("poll")).error, "pairing_expired");
  const terminal = await harness(browser);
  await terminal.pair("start");
  terminal.control.status = "expired";
  assert.equal((await terminal.pair("poll")).body.status, "expired");
  assert.equal((await terminal.pair("poll")).error, "pairing_expired");
  passed++;
}

const nativeCalls = [];
const native = await harness("chrome", {
  [connectionKey]: { serviceURL: "http://127.0.0.1:5051", mode: "paired", deviceID: "device-fixture", transport: "native" }
}, async (_host, message) => {
  nativeCalls.push(message);
  throw new Error("fixture_native_unavailable");
});
await native.send({ type: "starcat.localRequest", path: "/plugin/v1/notes", method: "PATCH", body: "{}" });
assert.equal(nativeCalls.length, 1);
assert.equal(native.calls.length, 0);
passed++;
const fallback = await harness("chrome", {}, async () => { throw new Error("fixture_missing_host"); });
assert.equal((await fallback.pair("discover")).body.candidates.length, 1);
assert.equal(fallback.calls.length, 2);
passed++;
console.log(`PASS: ${passed} isolated browser control-flow checks; real browser acceptance remains separate.`);
