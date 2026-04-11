import http from "node:http";
import crypto from "node:crypto";
import os from "node:os";
import { execFile } from "node:child_process";

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
const CONFIGURED_COMMAND_TARGET = process.env.WATCHCONTROL_TMUX_TARGET || process.env.TMUX_SESSION || null;
const TMUX_MIRROR_INTERVAL_MS = parseInt(process.env.WATCHCONTROL_TMUX_MIRROR_INTERVAL_MS, 10) || 1_000;
const TMUX_MIRROR_HISTORY_LINES = parseInt(process.env.WATCHCONTROL_TMUX_MIRROR_HISTORY_LINES, 10) || 80;
const TMUX_MIRROR_EMIT_LINES = parseInt(process.env.WATCHCONTROL_TMUX_MIRROR_EMIT_LINES, 10) || 20;

const sessionTokens = new Set();
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
let tmuxMirrorTimer = null;
let tmuxMirrorBusy = false;
let tmuxMirrorTarget = null;
let tmuxMirrorLines = [];
let tmuxMirrorActive = false;
let tmuxMirrorLastError = null;

function generatePairingCode() {
  const code = crypto.randomInt(0, 1_000_000).toString().padStart(6, "0");
  pairingCode = code;
  pairingCodeExpiresAt = Date.now() + PAIRING_CODE_TTL_MS;
  log("info", `Pairing code: ${code}`);
  return code;
}

function generateSessionToken() {
  const token = crypto.randomBytes(32).toString("hex");
  sessionTokens.add(token);
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
  return sessionTokens.has(token);
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

function execFilePromise(command, args) {
  return new Promise((resolve, reject) => {
    execFile(command, args, (err, stdout) => {
      if (err) reject(err);
      else resolve(stdout);
    });
  });
}

async function resolveCommandTarget(requestedTarget) {
  if (requestedTarget) return requestedTarget;
  if (CONFIGURED_COMMAND_TARGET) return CONFIGURED_COMMAND_TARGET;

  const stdout = await execFilePromise("tmux", [
    "list-panes",
    "-a",
    "-F",
    "#{session_name}:#{window_index}.#{pane_index}\t#{pane_current_command}",
  ]);
  const panes = stdout.trim().split("\n").filter(Boolean).map((line) => {
    const [target, command = ""] = line.split("\t");
    return { target, command: command.toLowerCase() };
  });
  const preferred = panes.find((pane) => /^(claude|codex)$/.test(pane.command)) || panes[0];
  if (!preferred) throw new Error("No tmux panes available");
  return preferred.target;
}

function sendTmuxCommand(target, command) {
  return execFilePromise("tmux", ["send-keys", "-t", target, command, "Enter"]);
}

function captureTmuxPane(target) {
  return execFilePromise("tmux", [
    "capture-pane",
    "-p",
    "-J",
    "-S",
    `-${TMUX_MIRROR_HISTORY_LINES}`,
    "-t",
    target,
  ]);
}

function normalizeTmuxCapture(stdout) {
  return stdout
    .replace(/\r/g, "")
    .split("\n")
    .map((line) => line.replace(/\s+$/g, ""))
    .filter((line) => line.trim().length > 0);
}

function findNewTmuxLines(previous, next) {
  if (!previous.length) return next.slice(-TMUX_MIRROR_EMIT_LINES);

  const maxOverlap = Math.min(previous.length, next.length);
  for (let size = maxOverlap; size > 0; size--) {
    let matches = true;
    for (let index = 0; index < size; index++) {
      if (previous[previous.length - size + index] !== next[index]) {
        matches = false;
        break;
      }
    }
    if (matches) return next.slice(size);
  }

  const lastLine = previous[previous.length - 1];
  const lastIndex = next.lastIndexOf(lastLine);
  if (lastIndex >= 0) return next.slice(lastIndex + 1);

  return next.slice(-TMUX_MIRROR_EMIT_LINES);
}

async function pollTmuxMirror() {
  if (tmuxMirrorBusy) return;
  if (!sseClients.size && sessionState !== "connected") return;

  tmuxMirrorBusy = true;
  try {
    const target = await resolveCommandTarget(tmuxMirrorTarget);
    if (target !== tmuxMirrorTarget) {
      tmuxMirrorTarget = target;
      tmuxMirrorLines = [];
      log("info", `tmux mirror target: ${target}`);
    }

    const stdout = await captureTmuxPane(target);
    const nextLines = normalizeTmuxCapture(stdout);
    const newLines = findNewTmuxLines(tmuxMirrorLines, nextLines);
    tmuxMirrorLines = nextLines;
    tmuxMirrorActive = true;
    tmuxMirrorLastError = null;

    if (newLines.length) {
      pushSseEvent("pty-output", { text: `${newLines.join("\n")}\n`, source: "tmux-mirror", target });
    }
  } catch (err) {
    tmuxMirrorActive = false;
    tmuxMirrorLastError = err.message;
  } finally {
    tmuxMirrorBusy = false;
  }
}

function startTmuxMirror() {
  if (tmuxMirrorTimer || TMUX_MIRROR_INTERVAL_MS <= 0) return;
  tmuxMirrorTimer = setInterval(() => {
    pollTmuxMirror().catch((err) => {
      tmuxMirrorActive = false;
      tmuxMirrorLastError = err.message;
    });
  }, TMUX_MIRROR_INTERVAL_MS);
  pollTmuxMirror().catch((err) => {
    tmuxMirrorActive = false;
    tmuxMirrorLastError = err.message;
  });
}

async function sendTmuxSnapshot(client) {
  const target = await resolveCommandTarget(tmuxMirrorTarget);
  tmuxMirrorTarget = target;
  const stdout = await captureTmuxPane(target);
  const nextLines = normalizeTmuxCapture(stdout);
  tmuxMirrorLines = nextLines;
  tmuxMirrorActive = true;
  tmuxMirrorLastError = null;
  const snapshot = nextLines.slice(-TMUX_MIRROR_EMIT_LINES);
  if (!snapshot.length) return;

  client.write(formatSseMessage({
    event: "pty-output",
    data: JSON.stringify({ text: `${snapshot.join("\n")}\n`, source: "tmux-snapshot", target }),
  }));
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
  let msg = entry.id ? `id: ${entry.id}\n` : "";
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
      const decision = { behavior: "deny", reason: "Timed out" };
      pushSseEvent("permission-resolved", { permissionId, decision });
      resolve(decision);
    }, PERMISSION_TIMEOUT_MS);
    pendingPermissions.set(permissionId, { resolve, timer });
  });
}

function resolvePermission(permissionId, decision) {
  const pending = pendingPermissions.get(permissionId);
  if (!pending) return false;
  clearTimeout(pending.timer);
  pendingPermissions.delete(permissionId);
  pushSseEvent("permission-resolved", { permissionId, decision });
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

  const { command } = body;
  if (typeof command === "string" && command.trim().length > 0) {
    const commandText = command.trim();
    const requestedTarget = typeof body.target === "string" && body.target.trim().length > 0
      ? body.target.trim()
      : null;
    let target = requestedTarget || CONFIGURED_COMMAND_TARGET || "auto";
    try {
      target = await resolveCommandTarget(requestedTarget);
      tmuxMirrorTarget = target;
      await sendTmuxCommand(target, commandText);
      log("info", `Watch command sent to ${target}: ${commandText.slice(0, 120)}`);
      pushSseEvent("pty-output", { text: `> ${commandText}\n` });
      return jsonResponse(res, 200, { ok: true, target });
    } catch (err) {
      log("error", `Failed to send watch command to ${target}:`, err.message);
      return jsonResponse(res, 500, { error: `Failed to send command to ${target}` });
    }
  }

  return jsonResponse(res, 400, { error: "Missing permissionId+decision or command" });
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
  if (!lastIdHeader) {
    sendTmuxSnapshot(res).catch((err) => {
      tmuxMirrorActive = false;
      tmuxMirrorLastError = err.message;
    });
  }
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
  // Map the watch's allow/deny decision into the current Claude Code
  // PreToolUse hook spec: { hookSpecificOutput: { hookEventName: "PreToolUse",
  // permissionDecision: "allow" | "deny", permissionDecisionReason: "..." } }.
  // Older clients (manual curl tests, watch app pre-rebrand) keyed off
  // decision.behavior, so include both for backwards compatibility.
  const permissionDecision = decision.behavior === "allow" ? "allow" : "deny";
  const permissionDecisionReason =
    decision.reason ||
    (permissionDecision === "allow" ? "Approved from watch-control" : "Denied from watch-control");
  return jsonResponse(res, 200, {
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision,
      permissionDecisionReason,
      // Legacy fields kept so older callers don't break.
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
    hasPty: true,
    commandTarget: CONFIGURED_COMMAND_TARGET || "auto",
    terminalMirror: {
      active: tmuxMirrorActive,
      target: tmuxMirrorTarget || CONFIGURED_COMMAND_TARGET || "auto",
      intervalMs: TMUX_MIRROR_INTERVAL_MS,
      lastError: tmuxMirrorLastError,
    },
    sseClients: sseClients.size,
    pairedClients: sessionTokens.size,
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
  startTmuxMirror();
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
