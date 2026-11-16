/**
 * 在隔离 VM 中验证 Chrome / Safari 扩展的配对与消息边界。
 * 替身不会启动浏览器、读取用户配置或连接 Starcat；真实扩展生命周期仍需人工验收。
 */
import assert from "node:assert/strict";
import { webcrypto } from "node:crypto";
import { readFile } from "node:fs/promises";
import { setImmediate as settle } from "node:timers/promises";
import { fileURLToPath } from "node:url";
import vm from "node:vm";

const workspace = fileURLToPath(new URL("../", import.meta.url));
const connectionKey = "starcatCompanionConnection";
let passed = 0;

/** 使用虚拟时钟验证真实超时边界，不让回归用例实际等待 5 秒或 2 分钟。 */
function clockHarness() {
  let now = Date.now();
  let sequence = 0;
  const timers = new Map();
  class ClockDate extends Date {
    constructor(...values) { super(...(values.length ? values : [now])); }
    static now() { return now; }
  }
  return {
    Date: ClockDate,
    setTimeout(callback, delay) {
      const identity = ++sequence;
      timers.set(identity, { callback, at: now + Math.max(0, delay) });
      return identity;
    },
    clearTimeout(identity) { timers.delete(identity); },
    async advance(milliseconds) {
      const target = now + milliseconds;
      await settle();
      for (;;) {
        const next = [...timers].filter(([, timer]) => timer.at <= target)
          .sort((first, second) => first[1].at - second[1].at)[0];
        if (!next) break;
        now = next[1].at;
        timers.delete(next[0]);
        next[1].callback();
        await settle();
      }
      now = target;
      await settle();
    }
  };
}

/** 每次使用独立配置、凭据和网络替身，避免用共享状态掩盖设备隔离问题。 */
async function harness(browser, initial = {}, nativeHandler, clock = clockHarness()) {
  const storage = { ...initial };
  const credentials = new Map([["device-fixture", "fixture-token"]]);
  const calls = [];
  const control = {
    status: "pending",
    offline: false,
    failCredential: false,
    failMetadata: false,
    distinctInstances: false,
    hangPath: "",
    hangPort: "",
    hangBody: "",
    hangConfig: false,
    pollDelay: 0
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
        if (control.hangConfig) return new Promise(() => {});
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
    if (control.hangPath && url.pathname.endsWith(control.hangPath) && (!control.hangPort || url.port === control.hangPort)) {
      return new Promise((_resolve, reject) => {
        options.signal?.addEventListener("abort", () => reject(new Error("fixture_aborted")), { once: true });
      });
    }
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
      expires_at: new clock.Date(clock.Date.now() + 120000).toISOString()
    };
    if (url.pathname.endsWith("/poll")) body = control.status === "approved"
      ? { status: "approved", token: "paired-token", device_id: "paired-device", scope: "companion" }
      : { status: control.status };
    if (url.pathname.endsWith("/cancel")) body = { status: "cancelled" };
    if (url.pathname.endsWith("/poll") && control.pollDelay) {
      await new Promise((resolve) => clock.setTimeout(resolve, control.pollDelay));
    }
    return {
      ok: true, status: 200,
      json: async () => control.hangBody && url.pathname.endsWith(control.hangBody) ? new Promise(() => {}) : body
    };
  };
  const context = vm.createContext({
    chrome: api, browser: browser === "safari" ? api : undefined, indexedDB, fetch,
    crypto: webcrypto, URL, URLSearchParams, AbortSignal, AbortController, TextDecoder, console,
    Date: clock.Date, setTimeout: clock.setTimeout, clearTimeout: clock.clearTimeout
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
  return { storage, credentials, calls, control, send, pair, sender, clock, connect: (port) => connectListener(port) };
}

/** 只模拟配对页用到的 DOM 和扩展消息，不把 VM 检查表述为真实浏览器验收。 */
async function pageHarness(browser, handler, locale = "zh", page = "pairing", initial = {}, clock = clockHarness()) {
  const elements = new Map();
  const nodes = [];
  const sourceRoot = `${workspace}supports/extensions/starcat-${browser}-plugin/src`;
  const html = await readFile(`${sourceRoot}/${page}/${page}.html`, "utf8");
  for (const [, attributes] of html.matchAll(/<[a-z][a-z0-9-]*\b([^>]*)>/gi)) {
    const attributesByName = Object.fromEntries([...attributes.matchAll(/([\w-]+)="([^"]*)"/g)]
      .map(([, name, value]) => [name, value]));
    const events = new Map();
    const element = {
      value: "", textContent: "", disabled: false, hidden: /\bhidden\b/.test(attributes),
      dataset: Object.fromEntries(Object.entries(attributesByName).filter(([name]) => name.startsWith("data-"))
        .map(([name, value]) => [name.slice(5).replace(/-([a-z])/g, (_match, letter) => letter.toUpperCase()), value])),
      attributes: attributesByName,
      addEventListener(name, callback) { events.set(name, callback); },
      setAttribute(name, value) { this.attributes[name] = value; },
      replaceChildren() { this.children = []; this.value = ""; },
      add(option) { (this.children ||= []).push(option); },
      dispatch(name) { return events.get(name)?.({ preventDefault() {} }); }
    };
    nodes.push(element);
    if (attributesByName.id) elements.set(attributesByName.id, element);
  }
  const calls = [];
  const preferences = { starcatOptionsLocale: locale, ...initial };
  const api = {
    runtime: {
      getURL: (path) => `${browser === "safari" ? "safari-web-extension" : "chrome-extension"}://fixture/${path}`,
      async sendMessage(message) {
        calls.push(message);
        return handler(message, clock);
      }
    },
    storage: { local: {
      async get() { return preferences; },
      async set(values) { Object.assign(preferences, values); },
      async remove(keys) { for (const key of Array.isArray(keys) ? keys : [keys]) delete preferences[key]; }
    } }
  };
  const context = vm.createContext({
    chrome: api, browser: browser === "safari" ? api : undefined,
    document: {
      documentElement: { dataset: {}, removeAttribute() {} },
      getElementById: (identity) => elements.get(identity),
      querySelector: (selector) => elements.get(selector.slice(1)),
      querySelectorAll: (selector) => {
        const name = selector.slice(1, -1);
        return nodes.filter((element) => name in element.attributes);
      }
    },
    navigator: { language: locale },
    location: { protocol: browser === "safari" ? "safari-web-extension:" : "chrome-extension:" },
    matchMedia: () => ({ matches: true }),
    addEventListener() {},
    Option: function (label, value) { return { label, value }; },
    Date: clock.Date, setTimeout: clock.setTimeout, clearTimeout: clock.clearTimeout, URL
  });
  vm.runInContext(await readFile(`${sourceRoot}/shared/shared.js`, "utf8"), context);
  const ready = vm.runInContext(await readFile(`${sourceRoot}/${page}/${page}.js`, "utf8"), context);
  await settle();
  return { elements, nodes, calls, clock, context, ready, storage: preferences };
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
  assert.deepEqual(current.calls.map((call) => call.address), [
    "http://127.0.0.1:5444/plugin/v1/discover",
    "http://127.0.0.1:5051/plugin/v1/discover"
  ]);
  passed++;

  // A fresh profile probes the App default once, without a historical-port fallback.
  const defaults = await harness(browser);
  assert.equal((await defaults.pair("discover")).body.candidates.length, 1);
  assert.deepEqual(defaults.calls.map((call) => call.address), [
    "http://127.0.0.1:5051/plugin/v1/discover"
  ]);
  passed++;

  const multiple = await harness(browser, { starcatCompanionPort: 5444 });
  multiple.control.distinctInstances = true;
  assert.equal((await multiple.pair("discover")).body.candidates.length, 2);
  const probes = multiple.calls.length;
  assert.equal((await multiple.pair("start", { serviceURL: "" })).error, "service_selection_required");
  assert.equal(multiple.calls.length, probes);
  assert.equal((await multiple.pair("start", { serviceURL: "http://127.0.0.1:5444" })).body.code, "123456");
  assert.equal(new URL(multiple.calls.at(-1).address).port, "5444");
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

  const timeout = await harness(browser);
  timeout.control.hangPath = "/discover";
  let discoveryTimeout;
  timeout.pair("discover").then((reply) => { discoveryTimeout = reply; });
  await timeout.clock.advance(1300);
  assert.equal(discoveryTimeout?.error, "discovery_timeout");
  assert.equal(timeout.calls[0].options.signal.aborted, true);
  passed++;

  const partial = await harness(browser, { starcatCompanionPort: 5444 });
  partial.control.hangPath = "/discover";
  partial.control.hangPort = "5444";
  const partialReply = partial.pair("discover");
  await partial.clock.advance(1300);
  assert.equal((await partialReply).body.candidates[0].serviceURL, "http://127.0.0.1:5051");
  passed++;

  const configTimeout = await harness(browser);
  configTimeout.control.hangConfig = true;
  let configReply;
  configTimeout.pair("discover").then((reply) => { configReply = reply; });
  await configTimeout.clock.advance(4999);
  assert.equal(configReply, undefined);
  await configTimeout.clock.advance(1);
  assert.equal(configReply?.error, "discovery_timeout");
  passed++;

  const requestTimeout = await harness(browser);
  requestTimeout.control.hangPath = "/start";
  let requestReply;
  requestTimeout.pair("start").then((reply) => { requestReply = reply; });
  await requestTimeout.clock.advance(4999);
  assert.equal(requestReply, undefined);
  await requestTimeout.clock.advance(1);
  assert.equal(requestReply?.error, "connection_timeout");
  assert.equal(requestTimeout.calls.length, 1);
  passed++;
  const bodyTimeout = await harness(browser);
  bodyTimeout.control.hangBody = "/start";
  let bodyReply;
  bodyTimeout.pair("start").then((reply) => { bodyReply = reply; });
  await bodyTimeout.clock.advance(5000);
  assert.equal(bodyReply?.error, "connection_timeout");
  assert.equal(bodyTimeout.calls[0].options.signal.aborted, true);
  passed++;

  let completePoll;
  let starts = 0;
  const page = await pageHarness(browser, async (message, clock) => {
    if (message.action === "discover") return { ok: true, body: { candidates: [] } };
    if (message.action === "start") return {
      ok: true, body: { code: ++starts === 1 ? "123456" : "654321", expiresAt: new clock.Date(clock.Date.now() + 120000).toISOString() }
    };
    if (message.action === "cancel") return { ok: true, body: { status: "cancelled" } };
    return new Promise((resolve) => { completePoll = resolve; });
  });
  await page.elements.get("pairing-form").dispatch("submit");
  assert.match(page.elements.get("countdown")?.textContent || "", /120/);
  await page.clock.advance(1000);
  assert.match(page.elements.get("countdown").textContent, /119/);
  await page.clock.advance(119000);
  assert.equal(page.elements.get("code").textContent, "");
  assert.equal(page.elements.get("countdown").textContent, "");
  assert.match(page.elements.get("status").textContent, /过期/);
  assert.equal(page.elements.get("connect").disabled, false);
  assert.equal(page.elements.get("connect").textContent, "重新配对");
  assert.equal(page.calls.at(-1).action, "cancel");
  passed++;
  await page.elements.get("pairing-form").dispatch("submit");
  completePoll({ ok: true, body: { status: "approved" } });
  await settle();
  assert.equal(page.elements.get("code").textContent, "654321");
  assert.match(page.elements.get("status").textContent, /核对/);
  await page.elements.get("cancel").dispatch("click");
  assert.equal(page.elements.get("countdown").textContent, "");
  assert.match(page.elements.get("status").textContent, /取消/);
  passed++;

  let completeDiscovery;
  const searching = await pageHarness(browser, () => new Promise((resolve) => { completeDiscovery = resolve; }));
  assert.equal(searching.elements.get("connect").disabled, true);
  await searching.clock.advance(4999);
  assert.match(searching.elements.get("status").textContent, /正在查找/);
  await searching.clock.advance(1);
  await searching.ready;
  assert.match(searching.elements.get("status").textContent, /超时/);
  assert.equal(searching.elements.get("discover").disabled, false);
  assert.equal(searching.elements.get("manual").hidden, false);
  assert.equal(searching.elements.get("manual").attributes.href, "../options/options.html");
  completeDiscovery({ ok: true, body: { candidates: [{ channel: "late", serviceURL: "http://127.0.0.1:9999" }] } });
  await settle();
  assert.match(searching.elements.get("status").textContent, /超时/);
  assert.equal(searching.elements.get("instances").children.length, 1);
  passed++;

  const failures = [
    ["pairing_expired", /过期/, /expired/],
    ["credential_storage_failed", /保存配对凭据/, /save the pairing credentials/],
    ["connection_timeout", /5 秒/, /5 seconds/],
    ["native_host_unavailable", /本地连接组件/, /local connection component/],
    ["pairing_already_configured", /先取消配对/, /Unpair it/],
    ["fixture_secret_should_not_be_shown", /连接失败/, /Connection failed/]
  ];
  for (const locale of ["zh", "en"]) {
    for (const [code, chinese, english] of failures) {
      const failedPage = await pageHarness(browser, async (message) => message.action === "discover"
        ? { ok: true, body: { candidates: [] } } : { ok: false, error: code }, locale);
      await failedPage.elements.get("pairing-form").dispatch("submit");
      assert.match(failedPage.elements.get("status").textContent, locale === "zh" ? chinese : english);
      assert.equal(failedPage.elements.get("status").textContent.includes(code), false);
      assert.equal(failedPage.elements.get("connect").disabled, false);
      assert.equal(failedPage.elements.get("manual").hidden, false);
      passed++;
    }
    for (const terminalStatus of ["approved", "rejected", "expired"]) {
      const terminalPage = await pageHarness(browser, async (message, clock) => {
        if (message.action === "discover") return { ok: true, body: { candidates: [] } };
        if (message.action === "start") return {
          ok: true, body: { code: "123456", expiresAt: new clock.Date(clock.Date.now() + 120000).toISOString() }
        };
        return { ok: true, body: { status: terminalStatus } };
      }, locale);
      await terminalPage.elements.get("pairing-form").dispatch("submit");
      await terminalPage.clock.advance(2000);
      assert.equal(terminalPage.elements.get("code").textContent, "");
      assert.equal(terminalPage.elements.get("countdown").textContent, "");
      const terminalMessage = terminalPage.elements.get("status").textContent;
      await terminalPage.clock.advance(120000);
      assert.equal(terminalPage.elements.get("status").textContent, terminalMessage);
      passed++;
    }
    const manual = await pageHarness(browser, async () => ({ ok: false, error: "http_401", status: 401 }), locale, "options");
    manual.elements.get("token").value = "manual-fixture";
    manual.elements.get("service-url").value = "http://127.0.0.1:5051";
    await manual.elements.get("options-form").dispatch("submit");
    assert.equal(manual.storage.starcatCompanionToken, "manual-fixture");
    assert.equal(manual.calls.length, 0);
    await manual.elements.get("test").dispatch("click");
    assert.match(manual.elements.get("status").textContent, locale === "zh" ? /Key 无效/ : /Key is invalid/);
    assert.equal(manual.elements.get("status").textContent.includes("http_401"), false);
    passed++;
    const pairedOptions = await pageHarness(browser, async () => ({}), locale, "options", {
      [connectionKey]: { serviceURL: "http://127.0.0.1:5051", mode: "paired", deviceID: "fixture" }
    });
    pairedOptions.elements.get("token").value = "new-manual-fixture";
    await pairedOptions.elements.get("options-form").dispatch("submit");
    assert.match(pairedOptions.elements.get("status").textContent, locale === "zh" ? /先在配对页取消/ : /Unpair this browser/);
    assert.equal(pairedOptions.storage[connectionKey].deviceID, "fixture");
    assert.match(manual.elements.get("key-help").textContent, locale === "zh" ? /扩展与连接 → 浏览器扩展/ : /Extensions & Connections > Browser Extensions/);
    assert.equal(manual.elements.get("token").attributes["aria-describedby"], "key-help");
    passed++;
  }

  const restored = await pageHarness(browser, async (message, clock) => {
    if (message.action === "discover") return { ok: true, body: { candidates: [] } };
    if (message.action === "start") return {
      ok: true, body: { code: "123456", expiresAt: new clock.Date(clock.Date.now() + 45000).toISOString() }
    };
    return { ok: true, body: { status: "pending" } };
  });
  await restored.elements.get("pairing-form").dispatch("submit");
  assert.match(restored.elements.get("countdown").textContent, /45/);
  await restored.clock.advance(45000);
  assert.match(restored.elements.get("status").textContent, /过期/);
  passed++;

  // Share time across the actual page and background: approval may be in flight
  // at expiry, and its queued cancellation must remove the just-saved credential.
  const sharedClock = clockHarness();
  const claiming = await harness(browser, {}, undefined, sharedClock);
  const expiring = await pageHarness(browser, (message) => claiming.send(message), "zh", "pairing", {}, sharedClock);
  await expiring.ready;
  await expiring.elements.get("pairing-form").dispatch("submit");
  await sharedClock.advance(116000);
  claiming.control.status = "approved";
  claiming.control.pollDelay = 3000;
  await sharedClock.advance(4000);
  assert.match(expiring.elements.get("status").textContent, /过期/);
  assert.equal(claiming.storage[connectionKey], undefined);
  await sharedClock.advance(1000);
  assert.match(expiring.elements.get("status").textContent, /过期/);
  assert.equal(claiming.storage[connectionKey], undefined);
  assert.equal(claiming.credentials.has("paired-device"), false);
  assert.equal(new URL(claiming.calls.at(-1).address).pathname, "/plugin/v1/pairing/cancel");
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
assert.equal(fallback.calls.length, 1);
passed++;
const stalledNative = await harness("chrome", {}, () => new Promise(() => {}));
const nativeDiscovery = stalledNative.pair("discover");
await stalledNative.clock.advance(3499);
assert.equal(stalledNative.calls.length, 0);
await stalledNative.clock.advance(1);
assert.equal((await nativeDiscovery).body.candidates.length, 1);
assert.equal(stalledNative.calls.length, 1);
passed++;
const allStalled = await harness("chrome", {}, () => new Promise(() => {}));
allStalled.control.hangPath = "/discover";
let allStalledReply;
allStalled.pair("discover").then((reply) => { allStalledReply = reply; });
await allStalled.clock.advance(4999);
assert.equal(allStalledReply?.error, "discovery_timeout");
assert.equal(allStalled.calls.length, 1);
passed++;
const stalledWrite = await harness("chrome", {
  [connectionKey]: { serviceURL: "http://127.0.0.1:5051", mode: "paired", deviceID: "device-fixture", transport: "native" }
}, () => new Promise(() => {}));
let stalledWriteReply;
stalledWrite.send({ type: "starcat.localRequest", path: "/plugin/v1/notes", method: "PATCH", body: "{}" })
  .then((reply) => { stalledWriteReply = reply; });
await stalledWrite.clock.advance(5000);
assert.equal(stalledWriteReply?.error, "connection_timeout");
assert.equal(stalledWrite.calls.length, 0);
passed++;
let completeNativeDiscovery;
const lateNative = await harness("chrome", {}, () => new Promise((resolve) => { completeNativeDiscovery = resolve; }));
const lateDiscoveryReply = lateNative.pair("discover");
await lateNative.clock.advance(3500);
assert.equal((await lateDiscoveryReply).body.candidates.length, 1);
completeNativeDiscovery({ ok: true, body: { candidates: [{
  serviceURL: "http://127.0.0.1:5051", instanceID: "late-native", channel: "direct"
}] } });
await settle();
await lateNative.pair("start");
assert.equal(lateNative.calls.at(-1).address, "http://127.0.0.1:5051/plugin/v1/pairing/start");
passed++;
console.log(`PASS: ${passed} isolated browser control-flow checks; real browser acceptance remains separate.`);
