#!/bin/sh
# 沙箱里没有 /dev/bus/usb，直接调 fastboot 永远看不到设备。
# 必须走 scripts/shim/fastboot → 宿主上的 host-agent.py（它有 USB 权限）。
#   . ./scripts/fb-env.sh
# 口令：$FB_AGENT_TOKEN，或 out/.fbtok，默认用安装桥接时打印的那个。
_self=${BASH_SOURCE[0]:-$0}
_here=$(cd "$(dirname "$_self")" && pwd)
case ":$PATH:" in
	*":$_here/shim:"*) ;;
	*) PATH=$_here/shim:$PATH ;;
esac
export PATH
export FB_AGENT_URL=${FB_AGENT_URL:-http://127.0.0.1:8799}
if [ -z "${FB_AGENT_TOKEN:-}" ]; then
	if [ -f "$_here/../out/.fbtok" ]; then
		FB_AGENT_TOKEN=$(cat "$_here/../out/.fbtok")
	else
		FB_AGENT_TOKEN=83f9179e9ecc8e0c
	fi
fi
export FB_AGENT_TOKEN
