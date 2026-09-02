// Bun WebSocket echo server fixture for ws_client integration testing.
// Listens on FX_WS_ECHO_PORT or argv[2] or an ephemeral port.
// Prints PORT:<port> to stdout once listening.

const requestedPort = parseInt(
  process.env.FX_WS_ECHO_PORT || process.argv[2] || "0",
  10
);

const server = Bun.serve({
  port: requestedPort,
  fetch(req, srv) {
    const upgraded = srv.upgrade(req);
    if (upgraded) return undefined;
    return new Response("WebSocket echo fixture", { status: 200 });
  },
  websocket: {
    message(ws, message) {
      if (typeof message === "string") {
        if (message === "close") {
          ws.close(1000, "normal closure");
          return;
        }
        if (message === "ping") {
          ws.ping();
          return;
        }
      }
      ws.send(message);
    },
    open(ws) {
      // client connected
    },
    close(ws, code, message) {
      // client disconnected
    },
  },
});

console.log(`PORT:${server.port}`);
