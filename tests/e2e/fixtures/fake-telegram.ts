// Fake Telegram Bot API HTTP server for end-to-end integration tests.
// Uses Bun.serve to host HTTP endpoints.
// Reads JSON lines from stdin representing queued updates.
// Prints `PORT <n>` to stdout on startup.

import { createInterface } from "readline";

let msgCounter = 0;

interface TelegramUpdate {
  update_id: number;
  message?: {
    message_id?: number;
    from?: { id: number; is_bot?: boolean; first_name?: string; username?: string };
    chat?: { id: number | string; type?: string };
    message_thread_id?: number;
    reply_to_message?: unknown;
    text?: string;
    date?: number;
  };
  callback_query?: {
    id: string;
    from?: { id: number; is_bot?: boolean; username?: string };
    message?: {
      message_id?: number;
      chat?: { id: number | string; type?: string };
      message_thread_id?: number;
    };
    data?: string;
  };
  [key: string]: unknown;
}

const queuedUpdates: TelegramUpdate[] = [];

type UpdateWaiter = {
  offset: number;
  resolve: (updates: TelegramUpdate[]) => void;
  timer: ReturnType<typeof setTimeout>;
};

const activeWaiters: UpdateWaiter[] = [];

function notifyWaiters() {
  for (let i = activeWaiters.length - 1; i >= 0; i--) {
    const waiter = activeWaiters[i];
    const matching = queuedUpdates.filter((u) => u.update_id >= waiter.offset);
    if (matching.length > 0) {
      clearTimeout(waiter.timer);
      activeWaiters.splice(i, 1);
      waiter.resolve(matching);
    }
  }
}

const rl = createInterface({
  input: process.stdin,
  crlfDelay: Infinity,
});

process.stdin.resume();

rl.on("line", (line) => {
  const trimmed = line.trim();
  if (!trimmed) return;
  try {
    const update = JSON.parse(trimmed) as TelegramUpdate;
    queuedUpdates.push(update);
    notifyWaiters();
  } catch (err) {
    console.error("Failed to parse stdin line as JSON:", err);
  }
});

const requestedPort = parseInt(process.env.FX_TELEGRAM_FAKE_PORT || "0", 10);

function logEvent(event: object) {
  process.stdout.write(JSON.stringify(event) + "\n");
}

const server = Bun.serve({
  port: requestedPort,
  async fetch(req) {
    const url = new URL(req.url);
    const parts = url.pathname.split("/").filter(Boolean);
    const method = parts.length > 0 ? parts[parts.length - 1] : "";

    let body: Record<string, unknown> = {};
    if (req.method === "POST") {
      try {
        body = (await req.json()) as Record<string, unknown>;
      } catch {}
    }

    // Log API call as JSON line
    logEvent({
      type: "api_call",
      method,
      body,
    });

    if (method === "getMe") {
      return Response.json({
        ok: true,
        result: {
          id: 123456789,
          is_bot: true,
          first_name: "AfxTestBot",
          username: "afx_test_bot",
        },
      });
    }

    if (method === "getUpdates") {
      const offset = typeof body.offset === "number" ? body.offset : 0;
      const timeoutSec = typeof body.timeout === "number" ? body.timeout : 25;

      const matching = queuedUpdates.filter((u) => u.update_id >= offset);
      if (matching.length > 0) {
        return Response.json({
          ok: true,
          result: matching,
        });
      }

      const { promise, resolve } = Promise.withResolvers<TelegramUpdate[]>();
      const timer = setTimeout(() => {
        const idx = activeWaiters.findIndex((w) => w.timer === timer);
        if (idx !== -1) activeWaiters.splice(idx, 1);
        resolve([]);
      }, Math.min(timeoutSec * 1000, 30000));

      activeWaiters.push({ offset, resolve, timer });
      const updates = await promise;

      return Response.json({
        ok: true,
        result: updates,
      });
    }

    if (method === "sendMessage") {
      const text = typeof body.text === "string" ? body.text : "";
      const parseMode = typeof body.parse_mode === "string" ? body.parse_mode : undefined;

      if ((text.includes("[[BADMD]]") || text.includes("BADMD")) && parseMode === "MarkdownV2") {
        return Response.json(
          {
            ok: false,
            error_code: 400,
            description: "Bad Request: can't parse entities: Character '[' is reserved and must be escaped",
          },
          { status: 400, headers: { "Connection": "close" } },
        );
      }

      msgCounter++;
      return Response.json({
        ok: true,
        result: {
          message_id: msgCounter,
          chat: { id: body.chat_id },
          message_thread_id: body.message_thread_id,
          text: body.text,
          date: Math.floor(Date.now() / 1000),
        },
      });
    }

    if (method === "editMessageText") {
      const text = typeof body.text === "string" ? body.text : "";
      return Response.json({
        ok: true,
        result: {
          message_id: body.message_id,
          chat: { id: body.chat_id },
          text: text,
        },
      });
    }

    if (method === "sendChatAction") {
      return Response.json({
        ok: true,
        result: true,
      });
    }

    if (method === "answerCallbackQuery") {
      return Response.json({
        ok: true,
        result: true,
      });
    }

    return Response.json(
      {
        ok: false,
        error_code: 404,
        description: `Method ${method} not found`,
      },
      { status: 404 },
    );
  },
});

console.log(`PORT ${server.port}`);
