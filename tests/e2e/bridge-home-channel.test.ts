import { describe, expect, test, afterEach } from "bun:test";
import type { Subprocess } from "bun";
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync, realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN } from "../evals/eval-helpers";
import {
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText as finalText,
  fakeGatewayToolCall as toolCall,
  type FakeGatewayResponse,
  startFakeGateway,
  TmuxSession,
} from "./tmux-helpers";

const TIMEOUT = 30_000;

class BridgeProcess {
  proc: Subprocess;
  stdoutLines: string[] = [];
  stderrLines: string[] = [];
  private closed = false;
  private lineWaiters: Array<{
    predicate: (l: string) => boolean;
    resolve: (l: string) => void;
    reject: (err: Error) => void;
    timer: Timer;
  }> = [];

  constructor(proc: Subprocess) {
    this.proc = proc;
    this.readStream(proc.stdout as ReadableStream<Uint8Array>, (line) => {
      this.stdoutLines.push(line);
      this.checkWaiters(line);
    });
    this.readStream(proc.stderr as ReadableStream<Uint8Array>, (line) => {
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

  async waitForStdoutLine(predicate: (line: string) => boolean, timeoutMs = 10_000): Promise<string> {
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

interface IsolatedEnvironment {
  root: string;
  home: string;
  workspace: string;
  sockPath: string;
}

const roots: string[] = [];
const gateways: Array<{ stop(): void }> = [];
const bridges: BridgeProcess[] = [];
let activeSession: TmuxSession | null = null;

afterEach(async () => {
  if (activeSession) {
    await activeSession.kill();
    activeSession = null;
  }
  for (const bridge of bridges.splice(0)) {
    await bridge.stop();
  }
  for (const gateway of gateways.splice(0)) {
    gateway.stop();
  }
  for (const root of roots.splice(0)) {
    rmSync(root, { recursive: true, force: true });
  }
});

function createIsolatedEnv(): IsolatedEnvironment {
  const tempRoot = existsSync("/private/tmp") ? "/private/tmp" : tmpdir();
  const root = realpathSync(mkdtempSync(join(tempRoot, "afx-home-chan-e2e-")));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  const bridgeDir = join(home, ".afx", "bridge");
  const sockPath = join(bridgeDir, "bridge.sock");

  mkdirSync(bridgeDir, { recursive: true });
  mkdirSync(workspace, { recursive: true });

  writeFileSync(
    join(home, ".afx", "bridge.json"),
    JSON.stringify({
      bridge: {
        workspace: workspace,
        permission_mode: "ask",
        home_channel: {
          connector: "fake",
          chat_id: "test_chat",
        },
        connectors: {
          fake: {
            allow_users: ["test_user"],
          },
        },
      },
    }),
  );

  writeFileSync(
    join(home, ".afx", "settings.json"),
    JSON.stringify({
      permission_mode: "ask",
      home_channel: true,
    }),
  );

  roots.push(root);
  return {
    root,
    home: realpathSync(home),
    workspace: realpathSync(workspace),
    sockPath,
  };
}

describe("bridge home channel", () => {
  test("permission ask mirrored to home channel and answered with deny; cancel on local answer; turn notification", async () => {
    const env = createIsolatedEnv();

    // 1. Start the bridge daemon with fake connector as home channel
    const bridgeProc = Bun.spawn({
      cmd: [FX_BIN, "bridge", "start", "--connector", "fake"],
      cwd: env.workspace,
      env: {
        HOME: env.home,
        FX_BRIDGE_SOCK: env.sockPath,
        FX_AUTO_UPGRADE: "0",
        NO_COLOR: "1",
      },
      stdin: "pipe",
      stdout: "pipe",
      stderr: "pipe",
    });
    const bridge = new BridgeProcess(bridgeProc);
    bridges.push(bridge);
    await bridge.waitForStdoutLine((l) => l.includes("Bridge daemon started"));

    // 2. Setup gateway responses:
    // Turn 1: tool call (terminal: touch file1.txt) -> denied -> model continues -> completes
    const responses: FakeGatewayResponse[] = [
      toolCall("call_1", "write_file", { path: "file1.txt", content: "first content\n" }),
      finalText("Denial acknowledged; first turn complete."),
      toolCall("call_2", "write_file", { path: "file2.txt", content: "second content\n" }),
      finalText("Local answer acknowledged; second turn complete."),
    ];
    const gateway = startFakeGateway(responses);
    gateways.push(gateway);

    // 3. Start TUI in tmux
    const stderrPath = join(env.root, "stderr.log");
    writeFileSync(stderrPath, "");
    activeSession = await TmuxSession.create({
      cmd: FX_BIN,
      cwd: env.workspace,
      env: {
        HOME: env.home,
        FX_BRIDGE_SOCK: env.sockPath,
        AI_GATEWAY_API_KEY: "fake-key",
        FX_GATEWAY_BASE_URL: gateway.baseUrl,
        FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        FX_MODEL: FAKE_GATEWAY_MODEL,
        FX_PERMISSION_MODE: "ask",
        FX_AUTO_UPGRADE: "0",
        NO_COLOR: "1",
        FX_TRACE: join(env.root, "trace.log"),
      },
      stderrPath,
      width: 120,
      height: 40,
    });
    await activeSession.waitForComposer(TIMEOUT);

    // --- CASE 1: In-chat Allow/Deny answers TUI prompt ---
    await activeSession.sendText("create file1.txt");
    // Daemon prints ASK tui:...
    const askLine1 = await bridge.waitForStdoutLine((l) => l.startsWith("ASK tui:"));
    const match1 = askLine1.match(/^ASK (tui:\d+:\d+) /);
    expect(match1).not.toBeNull();
    const reqId1 = match1![1];

    // Assert TUI is waiting on approval screen
    await activeSession.waitForPane((pane) => pane.includes("terminal.exec") || pane.includes("touch file1.txt") || pane.includes("file1.txt"));

    // Send APPROVE <id> deny on daemon stdin
    bridge.writeLine(`APPROVE ${reqId1} deny`);

    await activeSession.waitForPane((pane) => pane.includes("Denial acknowledged; first turn complete."), TIMEOUT);

    // Check turn complete notification sent to home channel
    const sendLine1 = await bridge.waitForStdoutLine((l) => l.startsWith("SEND test_chat afx: turn complete in"));
    expect(sendLine1).toContain("Denial acknowledged; first turn complete.");
    // --- CASE 2: User answers locally in terminal -> daemon receives cancel_ask ---
    await activeSession.sendText("create file2.txt");

    // Daemon prints ASK tui:...
    const askLine2 = await bridge.waitForStdoutLine((l) => l.startsWith("ASK tui:") && l !== askLine1);
    const match2 = askLine2.match(/^ASK (tui:\d+:\d+) /);
    expect(match2).not.toBeNull();
    const reqId2 = match2![1];

    // Assert TUI is showing approval prompt
    await activeSession.waitForPane((pane) => pane.includes("second content") || pane.includes("file2.txt"));

    // User answers locally in tmux (press 3 for deny)
    await activeSession.sendKeys("3");
    // Daemon stdout shows EDIT ... answered in terminal
    const editLine = await bridge.waitForStdoutLine((l) => l.includes("answered in terminal"));
    expect(editLine).toContain(reqId2);
    expect(editLine).toContain("answered in terminal");

    // Turn completes in TUI
    await activeSession.waitForPane((pane) => pane.includes("Local answer acknowledged; second turn complete."), TIMEOUT);

    // Check turn complete notification sent for second turn
    const sendLine2 = await bridge.waitForStdoutLine((l) => l.startsWith("SEND test_chat afx: turn complete in") && l !== sendLine1);
    expect(sendLine2).toContain("Local answer acknowledged; second turn complete.");
  }, TIMEOUT);
});
