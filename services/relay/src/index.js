import { connect } from 'cloudflare:sockets';

/**
 * traits.build relay — Cloudflare Worker + Durable Objects
 *
 * One RelaySession DO per pairing code. The DO holds all in-flight state
 * in memory, so long-poll coordination is instant and zero-latency.
 *
 * Routes:
 *   GET  /health
 *   POST /relay/register      → { code }
 *   POST /relay/connect       { code } → { token, code }   (HMAC-signed token)
 *   GET  /relay/poll?code=    → {id, path, args} when a call arrives, 204 on timeout
 *   POST /relay/call          { code|token, path, args } → { result, error }
 *   POST /relay/respond       { code, id, result }
 *   GET  /relay/status?code=  → { active, age_seconds, code }
 *   GET  /relay/status?token= → same, validated from signed token
 *
 * Signed tokens (requires RELAY_SECRET worker secret):
 *   After a client enters the 4-char pairing code, call /relay/connect to get a
 *   HMAC-SHA256 signed token { code, relay, iat, exp }. The token is stateless —
 *   the relay verifies its signature without any persistent store. Clients save the
 *   token in localStorage and use it for all future status checks and calls without
 *   re-entering the pairing code.
 *
 *   Setup:  npx wrangler secret put RELAY_SECRET
 *           (generate with: openssl rand -base64 32)
 */

// ── HMAC-SHA256 token signing (Web Crypto) ────────────────────────────────────

async function _getHmacKey(secret) {
  return crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign', 'verify'],
  );
}

const TOKEN_TTL_SECS = 86400 * 30; // 30 days

async function signToken(code, relayOrigin, secret) {
  const payload = {
    code,
    relay: relayOrigin,
    iat: Math.floor(Date.now() / 1000),
    exp: Math.floor(Date.now() / 1000) + TOKEN_TTL_SECS,
  };
  const payloadBytes = new TextEncoder().encode(JSON.stringify(payload));
  const key = await _getHmacKey(secret);
  const sig = await crypto.subtle.sign('HMAC', key, payloadBytes);
  const payloadB64 = btoa(JSON.stringify(payload));
  const sigB64 = btoa(String.fromCharCode(...new Uint8Array(sig)));
  return `${payloadB64}.${sigB64}`;
}

async function verifyToken(token, secret) {
  try {
    const dot = token.lastIndexOf('.');
    if (dot === -1) return null;
    const payloadB64 = token.slice(0, dot);
    const sigB64    = token.slice(dot + 1);
    const payload   = JSON.parse(atob(payloadB64));
    // Check expiry client-side before hitting crypto
    if (!payload.exp || Date.now() / 1000 > payload.exp) return null;
    const key       = await _getHmacKey(secret);
    const sigBytes  = Uint8Array.from(atob(sigB64), c => c.charCodeAt(0));
    const dataBytes = new TextEncoder().encode(JSON.stringify(payload));
    const valid     = await crypto.subtle.verify('HMAC', key, sigBytes, dataBytes);
    return valid ? payload : null;
  } catch(_) { return null; }
}

// ── CORS ─────────────────────────────────────────────────────────────────────

function cors() {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "GET,POST,PUT,DELETE,PATCH,OPTIONS",
    "Access-Control-Allow-Headers": "*",
  };
}

function json(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json", ...cors() },
  });
}

// ── Tunnel instrumentation (best-effort, isolate-local) ─────────────────────

const RELAY_BUILD = '2026-04-22-wisp-sockets';
const TUNNEL_EVENT_LIMIT = 200;

const tunnelStats = {
  boot_iso: new Date().toISOString(),
  open_requests: 0,
  open_accepted: 0,
  upgrade_rejected: 0,
  active_connections: 0,
  closes: 0,
  errors: 0,
  message_events: 0,
  text_pings: 0,
  binary_packets: 0,
  parse_dropped: 0,
  icmp_packets: 0,
  udp_packets: 0,
  dns_queries: 0,
  dns_replies: 0,
  dns_failures: 0,
  dhcp_discovers: 0,
  dhcp_requests: 0,
  dhcp_offers: 0,
  dhcp_acks: 0,
  tcp_resets: 0,
  arp_requests: 0,
  arp_replies: 0,
  eth_frames: 0,
  raw_ip_packets: 0,
  ntp_replies: 0,
};

const tunnelConnections = new Map(); // connId -> { started, bytes_rx, packets_rx, colo }
const tunnelEvents = [];

function safeError(err) {
  const e = err || {};
  const stack = String(e.stack || '').split('\n').slice(0, 3).join(' | ');
  return {
    name: String(e.name || 'Error'),
    message: String(e.message || e || 'unknown error'),
    stack,
  };
}

function logTunnelEvent(type, fields = {}) {
  const evt = { ts: new Date().toISOString(), type, ...fields };
  tunnelEvents.push(evt);
  if (tunnelEvents.length > TUNNEL_EVENT_LIMIT) tunnelEvents.shift();
  try {
    console.log('[linux-tunnel]', JSON.stringify(evt));
  } catch (_) {
    console.log('[linux-tunnel]', type);
  }
}

function tunnelDebugSnapshot() {
  return {
    relay_build: RELAY_BUILD,
    stats: { ...tunnelStats, active_connections: tunnelConnections.size },
    active: Array.from(tunnelConnections.entries()).map(([id, c]) => ({
      id,
      started: c.started,
      age_ms: Date.now() - c.started,
      bytes_rx: c.bytes_rx,
      packets_rx: c.packets_rx,
      colo: c.colo,
      ua: c.ua,
    })),
    recent_events: tunnelEvents.slice(-40),
  };
}

// ── Linux tunnel helpers (Ethernet frames + raw IPv4 packets over WebSocket) ─

// ── v86 default network config ──
// When no overrides, v86 uses these for its SLIRP-style user-mode networking:
const V86_ROUTER_MAC = [0x52, 0x54, 0x00, 0x01, 0x02, 0x03]; // 52:54:00:01:02:03
const V86_ROUTER_IP  = [192, 168, 86, 1];
const V86_VM_IP      = [192, 168, 86, 100];
const V86_SUBNET     = [255, 255, 255, 0];
const V86_DNS_IP     = V86_ROUTER_IP; // v86 uses router as DNS (we do DoH behind the scenes)

// ── www.linux default network config ──
const LINUX_GUEST_IP  = [10, 0, 2, 15];
const LINUX_SERVER_IP = [10, 0, 2, 2];
const LINUX_DNS_IP    = [1, 1, 1, 1];
const LINUX_SUBNET    = [255, 255, 255, 0];
const LINUX_UPSTREAM_TUNNEL_URL = 'https://apptron.dev/x/net';

const DHCP_LEASE_SECS = 86400;
const DHCP_MAGIC      = [99, 130, 83, 99];

function _checksum(bytes) {
  let sum = 0;
  for (let i = 0; i < bytes.length; i += 2) {
    sum += ((bytes[i] << 8) | (bytes[i + 1] || 0));
  }
  while (sum >> 16) sum = (sum & 0xffff) + (sum >> 16);
  return (~sum) & 0xffff;
}

// ── Auto-detect frame type ──
// Returns 'ethernet' if bytes look like an Ethernet frame, 'ipv4' for raw IP.
function _detectFrameType(bytes) {
  if (bytes.length < 20) return 'unknown';
  // Check if byte 0 upper nibble = 4 → raw IPv4
  if ((bytes[0] >> 4) === 4) return 'ipv4';
  // Otherwise, check EtherType at bytes 12-13
  if (bytes.length >= 14) {
    const etherType = (bytes[12] << 8) | bytes[13];
    if (etherType === 0x0800 || etherType === 0x0806 || etherType === 0x86DD) return 'ethernet';
  }
  // Fallback: if first byte is 0xFF (broadcast MAC) or 0x52 (v86 router MAC prefix), likely Ethernet
  if (bytes[0] === 0xFF || bytes[0] === 0x52) return 'ethernet';
  return 'unknown';
}

// ── Ethernet frame parsing/encoding ──

function _parseEthFrame(bytes) {
  if (bytes.length < 14) return null;
  const destMac = bytes.slice(0, 6);
  const srcMac = bytes.slice(6, 12);
  const etherType = (bytes[12] << 8) | bytes[13];
  const payload = bytes.slice(14);
  return { destMac, srcMac, etherType, payload };
}

function _buildEthFrame(destMac, srcMac, etherType, payload) {
  const frame = new Uint8Array(14 + payload.length);
  frame.set(destMac, 0);
  frame.set(srcMac, 6);
  frame[12] = (etherType >> 8) & 0xff;
  frame[13] = etherType & 0xff;
  frame.set(payload, 14);
  return frame;
}

// ── ARP handling ──

function _parseArp(payload) {
  if (payload.length < 28) return null;
  const htype = (payload[0] << 8) | payload[1];
  const ptype = (payload[2] << 8) | payload[3];
  const hlen = payload[4];
  const plen = payload[5];
  const oper = (payload[6] << 8) | payload[7];
  const sha = payload.slice(8, 8 + hlen);
  const spa = payload.slice(8 + hlen, 8 + hlen + plen);
  const tha = payload.slice(8 + hlen + plen, 8 + 2 * hlen + plen);
  const tpa = payload.slice(8 + 2 * hlen + plen, 8 + 2 * hlen + 2 * plen);
  return { htype, ptype, oper, sha, spa, tha, tpa };
}

function _buildArpReply(request, routerMac) {
  // Build ARP reply: "I am the target IP, here is my MAC"
  const payload = new Uint8Array(28);
  payload[0] = 0; payload[1] = 1;   // htype = Ethernet
  payload[2] = 0x08; payload[3] = 0; // ptype = IPv4
  payload[4] = 6;                     // hlen = 6 (MAC)
  payload[5] = 4;                     // plen = 4 (IPv4)
  payload[6] = 0; payload[7] = 2;    // oper = Reply
  payload.set(routerMac, 8);          // sha = our MAC
  payload.set(request.tpa, 14);       // spa = requested IP (we claim to own it)
  payload.set(request.sha, 18);       // tha = requester's MAC
  payload.set(request.spa, 24);       // tpa = requester's IP
  return payload;
}

// ── IPv4 parsing/encoding ──

function _parseIpPacket(buf) {
  if (!(buf instanceof Uint8Array) || buf.length < 20) return null;
  const version = (buf[0] >> 4) & 0xf;
  if (version !== 4) return null;
  const ihl = (buf[0] & 0xf) * 4;
  const totalLen = (buf[2] << 8) | buf[3];
  if (ihl < 20 || totalLen < ihl || totalLen > buf.length) return null;
  const protocol = buf[9];
  const srcIp = [buf[12], buf[13], buf[14], buf[15]];
  const dstIp = [buf[16], buf[17], buf[18], buf[19]];
  const id = (buf[4] << 8) | buf[5];
  const payload = buf.slice(ihl, totalLen);
  return { protocol, srcIp, dstIp, id, payload };
}

function _buildIpPacket(protocol, srcIp, dstIp, payload, id = 0) {
  const totalLen = 20 + payload.length;
  const pkt = new Uint8Array(totalLen);
  pkt[0] = 0x45;
  pkt[1] = 0;
  pkt[2] = (totalLen >> 8) & 0xff;
  pkt[3] = totalLen & 0xff;
  pkt[4] = (id >> 8) & 0xff;
  pkt[5] = id & 0xff;
  pkt[6] = 0x40;
  pkt[7] = 0;
  pkt[8] = 64;
  pkt[9] = protocol;
  pkt[12] = srcIp[0]; pkt[13] = srcIp[1]; pkt[14] = srcIp[2]; pkt[15] = srcIp[3];
  pkt[16] = dstIp[0]; pkt[17] = dstIp[1]; pkt[18] = dstIp[2]; pkt[19] = dstIp[3];
  const cksum = _checksum(pkt.slice(0, 20));
  pkt[10] = (cksum >> 8) & 0xff;
  pkt[11] = cksum & 0xff;
  pkt.set(payload, 20);
  return pkt;
}

// ── UDP ──

function _parseUdp(payload) {
  if (payload.length < 8) return null;
  const srcPort = (payload[0] << 8) | payload[1];
  const dstPort = (payload[2] << 8) | payload[3];
  const length = (payload[4] << 8) | payload[5];
  if (length < 8 || length > payload.length) return null;
  const data = payload.slice(8, length);
  return { srcPort, dstPort, data };
}

function _buildUdp(srcPort, dstPort, data) {
  const len = 8 + data.length;
  const udp = new Uint8Array(len);
  udp[0] = (srcPort >> 8) & 0xff;
  udp[1] = srcPort & 0xff;
  udp[2] = (dstPort >> 8) & 0xff;
  udp[3] = dstPort & 0xff;
  udp[4] = (len >> 8) & 0xff;
  udp[5] = len & 0xff;
  udp[6] = 0;
  udp[7] = 0;
  udp.set(data, 8);
  return udp;
}

// ── ICMP ──

function _handleIcmpEcho(ipPkt) {
  const p = ipPkt.payload;
  if (p.length < 8 || p[0] !== 8) return null;
  const reply = new Uint8Array(p);
  reply[0] = 0;
  reply[2] = 0;
  reply[3] = 0;
  const cksum = _checksum(reply);
  reply[2] = (cksum >> 8) & 0xff;
  reply[3] = cksum & 0xff;
  return _buildIpPacket(1, ipPkt.dstIp, ipPkt.srcIp, reply, ipPkt.id);
}

// ── NTP ──

function _handleNtp(ipPkt, udp) {
  if (udp.data.length < 48) return null;
  const now = Date.now();
  // NTP epoch: 1900-01-01 vs Unix epoch: 1970-01-01 = 2208988800 seconds
  const NTP_EPOCH_OFFSET = 2208988800;
  const ntpSecs = Math.floor(now / 1000) + NTP_EPOCH_OFFSET;
  const ntpFrac = Math.floor((now % 1000) / 1000 * 0x100000000);

  const reply = new Uint8Array(48);
  const view = new DataView(reply.buffer);
  // LI=0, VN=4, Mode=4(server) → 0x24
  view.setUint8(0, 0x24);
  view.setUint8(1, 2);       // stratum 2
  view.setUint8(2, 10);      // poll interval
  view.setInt8(3, -20);      // precision
  // root delay/dispersion = 0
  // reference ID = 0
  // reference timestamp = now
  view.setUint32(16, ntpSecs);
  view.setUint32(20, ntpFrac);
  // origin timestamp = client's transmit timestamp
  const clientData = udp.data;
  reply.set(clientData.slice(40, 48), 24); // ori = client's xmit
  // receive timestamp = now
  view.setUint32(32, ntpSecs);
  view.setUint32(36, ntpFrac);
  // transmit timestamp = now
  view.setUint32(40, ntpSecs);
  view.setUint32(44, ntpFrac);

  const udpReply = _buildUdp(123, udp.srcPort, reply);
  return _buildIpPacket(17, ipPkt.dstIp, ipPkt.srcIp, udpReply, ipPkt.id);
}

// ── DHCP ──

function _handleDhcpUdp(ipPkt, udp, netCfg) {
  const data = udp.data;
  if (data.length < 241) return null;
  if (data[0] !== 1) return null;
  if (data[236] !== 99 || data[237] !== 130 || data[238] !== 83 || data[239] !== 99) return null;

  const xid = data.slice(4, 8);
  const chaddr = data.slice(28, 44); // full 16 bytes for chaddr field

  let msgType = 0;
  let i = 240;
  while (i < data.length) {
    const opt = data[i];
    if (opt === 255) break;
    if (opt === 0) { i++; continue; }
    const len = data[i + 1] || 0;
    if (opt === 53 && len >= 1) msgType = data[i + 2];
    i += 2 + len;
  }

  let replyType;
  if (msgType === 1) { tunnelStats.dhcp_discovers += 1; replyType = 2; }
  else if (msgType === 3) { tunnelStats.dhcp_requests += 1; replyType = 5; }
  else return null;

  const reply = new Uint8Array(300);
  reply[0] = 2; // BOOTREPLY
  reply[1] = 1; // htype Ethernet
  reply[2] = 6; // hlen
  reply[3] = 0; // hops
  reply.set(xid, 4);
  // flags
  reply[10] = 0x80; reply[11] = 0x00; // broadcast bit set
  reply.set(netCfg.guestIp, 16);  // yiaddr
  reply.set(netCfg.serverIp, 20); // siaddr
  reply.set(netCfg.serverIp, 24); // giaddr
  reply.set(chaddr, 28);          // chaddr (16 bytes)
  reply.set(DHCP_MAGIC, 236);

  let p = 240;
  const opt = (type, ...bytes) => {
    reply[p++] = type;
    reply[p++] = bytes.length;
    for (const b of bytes) reply[p++] = b;
  };
  opt(53, replyType);
  opt(54, ...netCfg.serverIp);
  if (replyType === 5) {
    opt(51, (DHCP_LEASE_SECS >> 24) & 0xff,
            (DHCP_LEASE_SECS >> 16) & 0xff,
            (DHCP_LEASE_SECS >>  8) & 0xff,
             DHCP_LEASE_SECS        & 0xff);
  }
  opt(1,  ...netCfg.subnet);
  opt(3,  ...netCfg.serverIp); // Router/gateway
  opt(6,  ...netCfg.dnsIp);   // DNS
  // v86 vendor class: "v86" = [118, 56, 54]
  opt(60, 118, 56, 54);
  reply[p++] = 255; // End

  const dhcpPayload = reply.slice(0, p);
  const udpReply = _buildUdp(67, 68, dhcpPayload);

  if (replyType === 2) tunnelStats.dhcp_offers += 1;
  else tunnelStats.dhcp_acks += 1;

  return _buildIpPacket(17, netCfg.serverIp, [255, 255, 255, 255], udpReply, 0);
}

// ── DNS ──

async function _handleDnsUdp(ipPkt, udp) {
  if (!udp || udp.dstPort !== 53 || udp.data.length === 0) return null;
  try {
    const resp = await fetch('https://cloudflare-dns.com/dns-query', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/dns-message',
        'Accept': 'application/dns-message',
      },
      body: udp.data,
    });
    if (!resp.ok) return null;
    const dns = new Uint8Array(await resp.arrayBuffer());
    const udpReply = _buildUdp(53, udp.srcPort, dns);
    return _buildIpPacket(17, ipPkt.dstIp, ipPkt.srcIp, udpReply, ipPkt.id);
  } catch (_) {
    return null;
  }
}

// ── TCP RST ──

function _handleTcpRst(ipPkt) {
  const p = ipPkt.payload;
  if (p.length < 20) return null;
  const srcPort = (p[0] << 8) | p[1];
  const dstPort = (p[2] << 8) | p[3];
  const seqNum = (p[4] << 24) | (p[5] << 16) | (p[6] << 8) | p[7];
  const flags = p[13];
  const isSyn = (flags & 0x02) !== 0;
  const isRst = (flags & 0x04) !== 0;
  if (!isSyn || isRst) return null;
  const rst = new Uint8Array(20);
  rst[0] = (dstPort >> 8) & 0xff; rst[1] = dstPort & 0xff;
  rst[2] = (srcPort >> 8) & 0xff; rst[3] = srcPort & 0xff;
  const ackNum = seqNum + 1;
  rst[8]  = (ackNum >> 24) & 0xff;
  rst[9]  = (ackNum >> 16) & 0xff;
  rst[10] = (ackNum >>  8) & 0xff;
  rst[11] = ackNum & 0xff;
  rst[12] = 0x50;
  rst[13] = 0x14; // RST + ACK
  return _buildIpPacket(6, ipPkt.dstIp, ipPkt.srcIp, rst, ipPkt.id);
}

// ── Unified packet handler (supports both Ethernet frames and raw IP) ──

function _handlePacket(bytes, connState, sendFn) {
  const frameType = connState.frameType || _detectFrameType(bytes);
  // Lock in the frame type for this connection after first packet
  if (!connState.frameType) connState.frameType = frameType;

  if (frameType === 'ethernet') {
    tunnelStats.eth_frames += 1;
    _handleEthernetFrame(bytes, connState, sendFn);
  } else if (frameType === 'ipv4') {
    tunnelStats.raw_ip_packets += 1;
    _handleRawIpPacket(bytes, connState, sendFn);
  } else {
    tunnelStats.parse_dropped += 1;
  }
}

function _handleEthernetFrame(bytes, connState, sendFn) {
  const eth = _parseEthFrame(bytes);
  if (!eth) { tunnelStats.parse_dropped += 1; return; }

  // Remember the VM's MAC from its first packet
  if (!connState.vmMac) connState.vmMac = Array.from(eth.srcMac);

  const routerMac = V86_ROUTER_MAC;
  const vmMac = connState.vmMac;

  // Network config for v86 Ethernet mode
  const netCfg = {
    serverIp: V86_ROUTER_IP,
    guestIp: V86_VM_IP,
    subnet: V86_SUBNET,
    dnsIp: V86_DNS_IP,
  };

  // Helper to wrap an IP packet in an Ethernet frame and send
  const sendEthIp = (ipPacket) => {
    const frame = _buildEthFrame(vmMac, routerMac, 0x0800, ipPacket);
    sendFn(frame);
  };

  // ARP (EtherType 0x0806)
  if (eth.etherType === 0x0806) {
    tunnelStats.arp_requests += 1;
    const arp = _parseArp(eth.payload);
    if (arp && arp.oper === 1 && arp.ptype === 0x0800) {
      // Respond to ARP request: we claim to own any IP in the subnet
      const replyPayload = _buildArpReply(arp, routerMac);
      const replyFrame = _buildEthFrame(vmMac, routerMac, 0x0806, replyPayload);
      tunnelStats.arp_replies += 1;
      sendFn(replyFrame);
    }
    return;
  }

  // IPv4 (EtherType 0x0800)
  if (eth.etherType === 0x0800) {
    const ipPkt = _parseIpPacket(eth.payload);
    if (!ipPkt) { tunnelStats.parse_dropped += 1; return; }

    // ICMP
    if (ipPkt.protocol === 1) {
      tunnelStats.icmp_packets += 1;
      const reply = _handleIcmpEcho(ipPkt);
      if (reply) sendEthIp(reply);
      return;
    }

    // TCP → RST
    if (ipPkt.protocol === 6) {
      tunnelStats.tcp_resets += 1;
      const rst = _handleTcpRst(ipPkt);
      if (rst) sendEthIp(rst);
      return;
    }

    // UDP
    if (ipPkt.protocol === 17) {
      tunnelStats.udp_packets += 1;
      const udpHdr = _parseUdp(ipPkt.payload);
      if (!udpHdr) return;

      // DHCP
      if (udpHdr.dstPort === 67) {
        const dhcpReply = _handleDhcpUdp(ipPkt, udpHdr, netCfg);
        if (dhcpReply) sendEthIp(dhcpReply);
        return;
      }

      // DNS
      if (udpHdr.dstPort === 53) {
        tunnelStats.dns_queries += 1;
        _handleDnsUdp(ipPkt, udpHdr)
          .then((reply) => {
            if (reply) { tunnelStats.dns_replies += 1; sendEthIp(reply); }
            else tunnelStats.dns_failures += 1;
          })
          .catch(() => { tunnelStats.dns_failures += 1; });
        return;
      }

      // NTP
      if (udpHdr.dstPort === 123) {
        tunnelStats.ntp_replies += 1;
        const ntpReply = _handleNtp(ipPkt, udpHdr);
        if (ntpReply) sendEthIp(ntpReply);
        return;
      }
    }
    return;
  }

  // IPv6 (0x86DD) — silently ignore
  if (eth.etherType === 0x86DD) return;

  tunnelStats.parse_dropped += 1;
}

function _handleRawIpPacket(bytes, connState, sendFn) {
  // Network config for www.linux raw-IP mode
  const netCfg = {
    serverIp: LINUX_SERVER_IP,
    guestIp: LINUX_GUEST_IP,
    subnet: LINUX_SUBNET,
    dnsIp: LINUX_DNS_IP,
  };

  const ipPkt = _parseIpPacket(bytes);
  if (!ipPkt) { tunnelStats.parse_dropped += 1; return; }

  if (ipPkt.protocol === 1) {
    tunnelStats.icmp_packets += 1;
    const reply = _handleIcmpEcho(ipPkt);
    if (reply) sendFn(reply);
    return;
  }

  if (ipPkt.protocol === 6) {
    tunnelStats.tcp_resets += 1;
    const rst = _handleTcpRst(ipPkt);
    if (rst) sendFn(rst);
    return;
  }

  if (ipPkt.protocol === 17) {
    tunnelStats.udp_packets += 1;
    const udpHdr = _parseUdp(ipPkt.payload);
    if (udpHdr && udpHdr.dstPort === 67) {
      const dhcpReply = _handleDhcpUdp(ipPkt, udpHdr, netCfg);
      if (dhcpReply) sendFn(dhcpReply);
      return;
    }
    if (udpHdr && udpHdr.dstPort === 53) {
      tunnelStats.dns_queries += 1;
      _handleDnsUdp(ipPkt, udpHdr)
        .then((reply) => {
          if (reply) { tunnelStats.dns_replies += 1; sendFn(reply); }
          else tunnelStats.dns_failures += 1;
        })
        .catch(() => { tunnelStats.dns_failures += 1; });
      return;
    }
    if (udpHdr && udpHdr.dstPort === 123) {
      tunnelStats.ntp_replies += 1;
      const ntpReply = _handleNtp(ipPkt, udpHdr);
      if (ntpReply) sendFn(ntpReply);
      return;
    }
  }
}

function _buildUpstreamTunnelHeaders(request) {
  const headers = new Headers();
  const pass = [
    'upgrade',
    'connection',
    'sec-websocket-key',
    'sec-websocket-version',
    'sec-websocket-protocol',
    'sec-websocket-extensions',
    'user-agent',
    'accept-language',
    'cache-control',
    'pragma',
  ];
  for (const name of pass) {
    const value = request.headers.get(name);
    if (value) headers.set(name, value);
  }
  // Keep origin pinned to apptron for upstream compatibility.
  headers.set('origin', 'https://apptron.dev');
  headers.set('referer', 'https://apptron.dev/');
  return headers;
}

function _safeCloseWs(ws, code = 1000, reason = '') {
  try {
    if (ws && ws.readyState === 1) ws.close(code, reason);
  } catch (_) {
  }
}

function _bridgeWebSockets(left, right, reqId) {
  const forward = (from, to, dir) => {
    from.addEventListener('message', (evt) => {
      try {
        to.send(evt.data);
      } catch (e) {
        tunnelStats.errors += 1;
        logTunnelEvent('proxy_forward_error', { req_id: reqId, dir, error: safeError(e) });
      }
    });
    from.addEventListener('close', (evt) => {
      _safeCloseWs(to, evt?.code || 1000, evt?.reason || '');
    });
    from.addEventListener('error', (evt) => {
      tunnelStats.errors += 1;
      logTunnelEvent('proxy_ws_error', { req_id: reqId, dir, error: safeError(evt) });
      _safeCloseWs(to, 1011, 'proxy_error');
    });
  };

  forward(left, right, 'client_to_upstream');
  forward(right, left, 'upstream_to_client');
}

async function _tryProxyLinuxTunnelWs(request, reqId) {
  tunnelStats.proxy_attempts = (tunnelStats.proxy_attempts || 0) + 1;
  const upstreamReq = new Request(LINUX_UPSTREAM_TUNNEL_URL, {
    method: 'GET',
    headers: _buildUpstreamTunnelHeaders(request),
  });

  let upstreamResp;
  try {
    upstreamResp = await Promise.race([
      fetch(upstreamReq),
      new Promise((_, reject) => setTimeout(() => reject(new Error('proxy connect timeout')), 1200)),
    ]);
  } catch (e) {
    tunnelStats.proxy_errors = (tunnelStats.proxy_errors || 0) + 1;
    logTunnelEvent('proxy_connect_error', { req_id: reqId, error: safeError(e) });
    return null;
  }

  if (upstreamResp.status !== 101 || !upstreamResp.webSocket) {
    tunnelStats.proxy_rejected = (tunnelStats.proxy_rejected || 0) + 1;
    logTunnelEvent('proxy_upgrade_rejected', {
      req_id: reqId,
      status: upstreamResp.status,
      status_text: String(upstreamResp.statusText || ''),
    });
    return null;
  }

  const pair = new WebSocketPair();
  const client = pair[0];
  const server = pair[1];
  const upstream = upstreamResp.webSocket;
  server.accept();
  upstream.accept();

  _bridgeWebSockets(server, upstream, reqId);

  tunnelStats.proxy_connected = (tunnelStats.proxy_connected || 0) + 1;
  logTunnelEvent('proxy_connected', { req_id: reqId, upstream: LINUX_UPSTREAM_TUNNEL_URL });
  return new Response(null, { status: 101, webSocket: client });
}

async function _linuxTunnelWsLocal(request, reqId, colo, ua) {

  const pair = new WebSocketPair();
  const client = pair[0];
  const server = pair[1];
  try {
    server.accept();
  } catch (e) {
    tunnelStats.errors += 1;
    logTunnelEvent('accept_error', { req_id: reqId, error: safeError(e) });
    throw e;
  }

  tunnelStats.open_accepted += 1;
  tunnelConnections.set(reqId, {
    started: Date.now(),
    bytes_rx: 0,
    packets_rx: 0,
    colo,
    ua: ua.slice(0, 120),
  });
  logTunnelEvent('ws_open', { req_id: reqId, colo });

  // Self-contained tunnel: ARP + DHCP + DNS + ICMP + NTP + TCP RST.
  // Supports both Ethernet frames (v86/Apptron) and raw IP packets (www.linux).
  // Frame type is auto-detected from the first binary message.

  const connState = { frameType: null, vmMac: null };
  const sendFn = (data) => { try { server.send(data); } catch(_) {} };

  server.addEventListener('message', (evt) => {
    try {
      tunnelStats.message_events += 1;
      const data = evt.data;
      if (typeof data === 'string') {
        if (data === 'ping') { tunnelStats.text_pings += 1; server.send('pong'); }
        return;
      }

      let bytes;
      if (data instanceof ArrayBuffer) bytes = new Uint8Array(data);
      else if (data && data.buffer instanceof ArrayBuffer) bytes = new Uint8Array(data.buffer, data.byteOffset || 0, data.byteLength || data.length || 0);
      else { tunnelStats.parse_dropped += 1; return; }

      tunnelStats.binary_packets += 1;
      const c = tunnelConnections.get(reqId);
      if (c) { c.bytes_rx += bytes.length; c.packets_rx += 1; }

      _handlePacket(bytes, connState, sendFn);
    } catch (e) {
      tunnelStats.errors += 1;
      logTunnelEvent('message_error', { req_id: reqId, error: safeError(e) });
    }
  });

  server.addEventListener('close', (evt) => {
    tunnelStats.closes += 1;
    tunnelConnections.delete(reqId);
    logTunnelEvent('ws_close', {
      req_id: reqId,
      code: evt && typeof evt.code === 'number' ? evt.code : null,
      reason: evt && evt.reason ? String(evt.reason).slice(0, 120) : '',
      clean: !!(evt && evt.wasClean),
    });
  });

  server.addEventListener('error', (evt) => {
    tunnelStats.errors += 1;
    logTunnelEvent('ws_error', { req_id: reqId, error: safeError(evt) });
  });

  return new Response(null, { status: 101, webSocket: client });
}

async function _linuxTunnelWs(request) {
  const reqId = crypto.randomUUID().slice(0, 8);
  const cf = request.cf || {};
  const colo = String(cf.colo || 'unknown');
  const ua = String(request.headers.get('user-agent') || '');
  const pathname = (() => { try { return new URL(request.url).pathname; } catch (_) { return ''; } })();
  tunnelStats.open_requests += 1;
  logTunnelEvent('open_request', { req_id: reqId, colo, ua: ua.slice(0, 120), pathname });

  const upgrade = request.headers.get('Upgrade');
  if (!upgrade || upgrade.toLowerCase() !== 'websocket') {
    tunnelStats.upgrade_rejected += 1;
    logTunnelEvent('upgrade_rejected', {
      req_id: reqId,
      upgrade: String(upgrade || ''),
      url: request.url,
    });
    return json({
      error: 'Upgrade required',
      hint: 'Use WebSocket at wss://relay.linuxontab.com/x/sys',
    }, 426);
  }

  // /x/sys is the relay-local path: always use local DHCP/ARP/ICMP/DNS(DoH) handler.
  // /linux/tunnel and /x/net try upstream (apptron.dev) first for richer TCP semantics.
  const forceLocal = pathname === '/x/sys';
  if (!forceLocal) {
    const proxied = await _tryProxyLinuxTunnelWs(request, reqId);
    if (proxied) return proxied;
    tunnelStats.proxy_fallback_local = (tunnelStats.proxy_fallback_local || 0) + 1;
    logTunnelEvent('proxy_fallback_local', { req_id: reqId });
  } else {
    tunnelStats.proxy_skipped_local = (tunnelStats.proxy_skipped_local || 0) + 1;
    logTunnelEvent('proxy_skipped_local', { req_id: reqId, reason: 'x/sys path' });
  }
  return _linuxTunnelWsLocal(request, reqId, colo, ua);
}

// ── WISP v1 server (for v86 WispNetworkAdapter) ──────────────────────────────
// Protocol: https://github.com/MercuryWorkshop/wisp-protocol (v1)
// Each message is a binary WebSocket frame:
//   [type:u8][stream_id:u32 LE][payload…]
// Types: 1=CONNECT, 2=DATA, 3=CONTINUE, 4=CLOSE, 5=INFO (v2 only)
//
// Uses cloudflare:sockets connect() to open real TCP from the Worker edge.
// TCP-only in this initial implementation (UDP/WISP-0x01-extension not supported).

const WISP_BUFFER = 1024 * 1024; // per-stream flow-control credits (bytes)

// ── WISP instrumentation ─────────────────────────────────────────────────────
// Per-stream record kept in a bounded ring. Inspect via GET /wisp/debug.
const WISP_STREAM_LIMIT = 64;
const WISP_FRAME_SAMPLE = 6; // sample first N frames each direction
const wispStreamRing = []; // { conn_id, sid, host, port, … }

function _hexHead(bytes, n = 32) {
  if (!bytes || !bytes.length) return '';
  const take = bytes.subarray(0, Math.min(n, bytes.length));
  let s = '';
  for (let i = 0; i < take.length; i++) {
    s += take[i].toString(16).padStart(2, '0');
  }
  return s;
}

function _wispClassifyTlsHead(bytes) {
  // TLS record: [type:u8][ver_major:u8][ver_minor:u8][len:u16 BE]
  // type 22 = handshake; handshake byte 5 = HandshakeType (1=ClientHello, 2=ServerHello, 11=Cert, …)
  if (!bytes || bytes.length < 6) return null;
  const t = bytes[0];
  if (t < 20 || t > 24) return null;
  const ver = `${bytes[1]}.${bytes[2]}`;
  const len = (bytes[3] << 8) | bytes[4];
  const names = { 20: 'ChangeCipherSpec', 21: 'Alert', 22: 'Handshake', 23: 'AppData', 24: 'Heartbeat' };
  let hs = null;
  if (t === 22 && bytes.length >= 6) {
    const hsTypes = { 1: 'ClientHello', 2: 'ServerHello', 11: 'Certificate', 12: 'ServerKeyExchange', 14: 'ServerHelloDone', 15: 'CertVerify', 16: 'ClientKeyExchange', 20: 'Finished' };
    hs = hsTypes[bytes[5]] || `hs-${bytes[5]}`;
  }
  return { type: names[t] || `t-${t}`, ver, len, hs };
}

function _wispPushStream(rec) {
  wispStreamRing.push(rec);
  if (wispStreamRing.length > WISP_STREAM_LIMIT) wispStreamRing.shift();
}

function _wispDebugSnapshot() {
  return {
    relay_build: RELAY_BUILD,
    now: new Date().toISOString(),
    wisp_buffer_bytes: WISP_BUFFER,
    stream_count: wispStreamRing.length,
    streams: wispStreamRing.slice().reverse().map(r => ({
      ...r,
      age_ms: Date.now() - r.started,
      closed_age_ms: r.closed ? Date.now() - r.closed : null,
    })),
  };
}

function _wispSendFrame(ws, type, streamId, payload) {
  const len = payload ? payload.length : 0;
  const buf = new Uint8Array(5 + len);
  buf[0] = type & 0xff;
  const dv = new DataView(buf.buffer);
  dv.setUint32(1, streamId >>> 0, true);
  if (payload && len) buf.set(payload, 5);
  try { ws.send(buf); } catch (_) {}
}

function _wispSendContinue(ws, streamId, remaining) {
  const buf = new Uint8Array(9);
  buf[0] = 3;
  const dv = new DataView(buf.buffer);
  dv.setUint32(1, streamId >>> 0, true);
  dv.setUint32(5, remaining >>> 0, true);
  try { ws.send(buf); } catch (_) {}
}

function _wispSendClose(ws, streamId, reason) {
  _wispSendFrame(ws, 4, streamId, new Uint8Array([reason & 0xff]));
}

async function _wispTunnelWs(request) {
  const reqId = crypto.randomUUID().slice(0, 8);
  const cf = request.cf || {};
  const colo = String(cf.colo || 'unknown');
  const ua = String(request.headers.get('user-agent') || '');

  const upgrade = request.headers.get('Upgrade');
  if (!upgrade || upgrade.toLowerCase() !== 'websocket') {
    return json({
      error: 'Upgrade required',
      hint: 'Use WebSocket (WISP protocol) at wss://relay.linuxontab.com/wisp',
    }, 426);
  }

  const pair = new WebSocketPair();
  const client = pair[0];
  const server = pair[1];
  try { server.accept(); } catch (e) { throw e; }

  tunnelStats.wisp_connections = (tunnelStats.wisp_connections || 0) + 1;
  logTunnelEvent('wisp_open', { req_id: reqId, colo, ua: ua.slice(0, 120) });

  // stream_id → { rec, socket, writer, bytesSinceCredit }
  const streams = new Map();

  // Initial CONTINUE(stream_id=0) — signals v1-compatible server ready.
  _wispSendContinue(server, 0, WISP_BUFFER);

  const finalizeRec = (rec, how, reason) => {
    if (rec.closed) return;
    rec.closed = Date.now();
    rec.close_how = how;              // 'client_close' | 'reader_done' | 'reader_err' | 'writer_err' | 'ws_close' | 'connect_fail'
    if (reason !== undefined) rec.close_reason = reason;
    rec.duration_ms = rec.closed - rec.started;
    logTunnelEvent('wisp_stream_end', {
      req_id: reqId, sid: rec.sid, host: rec.host, port: rec.port,
      how, reason, duration_ms: rec.duration_ms,
      bytes_up: rec.bytes_up, bytes_down: rec.bytes_down,
      frames_up: rec.frames_up, frames_down: rec.frames_down,
      first_down_ms: rec.first_down_ms, last_down_ms: rec.last_down_ms,
      last_up_ms: rec.last_up_ms,
      up_head: rec.up_samples[0] || null,
      down_head: rec.down_samples[0] || null,
    });
  };

  const closeStream = (sid, reason = 0x02, how = 'closeStream') => {
    const s = streams.get(sid);
    if (!s) return;
    streams.delete(sid);
    try { s.writer.close(); } catch (_) {}
    try { s.socket.close(); } catch (_) {}
    _wispSendClose(server, sid, reason);
    finalizeRec(s.rec, how, reason);
  };

  server.addEventListener('message', async (evt) => {
    try {
      const data = evt.data;
      if (typeof data === 'string') {
        if (data === 'ping') { try { server.send('pong'); } catch(_) {} }
        return;
      }
      let bytes;
      if (data instanceof ArrayBuffer) bytes = new Uint8Array(data);
      else if (data && data.buffer instanceof ArrayBuffer) {
        bytes = new Uint8Array(data.buffer, data.byteOffset || 0, data.byteLength || data.length || 0);
      } else return;
      if (bytes.length < 5) return;

      const type = bytes[0];
      const dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
      const streamId = dv.getUint32(1, true);
      const payload = bytes.subarray(5);

      if (type === 1) {
        // CONNECT: [stream_type:u8][port:u16 LE][hostname:utf-8]
        if (payload.length < 3) { _wispSendClose(server, streamId, 0x41); return; }
        const streamType = payload[0];
        const port = payload[1] | (payload[2] << 8);
        const hostname = new TextDecoder().decode(payload.subarray(3));
        if (streamType !== 1) {
          // UDP (0x02) not supported yet — reject cleanly.
          _wispSendClose(server, streamId, 0x41);
          logTunnelEvent('wisp_reject_udp', { req_id: reqId, sid: streamId, host: hostname, port });
          return;
        }
        const rec = {
          conn_id: reqId,
          sid: streamId,
          host: hostname,
          port,
          started: Date.now(),
          bytes_up: 0, bytes_down: 0,
          frames_up: 0, frames_down: 0,
          credits_issued: 0,
          first_down_ms: null, last_down_ms: null, last_up_ms: null,
          up_samples: [],   // [{ n, len, hex, tls? }]
          down_samples: [],
          closed: null, close_how: null, close_reason: null, duration_ms: null,
        };
        _wispPushStream(rec);

        let sock, writer, reader;
        try {
          // KNOWN LIMITATION: Cloudflare's `cloudflare:sockets.connect()`
          // refuses to reach other Cloudflare-hosted IPs from within a Worker
          // (loopback prevention). It fails with:
          //   "proxy request failed, cannot connect to the specified address.
          //    It looks like you might be trying to connect to a HTTP-based
          //    service — consider using fetch instead"
          // The error is port-agnostic: it triggers on 80/443 AND anything
          // else when the upstream IP is on CF's network. The message is
          // misleading — it's really Worker→CF loopback prevention. Egress to
          // non-CF IPs (AWS, GitHub SSH, etc.) works fine. See
          //   tests: github.com:22 OK, smtp.gmail.com:587 OK, httpbin.org:443 OK;
          //          api.openai.com:443 FAIL (CF-fronted), example.com:443 FAIL (CF).
          // Mitigation: egress CF-fronted targets via the Fly.io backend
          // (real tokio TCP, no such restriction) — not implemented here yet.
          sock = connect({ hostname, port });
        } catch (e) {
          _wispSendClose(server, streamId, 0x42); // unreachable
          finalizeRec(rec, 'connect_fail', 0x42);
          rec.connect_error = safeError(e);
          logTunnelEvent('wisp_connect_fail', {
            req_id: reqId, sid: streamId, host: hostname, port, error: safeError(e),
          });
          return;
        }

        // Observe the `opened` promise for diagnostics but DON'T await it here
        // (awaiting would reorder CONNECT/DATA handling).
        try {
          if (sock.opened && typeof sock.opened.then === 'function') {
            sock.opened.then(
              (info) => {
                rec.opened_ms = Date.now() - rec.started;
                rec.opened_info = info ? { remoteAddress: info.remoteAddress, localAddress: info.localAddress } : null;
                logTunnelEvent('wisp_socket_opened', {
                  req_id: reqId, sid: streamId, host: hostname, port,
                  t_ms: rec.opened_ms, info: rec.opened_info,
                });
              },
              (err) => {
                rec.opened_error = safeError(err);
                logTunnelEvent('wisp_socket_open_err', {
                  req_id: reqId, sid: streamId, host: hostname, port, error: safeError(err),
                });
              },
            );
          }
          if (sock.closed && typeof sock.closed.then === 'function') {
            sock.closed.then(
              () => {
                rec.socket_closed_ms = Date.now() - rec.started;
                logTunnelEvent('wisp_socket_closed_ok', {
                  req_id: reqId, sid: streamId, host: hostname, port, t_ms: rec.socket_closed_ms,
                });
              },
              (err) => {
                rec.socket_closed_error = safeError(err);
                logTunnelEvent('wisp_socket_closed_err', {
                  req_id: reqId, sid: streamId, host: hostname, port, error: safeError(err),
                });
              },
            );
          }
        } catch (_) {}

        try {
          reader = sock.readable.getReader();
          writer = sock.writable.getWriter();
        } catch (e) {
          _wispSendClose(server, streamId, 0x42);
          finalizeRec(rec, 'stream_attach_fail', 0x42);
          rec.attach_error = safeError(e);
          logTunnelEvent('wisp_stream_attach_fail', {
            req_id: reqId, sid: streamId, host: hostname, port, error: safeError(e),
          });
          return;
        }
        streams.set(streamId, { rec, socket: sock, writer, bytesSinceCredit: 0 });
        // Grant initial flow credits so client may start sending DATA.
        _wispSendContinue(server, streamId, WISP_BUFFER);
        rec.credits_issued += WISP_BUFFER;
        logTunnelEvent('wisp_connect_ok', {
          req_id: reqId, sid: streamId, host: hostname, port,
          credit: WISP_BUFFER,
        });

        // Pump socket.readable → DATA frames. Keep this async IIFE detached.
        (async () => {
          try {
            while (true) {
              const { value, done } = await reader.read();
              if (done) break;
              if (value && value.length) {
                _wispSendFrame(server, 2, streamId, value);
                rec.bytes_down += value.length;
                rec.frames_down += 1;
                const nowMs = Date.now() - rec.started;
                if (rec.first_down_ms == null) rec.first_down_ms = nowMs;
                rec.last_down_ms = nowMs;
                if (rec.down_samples.length < WISP_FRAME_SAMPLE) {
                  rec.down_samples.push({
                    n: rec.frames_down,
                    t_ms: nowMs,
                    len: value.length,
                    hex: _hexHead(value, 32),
                    tls: _wispClassifyTlsHead(value),
                  });
                }
              }
            }
            _wispSendClose(server, streamId, 0x02); // voluntary
            streams.delete(streamId);
            finalizeRec(rec, 'reader_done', 0x02);
          } catch (e) {
            _wispSendClose(server, streamId, 0x03); // network error
            streams.delete(streamId);
            rec.reader_error = safeError(e);
            finalizeRec(rec, 'reader_err', 0x03);
            logTunnelEvent('wisp_read_err', {
              req_id: reqId, sid: streamId, host: rec.host, port: rec.port,
              bytes_down: rec.bytes_down, frames_down: rec.frames_down,
              error: safeError(e),
            });
          } finally {
            try { reader.releaseLock(); } catch(_) {}
            try { sock.close(); } catch(_) {}
          }
        })();
      } else if (type === 2) {
        // DATA client→server
        const s = streams.get(streamId);
        if (!s) return;
        const rec = s.rec;
        rec.bytes_up += payload.length;
        rec.frames_up += 1;
        rec.last_up_ms = Date.now() - rec.started;
        if (rec.up_samples.length < WISP_FRAME_SAMPLE) {
          rec.up_samples.push({
            n: rec.frames_up,
            t_ms: rec.last_up_ms,
            len: payload.length,
            hex: _hexHead(payload, 32),
            tls: _wispClassifyTlsHead(payload),
          });
        }
        try {
          await s.writer.write(payload);
        } catch (e) {
          rec.writer_error = safeError(e);
          closeStream(streamId, 0x03, 'writer_err');
          return;
        }
        // Replenish flow-control credits based on DATA bytes consumed.
        s.bytesSinceCredit = (s.bytesSinceCredit || 0) + payload.length;
        if (s.bytesSinceCredit >= (WISP_BUFFER >> 1)) {
          s.bytesSinceCredit = 0;
          _wispSendContinue(server, streamId, WISP_BUFFER);
          rec.credits_issued += WISP_BUFFER;
        }
      } else if (type === 4) {
        // CLOSE from client
        const reason = payload.length >= 1 ? payload[0] : 0x02;
        closeStream(streamId, reason, 'client_close');
      }
      // type 3 (CONTINUE) / 5 (INFO) — ignore; we don't rate-limit outbound.
    } catch (e) {
      logTunnelEvent('wisp_message_err', { req_id: reqId, error: safeError(e) });
    }
  });

  server.addEventListener('close', () => {
    for (const sid of Array.from(streams.keys())) {
      const s = streams.get(sid);
      if (!s) continue;
      streams.delete(sid);
      try { s.writer.close(); } catch (_) {}
      try { s.socket.close(); } catch (_) {}
      finalizeRec(s.rec, 'ws_close', null);
    }
    logTunnelEvent('wisp_close', { req_id: reqId });
  });

  server.addEventListener('error', (evt) => {
    logTunnelEvent('wisp_error', { req_id: reqId, error: safeError(evt) });
  });

  return new Response(null, { status: 101, webSocket: client });
}

// ── CORS proxy (for v86 fetch backend + generic in-browser requests) ─────────
// Usage: GET /cors?url=https://example.com/path
// Passes method+headers+body through; strips host-sensitive request headers.

async function _corsProxy(request) {
  const url = new URL(request.url);
  let target = url.searchParams.get('url');
  if (!target) {
    // Also accept suffix form: /cors/https://example.com/...
    const prefix = '/cors/';
    if (url.pathname.startsWith(prefix)) {
      target = url.pathname.slice(prefix.length) + url.search;
    }
  }
  if (!target) return json({ error: "missing ?url=" }, 400);
  let targetUrl;
  try { targetUrl = new URL(target); } catch (_) { return json({ error: "invalid url" }, 400); }
  if (targetUrl.protocol !== 'http:' && targetUrl.protocol !== 'https:') {
    return json({ error: "only http/https supported" }, 400);
  }

  const forwardHeaders = new Headers();
  for (const [k, v] of request.headers) {
    const kl = k.toLowerCase();
    if (kl === 'host' || kl === 'origin' || kl === 'referer' || kl.startsWith('cf-') ||
        kl.startsWith('x-forwarded-') || kl === 'x-real-ip') continue;
    forwardHeaders.set(k, v);
  }
  try {
    const upstream = await fetch(targetUrl.toString(), {
      method: request.method,
      headers: forwardHeaders,
      body: (request.method === 'GET' || request.method === 'HEAD') ? undefined : request.body,
      redirect: 'follow',
    });
    const headers = new Headers(upstream.headers);
    for (const [k, v] of Object.entries(cors())) headers.set(k, v);
    // Drop headers that would confuse the browser about the origin
    headers.delete('content-security-policy');
    headers.delete('content-security-policy-report-only');
    return new Response(upstream.body, {
      status: upstream.status,
      statusText: upstream.statusText,
      headers,
    });
  } catch (e) {
    return json({ error: `cors proxy failed: ${e?.message || e}` }, 502);
  }
}

// ── DoH (DNS-over-HTTPS) proxy ───────────────────────────────────────────────
// Compatible with RFC 8484. v86's WispNetworkAdapter uses this for guest DNS:
//   POST /dns-query   Content-Type: application/dns-message   body = DNS wire format
//   GET  /dns-query?dns=<base64url-encoded DNS wire format>
// Returns application/dns-message from Cloudflare's 1.1.1.1 resolver.
// Needed because a direct browser fetch to cloudflare-dns.com from a file:// or
// third-party origin fails CORS preflight (content-type: application/dns-message
// is non-simple, and the DoH server's preflight response can be rejected). This
// endpoint answers the preflight itself and returns full CORS headers.

async function _dnsQuery(request) {
  const url = new URL(request.url);
  const UPSTREAM = 'https://1.1.1.1/dns-query';
  let body;
  let method = request.method;
  if (method === 'GET') {
    const dns = url.searchParams.get('dns');
    if (!dns) return new Response('missing ?dns=', { status: 400, headers: cors() });
    try {
      // upstream accepts GET with ?dns=base64url directly, proxy as-is
      const up = await fetch(`${UPSTREAM}?dns=${encodeURIComponent(dns)}`, {
        method: 'GET',
        headers: { 'accept': 'application/dns-message' },
      });
      const headers = new Headers({
        ...cors(),
        'content-type': up.headers.get('content-type') || 'application/dns-message',
        'cache-control': 'no-store',
      });
      return new Response(up.body, { status: up.status, headers });
    } catch (e) {
      return new Response(`dns upstream failed: ${e?.message || e}`, { status: 502, headers: cors() });
    }
  }
  if (method === 'POST') {
    try {
      body = await request.arrayBuffer();
      const up = await fetch(UPSTREAM, {
        method: 'POST',
        headers: {
          'content-type': 'application/dns-message',
          'accept': 'application/dns-message',
        },
        body,
      });
      const headers = new Headers({
        ...cors(),
        'content-type': up.headers.get('content-type') || 'application/dns-message',
        'cache-control': 'no-store',
      });
      return new Response(up.body, { status: up.status, headers });
    } catch (e) {
      return new Response(`dns upstream failed: ${e?.message || e}`, { status: 502, headers: cors() });
    }
  }
  return new Response('method not allowed', { status: 405, headers: cors() });
}

// ── Pairing code generation ───────────────────────────────────────────────────

const CODE_CHARS = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"; // unambiguous chars

function generateCode() {
  const buf = new Uint8Array(4);
  crypto.getRandomValues(buf);
  return Array.from(buf, (v) => CODE_CHARS[v % CODE_CHARS.length]).join("");
}

function normalizeCode(code) {
  if (!code) return null;
  const normalized = String(code).trim().toUpperCase();
  return /^[A-Z0-9]{4}$/.test(normalized) ? normalized : null;
}

// ── Durable Object: RelaySession ──────────────────────────────────────────────
//
// One instance per pairing code (created via idFromName(code)).
// All relay coordination happens in-memory — no KV writes needed.
//
// In-memory state:
//   pendingRequest  — a request the Mac hasn't picked up yet (phone arrived first)
//   pollResolve     — the Mac's waiting resolve() (poller arrived first)
//   resultResolvers — Map<id, resolve> for open phone /relay/call Promises

// Legacy DO class kept for backwards compatibility with previously deployed
// migrations that reference this class name.
export class GameRoom {
  async fetch() {
    return json({ error: 'GameRoom is deprecated' }, 410);
  }
}

// Legacy DO class kept for backwards compatibility with deployed migration
// histories that still reference GameRoomV2.
export class GameRoomV2 {
  async fetch() {
    return json({ error: 'GameRoomV2 is deprecated' }, 410);
  }
}

export class RelaySession {
  constructor(state, env) {
    this.created = Date.now();
    this.lastPollAt = null;     // timestamp of last /poll from Mac
    this.pendingRequest = null; // { id, path, args }
    this.pollResolve = null;    // fn(request) — Mac's waiting resolver
    this.resultResolvers = new Map(); // id → fn(result)
  }

  async fetch(request) {
    const url = new URL(request.url);

    switch (url.pathname) {
      case "/register": return this._register();
      case "/poll":    return this._poll();
      case "/call":    return this._call(request);
      case "/respond": return this._respond(request);
      case "/status":  return this._status();
      default:         return new Response("not found", { status: 404 });
    }
  }

  _register() {
    this.created = Date.now();
    this.lastPollAt = null;
    this.pendingRequest = null;
    this.pollResolve = null;
    this.resultResolvers.clear();
    return json({ ok: true });
  }

  // Mac long-polls here. Resolves immediately if a request is already waiting,
  // otherwise suspends for up to 29s then returns 204 (Mac should re-poll).
  _poll() {
    this.lastPollAt = Date.now(); // track liveness for _status()
    return new Promise((resolve) => {
      const timer = setTimeout(() => {
        this.pollResolve = null;
        resolve(new Response(null, { status: 204, headers: cors() }));
      }, 29_000);

      const deliver = (req) => {
        clearTimeout(timer);
        this.pollResolve = null;
        resolve(json(req));
      };

      if (this.pendingRequest) {
        // A call was already queued before Mac reconnected — deliver immediately.
        const req = this.pendingRequest;
        this.pendingRequest = null;
        deliver(req);
      } else {
        this.pollResolve = deliver;
      }
    });
  }

  // Phone calls a trait via relay. Suspends until Mac responds or 60s timeout.
  async _call(request) {
    const body = await request.json();
    const id = crypto.randomUUID();
    const req = { id, path: body.path, args: body.args ?? [] };

    return new Promise((resolve) => {
      const timer = setTimeout(() => {
        this.resultResolvers.delete(id);
        resolve(json({ error: "Relay timeout (60s)", result: null }, 504));
      }, 60_000);

      this.resultResolvers.set(id, (result) => {
        clearTimeout(timer);
        resolve(json(result));
      });

      // Wake the Mac if it's polling, otherwise queue the request.
      if (this.pollResolve) {
        this.pollResolve(req);
      } else {
        this.pendingRequest = req;
      }
    });
  }

  // Mac sends back the result for a previous request.
  async _respond(request) {
    const body = await request.json();
    const resolve = this.resultResolvers.get(body.id);
    if (!resolve) {
      return json({ error: "No pending request with that id" }, 404);
    }
    this.resultResolvers.delete(body.id);
    resolve(body); // body contains { id, result, error? }
    return json({ ok: true });
  }

  _status() {
    // Mac is considered connected if it's currently in a poll OR polled within the
    // last 35s (29s poll timeout + 6s grace for reconnect).
    const macConnected =
      this.pollResolve !== null ||
      (this.lastPollAt !== null && Date.now() - this.lastPollAt < 35_000);
    return json({
      active: macConnected,
      age_seconds: Math.floor((Date.now() - this.created) / 1000),
    });
  }
}

// ── Main Worker ───────────────────────────────────────────────────────────────

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (url.pathname.startsWith('/data/')) {
      // Answer preflight locally so Wanix syncfs PUT/DELETE passes CORS.
      if (request.method === 'OPTIONS') {
        return new Response(null, { status: 204, headers: cors() });
      }
      // We have no authoritative /data backend — persistence is local-only
      // (browser IDB via Wanix idbfs). For mutating methods, acknowledge the
      // write with 204 so Wanix syncfs MkdirAll/PUT/DELETE succeed and boot
      // progresses past user/project/public FS setup.
      const mutating = request.method === 'PUT' || request.method === 'POST'
        || request.method === 'DELETE' || request.method === 'PATCH';
      if (mutating) {
        const h = new Headers(cors());
        h.set('x-relay-data-fallback', 'local-only-ack');
        h.set('content-type', 'text/plain');
        return new Response('ok', { status: 200, headers: h });
      }
      const upstreamUrl = `https://apptron.dev${url.pathname}${url.search}`;
      const upstreamFallbackUrl = `https://www.apptron.dev${url.pathname}${url.search}`;
      try {
        const forwardHeaders = new Headers();
        const reqHeaders = request.headers;
        const copyHeader = (name) => {
          const val = reqHeaders.get(name);
          if (val) forwardHeaders.set(name, val);
        };
        copyHeader('accept');
        copyHeader('accept-language');
        copyHeader('cache-control');
        copyHeader('if-none-match');
        copyHeader('if-modified-since');
        copyHeader('range');
        copyHeader('user-agent');
        // Prefer first-party-style headers for hosts that gate /data assets.
        forwardHeaders.set('origin', 'https://apptron.dev');
        forwardHeaders.set('referer', 'https://apptron.dev/');

        let upstream = await fetch(upstreamUrl, {
          method: request.method,
          headers: forwardHeaders,
          body: request.method === 'GET' || request.method === 'HEAD' ? undefined : request.body,
          redirect: 'follow',
        });
        if (upstream.status === 403) {
          upstream = await fetch(upstreamFallbackUrl, {
            method: request.method,
            headers: forwardHeaders,
            body: request.method === 'GET' || request.method === 'HEAD' ? undefined : request.body,
            redirect: 'follow',
          });
        }
        // Upstream apptron.dev returns 403 (hotlink block) or 404 (path not
        // present) for many /data/* GETs. Wanix httpfs treats both as fatal
        // on initial fetch (boot.go:597 log.Fatalf "expected multipart
        // response"), which kills the Go runtime before the shell spawns.
        // Map both → 200 with an empty multipart/mixed body so httpfs sees a
        // valid "empty listing" and continues with local-only idbfs.
        if (upstream.status === 403 || upstream.status === 404) {
          const boundary = 'wanix-empty-fallback';
          const fallbackHeaders = new Headers(cors());
          fallbackHeaders.set('x-relay-data-fallback', `upstream-${upstream.status}-empty-multipart`);
          fallbackHeaders.set('content-type', `multipart/mixed; boundary=${boundary}`);
          return new Response(`--${boundary}--\r\n`, { status: 200, headers: fallbackHeaders });
        }
        const headers = new Headers(upstream.headers);
        for (const [k, v] of Object.entries(cors())) headers.set(k, v);
        return new Response(upstream.body, {
          status: upstream.status,
          statusText: upstream.statusText,
          headers,
        });
      } catch (e) {
        return json({ error: `data proxy failed: ${e?.message || e}` }, 502);
      }
    }

    // /bundles/* proxy — Go toolchain bundles from apptron.dev
    if (url.pathname.startsWith('/bundles/')) {
      const upstreamUrl = `https://apptron.dev${url.pathname}${url.search}`;
      try {
        const forwardHeaders = new Headers();
        forwardHeaders.set('accept', request.headers.get('accept') || '*/*');
        forwardHeaders.set('accept-encoding', 'br, gzip, deflate');
        forwardHeaders.set('origin', 'https://apptron.dev');
        forwardHeaders.set('referer', 'https://apptron.dev/');
        const upstream = await fetch(upstreamUrl, {
          method: 'GET',
          headers: forwardHeaders,
          redirect: 'follow',
        });
        if (!upstream.ok) {
          return new Response(upstream.body, {
            status: upstream.status,
            statusText: upstream.statusText,
            headers: { ...cors() },
          });
        }
        const headers = new Headers(upstream.headers);
        for (const [k, v] of Object.entries(cors())) headers.set(k, v);
        return new Response(upstream.body, {
          status: upstream.status,
          statusText: upstream.statusText,
          headers,
        });
      } catch (e) {
        return json({ error: `bundles proxy failed: ${e?.message || e}` }, 502);
      }
    }

    if (url.pathname === '/linux/tunnel/debug' && request.method === 'GET') {
      return json(tunnelDebugSnapshot());
    }

    if (url.pathname === '/wisp/debug' && request.method === 'GET') {
      return json(_wispDebugSnapshot());
    }

    if (url.pathname === '/wisp' || url.pathname === '/wisp/') {
      return _wispTunnelWs(request);
    }

    if (url.pathname === '/cors' || url.pathname.startsWith('/cors/')) {
      if (request.method === 'OPTIONS') {
        return new Response(null, { status: 204, headers: cors() });
      }
      return _corsProxy(request);
    }

    if (url.pathname === '/dns-query') {
      if (request.method === 'OPTIONS') {
        return new Response(null, { status: 204, headers: cors() });
      }
      return _dnsQuery(request);
    }

    if (url.pathname === '/linux/tunnel' || url.pathname === '/x/net' || url.pathname === '/x/sys') {
      return _linuxTunnelWs(request);
    }

    // CORS preflight
    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: cors() });
    }

    if (url.pathname === "/health") {
      return new Response("ok", { headers: cors() });
    }

    // POST /relay/register
    if (url.pathname === "/relay/register" && request.method === "POST") {
      let preferred = null;
      try {
        const text = await request.text();
        if (text) {
          const body = JSON.parse(text);
          preferred = normalizeCode(body.code);
        }
      } catch (_) {
      }
      const code = preferred || generateCode();
      const stub = env.RELAY.get(env.RELAY.idFromName(code));
      await stub.fetch(new Request("http://do/register", { method: "POST" }));
      return json({ code });
    }

    // GET /relay/poll?code=XXXX
    if (url.pathname === "/relay/poll" && request.method === "GET") {
      const code = url.searchParams.get("code");
      if (!code) return json({ error: "missing code" }, 400);
      return env.RELAY.get(env.RELAY.idFromName(code)).fetch(
        new Request("http://do/poll")
      );
    }

    // POST /relay/connect  { code } → { token, code }  (issues signed token)
    if (url.pathname === "/relay/connect" && request.method === "POST") {
      if (!env.RELAY_SECRET) return json({ error: "Token signing not configured on relay" }, 503);
      const body = await request.json().catch(() => ({}));
      const code = normalizeCode(body.code);
      if (!code) return json({ error: "invalid code" }, 400);
      // Verify Mac is actually polling before issuing a token
      const stub = env.RELAY.get(env.RELAY.idFromName(code));
      const statusData = await stub.fetch(new Request("http://do/status")).then(r => r.json());
      if (!statusData.active) return json({ error: "No helper connected with this code" }, 404);
      const token = await signToken(code, new URL(request.url).origin, env.RELAY_SECRET);
      return json({ ok: true, token, code });
    }

    // POST /relay/call  { code|token, path, args }
    if (url.pathname === "/relay/call" && request.method === "POST") {
      const body = await request.json();
      let code = normalizeCode(body.code);
      // Accept signed token in place of code
      if (!code && body.token && env.RELAY_SECRET) {
        const payload = await verifyToken(body.token, env.RELAY_SECRET);
        if (!payload) return json({ error: "Invalid or expired relay token" }, 401);
        code = payload.code;
      }
      if (!code) return json({ error: "missing code or token" }, 400);
      return env.RELAY.get(env.RELAY.idFromName(code)).fetch(
        new Request("http://do/call", {
          method: "POST",
          body: JSON.stringify({ ...body, code }),
          headers: { "Content-Type": "application/json" },
        })
      );
    }

    // POST /relay/respond  { code, id, result }
    if (url.pathname === "/relay/respond" && request.method === "POST") {
      const body = await request.json();
      if (!body.code) return json({ error: "missing code" }, 400);
      return env.RELAY.get(env.RELAY.idFromName(body.code)).fetch(
        new Request("http://do/respond", {
          method: "POST",
          body: JSON.stringify(body),
          headers: { "Content-Type": "application/json" },
        })
      );
    }

    // POST /llm/proxy — CORS proxy for OpenAI-compatible LLM APIs
    // Browser sends Authorization + JSON body; relay forwards to OpenAI and
    // returns the response with CORS headers.  Origin-locked to traits.build.
    if (url.pathname === "/llm/proxy" && request.method === "POST") {
      const origin = request.headers.get("Origin") || "";
      if (!origin.match(/^https?:\/\/(www\.)?traits\.build$/)) {
        return json({ error: "Origin not allowed" }, 403);
      }
      const auth = request.headers.get("Authorization");
      if (!auth) return json({ error: "Missing Authorization header" }, 401);
      const body = await request.text();
      try {
        const upstream = await fetch("https://api.openai.com/v1/chat/completions", {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "Authorization": auth,
          },
          body,
        });
        const data = await upstream.text();
        return new Response(data, {
          status: upstream.status,
          headers: { "Content-Type": "application/json", ...cors() },
        });
      } catch (e) {
        return json({ error: "Upstream fetch failed: " + e.message }, 502);
      }
    }

    // GET /relay/status?code=XXXX  or  ?token=XXX
    if (url.pathname === "/relay/status" && request.method === "GET") {
      let code = url.searchParams.get("code");
      // Accept signed token in place of code
      const token = url.searchParams.get("token");
      if (!code && token && env.RELAY_SECRET) {
        const payload = await verifyToken(token, env.RELAY_SECRET);
        if (!payload) return json({ error: "Invalid or expired relay token" }, 401);
        code = payload.code;
      }
      if (!code) return json({ error: "missing code or token" }, 400);
      const stub = env.RELAY.get(env.RELAY.idFromName(code));
      const res  = await stub.fetch(new Request("http://do/status"));
      const data = await res.json();
      return json({ ...data, code }); // always include resolved code in response
    }

    return json({ error: "not found" }, 404);
  },
};
