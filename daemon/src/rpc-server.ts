import { createServer, type Socket } from "node:net";
import { chmod, mkdir, unlink } from "node:fs/promises";
import { dirname } from "node:path";
import type { DriveEngine } from "./engine.ts";
import { AuthenticationRequiredError } from "./domain.ts";
import type { AccountInfo, RequestPriority } from "./provider.ts";
import { clampedIntegerSetting } from "./settings.ts";

interface Request { id: string | number; method: string; params?: Record<string, unknown>; }

// SDK node UIDs are two URL-safe base64 components separated by `~` and may
// retain `=` padding. Path separators, whitespace and shell metacharacters
// remain forbidden.
const SAFE_ID = /^[A-Za-z0-9._~=-]+$/;
const MAX_NAME_LENGTH = 255;
const RPC_TIMEOUT_MS = clampedIntegerSetting("OMARCHY_DRIVE_RPC_TIMEOUT_MS", 5 * 60_000, 1_000);
const ACCOUNT_RETRY_MS = 10_000;
const WATCH_STATUS_INTERVAL_MS = 10_000;
const ACCOUNT_TTL_MS = clampedIntegerSetting("OMARCHY_DRIVE_ACCOUNT_TTL_MS", 5 * 60_000, 10_000);

function requiredId(value: unknown, field: string): string {
  if (typeof value !== "string" || !SAFE_ID.test(value)) throw new Error(`Invalid ${field}`);
  return value;
}

function requiredName(value: unknown): string {
  if (typeof value !== "string") throw new Error("Invalid node name");
  const normalized = value.normalize("NFC");
  if (normalized.length === 0 || Buffer.byteLength(normalized, "utf8") > MAX_NAME_LENGTH || normalized.includes("\0") || normalized === "." || normalized === ".." || normalized.includes("/") || /[\uD800-\uDFFF]/u.test(normalized)) {
    throw new Error("Invalid node name");
  }
  return normalized;
}

function conflictResolution(value: unknown): "keep-local" | "keep-remote" | "save-both" {
  if (value === "keep-local" || value === "keep-remote" || value === "save-both") return value;
  throw new Error("Invalid conflict resolution");
}

export class RpcServer {
  readonly engine: DriveEngine;
  readonly socketPath: string;
  private account: AccountInfo | null = null;
  private accountConnectionError = "";
  private accountCheckedAt = 0;
  private accountRefresh?: Promise<void>;
  private readonly timeoutMs: number;
  constructor(engine: DriveEngine, socketPath: string, timeoutMs = RPC_TIMEOUT_MS) {
    this.engine = engine;
    this.socketPath = socketPath;
    this.timeoutMs = timeoutMs;
  }
  private async refreshAccount(priority: RequestPriority): Promise<void> {
    if (!this.engine.provider.getAccountInfo) {
      this.account = null; this.accountConnectionError = ""; this.accountCheckedAt = Date.now(); return;
    }
    if (this.accountRefresh) return this.accountRefresh;
    this.accountRefresh = (async () => {
      try {
        this.account = await this.engine.provider.getAccountInfo!(priority);
        this.accountConnectionError = "";
      } catch (error) {
        this.account = null;
        this.accountConnectionError = error instanceof AuthenticationRequiredError ? "" : "Nie udało się połączyć z Proton Drive.";
      } finally {
        this.accountCheckedAt = Date.now();
      }
    })().finally(() => { this.accountRefresh = undefined; });
    return this.accountRefresh;
  }
  private async accountStatus(): Promise<{ account: AccountInfo | null; connectionError: string; checkedAt: number }> {
    if (this.accountCheckedAt === 0) await this.refreshAccount("interactive");
    else if (this.accountConnectionError && Date.now() - this.accountCheckedAt >= ACCOUNT_RETRY_MS) {
      // Do not cache a transient network failure for the successful-account TTL.
      await this.refreshAccount("background");
    } else if (Date.now() - this.accountCheckedAt >= ACCOUNT_TTL_MS) void this.refreshAccount("background");
    return { account: this.account, connectionError: this.accountConnectionError, checkedAt: this.accountCheckedAt };
  }
  async listen(): Promise<void> {
    const socketDirectory = dirname(this.socketPath);
    await mkdir(socketDirectory, { recursive: true, mode: 0o700 });
    await chmod(socketDirectory, 0o700);
    try { await unlink(this.socketPath); } catch (e) { if ((e as NodeJS.ErrnoException).code !== "ENOENT") throw e; }
    const sockets = new Set<Socket>();
    const server = createServer(socket => {
      sockets.add(socket);
      socket.on("error", error => {
        const code = (error as NodeJS.ErrnoException).code ?? error.name;
        if (code !== "EPIPE" && code !== "ECONNRESET") console.error(JSON.stringify({ level: "warn", event: "rpc_client_error", code }));
        socket.destroy();
      });
      socket.once("close", () => sockets.delete(socket));
      this.handleSocket(socket);
    });
    await new Promise<void>((resolve, reject) => { server.once("error", reject); server.listen(this.socketPath, () => resolve()); });
    await chmod(this.socketPath, 0o600);
    let shuttingDown = false;
    const shutdown = () => {
      if (shuttingDown) return;
      shuttingDown = true;
      // Stop accepting first. Otherwise a FUSE/DBus client can reconnect in
      // the gap between destroying the current sockets and server.close(),
      // leaving systemd stuck waiting for SIGTERM shutdown forever.
      server.close();
      for (const socket of sockets) socket.destroy();
      process.exit(0);
    };
    process.once("SIGTERM", shutdown);
    process.once("SIGINT", shutdown);
  }
  private handleSocket(socket: Socket): void {
    let input = "";
    socket.setEncoding("utf8");
    socket.on("data", chunk => {
      input += chunk;
      if (Buffer.byteLength(input, "utf8") > 1024 * 1024) { socket.end(JSON.stringify({ id: null, error: { code: "REQUEST_TOO_LARGE", message: "RPC request exceeds 1 MiB" } }) + "\n"); return; }
      let at: number; while ((at = input.indexOf("\n")) >= 0) { const line = input.slice(0, at); input = input.slice(at + 1); if (line.trim()) void this.reply(socket, line); }
    });
  }
  private async reply(socket: Socket, line: string): Promise<void> {
    const disconnected = new AbortController();
    const abortDisconnected = () => disconnected.abort();
    socket.once("close", abortDisconnected);
    let parsed: unknown;
    try { parsed = JSON.parse(line); }
    catch { socket.end(JSON.stringify({ id: null, error: { code: "BAD_JSON", message: "Invalid JSON" } }) + "\n"); return; }
    let requestId: string | number | null = null;
    try {
      if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) throw new Error("Invalid RPC request");
      const request = parsed as Partial<Request>;
      if (typeof request.id !== "string" && typeof request.id !== "number") throw new Error("Invalid RPC request id");
      requestId = request.id;
      if (typeof request.method !== "string") throw new Error("Invalid RPC method");
      if (request.params !== undefined && (!request.params || typeof request.params !== "object" || Array.isArray(request.params))) throw new Error("Invalid RPC params");
      if (request.method === "Watch") {
        const write = (event: string, data: unknown) => { if (!socket.destroyed) socket.write(JSON.stringify({ event, data }) + "\n"); };
        const nodeChanged = (nodeId: string) => write("NodeChanged", { nodeId });
        const transferChanged = (transfer: unknown) => write("TransferChanged", transfer);
        const conflicts = new Set<string>();
        const syncConflict = () => {
          const current = this.engine.conflicts();
          for (const conflict of current) if (!conflicts.has(conflict.nodeId)) { conflicts.add(conflict.nodeId); write("Conflict", conflict); }
          for (const nodeId of [...conflicts]) if (!current.some(c => c.nodeId === nodeId)) { conflicts.delete(nodeId); write("ConflictResolved", { nodeId }); }
        };
        this.engine.on("nodeChanged", nodeChanged); this.engine.transfers.on("changed", transferChanged);
        socket.on("close", () => { this.engine.off("nodeChanged", nodeChanged); this.engine.transfers.off("changed", transferChanged); });
        const status = await this.boundedDispatch("GetStatus", {}, disconnected.signal) as { conflicts?: unknown };
        if (socket.destroyed) return;
        write("Status", status);
        if (Array.isArray(status.conflicts)) for (const conflict of status.conflicts) if (conflict && typeof conflict === "object" && "nodeId" in conflict) { conflicts.add(String((conflict as { nodeId: unknown }).nodeId)); write("Conflict", conflict); }
        this.engine.on("nodeChanged", syncConflict);
        socket.on("close", () => this.engine.off("nodeChanged", syncConflict));
        // Watch must update idle clients too: network recovery need not emit
        // any file or transfer event. Schedule after completion to avoid overlap.
        let statusTimer: ReturnType<typeof setTimeout> | undefined;
        const pollStatus = async () => {
          try {
            const current = await this.boundedDispatch("GetStatus", {}, disconnected.signal);
            write("Status", current);
          } catch {
            // Let the client reconnect rather than silently keep stale status.
            socket.destroy();
          }
          if (!socket.destroyed) statusTimer = setTimeout(pollStatus, WATCH_STATUS_INTERVAL_MS);
        };
        socket.once("close", () => { if (statusTimer) clearTimeout(statusTimer); });
        if (!socket.destroyed) statusTimer = setTimeout(pollStatus, WATCH_STATUS_INTERVAL_MS);
        return;
      }
      const result = await this.boundedDispatch(request.method, request.params ?? {}, disconnected.signal);
      socket.end(JSON.stringify({ id: requestId, result }) + "\n");
    } catch (error) {
      if (!socket.destroyed) socket.end(JSON.stringify({ id: requestId, error: { code: error instanceof Error ? error.name : "ERROR", message: error instanceof Error ? error.message : String(error) } }) + "\n");
    }
  }
  private async boundedDispatch(method: string, params: Record<string, unknown>, externalSignal?: AbortSignal): Promise<unknown> {
    const controller = new AbortController();
    let timedOut = false;
    const timer = setTimeout(() => { timedOut = true; controller.abort(); }, this.timeoutMs);
    const abort = () => controller.abort(externalSignal?.reason);
    if (externalSignal?.aborted) abort();
    else externalSignal?.addEventListener("abort", abort, { once: true });
    try {
      return await this.dispatch(method, params, controller.signal);
    } catch (error) {
      if (timedOut) {
        const timeout = new Error(`RPC operation timed out and was cancelled: ${method}`);
        timeout.name = "TimeoutError";
        throw timeout;
      }
      throw error;
    } finally { clearTimeout(timer); externalSignal?.removeEventListener("abort", abort); }
  }
  private async dispatch(method: string, p: Record<string, unknown>, signal?: AbortSignal): Promise<unknown> {
    const id = () => requiredId(p.nodeId, "nodeId");
    switch (method) {
      case "GetVersion": return { version: "1.0.2", apiVersion: 1, provider: this.engine.provider.kind, readOnly: false };
      case "GetStatus": {
        const { account, connectionError, checkedAt } = await this.accountStatus();
        const authenticated = this.engine.provider.kind === "fake" || account !== null;
        return {
          connected: authenticated && connectionError === "", authenticated,
          readOnly: false, provider: this.engine.provider.kind,
          account, connectionError, checkedAt, cacheBytes: await this.engine.cacheUsage(),
          version: "1.0.2", apiVersion: 1, transfers: this.engine.transfers.list(true),
          conflicts: this.engine.conflicts(),
        };
      }
      case "GetRoot": return this.engine.root();
      case "GetNode": return this.engine.getNode(id());
      case "ListChildren": return (await this.engine.listChildren(id())).map(node => ({ ...node, localStatus: this.engine.getState(node.id)?.status ?? "cloud-only" }));
      case "LookupChild": {
        const node = await this.engine.lookupChild(requiredId(p.parentId, "parentId"), requiredName(p.name));
        return { ...node, localStatus: this.engine.getState(node.id)?.status ?? "cloud-only" };
      }
      case "GetNodeStatus": return this.engine.getState(id()) ?? null;
      case "Materialize": return { path: await this.engine.materialize(id()) };
      case "BeginWrite": return { path: await this.engine.beginWrite(id()) };
      case "CommitWrite": return this.engine.queueCommit(id());
      case "SetPinned": return this.engine.pin(id(), Boolean(p.pinned));
      case "Evict": return this.engine.evict(id());
      case "Retry": return this.engine.retry(id());
      case "CreateFolder": return this.engine.createFolder(requiredId(p.parentId, "parentId"), requiredName(p.name), signal);
      case "CreateFile": return this.engine.createFile(requiredId(p.parentId, "parentId"), requiredName(p.name), new Uint8Array(), signal);
      case "Rename": return this.engine.rename(id(), requiredName(p.name), signal);
      case "Move": return this.engine.move(id(), requiredId(p.parentId, "parentId"), signal);
      case "Replace": return this.engine.replace(id(), requiredId(p.destinationId, "destinationId"), signal);
      case "Trash": await this.engine.trash(id(), signal); return null;
      case "ResolveConflict": return this.engine.resolveConflict(id(), conflictResolution(p.resolution), p.copyName === undefined ? undefined : requiredName(p.copyName), signal);
      case "GetTransfers": return this.engine.transfers.list();
      case "CancelTransfer": return this.engine.cancelQueuedUpload(requiredId(p.transferId, "transferId"));
      case "Sync": await this.refreshAccount("interactive"); await this.engine.syncQueued(); await this.engine.processEvents(); return null;
      case "ClearCache": return this.engine.clearDisposableCache();
      case "ClearPinnedCache": return this.engine.clearPinnedCache();
      default: throw new Error(`Unknown method: ${method}`);
    }
  }
}
