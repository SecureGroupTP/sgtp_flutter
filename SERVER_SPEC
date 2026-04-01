# SGTP Server Spec (Transport Discovery + Multi-Transport)

This document specifies how the server advertises available transports and how a client selects and connects.

The SGTP **protocol frames** (payload bytes) are identical for all transports. Only the **transport** changes.

## 1. Terminology

- **Discovery port**: a single TCP port configured in the client settings. The client uses it to obtain the server’s available transport options + per-option ports.
- **Transport port**: a port dedicated to a specific transport option (e.g. TCP+TLS, WebSocket, HTTPS, etc).
- **Option**: one of the 6 transport variants below:
  1) `TCP`
  2) `TCP + TLS`
  3) `HTTP`
  4) `HTTP + TLS`
  5) `WebSocket`
  6) `WebSocket + TLS`

## 2. Discovery (capabilities) response

When a client connects to the **discovery port** over **plain TCP**, the server returns exactly **25 bytes** and then closes the connection.

### 2.1 Layout (25 bytes)

```
Byte 0: Flags bitfield
Bytes 1..24: 6 ports (uint32, big-endian), in fixed order
```

### 2.2 Flags (byte 0)

Bit index | Meaning
---|---
0 | TCP available
1 | TCP + TLS available
2 | HTTP available
3 | HTTP + TLS available
4 | WebSocket available
5 | WebSocket + TLS available
6..7 | Reserved (must be 0 for now)

### 2.3 Ports (bytes 1..24)

Ports are encoded as **unsigned 32-bit big-endian** integers (network byte order). Each must be either `0` (unused) or a valid TCP port `1..65535`.

Order (each is 4 bytes):

Index | Bytes | Meaning
---|---|---
0 | 1..4 | TCP port
1 | 5..8 | TCP + TLS port
2 | 9..12 | HTTP port
3 | 13..16 | HTTP + TLS port
4 | 17..20 | WebSocket port
5 | 21..24 | WebSocket + TLS port

## 3. Transport behavior

### 3.1 TCP / TCP+TLS

- After connecting to the selected port, the client sends/receives raw SGTP frames over the stream.
- For `TCP+TLS`, the TCP stream is wrapped in TLS (server presents a TLS certificate).

### 3.2 WebSocket / WebSocket+TLS

- The server exposes a WebSocket endpoint on the selected port.
- Each WebSocket message must be **binary** and contain one or more concatenated SGTP frames.
- For `WebSocket+TLS`, the endpoint uses `wss://`.

### 3.3 HTTP / HTTP+TLS (SGTP-over-HTTP)

Because HTTP is request/response, the transport is defined as a small session protocol:

1) **Create session**
   - Request: `POST /sgtp/session`
   - Response:
     - `200 OK`
     - Body: **16 raw bytes** session id (`sid`)

2) **Send frames**
   - Request: `POST /sgtp/send?sid=<hex32>`
   - Body: raw SGTP frame bytes (may include multiple concatenated frames)
   - Response: `204 No Content`

3) **Receive frames (stream/long-poll)**
   - Request: `GET /sgtp/recv?sid=<hex32>`
   - Response: `200 OK`
   - Body: a stream of raw bytes containing concatenated SGTP frames.
   - The server may close the connection at any time; the client reconnects.

4) **Close session (best-effort)**
   - Request: `DELETE /sgtp/session?sid=<hex32>`
   - Response: `204 No Content` (or `200 OK`)

Notes:
- The server should set reasonable timeouts for `/sgtp/recv` (e.g. 30–120 seconds) and allow reconnect.
- `HTTP+TLS` uses the same endpoints over HTTPS.

## 4. Backward compatibility

If a server does not implement discovery, clients that require it will fail fast.
To support legacy clients, run the old raw-TCP SGTP server on a separate port and advertise it via discovery as `TCP`.

