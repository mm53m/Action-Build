#!/usr/bin/env python3
"""打印 APK 签名证书的 DER 长度与 SHA256（与 KernelSU/FinaSU 内核 apk_sign.c 的比对口径一致）。

用法: manager_cert.py <apk>            ->  "<size> <sha256hex>"
内核取值: EXPECTED_SIZE = DER 字节数, EXPECTED_HASH = sha256(cert DER)
只解析 APK Signing Block 的 v2/v3，不依赖 v1 JAR 签名。
"""
import hashlib
import struct
import sys

V2 = 0x7109871A
V3 = 0xF05368C0
V31 = 0x1B93AD61


def signing_pairs(data):
    eocd = data.rfind(b"PK\x05\x06")
    if eocd < 0:
        raise SystemExit("not a zip/apk")
    cd_off = struct.unpack("<I", data[eocd + 16:eocd + 20])[0]
    if data[cd_off - 16:cd_off] != b"APK Sig Block 42":
        raise SystemExit("no APK signing block")
    footer = struct.unpack("<Q", data[cd_off - 24:cd_off - 16])[0]
    pos = cd_off - footer - 8 + 8
    end = cd_off - 24
    pairs = {}
    while pos < end:
        plen = struct.unpack("<Q", data[pos:pos + 8])[0]
        sid = struct.unpack("<I", data[pos + 8:pos + 12])[0]
        pairs[sid] = data[pos + 12:pos + 8 + plen]
        pos += 8 + plen
    return pairs


def take(buf, off):
    ln = struct.unpack("<I", buf[off:off + 4])[0]
    return buf[off + 4:off + 4 + ln], off + 4 + ln


def first_cert(block):
    # signers: length-prefixed sequence -> signer -> signed_data
    off = 4
    off += 4
    sd_len = struct.unpack("<I", block[off:off + 4])[0]
    signed = block[off + 4:off + 4 + sd_len]
    _, o = take(signed, 0)          # digests
    certs, o = take(signed, o)      # certificates
    clen = struct.unpack("<I", certs[0:4])[0]
    return certs[4:4 + clen]


def main():
    data = open(sys.argv[1], "rb").read()
    pairs = signing_pairs(data)
    for sid in (V2, V3, V31):
        block = pairs.get(sid)
        if block:
            cert = first_cert(block)
            print(len(cert), hashlib.sha256(cert).hexdigest())
            return
    raise SystemExit("no v2/v3 signature block")


if __name__ == "__main__":
    main()
