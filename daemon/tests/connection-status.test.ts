import test from "node:test";
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import type { Socket } from "node:net";
import { RpcServer } from "../src/rpc-server.ts";
import type { DriveEngine } from "../src/engine.ts";

const account = { email: "test@example.invalid", usedBytes: 1, totalBytes: 10 };

function fixture() {
  let online = false;
  let calls = 0;
  const engine = Object.assign(new EventEmitter(), {
    provider: { kind: "proton-cli", getAccountInfo: async () => {
      calls++;
      if (!online) throw new Error("Network unavailable");
      return account;
    } },
    transfers: Object.assign(new EventEmitter(), { list: () => [] }),
    conflicts: () => [], cacheUsage: async () => 0,
    syncQueued: async () => {}, processEvents: async () => {},
  });
  const server = new RpcServer(engine as unknown as DriveEngine, "/unused");
  // Exercise the real RPC dispatch/watch paths without opening a live socket.
  const rpc = server as unknown as {
    dispatch(method: string, params: Record<string, unknown>): Promise<any>;
    reply(socket: Socket, line: string): Promise<void>;
  };
  return { engine, rpc, online: () => { online = true; }, calls: () => calls };
}

async function settle() {
  for (let i = 0; i < 20; i++) await Promise.resolve();
}

test("transient failures retry after ten seconds while successful checks remain cached", async t => {
  t.mock.timers.enable({ apis: ["Date"], now: 1000 });
  const f = fixture();
  assert.equal((await f.rpc.dispatch("GetStatus", {})).connected, false);
  f.online();
  t.mock.timers.tick(9999);
  assert.equal((await f.rpc.dispatch("GetStatus", {})).connected, false);
  assert.equal(f.calls(), 1);
  t.mock.timers.tick(1);
  const recovered = await f.rpc.dispatch("GetStatus", {});
  assert.equal(recovered.connected, true);
  assert.equal(recovered.connectionError, "");
  assert.deepEqual(recovered.account, account);
  t.mock.timers.tick(10000);
  assert.equal((await f.rpc.dispatch("GetStatus", {})).connected, true);
  assert.equal(f.calls(), 2);
});

test("Try again's Sync refreshes a cached error immediately", async () => {
  const f = fixture();
  await f.rpc.dispatch("GetStatus", {});
  f.online();
  await f.rpc.dispatch("Sync", {});
  assert.equal((await f.rpc.dispatch("GetStatus", {})).connected, true);
  assert.equal(f.calls(), 2);
});

test("idle Watch reports recovery without file events and stops polling on close", async t => {
  t.mock.timers.enable({ apis: ["Date", "setTimeout"], now: 1000 });
  const f = fixture();
  const events: any[] = [];
  const socket = Object.assign(new EventEmitter(), {
    destroyed: false,
    write: (line: string) => { events.push(JSON.parse(line)); return true; },
    destroy() { socket.destroyed = true; socket.emit("close"); },
  });
  await f.rpc.reply(socket as unknown as Socket, JSON.stringify({ id: 1, method: "Watch" }));
  assert.equal(events[0].data.connected, false);
  f.online();
  t.mock.timers.tick(10000);
  await settle();
  assert.equal(events.length, 2);
  assert.equal(events[1].event, "Status");
  assert.equal(events[1].data.connected, true);
  socket.destroy();
  t.mock.timers.tick(300000);
  await settle();
  assert.equal(events.length, 2);
  assert.equal(f.calls(), 2);
  assert.equal(f.engine.listenerCount("nodeChanged"), 0);
  assert.equal(f.engine.transfers.listenerCount("changed"), 0);
});
