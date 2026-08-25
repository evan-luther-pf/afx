import json, sys
seq = 1

def read():
    length = None
    while True:
        line = sys.stdin.buffer.readline()
        if not line:
            return None
        line = line.strip()
        if not line:
            break
        if line.lower().startswith(b"content-length:"):
            length = int(line.split(b":", 1)[1])
    return json.loads(sys.stdin.buffer.read(length))

def send(value):
    global seq
    value.setdefault("seq", seq)
    seq += 1
    data = json.dumps(value, separators=(",", ":")).encode()
    sys.stdout.buffer.write(f"Content-Length: {len(data)}\r\n\r\n".encode() + data)
    sys.stdout.buffer.flush()

def respond(request, body=None):
    send({"type": "response", "request_seq": request["seq"], "success": True, "command": request["command"], "body": body or {}})

while True:
    request = read()
    if request is None:
        break
    command = request.get("command")
    if command == "initialize":
        respond(request, {"supportsConfigurationDoneRequest": True})
    elif command == "launch":
        send({"type": "event", "event": "initialized"})
        configuration = read()
        respond(configuration)
        respond(request)
    elif command == "threads":
        respond(request, {"threads": [{"id": 1, "name": "main"}]})
    elif command == "disconnect":
        respond(request)
        break
    else:
        respond(request)
