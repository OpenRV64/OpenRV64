"""Wire format: the framing and message types shared by host and remote.

A module is either in-process (direct method calls, no serialisation) or
out-of-process (this framing over a pipe pair).  Both sides run the identical
protocol; only the transport differs.  A remote module's messages are exactly
the calls the bus would have made locally.

Frame = 4-byte big-endian length + codec payload.  Two codecs:

  ``pickle`` (default)  python <-> python/pypy, fast, arbitrary payloads
  ``json``              portable, for a module written in another language

The codec is chosen by the host in HELLO; the remote must honour it.  Under
``json`` every published value must be JSON-representable, which is a real
constraint on signal payloads and the reason it is not the default.
"""

import json
import pickle
import struct

PROTO = 1

# host -> module
HELLO = "hello"     # {proto, codec, name}      -> MANIFEST
BUILD = "build"     # {}                        -> PUB (reg publishes at build)
DELTA = "delta"     # {cycle, delta, fired:{}}  -> PUB   (settling round)
TICK = "tick"       # {cycle, vals, sfired}     -> PUB   (clock edge, reg only)
FINISH = "finish"   # {}                        -> REPORT

# module -> host
MANIFEST = "manifest"  # {name, publishes:[...], subscribes:[], clock, reset_n}
PUB = "pub"            # {pubs: [[sig,value],...], wake: bool}
REPORT = "report"      # {report: <any>}
FAULT = "fault"        # {where, error}

_HDR = struct.Struct(">I")


class Codec(object):
    __slots__ = ("name", "_dumps", "_loads")

    def __init__(self, name):
        self.name = name
        if name == "pickle":
            self._dumps = lambda o: pickle.dumps(o, 4)
            self._loads = pickle.loads
        elif name == "json":
            self._dumps = lambda o: json.dumps(o).encode()
            self._loads = lambda b: json.loads(b.decode())
        else:
            raise ValueError("unknown codec %r" % name)

    def dumps(self, o):
        return self._dumps(o)

    def loads(self, b):
        return self._loads(b)


class Framer(object):
    """Length-prefixed message transport over a pair of binary streams."""

    __slots__ = ("rd", "wr", "codec")

    def __init__(self, rd, wr, codec="pickle"):
        self.rd = rd
        self.wr = wr
        self.codec = codec if isinstance(codec, Codec) else Codec(codec)

    def send(self, kind, **body):
        body["k"] = kind
        payload = self.codec.dumps(body)
        self.wr.write(_HDR.pack(len(payload)))
        self.wr.write(payload)
        self.wr.flush()

    def recv(self):
        hdr = _readn(self.rd, 4)
        if hdr is None:
            return None
        n = _HDR.unpack(hdr)[0]
        payload = _readn(self.rd, n)
        if payload is None:
            return None
        return self.codec.loads(payload)

    def expect(self, kind):
        m = self.recv()
        if m is None:
            raise EOFError("remote closed while waiting for %s" % kind)
        if m["k"] == FAULT:
            raise RuntimeError("remote fault in %s: %s" % (m.get("where"), m.get("error")))
        if m["k"] != kind:
            raise RuntimeError("expected %s, got %s" % (kind, m["k"]))
        return m


def _readn(f, n):
    buf = b""
    while len(buf) < n:
        chunk = f.read(n - len(buf))
        if not chunk:
            return None
        buf += chunk
    return buf
