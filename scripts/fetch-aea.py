#!/usr/bin/env python3
"""
从远程 IPSW（Apple CDN 上的 zip）里，用 HTTP Range 精确取出单个 stored 条目。

为什么要这个：iPhone18,2 的 IPSW 有 11.4 GB，而我们只需要其中的 .dmg.aea。
这些条目在 zip 里是 STORED（compress_type=0），所以可以按字节区间直取，
不必下载整个包。macOS runner 的可用磁盘很小，这招能把 11.4 GB 压到 1.9 GB。

用法：
    fetch-aea.py <ipsw-url> <entry-name> <output-path> [--entry-name2 out2 ...]

也支持本地文件（file:// 或普通路径），方便离线验证。
"""
import sys
import os
import struct
import shutil
import urllib.request


def _read(url, start, end):
    """读 [start, end] 闭区间（HTTP Range 或本地 seek）。"""
    n = end - start + 1
    if url.startswith("file://"):
        with open(url[7:], "rb") as f:
            f.seek(start)
            return f.read(n)
    if os.path.exists(url) and not url.startswith(("http://", "https://")):
        with open(url, "rb") as f:
            f.seek(start)
            return f.read(n)
    req = urllib.request.Request(url, headers={"Range": f"bytes={start}-{end}"})
    with urllib.request.urlopen(req, timeout=120) as r:
        if r.status not in (200, 206):
            raise RuntimeError(f"Range 请求失败: HTTP {r.status}")
        data = r.read()
    if len(data) != n:
        raise RuntimeError(f"短读：期望 {n} 字节，实际 {len(data)}")
    return data


def _size(url):
    if url.startswith("file://"):
        return os.path.getsize(url[7:])
    if os.path.exists(url) and not url.startswith(("http://", "https://")):
        return os.path.getsize(url)
    req = urllib.request.Request(url, method="HEAD")
    with urllib.request.urlopen(req, timeout=60) as r:
        return int(r.headers["Content-Length"])


def parse_central_directory(url):
    """读 EOCD（含 ZIP64），解析 central directory，返回 {name: (header_offset, csize, usize, ctype)}。"""
    total = _size(url)
    tail_len = min(1 << 20, total)
    tail = _read(url, total - tail_len, total - 1)

    idx = tail.rfind(b"PK\x05\x06")
    if idx < 0:
        raise RuntimeError("找不到 EOCD 记录")
    cd_size, cd_offset = struct.unpack("<II", tail[idx + 12:idx + 20])
    entries_total = struct.unpack("<H", tail[idx + 10:idx + 12])[0]

    if cd_offset == 0xFFFFFFFF or cd_size == 0xFFFFFFFF or entries_total == 0xFFFF:
        # ZIP64：EOCD 之前有 locator(PK\x06\x07)，指到 ZIP64 EOCD(PK\x06\x06)
        loc = tail.rfind(b"PK\x06\x07", 0, idx)
        if loc < 0:
            raise RuntimeError("ZIP64：找不到 EOCD locator")
        loc_abs = total - tail_len + loc
        z64_off = struct.unpack("<Q", _read(url, loc_abs + 8, loc_abs + 15))[0]
        z64 = _read(url, z64_off, z64_off + 55)
        if z64[:4] != b"PK\x06\x06":
            raise RuntimeError("ZIP64 EOCD 魔数不对")
        entries_total = struct.unpack("<Q", z64[32:40])[0]
        cd_size, cd_offset = struct.unpack("<QQ", z64[40:56])

    print(f"[*] 中央目录：{entries_total} 条目，offset={cd_offset} size={cd_size}")
    cd = _read(url, cd_offset, cd_offset + cd_size - 1)

    entries = {}
    p = 0
    while p + 46 <= len(cd) and cd[p:p + 4] == b"PK\x01\x02":
        compress_type = struct.unpack("<H", cd[p + 10:p + 12])[0]
        csize, usize = struct.unpack("<II", cd[p + 20:p + 28])
        nlen, elen, clen = struct.unpack("<HHH", cd[p + 28:p + 34])
        offset = struct.unpack("<I", cd[p + 42:p + 46])[0]
        name = cd[p + 46:p + 46 + nlen].decode("utf-8", "replace")
        extra = cd[p + 46 + nlen:p + 46 + nlen + elen]

        need = (offset == 0xFFFFFFFF or csize == 0xFFFFFFFF or usize == 0xFFFFFFFF)
        if need:
            vals = []
            q = 0
            while q + 4 <= len(extra):
                hid, hsz = struct.unpack("<HH", extra[q:q + 4])
                body = extra[q + 4:q + 4 + hsz]
                if hid == 0x0001:
                    r = 0
                    while r + 8 <= len(body):
                        vals.append(struct.unpack("<Q", body[r:r + 8])[0])
                        r += 8
                    break
                q += 4 + hsz
            # usize/csize 未标记时 vals 只含 offset
            k = 0
            if usize == 0xFFFFFFFF:
                usize = vals[k]; k += 1
            if csize == 0xFFFFFFFF:
                csize = vals[k]; k += 1
            if offset == 0xFFFFFFFF:
                offset = vals[k]; k += 1

        entries[name] = (offset, csize, usize, compress_type)
        p += 46 + nlen + elen + clen
    return entries


def data_bounds(url, header_offset):
    """由 local file header 算出数据起始位置（跳过文件名与 extra）。"""
    hdr = _read(url, header_offset, header_offset + 29)
    if hdr[:4] != b"PK\x03\x04":
        raise RuntimeError("local file header 魔数不对")
    nlen, elen = struct.unpack("<HH", hdr[26:30])
    return header_offset + 30 + nlen + elen


def extract(url, entry, out_path):
    entries = parse_central_directory(url)
    if entry not in entries:
        raise SystemExit(f"条目不存在: {entry}\n可用条目示例: {list(entries)[:10]}")

    header_offset, csize, usize, ctype = entries[entry]
    if ctype != 0:
        raise SystemExit(f"{entry} 是压缩条目（type={ctype}），不能用 Range 直取")

    start = data_bounds(url, header_offset)
    print(f"[*] {entry}: offset={start} size={csize} ({csize/2**30:.2f} GiB)")

    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    done = 0
    chunk = 64 << 20
    with open(out_path, "wb") as f:
        while done < csize:
            n = min(chunk, csize - done)
            f.write(_read(url, start + done, start + done + n - 1))
            done += n
            pct = done * 100 // csize
            print(f"\r    {done/2**30:6.2f}/{csize/2**30:.2f} GiB  {pct:3d}%", end="", flush=True)
    print()
    print(f"[+] 写出 {out_path} ({os.path.getsize(out_path)} 字节)")


def main():
    if len(sys.argv) < 4:
        raise SystemExit(__doc__)
    url = sys.argv[1]
    pairs = sys.argv[2:]
    if len(pairs) % 2:
        raise SystemExit("参数必须成对：<entry> <out>")
    for i in range(0, len(pairs), 2):
        extract(url, pairs[i], pairs[i + 1])


if __name__ == "__main__":
    main()
