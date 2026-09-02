import { describe, expect, test, afterEach } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN, REPO_ROOT } from "../evals/eval-helpers";
import {
  fakeGatewayFinalText,
  fakeGatewayToolCall,
  startFakeGateway,
} from "./tmux-helpers";

const TIMEOUT = 30_000;

type GatewayInstance = {
  baseUrl: string;
  chatUrl: string;
  requests: Array<{ body: string; headers: Headers }>;
  stop: () => void;
};

type FakeSlackEvent =
  | { type: "ws_connected"; active_clients: number }
  | { type: "ws_disconnected"; active_clients: number }
  | { type: "ws_message"; payload: { envelope_id?: string; [key: string]: unknown } }
  | {
      type: "api_call";
      method: string;
      body?: {
        channel?: string;
        text?: string;
        thread_ts?: string;
        blocks?: unknown;
        ts?: string;
        [key: string]: unknown;
      };
      auth?: string;
      ts?: string;
      channel?: string;
      is_im?: boolean;
    }
  | { type: string; [key: string]: unknown };

class FakeSlackServer {
  proc: ReturnType<typeof Bun.spawn>;
  httpPort = 0;
  wsPort = 0;
  events: FakeSlackEvent[] = [];
  private closed = false;
  private portsResolver = Promise.withResolvers<{ httpPort: number; wsPort: number }>();
  private eventWaiters: Array<{
    predicate: (e: FakeSlackEvent) => boolean;
    resolve: (e: FakeSlackEvent) => void;
    reject: (err: Error) => void;
    timer: ReturnType<typeof setTimeout>;
  }> = [];

  constructor(proc: ReturnType<typeof Bun.spawn>) {
    this.proc = proc;
    this.readStream(proc.stdout);
  }

  static async start(): Promise<FakeSlackServer> {
    const proc = Bun.spawn(["bun", "run", join(REPO_ROOT, "tests/e2e/fixtures/fake-slack.ts")], {
      env: { ...process.env },
      stdin: "pipe",
      stdout: "pipe",
      stderr: "pipe",
    });

    const server = new FakeSlackServer(proc);
    const ports = await server.portsResolver.promise;
    server.httpPort = ports.httpPort;
    server.wsPort = ports.wsPort;
    return server;
  }

  private async readStream(stream: ReadableStream<Uint8Array>) {
    const reader = stream.getReader();
    const decoder = new TextDecoder();
    let buffer = "";
    try {
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        buffer += decoder.decode(value, { stream: true });
        const parts = buffer.split("\n");
        buffer = parts.pop()!;
        for (const part of parts) {
          if (part.trim()) this.handleLine(part.trim());
        }
      }
      if (buffer.trim()) {
        this.handleLine(buffer.trim());
      }
    } catch {}
  }

  private handleLine(line: string) {
    if (line.startsWith("PORTS ")) {
      const parts = line.split(" ");
      if (parts.length >= 3) {
        const httpPort = parseInt(parts[1], 10);
        const wsPort = parseInt(parts[2], 10);
        this.portsResolver.resolve({ httpPort, wsPort });
      }
      return;
    }
    try {
      const event = JSON.parse(line) as FakeSlackEvent;
      this.events.push(event);
      for (let i = this.eventWaiters.length - 1; i >= 0; i--) {
        const waiter = this.eventWaiters[i];
        if (waiter.predicate(event)) {
          clearTimeout(waiter.timer);
          this.eventWaiters.splice(i, 1);
          waiter.resolve(event);
        }
      }
    } catch {}
  }

  sendEnvelope(envelope: object) {
    this.proc.stdin.write(JSON.stringify(envelope) + "\n");
    this.proc.stdin.flush();
  }

  async waitForEvent(predicate: (e: FakeSlackEvent) => boolean, timeoutMs = 7000): Promise<FakeSlackEvent> {
    for (const e of this.events) {
      if (predicate(e)) {
        return e;
      }
    }
    const { promise, resolve, reject } = Promise.withResolvers<FakeSlackEvent>();
    const timer = setTimeout(() => {
      const idx = this.eventWaiters.findIndex((w) => w.timer === timer);
      if (idx !== -1) this.eventWaiters.splice(idx, 1);
      reject(
        new Error(
          `Timed out after ${timeoutMs}ms waiting for fake-slack event.\nGot events:\n${JSON.stringify(
            this.events,
            null,
            2,
          )}`,
        ),
      );
    }, timeoutMs);
    this.eventWaiters.push({ predicate, resolve, reject, timer });
    return promise;
  }

  async stop() {
    if (this.closed) return;
    this.closed = true;
    try {
      this.proc.kill();
      await this.proc.exited;
    } catch {}
  }
}

type SlackTestContext = {
  root: string;
  home: string;
  workspace: string;
  fakeSlack: FakeSlackServer;
  gateway: GatewayInstance | null;
  bridgeProc: ReturnType<typeof Bun.spawn> | null;
};

async function setupSlackTestContext(): Promise<SlackTestContext> {
  const root = mkdtempSync(join(tmpdir(), "afx-bridge-slack-e2e-"));
  const home = join(root, "home");
  const workspace = join(root, "workspace");

  mkdirSync(join(home, ".afx", "bridge"), { recursive: true });
  mkdirSync(workspace, { recursive: true });

  const fakeSlack = await FakeSlackServer.start();

  const bridgeConfig = {
    bridge: {
      workspace: workspace,
      permission_mode: "ask",
      connectors: {
        slack: {
          app_token_env: "SLACK_APP_TOKEN",
          bot_token_env: "SLACK_BOT_TOKEN",
          allow_users: ["UUSER123"],
          channels: {
            C12345: {
              workspace: workspace,
            },
          },
          groups: "mention",
        },
      },
    },
  };
  writeFileSync(join(home, ".afx", "bridge.json"), JSON.stringify(bridgeConfig, null, 2), {
    mode: 0o600,
  });

  return {
    root,
    home,
    workspace,
    fakeSlack,
    gateway: null,
    bridgeProc: null,
  };
}

function spawnSlackBridge(ctx: SlackTestContext, gateway: GatewayInstance): ReturnType<typeof Bun.spawn> {
  const proc = Bun.spawn([FX_BIN, "bridge", "start", "--connector", "slack"], {
    cwd: ctx.workspace,
    env: {
      ...process.env,
      HOME: ctx.home,
      FX_BRIDGE_SLACK_API_URL: `http://127.0.0.1:${ctx.fakeSlack.httpPort}`,
      SLACK_APP_TOKEN: "xapp-test-app-token",
      SLACK_BOT_TOKEN: "xoxb-test-bot-token",
      FX_GATEWAY_CHAT_URL: gateway.chatUrl,
      AI_GATEWAY_API_KEY: "fake-slack-key",
      FX_PERMISSION_MODE: "ask",
    },
    stdin: "pipe",
    stdout: "pipe",
    stderr: "pipe",
  });
  ctx.bridgeProc = proc;
  return proc;
}

describe("afx bridge (slack connector)", () => {
  let ctx: SlackTestContext | null = null;

  afterEach(async () => {
    if (ctx) {
      if (ctx.bridgeProc) {
        try {
          ctx.bridgeProc.kill();
          await ctx.bridgeProc.exited;
        } catch {}
      }
      if (ctx.fakeSlack) {
        await ctx.fakeSlack.stop();
      }
      if (ctx.gateway) {
        ctx.gateway.stop();
      }
      try {
        rmSync(ctx.root, { recursive: true, force: true });
      } catch {}
      ctx = null;
    }
  });

  test("startup: verifies auth.test, apps.connections.open, and connects socket mode", async () => {
    ctx = await setupSlackTestContext();
    const gateway = startFakeGateway([]);
    ctx.gateway = gateway;

    spawnSlackBridge(ctx, gateway);

    await ctx.fakeSlack.waitForEvent((e) => e.type === "api_call" && e.method === "auth.test");
    await ctx.fakeSlack.waitForEvent((e) => e.type === "api_call" && e.method === "apps.connections.open");
    const wsConn = await ctx.fakeSlack.waitForEvent((e) => e.type === "ws_connected");
    expect(wsConn.active_clients).toBeGreaterThanOrEqual(1);
  }, TIMEOUT);

  test("inbound DM events_api: acks envelope and posts model response via chat.postMessage", async () => {
    ctx = await setupSlackTestContext();
    const gateway = startFakeGateway([fakeGatewayFinalText("Hello from model in Slack DM!")]);
    ctx.gateway = gateway;

    spawnSlackBridge(ctx, gateway);
    await ctx.fakeSlack.waitForEvent((e) => e.type === "ws_connected");

    ctx.fakeSlack.sendEnvelope({
      envelope_id: "env_dm_test_1",
      type: "events_api",
      payload: {
        event: {
          type: "message",
          channel: "D12345",
          user: "UUSER123",
          text: "Hello assistant",
          ts: "1700000001.000001",
        },
      },
    });

    const ack = await ctx.fakeSlack.waitForEvent(
      (e) => e.type === "ws_message" && e.payload?.envelope_id === "env_dm_test_1",
    );
    expect(ack).toBeDefined();

    const postMsg = await ctx.fakeSlack.waitForEvent(
      (e) =>
        e.type === "api_call" &&
        e.method === "chat.postMessage" &&
        e.body?.channel === "D12345" &&
        typeof e.body?.text === "string" &&
        e.body.text.includes("Hello from model in Slack DM!"),
    );
    expect(postMsg).toBeDefined();
  }, TIMEOUT);

  test("channel messages: ignored without mention, replied in thread_ts when bot mentioned", async () => {
    ctx = await setupSlackTestContext();
    const gateway = startFakeGateway([fakeGatewayFinalText("Thread reply from assistant.")]);
    ctx.gateway = gateway;

    spawnSlackBridge(ctx, gateway);
    await ctx.fakeSlack.waitForEvent((e) => e.type === "ws_connected");

    // 1. Channel message WITHOUT bot mention
    ctx.fakeSlack.sendEnvelope({
      envelope_id: "env_chan_no_mention",
      type: "events_api",
      payload: {
        event: {
          type: "message",
          channel: "C12345",
          user: "UUSER123",
          text: "Just talking to colleagues in channel",
          ts: "1700000002.000001",
        },
      },
    });

    // Verify envelope is acked
    await ctx.fakeSlack.waitForEvent(
      (e) => e.type === "ws_message" && e.payload?.envelope_id === "env_chan_no_mention",
    );

    // 2. Channel message WITH bot mention (<@UBOT123>)
    ctx.fakeSlack.sendEnvelope({
      envelope_id: "env_chan_with_mention",
      type: "events_api",
      payload: {
        event: {
          type: "app_mention",
          channel: "C12345",
          user: "UUSER123",
          text: "<@UBOT123> Help with repository question",
          ts: "1700000003.000001",
          thread_ts: "1700000003.000001",
        },
      },
    });

    await ctx.fakeSlack.waitForEvent(
      (e) => e.type === "ws_message" && e.payload?.envelope_id === "env_chan_with_mention",
    );

    const postMsg = await ctx.fakeSlack.waitForEvent(
      (e) =>
        e.type === "api_call" &&
        e.method === "chat.postMessage" &&
        e.body?.channel === "C12345" &&
        e.body?.thread_ts === "1700000003.000001" &&
        typeof e.body?.text === "string" &&
        e.body.text.includes("Thread reply from assistant."),
    );
    expect(postMsg).toBeDefined();
  }, TIMEOUT);

  test("tool-call approval: posts block buttons and handles interactive block_actions deny", async () => {
    ctx = await setupSlackTestContext();
    const targetPath = join(ctx.workspace, "slack_denied.txt");

    const gateway = startFakeGateway([
      fakeGatewayToolCall("cmd_slack_1", "terminal", {
        action: "exec",
        command: "touch slack_denied.txt",
      }),
      fakeGatewayFinalText("Tool execution was denied by user."),
    ]);
    ctx.gateway = gateway;

    spawnSlackBridge(ctx, gateway);
    await ctx.fakeSlack.waitForEvent((e) => e.type === "ws_connected");

    ctx.fakeSlack.sendEnvelope({
      envelope_id: "env_tool_request",
      type: "events_api",
      payload: {
        event: {
          type: "message",
          channel: "D12345",
          user: "UUSER123",
          text: "Execute file command",
          ts: "1700000004.000001",
        },
      },
    });

    // Wait for postMessage containing interactive buttons in blocks
    const buttonPost = await ctx.fakeSlack.waitForEvent(
      (e) =>
        e.type === "api_call" &&
        e.method === "chat.postMessage" &&
        e.body?.blocks !== undefined &&
        e.body.blocks !== null,
    );
    expect(buttonPost).toBeDefined();

    const blocks =
      typeof buttonPost.body!.blocks === "string"
        ? JSON.parse(buttonPost.body!.blocks)
        : buttonPost.body!.blocks;

    let allowActionId: string | null = null;
    let denyActionId: string | null = null;
    let reqId: string | null = null;

    for (const block of blocks as Array<{ type: string; elements?: Array<{ action_id?: string; value?: string }> }>) {
      if (block.type === "actions" && Array.isArray(block.elements)) {
        for (const el of block.elements) {
          if (el.action_id?.endsWith(":allow_once")) {
            allowActionId = el.action_id;
          } else if (el.action_id?.endsWith(":deny")) {
            denyActionId = el.action_id;
            reqId = el.value || el.action_id.split(":")[1];
          }
        }
      }
    }

    expect(allowActionId).not.toBeNull();
    expect(denyActionId).not.toBeNull();
    expect(reqId).not.toBeNull();

    // Send interactive denial payload
    ctx.fakeSlack.sendEnvelope({
      envelope_id: "env_inter_deny_choice",
      type: "interactive",
      payload: {
        type: "block_actions",
        user: { id: "UUSER123" },
        channel: { id: "D12345" },
        actions: [
          {
            action_id: denyActionId,
            value: reqId,
          },
        ],
      },
    });

    await ctx.fakeSlack.waitForEvent(
      (e) => e.type === "ws_message" && e.payload?.envelope_id === "env_inter_deny_choice",
    );

    // Final response posted after denial
    const finalMsg = await ctx.fakeSlack.waitForEvent(
      (e) =>
        (e.type === "api_call" &&
          e.method === "chat.postMessage" &&
          typeof e.body?.text === "string" &&
          e.body.text.includes("Tool execution was denied")) ||
        (e.type === "api_call" &&
          e.method === "chat.update" &&
          typeof e.body?.text === "string" &&
          e.body.text.includes("Tool execution was denied")),
    );
    expect(finalMsg).toBeDefined();
    expect(existsSync(targetPath)).toBe(false);
  }, TIMEOUT);

  test("disconnect envelope triggers fresh apps.connections.open reconnection within 5s", async () => {
    ctx = await setupSlackTestContext();
    const gateway = startFakeGateway([]);
    ctx.gateway = gateway;

    spawnSlackBridge(ctx, gateway);
    await ctx.fakeSlack.waitForEvent((e) => e.type === "ws_connected");

    const initialOpenCount = ctx.fakeSlack.events.filter(
      (e) => e.type === "api_call" && e.method === "apps.connections.open",
    ).length;
    expect(initialOpenCount).toBe(1);

    // Send disconnect envelope
    ctx.fakeSlack.sendEnvelope({
      envelope_id: "env_disconnect_cmd",
      type: "disconnect",
    });

    // Disconnect is acked
    await ctx.fakeSlack.waitForEvent(
      (e) => e.type === "ws_message" && e.payload?.envelope_id === "env_disconnect_cmd",
    );

    // Within 5s, reconnect occurs: apps.connections.open is called again
    const reconnectedOpen = await ctx.fakeSlack.waitForEvent(
      (e) => {
        if (e.type === "api_call" && e.method === "apps.connections.open") {
          const count = ctx!.fakeSlack.events.filter(
            (ev) => ev.type === "api_call" && ev.method === "apps.connections.open",
          ).length;
          return count >= 2;
        }
        return false;
      },
      5000,
    );
    expect(reconnectedOpen).toBeDefined();
  }, TIMEOUT);

  test("long model text (>39000 bytes) is split into chunks without breaking markdown code fences", async () => {
    ctx = await setupSlackTestContext();

    // Create a code block that exceeds 40,000 bytes
    const repeatedLines = "// line of code to reach large chunk limit\n".repeat(1000);
    const largeMessage = `Intro message before block\n\`\`\`zig\n${repeatedLines}\`\`\`\nFinal summary after block.`;
    expect(largeMessage.length).toBeGreaterThan(39000);

    const gateway = startFakeGateway([fakeGatewayFinalText(largeMessage)]);
    ctx.gateway = gateway;

    spawnSlackBridge(ctx, gateway);
    await ctx.fakeSlack.waitForEvent((e) => e.type === "ws_connected");

    ctx.fakeSlack.sendEnvelope({
      envelope_id: "env_large_code_msg",
      type: "events_api",
      payload: {
        event: {
          type: "message",
          channel: "D12345",
          user: "UUSER123",
          text: "Generate large code file",
          ts: "1700000005.000001",
        },
      },
    });

    await ctx.fakeSlack.waitForEvent(
      (e) => e.type === "ws_message" && e.payload?.envelope_id === "env_large_code_msg",
    );

    // Wait until at least 2 chat.postMessage calls have arrived for D12345
    await ctx.fakeSlack.waitForEvent(
      () => {
        const posts = ctx!.fakeSlack.events.filter(
          (e) => e.type === "api_call" && e.method === "chat.postMessage" && e.body?.channel === "D12345",
        );
        return posts.length >= 2;
      },
      7000,
    );

    const postMessages = ctx.fakeSlack.events.filter(
      (e) =>
        e.type === "api_call" &&
        e.method === "chat.postMessage" &&
        e.body?.channel === "D12345" &&
        typeof e.body?.text === "string",
    ) as Array<{ body: { text: string } }>;

    expect(postMessages.length).toBeGreaterThanOrEqual(2);

    for (const post of postMessages) {
      expect(post.body.text.length).toBeLessThanOrEqual(39000);
    }

    const chunk0 = postMessages[0].body.text;
    const chunk1 = postMessages[1].body.text;

    // First chunk ends with closed code block
    expect(chunk0.trimEnd().endsWith("```")).toBe(true);
    // Second chunk opens with matching code block
    expect(chunk1.startsWith("```\n") || chunk1.startsWith("```zig\n")).toBe(true);
  }, TIMEOUT);
});
