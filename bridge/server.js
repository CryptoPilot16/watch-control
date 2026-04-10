import http from "node:http";
import crypto from "node:crypto";
import os from "node:os";

function log(level, msg, ...args) {
  const ts = new Date().toISOString();
  const prefix = `[${ts}] [${level.toUpperCase()}]`;
  if (args.length) {
    console.log(prefix, msg, ...args);
  } else {
    console.log(prefix, msg);
  }
}

const PORT = parseInt(process.env.PORT, 10) || 7860;
const PAIRING_CODE_TTL_MS = 5 * 60 * 1000;
const RATE_LIMIT_WINDOW_MS = 5 * 60 * 1000;
const RATE_LIMIT_MAX_ATTEMPTS = 5;
const SSE_HEARTBEAT_INTERVAL_MS = 10_000;
const SSE_BUFFER_SIZE = 500;
const PERMISSION_TIMEOUT_MS = 600_000;
const SESSION_ID = crypto.randomUUID();

let sessionToken = null;
let pairingCode = null;
let pairingCodeExpiresAt = 0;
let rateLimitAttempts = 0;
let rateLimitWindowStart = Date.now();
let sessionState = "idle";
let sseEventId = 0;
const sseBuffer = [];
const sseClients = new Set();
const pendingPermissions = new Map();
const pendingPermissionBodies = new Map();

function generatePairingCode() {
  const code = crypto.randomInt(0, 1_000_000).toString().padStart(6, "0");
  pairingCode = code;
  pairingCodeExpiresAt = Date.now() + PAIRING_CODE_TTL_MS;
  log("info", `Pairing code: ${code}`);
  return code;
}

function generateSessionToken() {
  const token = crypto.randomBytes(32).toString("hex");
  sessionToken = token;
  return token;
}

function isRateLimited() {
  const now = Date.now();
  if (now - rateLimitWindowStart > RATE_LIMIT_WINDOW_MS) {
    rateLimitAttempts = 0;
    rateLimitWindowStart = now;
  }
  return rateLimitAttempts >= RATE_LIMIT_MAX_ATTEMPTS;
}

function recordRateLimitAttempt() {
  const now = Date.now();
  if (now - rateLimitWindowStart > RATE_LIMIT_WINDOW_MS) {
    rateLimitAttempts = 0;
    rateLimitWindowStart = now;
  }
  rateLimitAttempts++;
}

function requireAuth(req) {
  const auth = req.headers["authorization"];
  if (!auth || !auth.startsWith("Bearer ")) return false;
  const token = auth.slice(7);
  return token === sessionToken && sessionToken !== null;
}

function jsonResponse(res, status, body) {
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    "Content-Type": "application/json",
    "Content-Length": Buffer.byteLength(payload),
  });
  res.end(payload);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => {
      try {
        const raw = Buffer.concat(chunks).toString("utf-8");
        resolve(raw.length ? JSON.parse(raw) : {});
      } catch (err) {
        reject(err);
      }
    });
    req.on("error", reject);
  });
}

function pushSseEvent(event, data) {
  sseEventId++;
  const entry = { id: sseEventId, event, data: typeof data === "string" ? data : JSON.stringify(data) };
  if (sseBuffer.length >= SSE_BUFFER_SIZE) sseBuffer.shift();
  sseBuffer.push(entry);
  const formatted = formatSseMessage(entry);
  for (const client of sseClients) {
    try {
      client.write(formatted);
    } catch {
      sseClients.delete(client);
    }
  }
}

function formatSseMessage(entry) {
  let msg = `id: ${entry.id}\n`;
  msg += `event: ${entry.event}\n`;
  for (const line of entry.data.split("\n")) {
    msg += `data: ${line}\n`;
  }
  msg += "\n";
  return msg;
}

function waitForPermission(permissionId) {
  return new Promise((resolve) => {
    const timer = setTimeout(() => {
      pendingPermissions.delete(permissionId);
      log("warn", `Permission ${permissionId} timed out, auto-denying`);
      resolve({ behavior: "deny", reason: "Timed out" });
    }, PERMISSION_TIMEOUT_MS);
    pendingPermissions.set(permissionId, { resolve, timer });
  });
}

function resolvePermission(permissionId, decision) {
  const pending = pendingPermissions.get(permissionId);
  if (!pending) return false;
  clearTimeout(pending.timer);
  pendingPermissions.delete(permissionId);
  pending.resolve(decision);
  return true;
}

async function handlePair(req, res) {
  if (req.method !== "POST") return jsonResponse(res, 405, { error: "Method not allowed" });
  if (isRateLimited()) return jsonResponse(res, 429, { error: "Too many attempts" });
  let body;
  try { body = await readBody(req); } catch { return jsonResponse(res, 400, { error: "Invalid JSON" }); }
  recordRateLimitAttempt();
  const { code } = body;
  if (!code || typeof code !== "string") return jsonResponse(res, 400, { error: "Missing code" });
  if (Date.now() > pairingCodeExpiresAt) {
    generatePairingCode();
    return jsonResponse(res, 401, { error: "Code expired. New code generated." });
  }
  if (code !== pairingCode) return jsonResponse(res, 401, { error: "Invalid pairing code" });
  const token = generateSessionToken();
  pairingCode = null;
  pairingCodeExpiresAt = 0;
  sessionState = "connected";
  pushSseEvent("session", { state: "connected" });
  log("info", "Watch paired successfully");
  return jsonResponse(res, 200, { token, sessionId: SESSION_ID });
}

async function handleCommand(req, res) {
  if (req.method !== "POST") return jsonResponse(res, 405, { error: "Method not allowed" });
  if (!requireAuth(req)) return jsonResponse(res, 401, { error: "Unauthorized" });
  let body;
  try { body = await readBody(req); } catch { return jsonResponse(res, 400, { error: "Invalid JSON" }); }
  const { permissionId, decision } = body;
  if (permissionId && decision) {
    const resolved = resolvePermission(permissionId, decision);
    if (!resolved) return jsonResponse(res, 404, { error: "No pending permission" });
    log("info", `Permission ${permissionId} resolved: ${decision.behavior}`);
    return jsonResponse(res, 200, { ok: true });
  }
  return jsonResponse(res, 400, { error: "Missing permissionId+decision" });
}

function handleEvents(req, res) {
  if (req.method !== "GET") return jsonResponse(res, 405, { error: "Method not allowed" });
  if (!requireAuth(req)) return jsonResponse(res, 401, { error: "Unauthorized" });
  res.writeHead(200, {
    "Content-Type": "text/event-stream",
    "Cache-Control": "no-cache",
    Connection: "keep-alive",
    "X-Accel-Buffering": "no",
  });
  const lastIdHeader = req.headers["last-event-id"];
  if (lastIdHeader) {
    const lastId = parseInt(lastIdHeader, 10);
    if (!isNaN(lastId)) {
      for (const entry of sseBuffer) {
        if (entry.id > lastId) res.write(formatSseMessage(entry));
      }
    }
  }
  sseClients.add(res);
  log("info", `SSE client connected (total: ${sseClients.size})`);
  const heartbeat = setInterval(() => {
    try { res.write(":heartbeat\n\n"); } catch {
      clearInterval(heartbeat);
      sseClients.delete(res);
    }
  }, SSE_HEARTBEAT_INTERVAL_MS);
  req.on("close", () => {
    clearInterval(heartbeat);
    sseClients.delete(res);
    log("info", `SSE client disconnected (total: ${sseClients.size})`);
  });
}

async function handleHookPermission(req, res) {
  if (req.method !== "POST") return jsonResponse(res, 405, { error: "Method not allowed" });
  let body;
  try { body = await readBody(req); } catch { return jsonResponse(res, 400, { error: "Invalid JSON" }); }
  const permissionId = crypto.randomUUID();
  log("info", `Permission request received (id: ${permissionId})`, body.tool_name || "");
  if (body.permission_suggestions) pendingPermissionBodies.set(permissionId, body.permission_suggestions);
  pushSseEvent("permission-request", { permissionId, ...body });
  const decision = await waitForPermission(permissionId);
  log("info", `Permission resolved: ${decision.behavior}`);
  return jsonResponse(res, 200, {
    hookSpecificOutput: {
      hookEventName: "PermissionRequest",
      decision: { behavior: decision.behavior },
    },
  });
}

async function handleHookToolOutput(req, res) {
  if (req.method !== "POST") return jsonResponse(res, 405, { error: "Method not allowed" });
  let body;
  try { body = await readBody(req); } catch { return jsonResponse(res, 400, { error: "Invalid JSON" }); }
  log("info", "Hook: PostToolUse", body.tool_name || "");
  pushSseEvent("tool-output", body);
  return jsonResponse(res, 200, { ok: true });
}

async function handleHookStop(req, res) {
  if (req.method !== "POST") return jsonResponse(res, 405, { error: "Method not allowed" });
  let body;
  try { body = await readBody(req); } catch { return jsonResponse(res, 400, { error: "Invalid JSON" }); }
  log("info", "Hook: Stop");
  pushSseEvent("stop", body);
  return jsonResponse(res, 200, { ok: true });
}

async function handleCodexApproval(req, res) {
  if (req.method !== "POST") return jsonResponse(res, 405, { error: "Method not allowed" });
  let body;
  try { body = await readBody(req); } catch { return jsonResponse(res, 400, { error: "Invalid JSON" }); }
  const permissionId = crypto.randomUUID();
  const prompt = body.prompt || "Codex needs approval";
  const session = body.session || "codex";
  log("info", `Codex approval request (id: ${permissionId}): ${prompt}`);
  pushSseEvent("permission-request", {
    permissionId,
    tool_name: "codex",
    session,
    prompt,
    source: "codex",
  });
  const decision = await waitForPermission(permissionId);
  log("info", `Codex permission resolved: ${decision.behavior}`);
  return jsonResponse(res, 200, { approved: decision.behavior === "allow", behavior: decision.behavior });
}

function handleStatus(_req, res) {
  return jsonResponse(res, 200, {
    state: sessionState,
    sessionId: SESSION_ID,
    hasPty: false,
    sseClients: sseClients.size,
    pendingPermissions: pendingPermissions.size,
    eventBufferSize: sseBuffer.length,
  });
}

const routes = {
  "POST /pair": handlePair,
  "POST /command": handleCommand,
  "GET /events": handleEvents,
  "POST /hooks/permission": handleHookPermission,
  "POST /hooks/tool-output": handleHookToolOutput,
  "POST /hooks/stop": handleHookStop,
  "POST /hooks/codex": handleCodexApproval,
  "GET /status": handleStatus,
};

async function onRequest(req, res) {
  const url = new URL(req.url, `http://${req.headers.host}`);
  const routeKey = `${req.method} ${url.pathname}`;
  const handler = routes[routeKey];
  if (handler) {
    try {
      await handler(req, res);
    } catch (err) {
      log("error", `Error in ${routeKey}:`, err.message);
      if (!res.headersSent) jsonResponse(res, 500, { error: "Internal server error" });
    }
  } else {
    jsonResponse(res, 404, { error: "Not found" });
  }
}

const server = http.createServer(onRequest);
server.listen(PORT, "0.0.0.0", () => {
  const code = generatePairingCode();
  console.log("");
  console.log("╔═══════════════════════════════════════╗");
  console.log("║      WATCHCONTROL BRIDGE              ║");
  console.log("╠═══════════════════════════════════════╣");
  console.log(`║  Pairing Code:  ${code}                ║`);
  console.log(`║  Port:          ${String(PORT).padEnd(20)}║`);
  console.log("╚═══════════════════════════════════════╝");
  console.log("");
});

process.on("SIGINT", () => process.exit(0));
process.on("SIGTERM", () => process.exit(0));
