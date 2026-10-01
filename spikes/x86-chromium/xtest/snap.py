# minimal RFB client: grab one full frame (raw encoding) -> PNG
import socket, struct, sys, zlib
host, port, out = sys.argv[1], int(sys.argv[2]), sys.argv[3]
s = socket.create_connection((host, port), timeout=30)
def rd(n):
    b = b''
    while len(b) < n:
        c = s.recv(n - len(b))
        if not c: raise EOFError
        b += c
    return b
ver = rd(12); s.sendall(b'RFB 003.008\n')
n = rd(1)[0]; types = rd(n); s.sendall(b'\x01')
if struct.unpack('>I', rd(4))[0] != 0: raise SystemExit('auth failed')
s.sendall(b'\x01')  # shared
w, h = struct.unpack('>HH', rd(4)); pf = rd(16); nl = struct.unpack('>I', rd(4))[0]; rd(nl)
# 32bpp little-endian BGRX
s.sendall(struct.pack('>BxxxBBBBHHHBBBxxx', 0, 32, 24, 0, 1, 255, 255, 255, 16, 8, 0))
s.sendall(struct.pack('>BxHi', 2, 1, 0))
s.sendall(struct.pack('>BBHHHH', 3, 0, 0, 0, w, h))
fb = bytearray(w * h * 4)
got = 0
while got < w * h:
    t = rd(1)[0]
    if t != 0:
        if t == 2: continue
        if t == 3: rd(3); ln = struct.unpack('>I', rd(4))[0]; rd(ln); continue
        raise SystemExit('msg %d' % t)
    rd(1); nr = struct.unpack('>H', rd(2))[0]
    for _ in range(nr):
        x, y, rw, rh, enc = struct.unpack('>HHHHi', rd(12))
        def fill(fx, fy, fw, fh, px):
            line = px * fw
            for r in range(fh):
                o = ((fy + r) * w + fx) * 4
                fb[o:o + fw * 4] = line
        if enc == 0:
            data = rd(rw * rh * 4)
            for r in range(rh):
                o = ((y + r) * w + x) * 4
                fb[o:o + rw * 4] = data[r * rw * 4:(r + 1) * rw * 4]
        elif enc == 2:  # RRE
            ns = struct.unpack('>I', rd(4))[0]; bg = rd(4)
            fill(x, y, rw, rh, bg)
            for _ in range(ns):
                px = rd(4); sx, sy, sw, sh = struct.unpack('>HHHH', rd(8))
                fill(x + sx, y + sy, sw, sh, px)
        elif enc == 1:  # CopyRect
            sx, sy = struct.unpack('>HH', rd(4))
            tmp = [bytes(fb[((sy + r) * w + sx) * 4:((sy + r) * w + sx + rw) * 4]) for r in range(rh)]
            for r in range(rh):
                o = ((y + r) * w + x) * 4; fb[o:o + rw * 4] = tmp[r]
        else: raise SystemExit('enc %d' % enc)
        got += rw * rh
raw = b''.join(b'\x00' + bytes(fb[(y*w)*4:(y*w+w)*4][i+2-i%4*0:i+3] if False else b'') for y in range(0))
rows = []
for y in range(h):
    row = bytearray(b'\x00')
    line = fb[y*w*4:(y+1)*w*4]
    for i in range(0, len(line), 4): row += bytes((line[i+2], line[i+1], line[i]))
    rows.append(bytes(row))
def chunk(t, d): return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(b''.join(rows))) + chunk(b'IEND', b'')
open(out, 'wb').write(png); print('snap', w, h, out)
