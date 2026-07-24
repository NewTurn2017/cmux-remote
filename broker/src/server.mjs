import { createHash, randomBytes, randomUUID, timingSafeEqual } from "node:crypto";
import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import http from "node:http";
import { dirname, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { WebSocket, WebSocketServer } from "ws";

const MAX_HTTP_BODY_BYTES = 64 * 1024;
export const MAX_WS_PAYLOAD_BYTES = 32 * 1024 * 1024;

function sha256(value) {
  return createHash("sha256").update(value, "utf8").digest("hex");
}

function secretEquals(left, right) {
  const a = Buffer.from(sha256(left));
  const b = Buffer.from(sha256(right));
  return timingSafeEqual(a, b);
}

function bearerToken(request) {
  const match = /^Bearer\s+(.+)$/i.exec(request.headers.authorization ?? "");
  return match?.[1]?.trim() || null;
}

function sendJSON(response, status, value) {
  const body = Buffer.from(JSON.stringify(value));
  response.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "content-length": body.length,
    "cache-control": "no-store",
  });
  response.end(body);
}

function sendEmpty(response, status) {
  response.writeHead(status, { "content-length": "0", "cache-control": "no-store" });
  response.end();
}

async function readJSON(request) {
  const chunks = [];
  let bytes = 0;
  for await (const chunk of request) {
    bytes += chunk.length;
    if (bytes > MAX_HTTP_BODY_BYTES) {
      const error = new Error("request body too large");
      error.statusCode = 413;
      throw error;
    }
    chunks.push(chunk);
  }
  if (chunks.length === 0) return {};
  try {
    return JSON.parse(Buffer.concat(chunks).toString("utf8"));
  } catch {
    const error = new Error("invalid JSON");
    error.statusCode = 400;
    throw error;
  }
}

function rejectUpgrade(socket, status, reason) {
  const body = Buffer.from(reason);
  const labels = {
    400: "Bad Request",
    401: "Unauthorized",
    404: "Not Found",
    500: "Internal Server Error",
    503: "Service Unavailable",
  };
  socket.end(
    `HTTP/1.1 ${status} ${labels[status] ?? "Error"}\r\n` +
      "Connection: close\r\n" +
      "Content-Type: text/plain; charset=utf-8\r\n" +
      `Content-Length: ${body.length}\r\n\r\n` +
      body,
  );
}

function requiredString(value, maxLength = 256) {
  return typeof value === "string" && value.length > 0 && value.length <= maxLength;
}

export class DeviceStore {
  constructor(path) {
    this.path = path;
    this.devices = [];
    this.operation = Promise.resolve();
  }

  async load() {
    return this.runExclusive(() => this.loadUnlocked());
  }

  async loadUnlocked() {
    await mkdir(dirname(this.path), { recursive: true });
    try {
      const parsed = JSON.parse(await readFile(this.path, "utf8"));
      this.devices = Array.isArray(parsed.devices) ? parsed.devices : [];
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
      this.devices = [];
    }
  }

  async saveUnlocked() {
    const temporaryPath = `${this.path}.${process.pid}.tmp`;
    const data = `${JSON.stringify({ version: 1, devices: this.devices }, null, 2)}\n`;
    await writeFile(temporaryPath, data, { mode: 0o600 });
    await rename(temporaryPath, this.path);
  }

  async register({ relayId, clientId, deviceName }) {
    return this.runExclusive(async () => {
      await this.loadUnlocked();
      const deviceId = randomUUID();
      const token = randomBytes(32).toString("base64url");
      this.devices = this.devices.filter(
        (device) => !(device.relay_id === relayId && device.client_id === clientId),
      );
      this.devices.push({
        device_id: deviceId,
        relay_id: relayId,
        client_id: clientId,
        device_name: deviceName,
        token_hash: sha256(token),
        registered_at: new Date().toISOString(),
      });
      await this.saveUnlocked();
      return { deviceId, token };
    });
  }

  async authenticate(token, relayId) {
    if (!token) return null;
    return this.runExclusive(async () => {
      // Device management runs in a separate process inside the container.
      // Reload before every new authentication so a revoke takes effect on
      // the next HTTP request or WebSocket reconnect without a broker restart.
      await this.loadUnlocked();
      const tokenHash = sha256(token);
      return (
        this.devices.find(
          (device) =>
            device.relay_id === relayId && secretEquals(device.token_hash, tokenHash),
        ) ?? null
      );
    });
  }

  async updateAPNs(deviceId, payload) {
    return this.runExclusive(async () => {
      await this.loadUnlocked();
      const device = this.devices.find((candidate) => candidate.device_id === deviceId);
      if (!device) return;
      device.apns_token_hash = sha256(payload.apns_token);
      device.apns_env = payload.env;
      await this.saveUnlocked();
    });
  }

  allDevices() {
    return this.devices.map(({ token_hash, apns_token_hash, ...device }) => device);
  }

  async revoke(deviceId) {
    return this.runExclusive(async () => {
      await this.loadUnlocked();
      const before = this.devices.length;
      this.devices = this.devices.filter((device) => device.device_id !== deviceId);
      if (this.devices.length === before) return false;
      await this.saveUnlocked();
      return true;
    });
  }

  runExclusive(operation) {
    const result = this.operation.then(operation, operation);
    this.operation = result.then(
      () => undefined,
      () => undefined,
    );
    return result;
  }
}

class SlidingWindowRateLimiter {
  constructor(limit, windowMs) {
    this.limit = limit;
    this.windowMs = windowMs;
    this.attempts = new Map();
  }

  allow(key, now = Date.now()) {
    const cutoff = now - this.windowMs;
    const recent = (this.attempts.get(key) ?? []).filter((value) => value > cutoff);
    if (recent.length >= this.limit) {
      this.attempts.set(key, recent);
      return false;
    }
    recent.push(now);
    this.attempts.set(key, recent);
    return true;
  }
}

function remoteIP(request, trustProxy) {
  if (trustProxy) {
    const forwarded = request.headers["x-forwarded-for"];
    if (typeof forwarded === "string") return forwarded.split(",", 1)[0].trim();
  }
  return request.socket.remoteAddress ?? "unknown";
}

export function configFromEnvironment(environment = process.env) {
  const config = {
    host: environment.CMUX_BROKER_HOST ?? "127.0.0.1",
    port: Number(environment.CMUX_BROKER_PORT ?? 4398),
    relayId: environment.CMUX_RELAY_ID ?? "",
    relayToken: environment.CMUX_RELAY_TOKEN ?? "",
    pairingCode: environment.CMUX_PAIRING_CODE ?? "",
    dataFile: resolve(environment.CMUX_BROKER_DATA_DIR ?? "./data", "devices.json"),
    trustProxy: environment.CMUX_TRUST_PROXY === "1",
  };
  if (!requiredString(config.relayId) || !requiredString(config.relayToken, 4096)) {
    throw new Error("CMUX_RELAY_ID and CMUX_RELAY_TOKEN are required");
  }
  if (!requiredString(config.pairingCode, 4096)) {
    throw new Error("CMUX_PAIRING_CODE is required");
  }
  if (!Number.isInteger(config.port) || config.port < 0 || config.port > 65535) {
    throw new Error("CMUX_BROKER_PORT must be a valid TCP port");
  }
  return config;
}

export async function createBrokerServer(options) {
  const config = { ...options };
  const logger = config.logger ?? console;
  const store = new DeviceStore(config.dataFile);
  await store.load();
  const rateLimiter = new SlidingWindowRateLimiter(config.pairingLimit ?? 5, 60_000);
  const relayConnections = new Map();
  const phoneSessions = new Map();

  const authenticatePhone = async (request, relayId) =>
    store.authenticate(bearerToken(request), relayId);

  const server = http.createServer(async (request, response) => {
    const url = new URL(request.url ?? "/", `http://${request.headers.host ?? "localhost"}`);
    try {
      if (request.method === "GET" && url.pathname === "/v1/health") {
        sendJSON(response, 200, {
          ok: true,
          relay_online: relayConnections.has(config.relayId),
          version: "0.1.0",
        });
        return;
      }

      if (request.method === "POST" && url.pathname === "/v1/devices/me/register") {
        if (!rateLimiter.allow(remoteIP(request, config.trustProxy))) {
          sendJSON(response, 429, { error: "too_many_pairing_attempts" });
          return;
        }
        const body = await readJSON(request);
        if (
          !requiredString(body.relay_id) ||
          !requiredString(body.pairing_code, 4096) ||
          !requiredString(body.client_id) ||
          !requiredString(body.device_name)
        ) {
          sendJSON(response, 400, { error: "invalid_registration" });
          return;
        }
        if (
          body.relay_id !== config.relayId ||
          !secretEquals(body.pairing_code, config.pairingCode)
        ) {
          sendJSON(response, 403, { error: "pairing_rejected" });
          return;
        }
        const registered = await store.register({
          relayId: body.relay_id,
          clientId: body.client_id,
          deviceName: body.device_name,
        });
        sendJSON(response, 200, {
          device_id: registered.deviceId,
          token: registered.token,
        });
        return;
      }

      if (request.method === "POST" && url.pathname === "/v1/devices/me/apns") {
        const relayId = url.searchParams.get("relay_id") ?? config.relayId;
        const device = await authenticatePhone(request, relayId);
        if (!device) {
          sendJSON(response, 401, { error: "unauthorized" });
          return;
        }
        const body = await readJSON(request);
        if (!requiredString(body.apns_token, 4096) || !["sandbox", "prod"].includes(body.env)) {
          sendJSON(response, 400, { error: "invalid_apns_registration" });
          return;
        }
        // The broker intentionally does not hold an Apple signing key. Keeping
        // only a hash lets a future E2E push service deduplicate registrations
        // without exposing the raw APNs device token at rest.
        await store.updateAPNs(device.device_id, body);
        sendEmpty(response, 204);
        return;
      }

      sendJSON(response, 404, { error: "not_found" });
    } catch (error) {
      logger.error?.("broker request failed", error);
      sendJSON(response, error.statusCode ?? 500, {
        error: error.statusCode ? error.message : "internal_error",
      });
    }
  });

  const relayWSS = new WebSocketServer({ noServer: true, maxPayload: MAX_WS_PAYLOAD_BYTES });
  const phoneWSS = new WebSocketServer({ noServer: true, maxPayload: MAX_WS_PAYLOAD_BYTES });

  function sendToRelay(relayId, envelope) {
    const relay = relayConnections.get(relayId);
    if (relay?.readyState !== WebSocket.OPEN) return false;
    relay.send(JSON.stringify(envelope));
    return true;
  }

  function closePhoneSession(sessionId, notifyRelay = true) {
    const session = phoneSessions.get(sessionId);
    if (!session) return;
    phoneSessions.delete(sessionId);
    if (notifyRelay) {
      sendToRelay(session.relayId, { type: "session.close", session_id: sessionId });
    }
  }

  relayWSS.on("connection", (socket, request, context) => {
    const previous = relayConnections.get(context.relayId);
    if (previous && previous !== socket) previous.close(4001, "replaced by a new relay connection");
    relayConnections.set(context.relayId, socket);
    socket.isAlive = true;
    socket.on("pong", () => {
      socket.isAlive = true;
    });
    socket.on("message", (data, isBinary) => {
      if (isBinary) return socket.close(1003, "text messages required");
      let envelope;
      try {
        envelope = JSON.parse(data.toString());
      } catch {
        return socket.close(1007, "invalid JSON");
      }
      if (
        !requiredString(envelope.session_id) ||
        !["session.text", "session.close"].includes(envelope.type)
      ) {
        return socket.close(1008, "invalid envelope");
      }
      const session = phoneSessions.get(envelope.session_id);
      if (!session || session.relayId !== context.relayId) return;
      if (envelope.type === "session.close") {
        session.socket.close(1000, "closed by relay");
        closePhoneSession(envelope.session_id, false);
        return;
      }
      if (typeof envelope.text !== "string") return socket.close(1008, "missing text");
      if (session.socket.readyState === WebSocket.OPEN) session.socket.send(envelope.text);
    });
    socket.on("close", () => {
      if (relayConnections.get(context.relayId) !== socket) return;
      relayConnections.delete(context.relayId);
      for (const [sessionId, session] of phoneSessions) {
        if (session.relayId !== context.relayId) continue;
        session.socket.close(1013, "Mac relay offline");
        closePhoneSession(sessionId, false);
      }
    });
  });

  phoneWSS.on("connection", (socket, request, context) => {
    const relay = relayConnections.get(context.relayId);
    if (relay?.readyState !== WebSocket.OPEN) {
      socket.close(1013, "Mac relay offline");
      return;
    }
    const sessionId = randomUUID();
    phoneSessions.set(sessionId, {
      socket,
      relayId: context.relayId,
      deviceId: context.device.device_id,
    });
    socket.isAlive = true;
    socket.on("pong", () => {
      socket.isAlive = true;
    });
    sendToRelay(context.relayId, {
      type: "session.open",
      session_id: sessionId,
      device_id: context.device.device_id,
    });
    socket.on("message", (data, isBinary) => {
      if (isBinary) return socket.close(1003, "text messages required");
      if (
        !sendToRelay(context.relayId, {
          type: "session.text",
          session_id: sessionId,
          text: data.toString(),
        })
      ) {
        socket.close(1013, "Mac relay offline");
      }
    });
    socket.on("close", () => closePhoneSession(sessionId));
  });

  async function handleUpgrade(request, socket, head) {
    let url;
    try {
      url = new URL(request.url ?? "/", `http://${request.headers.host ?? "localhost"}`);
    } catch {
      rejectUpgrade(socket, 400, "invalid URL");
      return;
    }
    const relayId = url.searchParams.get("relay_id") ?? "";
    if (url.pathname === "/v1/relay/ws") {
      const token = bearerToken(request);
      if (
        relayId !== config.relayId ||
        !token ||
        !secretEquals(token, config.relayToken)
      ) {
        rejectUpgrade(socket, 401, "invalid relay credentials");
        return;
      }
      relayWSS.handleUpgrade(request, socket, head, (webSocket) => {
        relayWSS.emit("connection", webSocket, request, { relayId });
      });
      return;
    }
    if (url.pathname === "/v1/ws") {
      const device = await authenticatePhone(request, relayId);
      if (!device) {
        rejectUpgrade(socket, 401, "invalid device credentials");
        return;
      }
      if (relayConnections.get(relayId)?.readyState !== WebSocket.OPEN) {
        rejectUpgrade(socket, 503, "Mac relay offline");
        return;
      }
      phoneWSS.handleUpgrade(request, socket, head, (webSocket) => {
        phoneWSS.emit("connection", webSocket, request, { relayId, device });
      });
      return;
    }
    rejectUpgrade(socket, 404, "not found");
  }

  server.on("upgrade", (request, socket, head) => {
    handleUpgrade(request, socket, head).catch((error) => {
      logger.error?.("broker upgrade failed", error);
      if (!socket.destroyed) rejectUpgrade(socket, 500, "internal error");
    });
  });

  const heartbeat = setInterval(() => {
    for (const webSocketServer of [relayWSS, phoneWSS]) {
      for (const socket of webSocketServer.clients) {
        if (socket.isAlive === false) {
          socket.terminate();
          continue;
        }
        socket.isAlive = false;
        socket.ping();
      }
    }
  }, config.heartbeatMs ?? 30_000);
  heartbeat.unref();

  return {
    server,
    async listen() {
      await new Promise((resolveListen, rejectListen) => {
        server.once("error", rejectListen);
        server.listen(config.port, config.host, () => {
          server.off("error", rejectListen);
          resolveListen();
        });
      });
      return server.address();
    },
    async close() {
      clearInterval(heartbeat);
      for (const webSocketServer of [relayWSS, phoneWSS]) {
        for (const socket of webSocketServer.clients) socket.terminate();
        webSocketServer.close();
      }
      if (server.listening) {
        await new Promise((resolveClose) => server.close(resolveClose));
      }
    },
  };
}

async function main() {
  const config = configFromEnvironment();
  const broker = await createBrokerServer(config);
  const address = await broker.listen();
  console.log(`cmux broker listening on ${address.address}:${address.port}`);
  const stop = async () => {
    await broker.close();
    process.exit(0);
  };
  process.once("SIGINT", stop);
  process.once("SIGTERM", stop);
}

const invokedDirectly =
  process.argv[1] && pathToFileURL(resolve(process.argv[1])).href === import.meta.url;
if (invokedDirectly) {
  main().catch((error) => {
    console.error(error);
    process.exit(1);
  });
}
