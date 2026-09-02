import { describe, expect, test, afterEach } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN, REPO_ROOT, runFx } from "../evals/eval-helpers";
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

class BridgeProcess {
  proc: ReturnType<typeof Bun.spawn>;
  stdoutLines: string[] = [];
  stderrLines: string[] = [];
  private closed = false;
  private lineWaiters: Array<{
    predicate: (l: string) => boolean;
    resolve: (l: string) => void;
    reject: (err: Error) => void;
    timer: ReturnType<typeof setTimeout>;
  }> = [];

  constructor(proc: ReturnType<typeof Bun.spawn>) {
    this.proc = proc;
    this.readStream(proc.stdout, (line) => {
      this.stdoutLines.push(line);
      this.checkWaiters(line);
    });
    this.readStream(proc.stderr, (line) => {
      this.stderrLines.push(line);
    });
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
          onLine(part);
        }
      }
      if (buffer.length > 0) {
        onLine(buffer);
      }
    } catch {}
  }

  private checkWaiters(line: string) {
    for (let i = this.lineWaiters.length - 1; i >= 0; i--) {
      const waiter = this.lineWaiters[i];
      if (waiter.predicate(line)) {
        clearTimeout(waiter.timer);
        this.lineWaiters.splice(i, 1);
        waiter.resolve(line);
      }
    }
  }

  async waitForStdoutLine(predicate: (line: string) => boolean, timeoutMs = 7000): Promise<string> {
    for (const line of this.stdoutLines) {
      if (predicate(line)) {
        return line;
      }
    }
    const { promise, resolve, reject } = Promise.withResolvers<string>();
    const timer = setTimeout(() => {
      const idx = this.lineWaiters.findIndex((w) => w.timer === timer);
      if (idx !== -1) this.lineWaiters.splice(idx, 1);
      reject(
        new Error(
          `Timed out after ${timeoutMs}ms waiting for stdout line.\nGot stdout lines:\n${this.stdoutLines.join(
            "\n",
          )}\nGot stderr lines:\n${this.stderrLines.join("\n")}`,
        ),
      );
    }, timeoutMs);
    this.lineWaiters.push({ predicate, resolve, reject, timer });
    return promise;
  }

  writeLine(line: string) {
    this.proc.stdin.write(line + "\n");
    this.proc.stdin.flush();
  }

  async stop(): Promise<void> {
    if (this.closed) return;
    this.closed = true;
    try {
      this.proc.kill();
      await this.proc.exited;
    } catch {}
  }
}

type TestContext = {
  root: string;
  home: string;
  workspace: string;
  gateway: GatewayInstance | null;
  bridge: BridgeProcess | null;
};

function setupTestContext(approvalTimeoutS = 600, allowUsers?: string[]): TestContext {
  const root = mkdtempSync(join(tmpdir(), "afx-bridge-e2e-"));
  const home = join(root, "home");
  const workspace = join(root, "workspace");

  mkdirSync(join(home, ".afx", "bridge"), { recursive: true });
  mkdirSync(workspace, { recursive: true });

  const bridgeConfig: {
    bridge: {
      workspace: string;
      permission_mode: string;
      approval_timeout_s: number;
      max_concurrent_sessions: number;
      connectors?: {
        fake?: {
          allow_users: string[];
        };
      };
    };
  } = {
    bridge: {
      workspace: workspace,
      permission_mode: "ask",
      approval_timeout_s: approvalTimeoutS,
      max_concurrent_sessions: 4,
    },
  };
  if (allowUsers !== undefined) {
    bridgeConfig.bridge.connectors = {
      fake: {
        allow_users: allowUsers,
      },
    };
  }
  writeFileSync(join(home, ".afx", "bridge.json"), JSON.stringify(bridgeConfig, null, 2), {
    mode: 0o600,
  });

  return {
    root,
    home,
    workspace,
    gateway: null,
    bridge: null,
  };
}

function spawnBridge(ctx: TestContext, gateway: GatewayInstance): BridgeProcess {
  const proc = Bun.spawn([FX_BIN, "bridge", "start", "--connector", "fake"], {
    cwd: ctx.workspace,
    env: {
      ...process.env,
      HOME: ctx.home,
      FX_GATEWAY_CHAT_URL: gateway.chatUrl,
      AI_GATEWAY_API_KEY: "fake-bridge-key",
      FX_PERMISSION_MODE: "ask",
    },
    stdin: "pipe",
    stdout: "pipe",
    stderr: "pipe",
  });
  const bridge = new BridgeProcess(proc);
  ctx.bridge = bridge;
  return bridge;
}

describe("afx bridge (fake connector)", () => {
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

  test("inbound MSG produces model reply via SEND and final EDIT", async () => {
    ctx = setupTestContext();
    const gateway = startFakeGateway([fakeGatewayFinalText("Hello from bridge agent!")]);
    ctx.gateway = gateway;

    const bridge = spawnBridge(ctx, gateway);
    await bridge.waitForStdoutLine((line) => line.includes("Bridge daemon started"));

    bridge.writeLine("MSG test_chat test_user Say hello");

    const sendLine = await bridge.waitForStdoutLine((line) => line.startsWith("SEND test_chat "));
    expect(sendLine).toContain("Hello from bridge agent!");

    const editLine = await bridge.waitForStdoutLine((line) => line.startsWith("EDIT fake_msg_1 "));
    expect(editLine).toContain("Hello from bridge agent!");
  }, TIMEOUT);

  test("mutating tool call emits ASK, deny rejects action and allow_once writes file", async () => {
    ctx = setupTestContext();
    const targetDenied = join(ctx.workspace, "denied.txt");
    const targetAllowed = join(ctx.workspace, "allowed.txt");

    const gateway = startFakeGateway([
      fakeGatewayToolCall("cmd_denied", "terminal", {
        action: "exec",
        command: "touch denied.txt",
      }),
      fakeGatewayFinalText("Action was denied by user."),
      fakeGatewayToolCall("cmd_allowed", "terminal", {
        action: "exec",
        command: "touch allowed.txt",
      }),
      fakeGatewayFinalText("Command execution completed successfully."),
    ]);
    ctx.gateway = gateway;

    const bridge = spawnBridge(ctx, gateway);
    await bridge.waitForStdoutLine((line) => line.includes("Bridge daemon started"));

    // 1. Turn with denial
    bridge.writeLine("MSG test_chat test_user Run denied command");
    const askLine1 = await bridge.waitForStdoutLine((line) => line.startsWith("ASK "));
    const reqId1 = askLine1.split(" ")[1];
    expect(reqId1.length).toBeGreaterThan(0);

    bridge.writeLine(`APPROVE ${reqId1} deny`);

    // Turn ends and file is not created
    await bridge.waitForStdoutLine((line) => line.startsWith("EDIT fake_msg_") || line.startsWith("SEND test_chat "));
    expect(existsSync(targetDenied)).toBe(false);

    // 2. Turn with allow_once
    bridge.writeLine("MSG test_chat test_user Run allowed command");
    const askLine2 = await bridge.waitForStdoutLine((line) => line.startsWith("ASK ") && !line.includes(reqId1));
    const reqId2 = askLine2.split(" ")[1];
    expect(reqId2.length).toBeGreaterThan(0);

    bridge.writeLine(`APPROVE ${reqId2} allow_once`);

    const finalLine = await bridge.waitForStdoutLine((line) => line.includes("Command execution completed"));
    expect(finalLine.length).toBeGreaterThan(0);

    expect(existsSync(targetAllowed)).toBe(true);
  }, TIMEOUT);

  test("approval timeout: expires approval and executes deny path when unapproved", async () => {
    ctx = setupTestContext(1); // 1-second timeout
    const targetTimeout = join(ctx.workspace, "timeout.txt");

    const gateway = startFakeGateway([
      fakeGatewayToolCall("cmd_timeout", "terminal", {
        action: "exec",
        command: "touch timeout.txt",
      }),
    ]);
    ctx.gateway = gateway;

    const bridge = spawnBridge(ctx, gateway);
    await bridge.waitForStdoutLine((line) => line.includes("Bridge daemon started"));

    bridge.writeLine("MSG test_chat test_user Run with timeout");
    const askLine = await bridge.waitForStdoutLine((line) => line.startsWith("ASK "));
    expect(askLine.length).toBeGreaterThan(0);

    // Do not approve -> wait for expiry thread to trigger within ~3 seconds
    const expireMsg = await bridge.waitForStdoutLine(
      (line) => line.includes("expired (denied)") || line.includes("Approval request expired"),
      5000,
    );
    expect(expireMsg).toContain("expired");
    expect(existsSync(targetTimeout)).toBe(false);
  }, TIMEOUT);

  test("in-chat slash commands /status, /new, and unknown /foo produce responses", async () => {
    ctx = setupTestContext();
    const gateway = startFakeGateway([]);
    ctx.gateway = gateway;

    const bridge = spawnBridge(ctx, gateway);
    await bridge.waitForStdoutLine((line) => line.includes("Bridge daemon started"));

    // /status command
    bridge.writeLine("MSG test_chat test_user /status");
    const statusLine = await bridge.waitForStdoutLine((line) => line.startsWith("SEND test_chat ") && line.includes("Model:"));
    expect(statusLine).toContain("Model:");
    const permLine = await bridge.waitForStdoutLine((line) => line.includes("Permissions:"));
    expect(permLine).toContain("Permissions:");

    // /new command
    bridge.writeLine("MSG test_chat test_user /new");
    const newLine = await bridge.waitForStdoutLine((line) => line.startsWith("SEND test_chat ") && line.includes("Started new session:"));
    expect(newLine).toContain("Started new session:");
    // Unknown command /foo
    bridge.writeLine("MSG test_chat test_user /foo");
    const unknownLine = await bridge.waitForStdoutLine((line) => line.startsWith("SEND test_chat ") && line.includes("Unknown command '/foo'"));
    expect(unknownLine).toContain("Unknown command '/foo'");
  }, TIMEOUT);

  test("bridge status --json and bridge stop control lifecycle", async () => {
    ctx = setupTestContext();
    const gateway = startFakeGateway([fakeGatewayFinalText("Conversation established")]);
    ctx.gateway = gateway;

    const bridge = spawnBridge(ctx, gateway);
    await bridge.waitForStdoutLine((line) => line.includes("Bridge daemon started"));

    // Send one message to create a conversation
    bridge.writeLine("MSG test_chat test_user Hi");
    await bridge.waitForStdoutLine((line) => line.startsWith("SEND test_chat "));

    // Query status --json while running
    const statusResult = await runFx(["bridge", "status", "--json"], {
      env: { HOME: ctx.home },
    });
    expect(statusResult.code).toBe(0);
    const parsedStatus = JSON.parse(statusResult.stdout);
    expect(parsedStatus.running).toBe(true);

    // Stop daemon via CLI
    const stopResult = await runFx(["bridge", "stop"], {
      env: { HOME: ctx.home },
    });
    expect(stopResult.code).toBe(0);
    expect(stopResult.stdout).toContain("Bridge daemon stopped");

    // Check status --json reports running: false
    const stoppedStatusResult = await runFx(["bridge", "status", "--json"], {
      env: { HOME: ctx.home },
    });
    expect(stoppedStatusResult.code).toBe(0);
    const parsedStopped = JSON.parse(stoppedStatusResult.stdout);
    expect(parsedStopped.running).toBe(false);
  }, TIMEOUT);

  test("bridge pair fake generates 6-digit code and pairing file", async () => {
    ctx = setupTestContext();

    const pairResult = await runFx(["bridge", "pair", "fake"], {
      env: { HOME: ctx.home },
    });
    expect(pairResult.code).toBe(0);
    expect(pairResult.stdout).toMatch(/Pairing code for fake: \d{6}/);

    const match = pairResult.stdout.match(/Pairing code for fake: (\d{6})/);
    expect(match).not.toBeNull();
    const code = match![1];

    const pairingFilePath = join(ctx.home, ".afx", "bridge", "pairing.json");
    expect(existsSync(pairingFilePath)).toBe(true);

    const savedJson = JSON.parse(readFileSync(pairingFilePath, "utf-8"));
    expect(savedJson.connector).toBe("fake");
    expect(savedJson.code).toBe(code);
    expect(typeof savedJson.expires_ms).toBe("number");
  }, TIMEOUT);

  test("unauthorized user message produces no SEND within 2s and daemon stays alive", async () => {
    ctx = setupTestContext(600, ["authorized_alice"]);
    const gateway = startFakeGateway([fakeGatewayFinalText("Should not be delivered")]);
    ctx.gateway = gateway;

    const bridge = spawnBridge(ctx, gateway);
    await bridge.waitForStdoutLine((line) => line.includes("Bridge daemon started"));

    bridge.writeLine("MSG test_chat intruder_eve Hello");

    const sendEmitted = await Promise.race([
      bridge.waitForStdoutLine((line) => line.startsWith("SEND test_chat "), 2000).then(() => true, () => false),
      new Promise<boolean>((resolve) => setTimeout(() => resolve(false), 2000)),
    ]);
    expect(sendEmitted).toBe(false);
    expect(bridge.proc.exitCode).toBeNull();
  }, TIMEOUT);

  test("pairing: unknown user pairs with code -> confirmation SEND -> bridge.json updated -> follow-up MSG succeeds", async () => {
    ctx = setupTestContext(600, ["authorized_alice"]);
    const gateway = startFakeGateway([fakeGatewayFinalText("Follow-up answer for new user.")]);
    ctx.gateway = gateway;

    const bridge = spawnBridge(ctx, gateway);
    await bridge.waitForStdoutLine((line) => line.includes("Bridge daemon started"));

    // Generate pairing code via CLI
    const pairResult = await runFx(["bridge", "pair", "fake"], {
      env: { HOME: ctx.home },
    });
    expect(pairResult.code).toBe(0);
    const match = pairResult.stdout.match(/Pairing code for fake: (\d{6})/);
    expect(match).not.toBeNull();
    const code = match![1];

    // Send code as DM from unknown user
    bridge.writeLine(`MSG test_chat unknown_bob ${code}`);
    const confirmLine = await bridge.waitForStdoutLine((line) => line.startsWith("SEND test_chat ") && line.includes("Pairing successful"));
    expect(confirmLine).toContain("authorized");

    // Verify bridge.json now lists unknown_bob
    const savedConfig = JSON.parse(readFileSync(join(ctx.home, ".afx", "bridge.json"), "utf-8"));
    const fakeAllowList: string[] = savedConfig.bridge?.connectors?.fake?.allow_users ?? [];
    expect(fakeAllowList).toContain("unknown_bob");

    // Follow-up message from unknown_bob now succeeds normally
    bridge.writeLine("MSG test_chat unknown_bob Hello assistant");
    const replyLine = await bridge.waitForStdoutLine((line) => line.startsWith("SEND test_chat ") && line.includes("Follow-up answer"));
    expect(replyLine).toContain("Follow-up answer for new user.");
  }, TIMEOUT);

  test("empty allow_users refuses to start fake connector unless pairing code is active", async () => {
    ctx = setupTestContext(600, []);
    const gateway = startFakeGateway([]);
    ctx.gateway = gateway;

    // 1. Attempt start with empty allowlist and no pairing code -> fails
    const failProc = Bun.spawn([FX_BIN, "bridge", "start", "--connector", "fake"], {
      cwd: ctx.workspace,
      env: {
        ...process.env,
        HOME: ctx.home,
        FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        AI_GATEWAY_API_KEY: "fake-bridge-key",
      },
      stdin: "pipe",
      stdout: "pipe",
      stderr: "pipe",
    });
    const exitCode = await failProc.exited;
    expect(exitCode).not.toBe(0);
    const errText = await new Response(failProc.stderr).text();
    expect(errText).toContain("disabled: allowlist is empty and no active pairing code exists");

    // 2. Generate pairing code
    const pairResult = await runFx(["bridge", "pair", "fake"], {
      env: { HOME: ctx.home },
    });
    expect(pairResult.code).toBe(0);

    // 3. Now start succeeds because pairing code is active
    const bridge = spawnBridge(ctx, gateway);
    const startLine = await bridge.waitForStdoutLine((line) => line.includes("Bridge daemon started"));
    expect(startLine).toContain("Bridge daemon started");
  }, TIMEOUT);
});
