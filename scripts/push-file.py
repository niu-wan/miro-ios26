#!/usr/bin/env python3
"""用 GitHub contents API 覆盖仓库里的一个文件（本地没有 clone，只能走 API）。

    ./scripts/push-file.py <本地文件> <仓库内路径> "<提交信息>"

token 从 out/.ghtok 或 $GITHUB_TOKEN 读。
"""
import base64
import json
import os
import subprocess
import sys

REPO = "niu-wan/miro-ios26"


def token():
    t = os.environ.get("GITHUB_TOKEN")
    if not t:
        try:
            t = open("out/.ghtok").read().strip()
        except OSError:
            t = ""
    return t


def api(method, path, payload=None):
    tok = token()
    cmd = ["curl", "-sS", "--http1.1", "--retry", "4", "--retry-all-errors",
           "--max-time", "90", "-X", method,
           "-H", "Accept: application/vnd.github+json",
           "-H", f"Authorization: Bearer {tok}",
           f"https://api.github.com/repos/{REPO}{path}"]
    data = None
    if payload is not None:
        data = json.dumps(payload).encode()
        cmd += ["-H", "Content-Type: application/json", "--data-binary", "@-"]
    p = subprocess.run(cmd, input=data, capture_output=True)
    if p.returncode != 0:
        sys.exit(f"curl 失败: {p.stderr.decode()[:300]}")
    try:
        return json.loads(p.stdout)
    except Exception:
        sys.exit(f"非 JSON 响应: {p.stdout[:300]!r}")


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    local, remote = sys.argv[1], sys.argv[2]
    msg = sys.argv[3] if len(sys.argv) > 3 else f"update {remote}"
    body = open(local, "rb").read()

    cur = api("GET", f"/contents/{remote}?ref=main")
    sha = cur.get("sha") if isinstance(cur, dict) else None
    payload = {
        "message": msg,
        "content": base64.b64encode(body).decode(),
        "branch": "main",
    }
    if sha:
        payload["sha"] = sha
    r = api("PUT", f"/contents/{remote}", payload)
    if isinstance(r, dict) and r.get("content"):
        print(f"✓ {remote} -> {r['content']['sha'][:12]} ({len(body)} B)")
    else:
        print(f"✗ 失败: {json.dumps(r)[:400]}")
        sys.exit(1)


if __name__ == "__main__":
    main()
