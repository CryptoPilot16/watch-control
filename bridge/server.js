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
const MAX_AGENT_TARGETS = parseInt(process.env.WATCHCONTROL_MAX_TARGETS, 10) || 4;
const AGENT_COMMAND_RE = /^(claude|codex)$/;
const TARGET_COLORS = ["dc2626", "0ea5e9", "22c55e", "e8a735"];
const PUSHOVER_APP_TOKEN = (process.env.PUSHOVER_APP_TOKEN || "").trim();
const PUSHOVER_USER_KEY = (process.env.PUSHOVER_USER_KEY || "").trim();
const PUSHOVER_DEVICE = (process.env.PUSHOVER_DEVICE || "").trim();
const WATCHCONTROL_NOTIFY_COOLDOWN_MS = parseInt(process.env.WATCHCONTROL_NOTIFY_COOLDOWN_MS, 10) || 30_000;

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
let activeCommandTarget = CONFIGURED_COMMAND_TARGET;
let tmuxMirrorTarget = activeCommandTarget;
let tmuxMirrorTargets = new Set(activeCommandTarget ? [activeCommandTarget] : []);
let tmuxMirrorLinesByTarget = new Map();
let tmuxMirrorActive = false;
let tmuxMirrorLastError = null;
const knownCommandTargets = new Map();
const remainOnExitTargets = new Set();
let lastApprovalNotificationAt = 0;

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
  if (activeCommandTarget) return activeCommandTarget;

  const targets = await listAgentTargets();
  const preferred = targets[0];
  if (!preferred) throw new Error("No Claude/Codex tmux pane available");
  activeCommandTarget = preferred.id;
  return preferred.id;
}

async function listAgentTargets() {
  const stdout = await execFilePromise("tmux", [
    "list-panes",
    "-a",
    "-F",
    "#{session_name}:#{window_index}.#{pane_index}\t#{pane_pid}\t#{pane_current_command}\t#{pane_current_path}\t#{pane_title}\t#{pane_dead}",
  ]);
  const panes = stdout
    .trim()
    .split("\n")
    .filter(Boolean)
    .map((line) => {
      const [id, pid = "", command = "", path = "", title = "", dead = "0"] = line.split("\t");
      return { id, pid, command: command.toLowerCase(), path, title, dead: dead === "1" };
    });
  const paneIds = new Set(panes.map((pane) => pane.id));
  for (const target of [...knownCommandTargets.keys()]) {
    if (!paneIds.has(target)) {
      knownCommandTargets.delete(target);
      tmuxMirrorTargets.delete(target);
      tmuxMirrorLinesByTarget.delete(target);
      remainOnExitTargets.delete(target);
      if (activeCommandTarget === target) activeCommandTarget = null;
      if (tmuxMirrorTarget === target) tmuxMirrorTarget = null;
    }
  }

  const processes = await listProcesses();
  const targets = [];
  const remainOnExitTasks = [];
  for (const pane of panes) {
    const previous = knownCommandTargets.get(pane.id);
    const agentCommand = pane.dead ? "" : resolveAgentCommand(pane, processes);
    if (!agentCommand && !previous) continue;

    if (agentCommand && !remainOnExitTargets.has(pane.id)) {
      remainOnExitTasks.push(setPaneRemainOnExit(pane.id).then(() => {
        remainOnExitTargets.add(pane.id);
      }));
    }

    const target = {
      ...pane,
      command: agentCommand || normalizeTargetCommand(pane.command, pane.dead),
      color: previous?.color || TARGET_COLORS[targets.length % TARGET_COLORS.length],
    };
    targets.push(target);
    knownCommandTargets.set(pane.id, target);
  }

  if (remainOnExitTasks.length) {
    await Promise.all(remainOnExitTasks.map((task) => task.catch((err) => {
      log("warn", "Unable to mark tmux pane remain-on-exit:", err.message);
    })));
  }

  return targets.slice(0, MAX_AGENT_TARGETS);
}

function normalizeTargetCommand(command, dead) {
  if (dead) return "closed";
  if (!command || ["bash", "sh", "zsh", "fish", "login"].includes(command)) return "shell";
  return command;
}

function setPaneRemainOnExit(target) {
  return execFilePromise("tmux", ["set-option", "-p", "-t", target, "remain-on-exit", "on"]);
}

async function ensureTmuxTargetAlive(target) {
  const stdout = await execFilePromise("tmux", ["display-message", "-p", "-t", target, "#{pane_dead}"]);
  if (stdout.trim() !== "1") return false;

  await execFilePromise("tmux", ["respawn-pane", "-k", "-t", target]);
  const previous = knownCommandTargets.get(target);
  if (previous) knownCommandTargets.set(target, { ...previous, command: "shell", dead: false });
  tmuxMirrorLinesByTarget.delete(target);
  tmuxMirrorActive = false;
  log("info", `Respawned dead tmux pane ${target} into a shell`);
  return true;
}

async function listProcesses() {
  try {
    const stdout = await execFilePromise("ps", ["-eo", "pid=,ppid=,comm=,args="]);
    return stdout
      .trim()
      .split("\n")
      .filter(Boolean)
      .map((line) => {
        const match = line.trim().match(/^(\d+)\s+(\d+)\s+(\S+)\s+(.*)$/);
        if (!match) return null;
        return {
          pid: match[1],
          ppid: match[2],
          command: match[3].toLowerCase(),
          args: match[4].toLowerCase(),
        };
      })
      .filter(Boolean);
  } catch {
    return [];
  }
}

function resolveAgentCommand(pane, processes) {
  if (AGENT_COMMAND_RE.test(pane.command)) return pane.command;

  const descendantPids = new Set([pane.pid]);
  let changed = true;
  while (changed) {
    changed = false;
    for (const process of processes) {
      if (!descendantPids.has(process.pid) && descendantPids.has(process.ppid)) {
        descendantPids.add(process.pid);
        changed = true;
      }
    }
  }

  for (const process of processes) {
    if (!descendantPids.has(process.pid)) continue;
    if (AGENT_COMMAND_RE.test(process.command)) return process.command;
    if (process.args.includes("/codex") || process.args.includes(" codex")) return "codex";
    if (process.args.includes("/claude") || process.args.includes(" claude")) return "claude";
  }

  return "";
}

function isPidDescendantOfPane(pid, panePid, processes) {
  const targetPid = String(pid || "");
  if (!targetPid) return false;

  const descendantPids = new Set([String(panePid)]);
  let changed = true;
  while (changed) {
    changed = false;
    for (const process of processes) {
      if (!descendantPids.has(process.pid) && descendantPids.has(process.ppid)) {
        descendantPids.add(process.pid);
        changed = true;
      }
    }
  }

  return descendantPids.has(targetPid);
}

async function isTrackedHookRequest(body) {
  const hook = body.watchcontrol_hook || {};
  const hookPid = hook.agent_pid || hook.hook_pid;
  if (!hookPid) return false;

  const targets = await listAgentTargets();
  const allowedTargetIds = new Set(syncMirrorTargetsWithTargets(targets));
  const processes = await listProcesses();
  return targets
    .filter((target) => allowedTargetIds.has(target.id))
    .some((target) => isPidDescendantOfPane(hookPid, target.pid, processes));
}

function ignoredHookResponse(res, reason) {
  return jsonResponse(res, 200, {
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "ask",
      permissionDecisionReason: reason,
      decision: { behavior: "ask" },
    },
  });
}

function syncMirrorTargetsWithTargets(targets) {
  const validIds = new Set(targets.map((target) => target.id));

  for (const target of [...tmuxMirrorTargets]) {
    if (!validIds.has(target)) {
      tmuxMirrorTargets.delete(target);
      tmuxMirrorLinesByTarget.delete(target);
    }
  }

  if (!activeCommandTarget && targets[0]) activeCommandTarget = targets[0].id;

  if (!tmuxMirrorTargets.size) {
    const fallback =
      activeCommandTarget && validIds.has(activeCommandTarget)
        ? activeCommandTarget
        : targets[0]?.id;
    if (fallback) tmuxMirrorTargets.add(fallback);
  }

  if (!tmuxMirrorTarget || !validIds.has(tmuxMirrorTarget)) {
    tmuxMirrorTarget =
      activeCommandTarget && validIds.has(activeCommandTarget)
        ? activeCommandTarget
        : [...tmuxMirrorTargets][0] || null;
  }

  const mirroredTargets = [...tmuxMirrorTargets]
    .filter((target) => validIds.has(target))
    .slice(0, MAX_AGENT_TARGETS);
  tmuxMirrorTargets = new Set(mirroredTargets);
  return mirroredTargets;
}

function serializeTargets(targets) {
  const mirrorTargets = new Set(syncMirrorTargetsWithTargets(targets));
  return targets.map((target) => ({
    ...target,
    active: target.id === activeCommandTarget,
    mirrored: mirrorTargets.has(target.id),
  }));
}

async function resolveMirrorTargets() {
  const targets = await listAgentTargets();
  const mirrorTargets = syncMirrorTargetsWithTargets(targets);
  if (!mirrorTargets.length) throw new Error("No Claude/Codex tmux pane available");
  return mirrorTargets;
}

async function setActiveCommandTarget(target) {
  const targets = await listAgentTargets();
  const selected = targets.find((item) => item.id === target);
  if (!selected) throw new Error(`Target ${target} is not an active Claude/Codex pane`);

  activeCommandTarget = selected.id;
  tmuxMirrorTarget = selected.id;
  tmuxMirrorTargets.add(selected.id);
  if (tmuxMirrorTargets.size > MAX_AGENT_TARGETS) {
    tmuxMirrorTargets = new Set([...tmuxMirrorTargets].slice(-MAX_AGENT_TARGETS));
  }
  tmuxMirrorLinesByTarget.delete(selected.id);
  tmuxMirrorActive = false;
  tmuxMirrorLastError = null;
  log("info", `Active tmux target: ${selected.id}`);
  scheduleTmuxMirrorRefresh();
  return selected;
}

async function setMirroredCommandTargets(targets) {
  if (!Array.isArray(targets)) throw new Error("targets must be an array");

  const requested = [...new Set(targets)]
    .filter((target) => typeof target === "string" && target.trim().length > 0)
    .map((target) => target.trim())
    .slice(0, MAX_AGENT_TARGETS);

  const agentTargets = await listAgentTargets();
  const validIds = new Set(agentTargets.map((target) => target.id));
  const selected = requested.filter((target) => validIds.has(target));
  if (!selected.length) throw new Error("Select at least one active Claude/Codex pane");

  tmuxMirrorTargets = new Set(selected);
  for (const target of [...tmuxMirrorLinesByTarget.keys()]) {
    if (!tmuxMirrorTargets.has(target)) tmuxMirrorLinesByTarget.delete(target);
  }
  tmuxMirrorTarget = activeCommandTarget && validIds.has(activeCommandTarget)
    ? activeCommandTarget
    : selected[0];
  if (!activeCommandTarget || !validIds.has(activeCommandTarget)) activeCommandTarget = selected[0];
  tmuxMirrorActive = false;
  tmuxMirrorLastError = null;
  log("info", `Mirroring tmux targets: ${selected.join(", ")}`);
  scheduleTmuxMirrorRefresh();
  return serializeTargets(agentTargets);
}


async function sendTmuxCommand(target, command) {
  await execFilePromise("tmux", ["send-keys", "-t", target, "-l", "--", command]);
  return execFilePromise("tmux", ["send-keys", "-t", target, "Enter"]);
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
    const targets = await resolveMirrorTargets();
    for (const target of targets) {
      if (target !== tmuxMirrorTarget && activeCommandTarget === target) {
        tmuxMirrorTarget = target;
        log("info", `tmux mirror target: ${target}`);
      }

      const stdout = await captureTmuxPane(target);
      const nextLines = normalizeTmuxCapture(stdout);
      const previousLines = tmuxMirrorLinesByTarget.get(target) || [];
      const newLines = findNewTmuxLines(previousLines, nextLines);
      tmuxMirrorLinesByTarget.set(target, nextLines);

      if (newLines.length) {
        pushSseEvent("pty-output", { text: `${newLines.join("\n")}\n`, source: "tmux-mirror", target });
      }
    }

    tmuxMirrorActive = targets.length > 0;
    tmuxMirrorLastError = null;
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

function scheduleTmuxMirrorRefresh() {
  for (const delay of [250, 1_250, 2_500]) {
    setTimeout(() => {
      pollTmuxMirror().catch((err) => {
        tmuxMirrorActive = false;
        tmuxMirrorLastError = err.message;
      });
    }, delay);
  }
}

async function pushTmuxSnapshotEvent() {
  if (tmuxMirrorBusy) return;

  tmuxMirrorBusy = true;
  try {
    const targets = await resolveMirrorTargets();
    for (const target of targets) {
      const stdout = await captureTmuxPane(target);
      const nextLines = normalizeTmuxCapture(stdout);
      tmuxMirrorLinesByTarget.set(target, nextLines);
      const snapshot = nextLines.slice(-TMUX_MIRROR_EMIT_LINES);
      if (!snapshot.length) continue;
      pushSseEvent("pty-output", { text: `${snapshot.join("\n")}\n`, source: "tmux-snapshot", target });
    }
    tmuxMirrorActive = targets.length > 0;
    tmuxMirrorLastError = null;
  } finally {
    tmuxMirrorBusy = false;
  }
}

async function sendTmuxSnapshot(client) {
  if (tmuxMirrorBusy) return;

  tmuxMirrorBusy = true;
  try {
    const targets = await resolveMirrorTargets();
    for (const target of targets) {
      const stdout = await captureTmuxPane(target);
      const nextLines = normalizeTmuxCapture(stdout);
      tmuxMirrorLinesByTarget.set(target, nextLines);
      const snapshot = nextLines.slice(-TMUX_MIRROR_EMIT_LINES);
      if (!snapshot.length) continue;

      client.write(formatSseMessage({
        event: "pty-output",
        data: JSON.stringify({ text: `${snapshot.join("\n")}\n`, source: "tmux-snapshot", target }),
      }));
    }
    tmuxMirrorActive = targets.length > 0;
    tmuxMirrorLastError = null;
  } finally {
    tmuxMirrorBusy = false;
  }
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

function approvalNotificationAvailable() {
  return PUSHOVER_APP_TOKEN.length > 0 && PUSHOVER_USER_KEY.length > 0;
}

function summarizePermissionRequest(body) {
  const toolName = body.tool_name || "Tool";
  const toolInput = body.tool_input || {};
  if (typeof toolInput.command === "string" && toolInput.command.trim()) {
    return `${toolName}: ${toolInput.command.trim().slice(0, 120)}`;
  }
  if (typeof toolInput.file_path === "string" && toolInput.file_path.trim()) {
    return `${toolName}: ${toolInput.file_path.trim().split("/").pop()}`;
  }
  if (Array.isArray(toolInput.questions) && toolInput.questions[0]?.question) {
    return `${toolName}: ${String(toolInput.questions[0].question).slice(0, 120)}`;
  }
  return `${toolName}: approval requested`;
}

async function sendApprovalNotification(body) {
  if (!approvalNotificationAvailable()) return;

  const now = Date.now();
  if (now - lastApprovalNotificationAt < WATCHCONTROL_NOTIFY_COOLDOWN_MS) return;
  lastApprovalNotificationAt = now;

  const params = new URLSearchParams();
  params.set("token", PUSHOVER_APP_TOKEN);
  params.set("user", PUSHOVER_USER_KEY);
  params.set("title", "Claude Approval Needed");
  params.set("message", summarizePermissionRequest(body));
  params.set("priority", "0");
  if (PUSHOVER_DEVICE) params.set("device", PUSHOVER_DEVICE);

  try {
    const response = await fetch("https://api.pushover.net/1/messages.json", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: params.toString(),
    });
    if (!response.ok) {
      const text = await response.text();
      log("warn", `Failed to send approval notification: HTTP ${response.status} ${text}`);
    }
  } catch (err) {
    log("warn", "Failed to send approval notification:", err.message);
  }
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
      tmuxMirrorTargets.add(target);
      await ensureTmuxTargetAlive(target);
      await sendTmuxCommand(target, commandText);
      log("info", `Watch command sent to ${target}: ${commandText.slice(0, 120)}`);
      scheduleTmuxMirrorRefresh();
      return jsonResponse(res, 200, { ok: true, target });
    } catch (err) {
      log("error", `Failed to send watch command to ${target}:`, err.message);
      return jsonResponse(res, 500, { error: `Failed to send command to ${target}` });
    }
  }

  return jsonResponse(res, 400, { error: "Missing permissionId+decision or command" });
}

async function handleTargets(req, res) {
  if (req.method !== "GET") return jsonResponse(res, 405, { error: "Method not allowed" });
  if (!requireAuth(req)) return jsonResponse(res, 401, { error: "Unauthorized" });

  try {
    const targets = await listAgentTargets();
    const serializedTargets = serializeTargets(targets);
    return jsonResponse(res, 200, {
      activeTarget: activeCommandTarget,
      targets: serializedTargets,
    });
  } catch (err) {
    return jsonResponse(res, 500, { error: err.message });
  }
}

async function handleTarget(req, res) {
  if (req.method !== "POST") return jsonResponse(res, 405, { error: "Method not allowed" });
  if (!requireAuth(req)) return jsonResponse(res, 401, { error: "Unauthorized" });

  let body;
  try { body = await readBody(req); } catch { return jsonResponse(res, 400, { error: "Invalid JSON" }); }
  if (!body.target || typeof body.target !== "string") return jsonResponse(res, 400, { error: "Missing target" });

  try {
    const selected = await setActiveCommandTarget(body.target);
    pushTmuxSnapshotEvent().catch((err) => {
      tmuxMirrorActive = false;
      tmuxMirrorLastError = err.message;
    });
    return jsonResponse(res, 200, { ok: true, activeTarget: selected.id });
  } catch (err) {
    return jsonResponse(res, 400, { error: err.message });
  }
}

async function handleMirrorTargets(req, res) {
  if (req.method !== "POST") return jsonResponse(res, 405, { error: "Method not allowed" });
  if (!requireAuth(req)) return jsonResponse(res, 401, { error: "Unauthorized" });

  let body;
  try { body = await readBody(req); } catch { return jsonResponse(res, 400, { error: "Invalid JSON" }); }

  try {
    const targets = await setMirroredCommandTargets(body.targets);
    pushTmuxSnapshotEvent().catch((err) => {
      tmuxMirrorActive = false;
      tmuxMirrorLastError = err.message;
    });
    return jsonResponse(res, 200, { ok: true, activeTarget: activeCommandTarget, targets });
  } catch (err) {
    return jsonResponse(res, 400, { error: err.message });
  }
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
  if (!(await isTrackedHookRequest(body))) {
    const reason = "watch-control ignored this hook because it is not from a mirrored tmux Claude/Codex pane.";
    log("info", "Ignoring unmirrored Claude hook", body.tool_name || "", body.watchcontrol_hook || {});
    return ignoredHookResponse(res, reason);
  }

  const permissionId = crypto.randomUUID();
  log("info", `Permission request received (id: ${permissionId})`, body.tool_name || "");
  if (body.permission_suggestions) pendingPermissionBodies.set(permissionId, body.permission_suggestions);
  pushSseEvent("permission-request", { permissionId, ...body });
  sendApprovalNotification(body).catch((err) => {
    log("warn", "Approval notification task failed:", err.message);
  });
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
    commandTarget: activeCommandTarget || "auto",
    terminalMirror: {
      active: tmuxMirrorActive,
      target: tmuxMirrorTarget || CONFIGURED_COMMAND_TARGET || "auto",
      targets: [...tmuxMirrorTargets],
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
  "GET /targets": handleTargets,
  "POST /target": handleTarget,
  "POST /mirror-targets": handleMirrorTargets,
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
  listAgentTargets().catch((err) => {
    log("warn", "Initial tmux target scan failed:", err.message);
  });
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
