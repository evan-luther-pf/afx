// Fake Slack Web API + Socket Mode server for end-to-end integration tests.
// Uses Bun.serve to host HTTP endpoints and WebSocket connection.
// Prints `PORTS <http> <ws>` to stdout on startup.

import { createInterface } from "readline";
import type { ServerWebSocket } from "bun";

let msgCounter = 0;
const activeSockets = new Set<ServerWebSocket<unknown>>();
const pendingEnvelopes: string[] = [];

const requestedHttpPort = parseInt(process.env.FX_SLACK_FAKE_HTTP || "0", 10);
const requestedWsPort = parseInt(process.env.FX_SLACK_FAKE_WS || "0", 10);

const wsServer = Bun.serve({
  port: requestedWsPort,
  fetch(req, server) {
    if (server.upgrade(req)) {
      return undefined;
    }
    return new Response("WebSocket endpoint", { status: 404 });
  },
  websocket: {
    open(ws) {
      activeSockets.add(ws);
      console.log(JSON.stringify({ type: "ws_connected", active_clients: activeSockets.size }));
      // Socket Mode hello envelope
      ws.send(JSON.stringify({ type: "hello", num_connections: activeSockets.size }));

      // Flush any envelopes that arrived on stdin before connection was open
      while (pendingEnvelopes.length > 0) {
        const env = pendingEnvelopes.shift();
        if (env) {
          ws.send(env);
        }
      }
    },
    message(ws, message) {
      const text = typeof message === "string" ? message : Buffer.from(message).toString("utf-8");
      try {
        const parsed: unknown = JSON.parse(text);
        console.log(JSON.stringify({ type: "ws_message", payload: parsed }));
      } catch {
        console.log(JSON.stringify({ type: "ws_raw_message", payload: text }));
      }
    },
    close(ws) {
      activeSockets.delete(ws);
      console.log(JSON.stringify({ type: "ws_disconnected", active_clients: activeSockets.size }));
    },
  },
});

interface SlackRequestBody {
  channel?: string;
  ts?: string;
  text?: string;
  thread_ts?: string;
  blocks?: unknown;
}

const httpServer = Bun.serve({
  port: requestedHttpPort,
  async fetch(req) {
    const url = new URL(req.url);
    const path = url.pathname.replace(/^\/api\//, "/").replace(/^\//, "");

    const authHeader = req.headers.get("authorization") || "";

    let body: SlackRequestBody | null = null;
    if (req.method === "POST") {
      const text = await req.text();
      if (text.length > 0) {
        try {
          body = JSON.parse(text) as SlackRequestBody;
        } catch {
          body = null;
        }
      }
    }

    // Rate-limiting simulation if requested
    if (url.searchParams.get("simulate_429") === "1" || req.headers.get("x-simulate-429") === "1") {
      console.log(JSON.stringify({ type: "api_call", method: path, status: 429 }));
      return new Response(JSON.stringify({ ok: false, error: "ratelimited" }), {
        status: 429,
        headers: {
          "content-type": "application/json",
          "retry-after": "1",
        },
      });
    }

    if (path === "auth.test") {
      console.log(JSON.stringify({ type: "api_call", method: "auth.test", auth: authHeader }));
      return Response.json({
        ok: true,
        url: "https://fake.slack.com/",
        team: "FakeWorkspace",
        user: "afx_bot",
        team_id: "T012345",
        user_id: "UBOT123",
        bot_id: "B012345",
      });
    }

    if (path === "apps.connections.open") {
      console.log(JSON.stringify({ type: "api_call", method: "apps.connections.open", auth: authHeader }));
      return Response.json({
        ok: true,
        url: `ws://127.0.0.1:${wsServer.port}/link`,
      });
    }

    if (path === "chat.postMessage") {
      msgCounter++;
      const ts = `1700000000.${String(msgCounter).padStart(6, "0")}`;
      console.log(JSON.stringify({ type: "api_call", method: "chat.postMessage", body, ts }));
      return Response.json({
        ok: true,
        channel: body?.channel || "C12345",
        ts,
        message: {
          text: body?.text,
          user: "UBOT123",
          ts,
        },
      });
    }

    if (path === "chat.update") {
      console.log(JSON.stringify({ type: "api_call", method: "chat.update", body }));
      return Response.json({
        ok: true,
        channel: body?.channel,
        ts: body?.ts,
        text: body?.text,
      });
    }

    if (path === "conversations.info") {
      const channel = body?.channel || url.searchParams.get("channel") || "C12345";
      const isIm = channel.startsWith("D");
      console.log(JSON.stringify({ type: "api_call", method: "conversations.info", channel, is_im: isIm }));
      return Response.json({
        ok: true,
        channel: {
          id: channel,
          name: isIm ? "directmessage" : "general",
          is_channel: !isIm,
          is_group: false,
          is_im: isIm,
          is_mpim: false,
        },
      });
    }

    console.log(JSON.stringify({ type: "api_call_unknown", method: path, body }));
    return Response.json({ ok: false, error: "unknown_method" }, { status: 404 });
  },
});

// Read JSON lines from stdin and broadcast to connected WebSocket clients as envelopes
const rl = createInterface({
  input: process.stdin,
  crlfDelay: Infinity,
});

rl.on("line", (line) => {
  const trimmed = line.trim();
  if (!trimmed) return;
  if (activeSockets.size === 0) {
    pendingEnvelopes.push(trimmed);
  } else {
    for (const ws of activeSockets) {
      ws.send(trimmed);
    }
  }
});

// Print PORTS output as expected
console.log(`PORTS ${httpServer.port} ${wsServer.port}`);
