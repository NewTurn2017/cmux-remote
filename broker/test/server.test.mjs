import assert from "node:assert/strict";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { WebSocket } from "ws";
import { createBrokerServer, DeviceStore } from "../src/server.mjs";

const silentLogger = { error() {} };

async function fixture() {
  const directory = await mkdtemp(join(tmpdir(), "cmux-broker-"));
  const broker = await createBrokerServer({
    host: "127.0.0.1",
    port: 0,
    relayId: "home-mac",
    relayToken: "relay-token",
    pairingCode: "pairing-code",
    dataFile: join(directory, "devices.json"),
    trustProxy: false,
    heartbeatMs: 60_000,
    logger: silentLogger,
  });
  const address = await broker.listen();
  const baseURL = `http://127.0.0.1:${address.port}`;
  return {
    broker,
    directory,
    baseURL,
    async close() {
      await broker.close();
      await rm(directory, { recursive: true, force: true });
    },
  };
}

async function register(baseURL, pairingCode = "pairing-code") {
  return fetch(`${baseURL}/v1/devices/me/register`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      relay_id: "home-mac",
      pairing_code: pairingCode,
      client_id: "phone-client",
      device_name: "Test iPhone",
    }),
  });
}

function openWebSocket(url, options = {}) {
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(url, options);
    socket.once("open", () => resolve(socket));
    socket.once("error", reject);
  });
}

function nextMessage(socket) {
  return new Promise((resolve, reject) => {
    socket.once("message", (data) => resolve(data.toString()));
    socket.once("error", reject);
  });
}

function rejectedStatus(url, options = {}) {
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(url, options);
    socket.once("unexpected-response", (_request, response) => {
      resolve(response.statusCode);
      response.resume();
    });
    socket.once("open", () => reject(new Error("WebSocket unexpectedly opened")));
    socket.once("error", () => {});
  });
}

test("health reports whether the Mac relay is online", async () => {
  const fx = await fixture();
  try {
    const offline = await (await fetch(`${fx.baseURL}/v1/health`)).json();
    assert.equal(offline.ok, true);
    assert.equal(offline.relay_online, false);

    const relay = await openWebSocket(
      fx.baseURL.replace("http", "ws") + "/v1/relay/ws?relay_id=home-mac",
      { headers: { authorization: "Bearer relay-token" } },
    );
    const online = await (await fetch(`${fx.baseURL}/v1/health`)).json();
    assert.equal(online.relay_online, true);
    relay.close();
  } finally {
    await fx.close();
  }
});

test("pairing rejects a wrong code and stores only a token hash", async () => {
  const fx = await fixture();
  try {
    assert.equal((await register(fx.baseURL, "wrong-code")).status, 403);
    const response = await register(fx.baseURL);
    assert.equal(response.status, 200);
    const credentials = await response.json();
    assert.ok(credentials.device_id);
    assert.ok(credentials.token.length >= 40);

    const persisted = await readFile(join(fx.directory, "devices.json"), "utf8");
    assert.equal(persisted.includes(credentials.token), false);
    assert.match(persisted, /"token_hash": "[a-f0-9]{64}"/);
  } finally {
    await fx.close();
  }
});

test("phone upgrade returns 503 while the Mac relay is offline", async () => {
  const fx = await fixture();
  try {
    const credentials = await (await register(fx.baseURL)).json();
    const status = await rejectedStatus(
      fx.baseURL.replace("http", "ws") + "/v1/ws?relay_id=home-mac",
      { headers: { authorization: `Bearer ${credentials.token}` } },
    );
    assert.equal(status, 503);
  } finally {
    await fx.close();
  }
});

test("broker forwards raw phone frames through isolated session envelopes", async () => {
  const fx = await fixture();
  try {
    const credentials = await (await register(fx.baseURL)).json();
    const relay = await openWebSocket(
      fx.baseURL.replace("http", "ws") + "/v1/relay/ws?relay_id=home-mac",
      { headers: { authorization: "Bearer relay-token" } },
    );
    const openEnvelopePromise = nextMessage(relay);
    const phone = await openWebSocket(
      fx.baseURL.replace("http", "ws") + "/v1/ws?relay_id=home-mac",
      { headers: { authorization: `Bearer ${credentials.token}` } },
    );
    const opened = JSON.parse(await openEnvelopePromise);
    assert.equal(opened.type, "session.open");
    assert.equal(opened.device_id, credentials.device_id);

    const phoneText = '{"deviceId":"ignored","appVersion":"1","protocolVersion":1}';
    const inboundPromise = nextMessage(relay);
    phone.send(phoneText);
    const inbound = JSON.parse(await inboundPromise);
    assert.equal(inbound.type, "session.text");
    assert.equal(inbound.session_id, opened.session_id);
    assert.equal(inbound.text, phoneText);

    const outboundPromise = nextMessage(phone);
    relay.send(
      JSON.stringify({
        type: "session.text",
        session_id: opened.session_id,
        text: '{"id":"1","ok":true,"result":{}}',
      }),
    );
    assert.equal(await outboundPromise, '{"id":"1","ok":true,"result":{}}');
    phone.close();
    relay.close();
  } finally {
    await fx.close();
  }
});

test("revoking a device invalidates its bearer token", async () => {
  const fx = await fixture();
  try {
    const credentials = await (await register(fx.baseURL)).json();
    const store = new DeviceStore(join(fx.directory, "devices.json"));
    await store.load();
    assert.equal(
      (await store.authenticate(credentials.token, "home-mac"))?.device_id,
      credentials.device_id,
    );
    assert.equal(await store.revoke(credentials.device_id), true);
    assert.equal(await store.authenticate(credentials.token, "home-mac"), null);
  } finally {
    await fx.close();
  }
});

test("an external device revoke is honored on the next WebSocket upgrade", async () => {
  const fx = await fixture();
  try {
    const credentials = await (await register(fx.baseURL)).json();
    const externalStore = new DeviceStore(join(fx.directory, "devices.json"));
    await externalStore.load();
    assert.equal(await externalStore.revoke(credentials.device_id), true);

    const status = await rejectedStatus(
      fx.baseURL.replace("http", "ws") + "/v1/ws?relay_id=home-mac",
      { headers: { authorization: `Bearer ${credentials.token}` } },
    );
    assert.equal(status, 401);
  } finally {
    await fx.close();
  }
});

test("concurrent registrations persist every device", async () => {
  const directory = await mkdtemp(join(tmpdir(), "cmux-broker-store-"));
  try {
    const dataFile = join(directory, "devices.json");
    const store = new DeviceStore(dataFile);
    await store.load();

    await Promise.all([
      store.register({ relayId: "home-mac", clientId: "phone-a", deviceName: "Phone A" }),
      store.register({ relayId: "home-mac", clientId: "phone-b", deviceName: "Phone B" }),
    ]);

    const persisted = new DeviceStore(dataFile);
    await persisted.load();
    assert.deepEqual(
      persisted.allDevices().map((device) => device.client_id).sort(),
      ["phone-a", "phone-b"],
    );
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
