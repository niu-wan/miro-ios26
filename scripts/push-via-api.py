#!/usr/bin/env python3
"""通过 GitHub Git Data API 提交文件，绕开 git:// 与 https://github.com。

背景：某些网络环境下 github.com:443 会被掐断（TLS 被中断 / 直接连不上），
但 api.github.com 仍然可用。这时 `git push` 必然失败，而 Git Data API
可以把「blob → tree → commit → 更新 ref」走完，效果等价于一次 push。

用法：
    GH_TOKEN=xxx python3 scripts/push-via-api.py [-m "提交信息"]

文件清单从 scripts/push-offline-work.sh 的 FILES 数组读，保持单一来源。
"""

import base64
import json
import os
import re
import sys
import urllib.error
import urllib.request

REPO = 'niu-wan/miro-ios26'
BRANCH = 'main'
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
API = 'https://api.github.com'


def token():
    t = os.environ.get('GH_TOKEN') or os.environ.get('GITHUB_TOKEN')
    if not t:
        sys.exit('缺 GH_TOKEN')
    return t


def call(method, path, body=None, tok=None, ok=(200, 201)):
    url = path if path.startswith('http') else API + path
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header('Authorization', 'Bearer ' + tok)
    req.add_header('Accept', 'application/vnd.github+json')
    if data:
        req.add_header('Content-Type', 'application/json')
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b'{}')


def file_list():
    """从 push-offline-work.sh 的 FILES 数组读 '本地:仓库' 映射。"""
    import subprocess
    sh = os.path.join(ROOT, 'scripts', 'push-offline-work.sh')
    txt = open(sh, encoding='utf-8').read()
    m = re.search(r'FILES=\((.*?)\n\)', txt, re.S)
    if not m:
        sys.exit('读不到 FILES 数组')
    out = []
    for line in m.group(1).splitlines():
        line = line.strip().strip('"')
        if not line or ':' not in line:
            continue
        a, b = line.split(':', 1)
        out.append((os.path.join(ROOT, a), b))
    return out


def main():
    msg = 'kernel/脚本：更新离线编内核链路'
    if '-m' in sys.argv:
        msg = sys.argv[sys.argv.index('-m') + 1]

    tok = token()

    st, ref = call('GET', '/repos/%s/git/ref/heads/%s' % (REPO, BRANCH), tok=tok)
    if st != 200:
        sys.exit('取 ref 失败 %s %s' % (st, ref))
    base = ref['object']['sha']

    st, commit = call('GET', '/repos/%s/git/commits/%s' % (REPO, base), tok=tok)
    if st != 200:
        sys.exit('取 commit 失败 %s' % (st, commit))
    base_tree = commit['tree']['sha']
    print('  基线 %s（tree %s）' % (base[:7], base_tree[:7]))

    entries = []
    for local, remote in file_list():
        if not os.path.isfile(local):
            print('  跳过（不存在）%s' % remote)
            continue
        raw = open(local, 'rb').read()
        st, blob = call('POST', '/repos/%s/git/blobs' % REPO,
                        {'content': base64.b64encode(raw).decode(), 'encoding': 'base64'}, tok=tok)
        if st not in (200, 201):
            print('  ✗ blob 失败 %s: %s' % (remote, blob))
            continue
        entries.append({'path': remote, 'mode': '100644', 'type': 'blob', 'sha': blob['sha']})
        print('  blob %-40s %6d B' % (remote, len(raw)))

    if not entries:
        sys.exit('没有可提交的文件')

    st, tree = call('POST', '/repos/%s/git/trees' % REPO,
                    {'base_tree': base_tree, 'tree': entries}, tok=tok)
    if st not in (200, 201):
        sys.exit('建 tree 失败 %s %s' % (st, tree))

    st, new_commit = call('POST', '/repos/%s/git/commits' % REPO,
                          {'message': msg, 'tree': tree['sha'], 'parents': [base]}, tok=tok)
    if st not in (200, 201):
        sys.exit('建 commit 失败 %s %s' % (st, new_commit))

    st, upd = call('PATCH', '/repos/%s/git/refs/heads/%s' % (REPO, BRANCH),
                   {'sha': new_commit['sha'], 'force': False}, tok=tok)
    if st not in (200, 201):
        sys.exit('更新 ref 失败 %s %s' % (st, upd))

    print('  已提交 %s -> %s' % (base[:7], new_commit['sha'][:7]))
    return new_commit['sha']


if __name__ == '__main__':
    main()
