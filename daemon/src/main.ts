import { promisify } from "node:util";
import { setTimeout as delay } from "node:timers/promises";
import { execFile } from "node:child_process";
import { fileURLToPath } from "node:url";
import { join } from "node:path";
import { homedir } from "node:os";
import { FakeDriveProvider } from "./fake-provider.ts";
import { StateStore } from "./state-store.ts";
import { LocalStorage } from "./local-storage.ts";
import { DriveEngine } from "./engine.ts";
import { RpcServer } from "./rpc-server.ts";
import { OfficialCliProvider } from "./official-cli-provider.ts";
import { clampedIntegerSetting } from "./settings.ts";

const dataHome = process.env.XDG_STATE_HOME ?? join(homedir(), ".local/state");
const cacheHome = process.env.XDG_CACHE_HOME ?? join(homedir(), ".cache");
const runtimeDir = process.env.XDG_RUNTIME_DIR ?? `/tmp/omarchy-drive-${process.getuid?.() ?? "user"}`;
const providerName = process.env.OMARCHY_DRIVE_PROVIDER ?? "unconfigured";
const defaultMaintenanceMs = providerName === "proton-cli" ? 5 * 60_000 : 60_000;
const maintenanceIntervalMs = clampedIntegerSetting("OMARCHY_DRIVE_MAINTENANCE_MS", defaultMaintenanceMs, 1_000);
const maxCacheBytes = clampedIntegerSetting("OMARCHY_DRIVE_CACHE_BYTES", 20 * 1024 ** 3, 0);

if (!["fake", "proton-cli"].includes(providerName)) {
  console.error("Set OMARCHY_DRIVE_PROVIDER=fake or proton-cli.");
  process.exitCode = 78;
} else {
  // Wait inside the daemon process, not ExecStartPre: dependent mount/bridge
  // units must remain eligible to retry while the keyring becomes available.
  // No account data is read by this metadata-only readiness check.
  if (providerName === "proton-cli") {
    for (;;) {
      try {
        await promisify(execFile)("/usr/bin/python3", [fileURLToPath(new URL("../../ipc/wait_secret_service.py", import.meta.url))], {
          timeout: 35_000,
        });
        break;
      } catch {
        // Keep this service alive so Requires= dependents are not stopped.
        // Each probe is bounded; a later unlock needs no manual restart.
        console.error(JSON.stringify({ level: "warn", event: "waiting_for_secret_service" }));
        await delay(5_000);
      }
    }
  }
  // ProtonSdkProvider is a tested seam for a future event-driven client and is
  // intentionally not selectable here (see docs/ARCHITECTURE.md).
  const provider = providerName === "fake"
    ? new FakeDriveProvider()
    : new OfficialCliProvider(process.env.OMARCHY_DRIVE_CLI ?? join(homedir(), ".local/bin/proton-drive"));
  const stateName = providerName === "fake" ? "state.sqlite" : `state-${providerName}.sqlite`;
  const legacyName = providerName === "fake" ? "state.json" : `state-${providerName}.json`;
  const engine = new DriveEngine(provider, new StateStore(join(dataHome, "omarchy-drive", stateName), join(dataHome, "omarchy-drive", legacyName)), new LocalStorage(join(cacheHome, "omarchy-drive"), join(dataHome, "omarchy-drive")));
  await engine.initialize();
  const server = new RpcServer(engine, join(runtimeDir, "omarchy-drive.sock"));
  console.log(JSON.stringify({ level: "info", event: "daemon_started", provider: providerName }));
  await server.listen();
  const runMaintenance = async () => {
    try { await engine.maintenanceCycle(maxCacheBytes); }
    catch (error) { const detail = error as Error & { code?: string }; console.error(JSON.stringify({ level: "warn", event: "maintenance_failed", code: detail?.code ?? detail?.name ?? "Error" })); }
    setTimeout(() => { void runMaintenance(); }, maintenanceIntervalMs).unref();
  };
  // Give interactive filesystem and status requests a clear queue after
  // startup. Cached metadata already serves browsing while this timer waits.
  setTimeout(() => { void runMaintenance(); }, Math.min(maintenanceIntervalMs, 60_000)).unref();
}
