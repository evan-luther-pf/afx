import { describe, expect, test, afterEach } from "bun:test";
import { type Subprocess } from "bun";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN, REPO_ROOT, runFx } from "../evals/eval-helpers";
import {
  fakeGatewayFinalText,
  fakeGatewayToolCall,
  startFakeGateway,
} from "./tmux-helpers";
import {
  FakeImsgDatabase,
  buildAttributedBodyBytes,
} from "./fixtures/fake-imsg/fake-imsg";

if (process.platform !== "darwin") {
  console.log("Skipping bridge-imsg.test.ts: macOS only (requires macOS Messages and AppleScript)");
}
const darwinTest = test.skipIf(process.platform !== "darwin");
const TIMEOUT = 30_000;
type GatewayInstance = {
  baseUrl: string;
  chatUrl: string;
  requests: Array<{ body: string; headers: Headers }>;
  stop: () => void;
};

type TestContext = {
  root: string;
  home: string;
  workspace: string;
  dbPath: string;
  db: FakeImsgDatabase;
  osascriptLog: string;
  gateway?: GatewayInstance;
  bridge?: BridgeProcess;
};

class BridgeProcess {
  proc: Subprocess;
  stdoutLines: string[] = [];
  stderrLines: string[] = [];

  constructor(proc: Subprocess) {
    this.proc = proc;
    this.readStream(proc.stdout as ReadableStream<Uint8Array>, (line) => this.stdoutLines.push(line));
    this.readStream(proc.stderr as ReadableStream<Uint8Array>, (line) => this.stderrLines.push(line));
  }

  private async readStream(stream: ReadableStream<Uint8Array>, onLine: (l: string) => void) {
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
          if (part.trim()) onLine(part.trim());
        }
      }
      if (buffer.trim()) onLine(buffer.trim());
    } catch {}
  }

  async waitForStdoutLine(predicate: (line: string) => boolean, timeoutMs = 10000): Promise<string> {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      for (const line of this.stdoutLines) {
        if (predicate(line)) return line;
      }
      await Bun.sleep(50);
    }
    throw new Error(
      `Timed out after ${timeoutMs}ms waiting for stdout line.\nGot stdout lines:\n${this.stdoutLines.join(
        "\n",
      )}\nGot stderr lines:\n${this.stderrLines.join("\n")}`,
    );
  }

  async stop() {
    try {
      this.proc.kill();
      await this.proc.exited;
    } catch {}
  }
}

function setupTestContext(opts: {
  allowHandles?: string[];
  pollIntervalMs?: number;
  groupPrefix?: string;
} = {}): TestContext {
  const root = mkdtempSync(join(tmpdir(), "afx-bridge-imsg-"));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  const afxDir = join(home, ".afx");
  const bridgeDir = join(afxDir, "bridge");

  mkdirSync(home, { recursive: true });
  mkdirSync(workspace, { recursive: true });
  mkdirSync(bridgeDir, { recursive: true });

  const dbPath = join(root, "chat.db");
  const db = FakeImsgDatabase.create(dbPath);
  const osascriptLog = join(root, "osascript.log");

  const bridgeConfig = {
    bridge: {
      workspace,
      permission_mode: "ask",
      connectors: {
        imsg: {
          allow_handles: opts.allowHandles ?? ["+15551234567", "alice@example.com"],
          poll_interval_ms: opts.pollIntervalMs ?? 50,
          db_path: dbPath,
          group_prefix: opts.groupPrefix ?? "@afx",
        },
      },
    },
  };

  writeFileSync(join(home, ".afx/bridge.json"), JSON.stringify(bridgeConfig, null, 2));

  return {
    root,
    home,
    workspace,
    dbPath,
    db,
    osascriptLog,
  };
}

function spawnBridge(ctx: TestContext, gateway: GatewayInstance): BridgeProcess {
  const stubDir = join(REPO_ROOT, "tests/e2e/fixtures/fake-imsg");
  const proc = Bun.spawn([FX_BIN, "bridge", "start", "--connector", "imsg"], {
    env: {
      ...process.env,
      HOME: ctx.home,
      FX_GATEWAY_CHAT_URL: gateway.chatUrl,
      AI_GATEWAY_API_KEY: "fake-key",
      FAKE_OSASCRIPT_LOG: ctx.osascriptLog,
      PATH: `${stubDir}:${process.env.PATH}`,
    },
    cwd: ctx.workspace,
    stdin: "pipe",
    stdout: "pipe",
    stderr: "pipe",
  });

  const bridge = new BridgeProcess(proc);
  ctx.bridge = bridge;
  return bridge;
}

async function waitForOsascriptLog(
  logPath: string,
  predicate: (content: string) => boolean,
  timeoutMs = 10000,
): Promise<string> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (existsSync(logPath)) {
      const content = readFileSync(logPath, "utf8");
      if (predicate(content)) return content;
    }
    await Bun.sleep(50);
  }
  const content = existsSync(logPath) ? readFileSync(logPath, "utf8") : "<no log file>";
  throw new Error(`Timed out after ${timeoutMs}ms waiting for osascript log.\nContent:\n${content}`);
}

describe("bridge: iMessage connector (macOS)", () => {
  let ctx: TestContext | null = null;

  afterEach(async () => {
    if (ctx) {
      if (ctx.bridge) {
        await ctx.bridge.stop();
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

  darwinTest("(a) first start ignores pre-existing rows; new row -> osascript send with model reply", async () => {
    ctx = setupTestContext();

    // 1. Insert pre-existing row before bridge starts
    ctx.db.appendMessage({
      handle: "+15551234567",
      chatGuid: "iMessage;-;+15551234567",
      text: "Pre-existing message",
    });

    const gateway = startFakeGateway([fakeGatewayFinalText("Hello from iMessage bridge!")]);
    ctx.gateway = gateway;

    const bridge = spawnBridge(ctx, gateway);
    await bridge.waitForStdoutLine((l) => l.includes("Bridge daemon started"));

    // Wait a short moment to ensure pre-existing row is not processed
    await Bun.sleep(200);
    expect(existsSync(ctx.osascriptLog)).toBe(false);

    // 2. Insert new message
    ctx.db.appendMessage({
      handle: "+15551234567",
      chatGuid: "iMessage;-;+15551234567",
      text: "Hello afx",
    });

    // 3. Verify osascript send received model reply
    const log = await waitForOsascriptLog(ctx.osascriptLog, (c) =>
      c.includes('tell application "Messages" to send "Hello from iMessage bridge!" to chat id "iMessage;-;+15551234567"'),
    );
    expect(log).toContain("Hello from iMessage bridge!");
  }, TIMEOUT);

  darwinTest("(b) attributedBody-only row decodes and gets a reply", async () => {
    ctx = setupTestContext();

    const gateway = startFakeGateway([fakeGatewayFinalText("Received attributed body text!")]);
    ctx.gateway = gateway;

    const bridge = spawnBridge(ctx, gateway);
    await bridge.waitForStdoutLine((l) => l.includes("Bridge daemon started"));

    // Insert attributedBody-only row
    const attrBytes = buildAttributedBodyBytes("Attributed text query");
    ctx.db.appendMessage({
      handle: "+15551234567",
      chatGuid: "iMessage;-;+15551234567",
      text: null,
      attributedBody: attrBytes,
    });

    const log = await waitForOsascriptLog(ctx.osascriptLog, (c) =>
      c.includes("Received attributed body text!"),
    );
    expect(log).toContain("Received attributed body text!");
  }, TIMEOUT);

  darwinTest("(c) is_from_me rows ignored", async () => {
    ctx = setupTestContext();

    const gateway = startFakeGateway([fakeGatewayFinalText("Should not be called")]);
    ctx.gateway = gateway;

    const bridge = spawnBridge(ctx, gateway);
    await bridge.waitForStdoutLine((l) => l.includes("Bridge daemon started"));

    // Insert outgoing message (is_from_me = 1)
    ctx.db.appendMessage({
      handle: "+15551234567",
      chatGuid: "iMessage;-;+15551234567",
      text: "Outgoing message from me",
      isFromMe: 1,
    });

    await Bun.sleep(300);
    expect(existsSync(ctx.osascriptLog)).toBe(false);
  }, TIMEOUT);

  darwinTest("(d) tool-call prompt -> ask text sent, reply 3 -> denial text; reply 1 -> file written", async () => {
    ctx = setupTestContext();
    const targetFile = join(ctx.workspace, "created_by_tool.txt");

    const gateway = startFakeGateway([
      // 1. First turn: returns tool call, which triggers ask prompt
      fakeGatewayToolCall("cmd_touch", "terminal", {
        action: "exec",
        command: "touch created_by_tool.txt",
      }),
      // When denied (reply 3), gateway receives tool result and produces denial summary
      fakeGatewayFinalText("Tool was denied by user."),

      // 2. Second turn: returns tool call again
      fakeGatewayToolCall("cmd_touch_2", "terminal", {
        action: "exec",
        command: "touch created_by_tool.txt",
      }),
      // When allowed (reply 1), gateway produces success summary
      fakeGatewayFinalText("File created successfully."),
    ]);
    ctx.gateway = gateway;

    const bridge = spawnBridge(ctx, gateway);
    await bridge.waitForStdoutLine((l) => l.includes("Bridge daemon started"));

    // --- Part 1: Deny (reply 3) ---
    ctx.db.appendMessage({
      handle: "+15551234567",
      chatGuid: "iMessage;-;+15551234567",
      text: "Please run tool",
    });

    // Wait for ask prompt sent via osascript
    await waitForOsascriptLog(ctx.osascriptLog, (c) =>
      c.includes("Reply 1 to allow once, 2 to allow for this session, 3 to deny"),
    );

    // Reply with "3" (deny)
    ctx.db.appendMessage({
      handle: "+15551234567",
      chatGuid: "iMessage;-;+15551234567",
      text: "3",
    });

    // Wait for denial text
    await waitForOsascriptLog(ctx.osascriptLog, (c) =>
      c.includes("Tool was denied by user."),
    );
    expect(existsSync(targetFile)).toBe(false);

    // --- Part 2: Allow once (reply 1) ---
    ctx.db.appendMessage({
      handle: "+15551234567",
      chatGuid: "iMessage;-;+15551234567",
      text: "Please run tool again",
    });

    // Wait for second ask prompt
    await waitForOsascriptLog(ctx.osascriptLog, (c) => {
      const occurrences = c.split("Reply 1 to allow once").length - 1;
      return occurrences >= 2;
    });

    // Reply with "1" (allow once)
    ctx.db.appendMessage({
      handle: "+15551234567",
      chatGuid: "iMessage;-;+15551234567",
      text: "1",
    });

    // Wait for final reply and confirm file was created
    await waitForOsascriptLog(ctx.osascriptLog, (c) =>
      c.includes("File created successfully."),
    );
    expect(existsSync(targetFile)).toBe(true);
  }, TIMEOUT);

  darwinTest("(e) group chat without prefix ignored, with prefix replied", async () => {
    ctx = setupTestContext({ groupPrefix: "@afx" });

    const gateway = startFakeGateway([fakeGatewayFinalText("Group reply!")]);
    ctx.gateway = gateway;

    const bridge = spawnBridge(ctx, gateway);
    await bridge.waitForStdoutLine((l) => l.includes("Bridge daemon started"));

    // 1. Message without prefix in group chat (starts with iMessage;+;)
    ctx.db.appendMessage({
      handle: "+15551234567",
      chatGuid: "iMessage;+;chat99999",
      text: "Hello room without prefix",
    });

    await Bun.sleep(250);
    expect(existsSync(ctx.osascriptLog)).toBe(false);

    // 2. Message with prefix in group chat
    ctx.db.appendMessage({
      handle: "+15551234567",
      chatGuid: "iMessage;+;chat99999",
      text: "@afx Hello room with prefix",
    });

    const log = await waitForOsascriptLog(ctx.osascriptLog, (c) =>
      c.includes('to chat id "iMessage;+;chat99999"'),
    );
    expect(log).toContain("Group reply!");
  }, TIMEOUT);

  darwinTest("(f) handle not in allowlist ignored", async () => {
    ctx = setupTestContext({ allowHandles: ["+15551234567"] });

    const gateway = startFakeGateway([fakeGatewayFinalText("Should not reply")]);
    ctx.gateway = gateway;

    const bridge = spawnBridge(ctx, gateway);
    await bridge.waitForStdoutLine((l) => l.includes("Bridge daemon started"));

    // Message from disallowed handle
    ctx.db.appendMessage({
      handle: "+19999999999",
      chatGuid: "iMessage;-;+19999999999",
      text: "Unauthorized query",
    });

    await Bun.sleep(300);
    expect(existsSync(ctx.osascriptLog)).toBe(false);
  }, TIMEOUT);

  darwinTest("(g) restart resumes from persisted ROWID cursor without replay", async () => {
    ctx = setupTestContext();

    const gateway = startFakeGateway([
      fakeGatewayFinalText("First reply before restart"),
      fakeGatewayFinalText("Second reply after restart"),
    ]);
    ctx.gateway = gateway;

    // 1. Start bridge and process first message
    const bridge1 = spawnBridge(ctx, gateway);
    await bridge1.waitForStdoutLine((l) => l.includes("Bridge daemon started"));

    ctx.db.appendMessage({
      handle: "+15551234567",
      chatGuid: "iMessage;-;+15551234567",
      text: "First message",
    });

    await waitForOsascriptLog(ctx.osascriptLog, (c) =>
      c.includes("First reply before restart"),
    );

    // 2. Stop bridge cleanly via CLI
    await runFx(["bridge", "stop"], {
      env: { HOME: ctx.home },
    });
    await bridge1.stop();

    // Clear log
    writeFileSync(ctx.osascriptLog, "");

    // 3. Restart bridge with same store
    const bridge2 = spawnBridge(ctx, gateway);
    await bridge2.waitForStdoutLine((l) => l.includes("Bridge daemon started"));

    // Wait a moment and confirm first message was not replayed
    await Bun.sleep(250);
    expect(readFileSync(ctx.osascriptLog, "utf8")).toBe("");

    // 4. Append new message and verify only new message gets replied to
    ctx.db.appendMessage({
      handle: "+15551234567",
      chatGuid: "iMessage;-;+15551234567",
      text: "Second message",
    });

    const log = await waitForOsascriptLog(ctx.osascriptLog, (c) =>
      c.includes("Second reply after restart"),
    );
    expect(log).toContain("Second reply after restart");
  }, TIMEOUT);
});
