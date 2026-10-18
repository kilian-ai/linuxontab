// Inbound port forwarding: a host TCP listener whose connections are opened
// inside the guest as if they came from the network (docker -p semantics).
//
// WispSlirp.injectConnect(guestPort, socket) is how the browser tab's tunnel
// does this: it takes a WebSocket-like object, sends the guest a SYN from a
// fake external address, and from then on
//   client bytes -> socket.onmessage({ data })  -> guest
//   guest bytes  -> socket.send(ArrayBuffer)    -> client
//   guest FIN    -> socket.close()
// plus "__pause__" / "__resume__" strings on send() when the guest falls
// behind, which here pause and resume the host socket.
import net from "node:net";

/** Parses "[ip:]hostPort:guestPort". */
export function parsePublish(spec) {
  const parts = spec.split(":");
  if (parts.length < 2 || parts.length > 3) throw new Error(`bad --publish "${spec}" (want [ip:]hostPort:guestPort)`);
  const [host, hostPort, guestPort] = parts.length === 3 ? parts : ["127.0.0.1", ...parts];
  const hp = +hostPort, gp = +guestPort;
  if (!(hp >= 0 && hp < 65536 && gp > 0 && gp < 65536)) throw new Error(`bad port in --publish "${spec}"`);
  return { host: host || "0.0.0.0", hostPort: hp, guestPort: gp };
}

function inboundSocket(sock) {
  const ws = {
    binaryType: "arraybuffer",
    readyState: 1,
    onmessage: null,
    onclose: null,
    send(data) {
      if (typeof data === "string") {
        if (data === "__pause__") sock.pause();
        else if (data === "__resume__") sock.resume();
        return;
      }
      if (ws.readyState !== 1) return;
      sock.write(new Uint8Array(data instanceof ArrayBuffer ? data : data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength)));
    },
    // The guest closed its side: finish sending, then hang up.
    close() {
      if (ws.readyState >= 2) return;
      ws.readyState = 2;
      sock.end();
      setTimeout(() => sock.destroy(), 60_000).unref();
    },
  };
  sock.on("data", (b) => {
    // Each chunk as its own ArrayBuffer: the slirp keeps references.
    if (ws.onmessage) ws.onmessage({ data: b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength) });
  });
  // The page's injected connections end with a reset when the client goes
  // away, so only a full close is passed on. A client half-close ('end') is
  // left alone: the guest may still be answering (allowHalfOpen).
  sock.on("close", () => {
    const wasOpen = ws.readyState < 3;
    ws.readyState = 3;
    if (wasOpen && ws.onclose) ws.onclose({ type: "close" });
  });
  sock.on("error", () => {});
  return ws;
}

/** Listens on host:hostPort and forwards each connection to the guest's guestPort. */
export function publishPort(slirp, { host, hostPort, guestPort }, log = () => {}) {
  const server = net.createServer({ allowHalfOpen: true }, (sock) => {
    sock.setNoDelay(true);
    log(`[publish] ${sock.remoteAddress}:${sock.remotePort} -> guest :${guestPort}`);
    slirp.injectConnect(guestPort, inboundSocket(sock));
  });
  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(hostPort, host, () => {
      server.off("error", reject);
      resolve(server);
    });
  });
}
