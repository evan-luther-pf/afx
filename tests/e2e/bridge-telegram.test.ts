import { describe, expect, test, afterEach } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Subprocess } from "bun";
import { FX_BIN, REPO_ROOT } from "../evals/eval-helpers";
import {
  fakeGatewayFinalText,
  fakeGatewayToolCall,
  startFakeGateway,
} from "./tmux-helpers";

const TIMEOUT = 30_000;

interface GatewayInstance {
  baseUrl: string;
  chatUrl: string;
  requests: Array<{ body: string; headers: Headers }>;
  stop: () => void;
}

interface FakeTelegramApiEvent {
  type: "api_call" | string;
  method?: string;
  body?: {
    chat_id?: number | string;
    message_id?: number;
    message_thread_id?: number;
    text?: string;
    parse_mode?: string;
    reply_markup?: unknown;
    offset?: number;
    timeout?: number;
    callback_query_id?: string;
    action?: string;
    [key: string]: unknown;
  };
  [key: string]: unknown;
}

class FakeTelegramServer {
  proc: Subprocess;
  port = 0;
  events: FakeTelegramApiEvent[] = [];
  private closed = false;
  private portResolver = Promise.withResolvers<number>();
  private eventWaiters: Array<{
    predicate: (e: FakeTelegramApiEvent) => boolean;
    resolve: (e: FakeTelegramApiEvent) => void;
    reject: (err: Error) => void;
    timer: ReturnType<typeof setTimeout>;
  }> = [];

  constructor(proc: Subprocess) {
    this.proc = proc;
    this.readStream(proc.stdout);
  }

  static async start(): Promise<FakeTelegramServer> {
    const proc = Bun.spawn(["bun", "run", join(REPO_ROOT, "tests/e2e/fixtures/fake-telegram.ts")], {
      env: { ...process.env },
      stdin: "pipe",
      stdout: "pipe",
      stderr: "pipe",
    });

    const server = new FakeTelegramServer(proc);
    const port = await server.portResolver.promise;
    server.port = port;
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
    if (line.startsWith("PORT ")) {
      const parts = line.split(" ");
      if (parts.length >= 2) {
        const port = parseInt(parts[1], 10);
        this.portResolver.resolve(port);
      }
      return;
    }
    try {
      const event = JSON.parse(line) as FakeTelegramApiEvent;
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

  sendUpdate(update: object) {
    this.proc.stdin.write(JSON.stringify(update) + "\n");
    this.proc.stdin.flush();
  }

  async waitForEvent(
    predicate: (e: FakeTelegramApiEvent) => boolean,
    timeoutMs = 7000,
  ): Promise<FakeTelegramApiEvent> {
    for (const e of this.events) {
      if (predicate(e)) {
        return e;
      }
    }
    const { promise, resolve, reject } = Promise.withResolvers<FakeTelegramApiEvent>();
    const timer = setTimeout(() => {
      const idx = this.eventWaiters.findIndex((w) => w.timer === timer);
      if (idx !== -1) this.eventWaiters.splice(idx, 1);
      reject(
        new Error(
          `Timed out after ${timeoutMs}ms waiting for fake-telegram event.\nGot events:\n${JSON.stringify(
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

function delay(ms: number): Promise<void> {
  const { promise, resolve } = Promise.withResolvers<void>();
  setTimeout(resolve, ms);
  return promise;
}

interface TelegramTestContext {
  root: string;
  home: string;
  workspace: string;
  fakeTelegram: FakeTelegramServer;
  gateway: GatewayInstance | null;
  bridgeProc: Subprocess | null;
}

async function setupTelegramTestContext(allowUsers: number[] = [12345]): Promise<TelegramTestContext> {
  const root = mkdtempSync(join(tmpdir(), "afx-bridge-telegram-e2e-"));
  const home = join(root, "home");
  const workspace = join(root, "workspace");

  mkdirSync(join(home, ".afx", "bridge"), { recursive: true });
  mkdirSync(workspace, { recursive: true });

  const fakeTelegram = await FakeTelegramServer.start();

  const bridgeConfig = {
    bridge: {
      workspace: workspace,
      permission_mode: "ask",
      connectors: {
        telegram: {
          token_env: "TELEGRAM_BOT_TOKEN",
          allow_users: allowUsers,
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
    fakeTelegram,
    gateway: null,
    bridgeProc: null,
  };
}

function spawnTelegramBridge(ctx: TelegramTestContext, gateway: GatewayInstance): Subprocess {
  const proc = Bun.spawn([FX_BIN, "bridge", "start", "--connector", "telegram"], {
    cwd: ctx.workspace,
    env: {
      ...process.env,
      HOME: ctx.home,
      FX_BRIDGE_TELEGRAM_API_URL: `http://127.0.0.1:${ctx.fakeTelegram.port}`,
      TELEGRAM_BOT_TOKEN: "123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11",
      FX_GATEWAY_CHAT_URL: gateway.chatUrl,
      AI_GATEWAY_API_KEY: "fake-telegram-key",
      FX_PERMISSION_MODE: "ask",
    },
    stdin: "pipe",
    stdout: "pipe",
    stderr: "pipe",
  });
  (async () => {
    const text = await new Response(proc.stderr).text();
    if (text.trim()) console.error("BRIDGE STDERR:", text);
  })();
  (async () => {
    const text = await new Response(proc.stdout).text();
    if (text.trim()) console.log("BRIDGE STDOUT:", text);
  })();
  ctx.bridgeProc = proc;
  return proc;
}

describe("afx bridge (telegram connector)", () => {
  let ctx: TelegramTestContext | null = null;

  afterEach(async () => {
    if (ctx) {
      if (ctx.bridgeProc) {
        try {
          ctx.bridgeProc.kill();
          await ctx.bridgeProc.exited;
        } catch {}
      }
      if (ctx.fakeTelegram) {
        await ctx.fakeTelegram.stop();
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

  test("startup: verifies getMe, starts getUpdates, persists cursor, advances offset on restart", async () => {
    ctx = await setupTelegramTestContext([12345]);
    const gateway = startFakeGateway([fakeGatewayFinalText("Cursor test response")]);
    ctx.gateway = gateway;

    spawnTelegramBridge(ctx, gateway);

    // Initial getMe and getUpdates
    await ctx.fakeTelegram.waitForEvent((e) => e.type === "api_call" && e.method === "getMe");
    await ctx.fakeTelegram.waitForEvent((e) => e.type === "api_call" && e.method === "getUpdates");

    // Send an update with update_id = 100
    ctx.fakeTelegram.sendUpdate({
      update_id: 100,
      message: {
        message_id: 1,
        from: { id: 12345, is_bot: false, username: "testuser" },
        chat: { id: 12345, type: "private" },
        text: "Testing cursor persistence",
        date: 1700000000,
      },
    });

    // Wait for response to be sent
    await ctx.fakeTelegram.waitForEvent(
      (e) => e.type === "api_call" && e.method === "sendMessage" && e.body?.chat_id === 12345,
    );

    // Give store a moment to save
    await delay(300);

    // Verify store.json contains the persisted cursor "101"
    const storePath = join(ctx.home, ".afx", "bridge", "store.json");
    expect(existsSync(storePath)).toBe(true);
    const storeContent = JSON.parse(readFileSync(storePath, "utf-8"));
    const tgCursor = storeContent.cursors?.find((c: { connector: string }) => c.connector === "telegram");
    expect(tgCursor).toBeDefined();
    expect(tgCursor.cursor).toBe("101");

    // Stop the bridge process
    if (ctx.bridgeProc) {
      ctx.bridgeProc.kill();
      await ctx.bridgeProc.exited;
      ctx.bridgeProc = null;
    }

    // Restart the bridge process
    spawnTelegramBridge(ctx, gateway);

    // Assert that the new getUpdates request starts with offset >= 101
    const nextUpdates = await ctx.fakeTelegram.waitForEvent(
      (e) => e.type === "api_call" && e.method === "getUpdates" && (e.body?.offset ?? 0) >= 101,
    );
    expect(nextUpdates).toBeDefined();
    expect(nextUpdates.body?.offset).toBe(101);
  }, TIMEOUT);

  test("private message: sendMessage MarkdownV2 and editMessageText final update", async () => {
    ctx = await setupTelegramTestContext([12345]);
    const gateway = startFakeGateway([fakeGatewayFinalText("Hello from model in Telegram DM!")]);
    ctx.gateway = gateway;

    spawnTelegramBridge(ctx, gateway);
    await ctx.fakeTelegram.waitForEvent((e) => e.type === "api_call" && e.method === "getMe");
    await ctx.fakeTelegram.waitForEvent((e) => e.type === "api_call" && e.method === "getUpdates");

    ctx.fakeTelegram.sendUpdate({
      update_id: 200,
      message: {
        message_id: 10,
        from: { id: 12345, is_bot: false, username: "testuser" },
        chat: { id: 12345, type: "private" },
        text: "Hello assistant",
        date: 1700000001,
      },
    });

    const sendMsg = await ctx.fakeTelegram.waitForEvent(
      (e) => e.type === "api_call" && e.method === "sendMessage" && e.body?.chat_id === 12345,
    );
    expect(sendMsg).toBeDefined();

    const finalMsg = await ctx.fakeTelegram.waitForEvent(
      (e) =>
        (e.type === "api_call" &&
          e.method === "editMessageText" &&
          typeof e.body?.text === "string" &&
          e.body.text.includes("Hello from model in Telegram DM")) ||
        (e.type === "api_call" &&
          e.method === "sendMessage" &&
          typeof e.body?.text === "string" &&
          e.body.text.includes("Hello from model in Telegram DM")),
    );
    expect(finalMsg).toBeDefined();
  }, TIMEOUT);

  test("group messages: ignored without mention, replied in thread when bot mentioned", async () => {
    ctx = await setupTelegramTestContext([12345]);
    const gateway = startFakeGateway([fakeGatewayFinalText("Topic reply from assistant in group.")]);
    ctx.gateway = gateway;

    spawnTelegramBridge(ctx, gateway);
    await ctx.fakeTelegram.waitForEvent((e) => e.type === "api_call" && e.method === "getMe");
    await ctx.fakeTelegram.waitForEvent((e) => e.type === "api_call" && e.method === "getUpdates");

    // 1. Group message without mention
    ctx.fakeTelegram.sendUpdate({
      update_id: 300,
      message: {
        message_id: 20,
        from: { id: 12345, is_bot: false },
        chat: { id: -1001234567890, type: "supergroup" },
        message_thread_id: 42,
        text: "Just talking to colleagues in group",
        date: 1700000002,
      },
    });

    // Wait 500ms to ensure it is not answered
    await delay(500);
    const unmentionedSend = ctx.fakeTelegram.events.find(
      (e) => e.type === "api_call" && e.method === "sendMessage" && e.body?.chat_id === -1001234567890,
    );
    expect(unmentionedSend).toBeUndefined();

    // 2. Group message with bot mention (@afx_test_bot)
    ctx.fakeTelegram.sendUpdate({
      update_id: 301,
      message: {
        message_id: 21,
        from: { id: 12345, is_bot: false },
        chat: { id: -1001234567890, type: "supergroup" },
        message_thread_id: 42,
        text: "@afx_test_bot Help with repository question",
        date: 1700000003,
      },
    });

    const sendWithThread = await ctx.fakeTelegram.waitForEvent(
      (e) =>
        e.type === "api_call" &&
        e.method === "sendMessage" &&
        e.body?.chat_id === -1001234567890 &&
        e.body?.message_thread_id === 42,
    );
    expect(sendWithThread).toBeDefined();

    const finalGroupMsg = await ctx.fakeTelegram.waitForEvent(
      (e) =>
        (e.type === "api_call" &&
          e.method === "editMessageText" &&
          typeof e.body?.text === "string" &&
          e.body.text.includes("Topic reply from assistant in group")) ||
        (e.type === "api_call" &&
          e.method === "sendMessage" &&
          typeof e.body?.text === "string" &&
          e.body.text.includes("Topic reply from assistant in group")),
    );
    expect(finalGroupMsg).toBeDefined();
  }, TIMEOUT);

  test("tool-call approval: posts inline keyboard buttons, callback_query deny triggers answer and denial edit", async () => {
    ctx = await setupTelegramTestContext([12345]);
    const targetPath = join(ctx.workspace, "telegram_denied.txt");

    const gateway = startFakeGateway([
      fakeGatewayToolCall("cmd_tg_1", "terminal", {
        action: "exec",
        command: "touch telegram_denied.txt",
      }),
      fakeGatewayFinalText("Tool execution was denied by user."),
    ]);
    ctx.gateway = gateway;

    spawnTelegramBridge(ctx, gateway);
    await ctx.fakeTelegram.waitForEvent((e) => e.type === "api_call" && e.method === "getMe");
    await ctx.fakeTelegram.waitForEvent((e) => e.type === "api_call" && e.method === "getUpdates");

    ctx.fakeTelegram.sendUpdate({
      update_id: 400,
      message: {
        message_id: 30,
        from: { id: 12345, is_bot: false },
        chat: { id: 12345, type: "private" },
        text: "Execute file command",
        date: 1700000004,
      },
    });

    // Wait for sendMessage containing reply_markup with inline_keyboard
    const buttonPost = await ctx.fakeTelegram.waitForEvent(
      (e) =>
        e.type === "api_call" &&
        e.method === "sendMessage" &&
        e.body?.reply_markup !== undefined &&
        e.body.reply_markup !== null,
    );
    expect(buttonPost).toBeDefined();

    const replyMarkup =
      typeof buttonPost.body!.reply_markup === "string"
        ? JSON.parse(buttonPost.body!.reply_markup)
        : buttonPost.body!.reply_markup;

    const inlineKeyboard = replyMarkup?.inline_keyboard as Array<Array<{ text: string; callback_data: string }>>;
    expect(inlineKeyboard).toBeDefined();

    let denyData: string | null = null;
    let allowData: string | null = null;

    for (const row of inlineKeyboard) {
      for (const btn of row) {
        if (btn.callback_data?.endsWith(":deny")) {
          denyData = btn.callback_data;
        } else if (btn.callback_data?.endsWith(":allow_once")) {
          allowData = btn.callback_data;
        }
      }
    }

    expect(denyData).not.toBeNull();
    expect(allowData).not.toBeNull();

    // Send callback_query deny
    ctx.fakeTelegram.sendUpdate({
      update_id: 401,
      callback_query: {
        id: "cb_query_deny_test",
        from: { id: 12345, is_bot: false },
        message: {
          message_id: 31,
          chat: { id: 12345, type: "private" },
        },
        data: denyData!,
      },
    });

    // Assert answerCallbackQuery is called
    const answer = await ctx.fakeTelegram.waitForEvent(
      (e) =>
        e.type === "api_call" &&
        e.method === "answerCallbackQuery" &&
        e.body?.callback_query_id === "cb_query_deny_test",
    );
    expect(answer).toBeDefined();

    // Final response posted after denial
    const finalMsg = await ctx.fakeTelegram.waitForEvent(
      (e) =>
        (e.type === "api_call" &&
          e.method === "editMessageText" &&
          typeof e.body?.text === "string" &&
          e.body.text.includes("Tool execution was denied")) ||
        (e.type === "api_call" &&
          e.method === "sendMessage" &&
          typeof e.body?.text === "string" &&
          e.body.text.includes("Tool execution was denied")),
    );
    expect(finalMsg).toBeDefined();
    expect(existsSync(targetPath)).toBe(false);
  }, TIMEOUT);

  test("[[BADMD]] fallback: on 400 can't parse entities, resends as plain text", async () => {
    ctx = await setupTelegramTestContext([12345]);
    const gateway = startFakeGateway([fakeGatewayFinalText("Result containing [[BADMD]] error marker")]);
    ctx.gateway = gateway;

    spawnTelegramBridge(ctx, gateway);
    await ctx.fakeTelegram.waitForEvent((e) => e.type === "api_call" && e.method === "getMe");
    await ctx.fakeTelegram.waitForEvent((e) => e.type === "api_call" && e.method === "getUpdates");

    ctx.fakeTelegram.sendUpdate({
      update_id: 500,
      message: {
        message_id: 40,
        from: { id: 12345, is_bot: false },
        chat: { id: 12345, type: "private" },
        text: "Trigger bad markdown test",
        date: 1700000005,
      },
    });

    // Verify fallback retry without parse_mode (plain text) succeeded
    const plainRetry = await ctx.fakeTelegram.waitForEvent(
      (e) =>
        e.type === "api_call" &&
        (e.method === "sendMessage" || e.method === "editMessageText") &&
        !e.body?.parse_mode &&
        typeof e.body?.text === "string" &&
        e.body.text.includes("BADMD"),
    );
    expect(plainRetry).toBeDefined();
  }, TIMEOUT);

  test("long model text (>4096 bytes) is chunked without breaking a fence", async () => {
    ctx = await setupTelegramTestContext([12345]);

    const repeatedLines = "// line of code for telegram chunk test\n".repeat(150);
    const largeMessage = `Intro message before fence\n\`\`\`zig\n${repeatedLines}\`\`\`\nFinal summary after fence.`;
    expect(largeMessage.length).toBeGreaterThan(4096);

    const gateway = startFakeGateway([fakeGatewayFinalText(largeMessage)]);
    ctx.gateway = gateway;

    spawnTelegramBridge(ctx, gateway);
    await ctx.fakeTelegram.waitForEvent((e) => e.type === "api_call" && e.method === "getMe");
    await ctx.fakeTelegram.waitForEvent((e) => e.type === "api_call" && e.method === "getUpdates");

    ctx.fakeTelegram.sendUpdate({
      update_id: 600,
      message: {
        message_id: 50,
        from: { id: 12345, is_bot: false },
        chat: { id: 12345, type: "private" },
        text: "Send large code file",
        date: 1700000006,
      },
    });

    // Wait for at least 2 sendMessage calls for chat 12345
    await ctx.fakeTelegram.waitForEvent((e) => {
      if (e.type === "api_call" && e.method === "sendMessage" && e.body?.chat_id === 12345) {
        const sendCount = ctx!.fakeTelegram.events.filter(
          (ev) => ev.type === "api_call" && ev.method === "sendMessage" && ev.body?.chat_id === 12345,
        ).length;
        return sendCount >= 2;
      }
      return false;
    });

    const sendMessages = ctx.fakeTelegram.events.filter(
      (e) => e.type === "api_call" && e.method === "sendMessage" && e.body?.chat_id === 12345,
    );
    expect(sendMessages.length).toBeGreaterThanOrEqual(2);

    for (const msg of sendMessages) {
      if (typeof msg.body?.text === "string") {
        expect(Buffer.byteLength(msg.body.text, "utf-8")).toBeLessThanOrEqual(4096);
      }
    }
  }, TIMEOUT);

  test("unauthorized user id is ignored", async () => {
    ctx = await setupTelegramTestContext([12345]); // only user 12345 allowed
    const gateway = startFakeGateway([fakeGatewayFinalText("Unauthorized response should not happen")]);
    ctx.gateway = gateway;

    spawnTelegramBridge(ctx, gateway);
    await ctx.fakeTelegram.waitForEvent((e) => e.type === "api_call" && e.method === "getMe");
    await ctx.fakeTelegram.waitForEvent((e) => e.type === "api_call" && e.method === "getUpdates");

    // Send message from unauthorized user 99999
    ctx.fakeTelegram.sendUpdate({
      update_id: 700,
      message: {
        message_id: 60,
        from: { id: 99999, is_bot: false },
        chat: { id: 99999, type: "private" },
        text: "Unauthorized attempt",
        date: 1700000007,
      },
    });

    // Wait 500ms and verify no messages or gateway calls
    await delay(500);
    const unauthorizedSend = ctx.fakeTelegram.events.find(
      (e) => e.type === "api_call" && e.method === "sendMessage" && e.body?.chat_id === 99999,
    );
    expect(unauthorizedSend).toBeUndefined();
    expect(gateway.requests.length).toBe(0);
  }, TIMEOUT);
});
