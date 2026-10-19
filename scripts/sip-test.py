#!/usr/bin/env python3
"""
Headless SIP tester for the doorbell device.

Registers as a real PJSIP endpoint, places a call, sends DTMF digits, streams
a WAV file as the caller's audio, and captures the incoming RTP to a WAV.

This exists because the demo needs to be verifiable without a GUI softphone:
it drives the same PJSIP endpoints the TUI's panels use (hadji, johnson,
miora, ulrich).

Usage:
    ./scripts/sip-test.py call --user hadji --target 9999
    ./scripts/sip-test.py call --user hadji --target 9999 --dtmf 3
    ./scripts/sip-test.py call --user hadji --target 9999 --dtmf 32 \
        --dtmf-delay 12 --audio msg.wav --audio-delay 8 --duration 30
    ./scripts/sip-test.py register --user miora

The password defaults to pass_<user>. This tester binds its own local SIP port
(--local-port, 5099 by default) so it can run *while* the TUI is up: the TUI's
baresip endpoints own 5070, 5080, 5090 and 5095.

Notes:
    - Requires the container to run with host networking, so Asterisk sees the
      real peer address (see docker/docker-compose.yml).
    - Asterisk only acts on DTMF once it has seen RTP from the caller, so the
      client keeps one continuous stream alive (consistent SSRC) and primes it
      before sending digits.
    - That stream is kept alive for the whole call, like a real softphone, so
      apps that behave differently on hangup behave here the way they do in the
      TUI. In particular `Record()` deletes its file when the caller hangs up
      while it is still recording -- that is why the dialplan passes the `k`
      option, and why `--duration 1` (hang up right after speaking) is the
      interesting case to test.
"""
import argparse
import hashlib
import os
import re
import socket
import struct
import sys
import threading
import time
import wave

SRTP_PORT = 25000


def header_tag(msg, name="To"):
    """Return the `tag=` value of a header, i.e. the dialog's remote tag.

    Asterisk puts a tag in the To header of its 200 OK. Every request that
    belongs to that dialog has to echo it: a BYE without it is answered
    "481 Call/Transaction Does Not Exist" and the call is never torn down.
    """
    for line in msg.splitlines():
        if line.lower().startswith(name.lower() + ":"):
            m = re.search(r";tag=([^;\s]+)", line)
            return m.group(1) if m else None
    return None

# Media address advertised in our SDP offer. With host networking (the
# supported setup) Asterisk sees us at plain 127.0.0.1, which is also where we
# want its RTP delivered. Override with SIPTEST_MEDIA_IP if you run the
# container on a bridge network instead.
MEDIA_IP = os.environ.get("SIPTEST_MEDIA_IP", "127.0.0.1")

# audioop was removed in Python 3.13, so decode G.711 mu-law by hand
# using the standard reference expansion from ITU-T G.711.
_ULAW_BIAS = 0x84


def ulaw2lin(data):
    out = bytearray()
    for b in data:
        u = ~b & 0xFF
        sample = ((u & 0x0F) << 3) + _ULAW_BIAS
        sample <<= (u & 0x70) >> 4
        sample -= _ULAW_BIAS
        out += struct.pack("<h", -sample if u & 0x80 else sample)
    return bytes(out)


def md5(s):
    return hashlib.md5(s.encode()).hexdigest()


def lin2ulaw(data):
    """Encode 16-bit signed-linear PCM to G.711 mu-law (inverse of ulaw2lin)."""
    out = bytearray()
    for i in range(0, len(data) - 1, 2):
        sample = struct.unpack_from("<h", data, i)[0]
        sign = 0x80 if sample < 0 else 0
        if sample < 0:
            sample = -sample
        if sample > 32635:
            sample = 32635
        sample += _ULAW_BIAS
        exponent = 7
        mask = 0x4000
        while exponent > 0 and not (sample & mask):
            exponent -= 1
            mask >>= 1
        mantissa = (sample >> (exponent + 3)) & 0x0F
        out.append(~(sign | (exponent << 4) | mantissa) & 0xFF)
    return bytes(out)


def rtp_checksum(data):
        """RFC 3550 RTP checksum over header+payload with the checksum zeroed.

        This container runs Asterisk with RTP checksums enabled (rtp.conf's
        'checksums' key is not honoured by Asterisk 20), so DTMF packets sent
        with a bad checksum are silently discarded.

        Note the checksum is the ones' complement of the folded sum, with the
        checksum field zeroed. Verify with:
            fold16(packet) == 0xffff
        """
        if len(data) % 2:
            data += b"\x00"
        total = 0
        for i in range(0, len(data), 2):
            total += (data[i] << 8) + data[i + 1]
        while total >> 16:
            total = (total & 0xFFFF) + (total >> 16)
        checksum = (~total) & 0xFFFF
        return struct.pack("!H", checksum if checksum else 0xFFFF)


class SipClient:
    def __init__(self, user, password, server="127.0.0.1", server_port=5060,
                 bind_rtp=True, local_port=5099):
        self.user = user
        self.password = password
        self.server = server
        self.server_port = server_port
        self.sip = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sip.bind(("127.0.0.1", local_port))
        self.rtp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        if bind_rtp:
            self.rtp.bind(("0.0.0.0", SRTP_PORT))
        # NOTE: keep the From tag and Call-ID free of "@". Asterisk silently
        # drops a REGISTER whose From tag contains "@" (verified by bisecting
        # the headers), so a normal-looking "<md5>@pc" tag yields no response
        # at all. Using a plain hex tag avoids that entirely.
        self.call_id = f"{md5(user)}{int(time.time()*1000) % 100000}@pc"
        self.from_tag = md5(user + str(time.time()))[:16]
        self.cseq = 1
        self.branch = "z9hG4bK" + md5(user + str(time.time()))[:10]
        self.local = self.sip.getsockname()
        self.auth_nonce = None
        self.remote_sdp = None
        self.remote_tag = None
        self.rtp_remote = None
        self.ssrc = 0x0D0BE11

    # ---------------------------------------------------------------- send/recv
    def send(self, msg):
        self.sip.sendto(msg.encode(), (self.server, self.server_port))

    def recv(self, timeout=5):
        self.sip.settimeout(timeout)
        try:
            data, addr = self.sip.recvfrom(65535)
            return data.decode(errors="replace"), addr
        except socket.timeout:
            return None, None

    def reply_200(self, request):
        """Answer an in-dialog request from Asterisk (a BYE) with 200 OK.

        Asterisk hangs up on its own whenever the dialplan finishes, so a
        caller that never answers its BYE leaves it retransmitting.
        """
        lines = request.split("\r\n")
        vias = [l for l in lines if l.lower().startswith("via:")]
        keep = [l for l in lines
                if l.lower().startswith(("from:", "to:", "call-id:", "cseq:"))]
        resp = "SIP/2.0 200 OK\r\n" + "".join(v + "\r\n" for v in vias)
        resp += "".join(k + "\r\n" for k in keep)
        resp += "Content-Length: 0\r\n\r\n"
        self.send(resp)

    def wait_for(self, *tokens, timeout=8):
        """Read until a response containing all tokens arrives."""
        end = time.time() + timeout
        while time.time() < end:
            msg, _ = self.recv(timeout=max(0.2, end - time.time()))
            if not msg:
                continue
            first = msg.splitlines()[0]
            for tok in tokens:
                if tok in first:
                    return msg
            # Ignore re-INVITEs / BYEs from Asterisk that arrive while we wait.
            if first.startswith("SIP/2.0 1") or first.startswith("SIP/2.0 2"):
                print("  < other:", first)
        return None

    def headers(self, method, to_uri, extra="", body="", to_tag=None):
        self.cseq += 1
        # A fresh branch per request. Reusing one makes Asterisk treat the
        # second REGISTER as a retransmission of the first and drop it
        # silently, which breaks the 401 -> authenticated REGISTER retry.
        self.branch = "z9hG4bK" + md5(
            f"{self.user}{self.cseq}{time.time()}")[:12]
        # Requests inside an established dialog carry the remote tag; the
        # dialog-creating ones (REGISTER, INVITE) must not.
        to = f"<{to_uri}>" + (f";tag={to_tag}" if to_tag else "")
        h = (
            f"{method} {to_uri} SIP/2.0\r\n"
            f"Via: SIP/2.0/UDP {self.local[0]}:{self.local[1]};branch={self.branch}\r\n"
            f"From: \"{self.user}\" <sip:{self.user}@127.0.0.1>;tag={self.from_tag}\r\n"
            f"To: {to}\r\n"
            f"Call-ID: {self.call_id}\r\n"
            f"CSeq: {self.cseq} {method}\r\n"
            f"Contact: <sip:{self.user}@{self.local[0]}:{self.local[1]}>\r\n"
            f"Max-Forwards: 70\r\n"
            f"User-Agent: doorbell-siptest\r\n"
        )
        if self.auth_nonce:
            # Digest without qop:
            #   HA1 = MD5(user:realm:pass)
            #   HA2 = MD5(method:uri)
            #   response = MD5(HA1:nonce:HA2)
            ha1 = md5(f"{self.user}:asterisk:{self.password}")
            ha2 = md5(f"{method}:{to_uri}")
            resp = md5(f"{ha1}:{self.auth_nonce}:{ha2}")
            h += (
                f"Authorization: Digest username=\"{self.user}\", realm=\"asterisk\", "
                f"nonce=\"{self.auth_nonce}\", uri=\"{to_uri}\", "
                f"response=\"{resp}\", algorithm=MD5\r\n"
            )
        h += extra
        h += f"Content-Length: {len(body)}\r\n\r\n{body}"
        return h

    # ---------------------------------------------------------------- register
    def register(self):
        to_uri = f"sip:{self.user}@127.0.0.1"
        self.auth_nonce = None
        self.send(self.headers("REGISTER", to_uri, "Expires: 3600\r\n"))
        msg = self.wait_for("401") or self.wait_for("200")
        if msg and msg.splitlines()[0].startswith("SIP/2.0 401"):
            for line in msg.splitlines():
                if line.lower().startswith("www-authenticate"):
                    self.auth_nonce = line.split("nonce=")[1].split(",")[0].strip('"')
            self.cseq = 1  # restart so the authenticated REGISTER uses CSeq 2
            self.send(self.headers("REGISTER", to_uri, "Expires: 3600\r\n"))
            msg = self.wait_for("200")
        if msg and msg.splitlines()[0].startswith("SIP/2.0 200"):
            print(f"  REGISTER {self.user}: OK")
            return True
        print(f"  REGISTER {self.user}: FAILED")
        return False

    # ---------------------------------------------------------------- call
    def sdp_offer(self):
        return (
            "v=0\r\n"
            f"o={self.user} 0 0 IN IP4 {MEDIA_IP}\r\n"
            f"s=doorbell-test\r\n"
            f"c=IN IP4 {MEDIA_IP}\r\n"
            "t=0 0\r\n"
            f"m=audio {SRTP_PORT} RTP/AVP 0 8 101\r\n"
            "a=rtpmap:0 PCMU/8000\r\n"
            "a=rtpmap:8 PCMA/8000\r\n"
            # Advertise telephone-event so Asterisk negotiates in-band DTMF.
            # Without this it will never accept RFC 2833 digits and the IVR
            # just times out.
            "a=rtpmap:101 telephone-event/8000\r\n"
            "a=fmtp:101 0-16\r\n"
            "a=fmtp:0 annexb=no\r\n"
            "a=sendrecv\r\n"
        )

    def headers_ack(self, to_uri, cseq, branch, to_tag=None):
        to = f"<{to_uri}>" + (f";tag={to_tag}" if to_tag else "")
        return (
            f"ACK {to_uri} SIP/2.0\r\n"
            f"Via: SIP/2.0/UDP {self.local[0]}:{self.local[1]};branch={branch}\r\n"
            f"From: \"{self.user}\" <sip:{self.user}@127.0.0.1>;tag={self.from_tag}\r\n"
            f"To: {to}\r\n"
            f"Call-ID: {self.call_id}\r\n"
            f"CSeq: {cseq} ACK\r\n"
            f"Max-Forwards: 70\r\n"
            f"Content-Length: 0\r\n\r\n"
        )

    def call(self, target, dtmf="", duration=12.0, answer_delay=1.0,
             dtmf_delay=0.0, audio_file=None, audio_delay=0.0,
             answer_timeout=60.0):
        to_uri = f"sip:{target}@127.0.0.1"
        self.send(self.headers(
            "INVITE", to_uri,
            "Content-Type: application/sdp\r\n"
            "Allow: INVITE, ACK, CANCEL, OPTIONS, BYE\r\n",
            self.sdp_offer(),
        ))

        # This device answers immediately (Answer() is the first thing the
        # dialplan does), so a 200 OK often arrives with no 180 at all.
        msg = self.wait_for("200", "180", timeout=10)
        if not msg:
            print("  no response to INVITE")
            return None

        code = msg.splitlines()[0].split()[1]
        if code == "180":
            # A call that rings has to be waited out: Asterisk only sends the
            # 200 OK once the far end answers (or, for an unanswered call, once
            # the dialplan moves on and starts playing to the caller).
            msg = self.wait_for("200", timeout=answer_timeout)
            if not msg:
                print("  no final response")
                return None
            code = msg.splitlines()[0].split()[1]
        if code != "200":
            print(f"  INVITE rejected: {code}")
            return None

        self.remote_sdp = msg.split("\r\n\r\n", 1)[1] if "\r\n\r\n" in msg else ""
        # The dialog's remote tag: needed by every in-dialog request below.
        self.remote_tag = header_tag(msg)
        # ACK must reuse the INVITE's CSeq number and branch, otherwise
        # Asterisk treats it as a new transaction and retransmits the 200.
        ack_branch = self.branch
        ack_cseq = self.cseq
        self.cseq += 1
        self.branch = ack_branch
        self.send(self.headers_ack(to_uri, ack_cseq, ack_branch, self.remote_tag))
        print(f"  INVITE -> 200 OK, call established (acked)")

        # Drain RTP on a background thread for the whole call. RFC 2833 DTMF
        # has to be sent back to the port Asterisk transmits from, and that
        # port is only known once the first inbound RTP packet arrives.
        self._pcm = bytearray()
        self._rx = threading.Thread(target=self._rx_loop, daemon=True)
        self._rx.start()
        self.seq = 0
        self.ts = 0

        # Wait until the first inbound packet reveals Asterisk's RTP port.
        if dtmf or audio_file:
            deadline = time.time() + 6
            while not self.rtp_remote and time.time() < deadline:
                time.sleep(0.1)

        if answer_delay:
            time.sleep(answer_delay)

        # Asterisk keys DTMF and audio to the media stream it learned from our
        # SDP, and needs a few packets to leave RTP "probation", so keep one
        # continuous stream (consistent SSRC, monotonic seq/timestamp).
        if (dtmf or audio_file) and not self.rtp_remote:
            print("  !! no inbound RTP yet, cannot send media")
        elif dtmf or audio_file:
            if dtmf and dtmf_delay:
                # Wait out the greeting; Background() only starts listening
                # for a digit once the prompt has finished playing.
                self._prime_until(dtmf_delay)
            else:
                self._prime_until(1.5)

            for digit in dtmf:
                time.sleep(0.4)
                self.send_dtmf(digit)
                print(f"  DTMF sent: {digit}")

            if audio_file:
                if audio_delay:
                    self._prime_until(audio_delay)
                self.stream_wav(audio_file)
                print(f"  audio streamed: {audio_file}")

        # Keep the call open for the requested duration, and keep the media
        # stream alive while we wait: a real softphone never stops sending RTP
        # mid-call. Letting it stop makes Asterisk see "no more media" and
        # finish apps that would otherwise still be running -- notably
        # Record(), which then returns normally instead of seeing the hangup.
        self._prime_until(max(0.0, duration))

        self._rx_stop = True
        self._rx.join(timeout=2)
        pcm = bytes(self._pcm)

        self.send(self.headers("BYE", to_uri, to_tag=self.remote_tag))
        # Wait for the answer to *this* BYE. Only responses count: Asterisk
        # sends its own BYE (with "BYE" in its CSeq) when the dialplan ends,
        # and that request is answered rather than mistaken for our reply.
        bye_ok = False
        deadline = time.time() + 4
        while time.time() < deadline:
            msg, _ = self.recv(timeout=0.5)
            if not msg:
                continue
            first = msg.splitlines()[0]
            if first.startswith("BYE"):
                self.reply_200(msg)
                continue
            if not first.startswith("SIP/2.0"):
                continue
            cseq = next((l for l in msg.splitlines()
                         if l.lower().startswith("cseq:")), "")
            if "BYE" not in cseq.upper():
                continue
            bye_ok = first.startswith("SIP/2.0 200")
            if not bye_ok:
                print("  !! BYE rejected:", first)
            break
        print("  BYE accepted, call torn down" if bye_ok
              else "  !! BYE not answered - the call may still be up")
        print(f"  call finished, captured {len(pcm) // 2} samples")
        return pcm

    def _send_rtp(self, payload):
        """Send one RTP packet (PCMU) on the shared media stream."""
        if not self.rtp_remote:
            return
        hdr = struct.pack("!BBHII", 0x80, 0, self.seq & 0xFFFF, self.ssrc,
                          self.ts & 0xFFFFFFFF)
        pkt = bytearray(hdr + payload)
        pkt[10:12] = rtp_checksum(bytes(pkt))
        self.rtp.sendto(bytes(pkt), self.rtp_remote)
        self.seq += 1
        self.ts += len(payload)

    def _prime_until(self, seconds):
        """Keep the RTP stream alive (and satisfy probation) for N seconds."""
        end = time.time() + seconds
        while time.time() < end and self.rtp_remote:
            # 160 bytes of PCMU = 20 ms. 0xFF is mu-law *silence*: 0x00 would
            # be full-scale noise, which keeps Asterisk's silence detector
            # (used by Record) from ever firing.
            self._send_rtp(b"\xff" * 160)
            time.sleep(0.02)

    def stream_wav(self, path):
        """Stream an 8 kHz mono WAV file as PCMU RTP.

        Used to leave a real voicemail message in automated tests.
        """
        with wave.open(path, "rb") as w:
            if w.getnchannels() != 1 or w.getsampwidth() != 2:
                raise ValueError(f"{path}: expected 8 kHz mono 16-bit WAV")
            frames = w.readframes(w.getnframes())
        ulaw = lin2ulaw(frames)
        for i in range(0, len(ulaw), 160):
            self._send_rtp(ulaw[i:i + 160])
            time.sleep(0.02)

    def _rx_loop(self):
        """Continuously drain RTP for the lifetime of a call."""
        self.rtp.settimeout(0.3)
        while not getattr(self, "_rx_stop", False):
            try:
                pkt, addr = self.rtp.recvfrom(4096)
            except socket.timeout:
                continue
            if len(pkt) < 12:
                continue
            if not self.rtp_remote:
                self.rtp_remote = addr
            if pkt[1] & 0x7F == 0:      # PCMU
                self._pcm += ulaw2lin(pkt[12:])

    def send_dtmf(self, digit):
        # RFC 2833 telephone-event. Each digit is sent as a 3-packet
        # sequence: 3 with the end bit set, then 2 continuation packets,
        # then 3 with end set to terminate. Asterisk needs all three to
        # register the digit.
        table = {
            "0": b"\x10", "1": b"\x01", "2": b"\x02", "3": b"\x03",
            "4": b"\x04", "5": b"\x05", "6": b"\x06", "7": b"\x07",
            "8": b"\x08", "9": b"\x09", "#": b"\x0b", "*": b"\x0a",
        }
        event = table.get(digit, b"\x01")
        if not self.rtp_remote:
            print("  !! no remote RTP endpoint, cannot send DTMF")
            return

        # RFC 2833 payload is exactly 3 bytes: event code, E|R|volume+dur,
        # volume. My first version emitted 4, which Asterisk silently drops.
        payload = bytes([
            event[0],   # event code
            0x0A,       # duration = 10 * 10ms = 100 ms
            0x00,       # volume
        ])
        # Use a fixed SSRC for the whole digit. Asterisk tracks DTMF per media
        # stream, so a randomised SSRC makes it drop the events as belonging to
        # some other stream.
        self._dtmf_seq = getattr(self, "_dtmf_seq", 1000)
        self._dtmf_ssrc = self.ssrc
        # RFC 2833: a begin packet (E clear), then an end packet (E set).
        # Asterisk turns *every* E-set packet into a digit of its own, so the
        # end packet is repeated as a genuine retransmission -- same sequence
        # number, which Asterisk de-duplicates. Bumping the sequence number
        # instead registers the digit twice and derails a multi-digit IVR.
        for endset in (False, True, True):
            end_bit = 0x80 if endset else 0x00
            pkt = bytearray(struct.pack("!BBHII", 0x80, 101,
                                        self._dtmf_seq & 0xFFFF,
                                        self._dtmf_ssrc, 16000))
            pkt += bytes([payload[0], payload[1] | end_bit, payload[2]])
            pkt[10:12] = b"\x00\x00"          # checksum placeholder
            pkt[10:12] = rtp_checksum(bytes(pkt))
            self.rtp.sendto(bytes(pkt), self.rtp_remote)
            if not endset:
                self._dtmf_seq += 1
            time.sleep(0.03)

    def save(self, pcm, path):
        with wave.open(path, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(8000)
            w.writeframes(pcm)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("mode")
    ap.add_argument("--user", default="hadji")
    ap.add_argument("--password", default=None)
    ap.add_argument("--local-port", type=int, default=5099,
                    help="local UDP port to bind; keep it clear of the TUI's "
                         "baresip ports (5070/5080/5090/5095) so the tester can "
                         "run while the TUI is up")
    ap.add_argument("--target", default="9999")
    ap.add_argument("--dtmf", default="")
    ap.add_argument("--duration", type=float, default=12.0)
    ap.add_argument("--answer", action="store_true")
    ap.add_argument("--dtmf-delay", type=float, default=9.0)
    ap.add_argument("--answer-timeout", type=float, default=60.0,
                    help="seconds to wait for the call to be answered. A "
                         "ringing call answers late: the doorbell rings 4 "
                         "times (24s) before it offers to take a message, so "
                         "the default is generous.")
    ap.add_argument("--audio", default=None,
                    help="8 kHz mono WAV to stream as the caller's audio")
    ap.add_argument("--audio-delay", type=float, default=0.0,
                    help="seconds to wait after DTMF before streaming audio")
    ap.add_argument("--out", default=None)
    a = ap.parse_args()

    pw = a.password or f"pass_{a.user}"
    c = SipClient(a.user, pw, local_port=a.local_port)
    if not c.register():
        sys.exit(1)
    if a.mode == "register":
        time.sleep(5)
        sys.exit(0)
    pcm = c.call(a.target, a.dtmf, a.duration, 1.0 if a.answer else 0.0,
                 dtmf_delay=a.dtmf_delay, audio_file=a.audio,
                 audio_delay=a.audio_delay, answer_timeout=a.answer_timeout)
    out = a.out or f"/tmp/doorbell-{a.user}-{a.target}.wav"
    if pcm:
        c.save(pcm, out)
        print(f"  saved {out}")