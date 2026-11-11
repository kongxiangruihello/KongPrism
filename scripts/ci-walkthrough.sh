#!/bin/bash
# Real-Mac walkthrough of KongPrism (runs in CI on macOS, after the app is built).
#
# A local shadowsocks server (sing-box) plays the provider's node, a local HTTP server plays
# the subscription. The installed app is driven through its kongprism:// links, and every
# result is checked from the outside: the clash API, real HTTP requests through the proxy,
# the files the app writes, screenshots of every settings page.
set -euo pipefail

APP=/Applications/KongPrism.app
CORE="$APP/Contents/MacOS/sing-box"
SUPPORT="$HOME/Library/Application Support/KongPrism"
SHOTS="${SHOTS:-$PWD/build/walkthrough}"
PORT=17899
API=19199
SECRET=ci
SUBPORT=18080
SSPORT=18388
mkdir -p "$SHOTS"
work="$(mktemp -d)"
step() { echo; echo "=== $* ==="; }
api() { curl -sS -m 5 -H "Authorization: Bearer $SECRET" "http://127.0.0.1:$API$1"; }
wait_for() { # wait_for <seconds> <command…>
  local seconds="$1"; shift
  for _ in $(seq 1 "$seconds"); do if "$@" >/dev/null 2>&1; then return 0; fi; sleep 1; done
  echo "超时：$*"; return 1
}
shot() { sleep "${2:-2}"; if screencapture -x "$SHOTS/$1.png"; then echo "截图 $1.png"; else echo "截图失败：$1"; fi; }
link() { echo "→ kongprism://$1"; open "kongprism://$1"; }
quit_app() { osascript -e 'tell application id "com.kongxiangrui.KongPrism" to quit' >/dev/null 2>&1 || true; wait_for 15 bash -c '! pgrep -x KongPrism'; }
rss_mb() { ps -o rss= -p "$1" | awk '{printf "%.0f", $1/1024}'; }

cleanup() {
  local status=$?
  quit_app || pkill -x KongPrism || true
  [[ -n "${SS_PID:-}" ]] && kill "$SS_PID" 2>/dev/null || true
  [[ -n "${HTTP_PID:-}" ]] && kill "$HTTP_PID" 2>/dev/null || true
  echo; echo "--- app.log ---"; tail -60 "$SUPPORT/logs/app.log" 2>/dev/null || true
  echo "--- core.log ---"; tail -30 "$SUPPORT/logs/core.log" 2>/dev/null || true
  [[ $status -eq 0 ]] && echo "走查通过" || echo "走查失败（退出码 ${status}）"
  exit "$status"
}
trap cleanup EXIT

step "节点和订阅（本机模拟机场）"
IP="$(ipconfig getifaddr en0 || ipconfig getifaddr en1 || true)"
[[ -n "$IP" ]] || IP="$(ifconfig | awk '/inet / && $2 != "127.0.0.1" {print $2; exit}')"
echo "本机地址 ${IP}（订阅里不能用 127.0.0.1：那是机场拒绝访问时的占位节点）"
cat > "$work/ss.json" <<JSON
{"log":{"level":"warn"},
 "inbounds":[{"type":"shadowsocks","listen":"0.0.0.0","listen_port":$SSPORT,"method":"aes-128-gcm","password":"ci-password"}],
 "outbounds":[{"type":"direct"}]}
JSON
"$CORE" run -c "$work/ss.json" > "$work/ss.log" 2>&1 &
SS_PID=$!
mkdir -p "$work/www"
cat > "$work/www/sub.yaml" <<YAML
proxies:
  - name: CI-SS
    type: ss
    server: $IP
    port: $SSPORT
    cipher: aes-128-gcm
    password: ci-password
  - name: CI-Fav
    type: ss
    server: $IP
    port: $SSPORT
    cipher: aes-128-gcm
    password: ci-password
YAML
# A Clash rule provider for the custom remote rule-set (target: 拦截).
cat > "$work/www/block.yaml" <<'YAML'
payload:
  - '+.example.com'
  - 'DOMAIN-SUFFIX,example.net'
YAML
(cd "$work/www" && exec python3 -m http.server "$SUBPORT" --bind 127.0.0.1) > "$work/http.log" 2>&1 &
HTTP_PID=$!
wait_for 10 curl -sf "http://127.0.0.1:$SUBPORT/sub.yaml"

step "准备设置（未连接、未加订阅）"
quit_app || true
rm -rf "$SUPPORT"
mkdir -p "$SUPPORT"
PROFILE_ID="7A1D2C3B-0000-4000-8000-00000000C1C1"
SYSTEM_PROXY=false
service="$(networksetup -listallnetworkservices | sed 1d | grep -v '^\*' | head -1)"
if networksetup -setwebproxystate "$service" off 2>/dev/null; then
  SYSTEM_PROXY=true
  echo "networksetup 可直接改系统代理（服务：${service}），一并检查系统代理"
else
  echo "networksetup 需要管理员授权，跳过系统代理检查"
fi
RULE_ID="5E7B1C2D-0000-4000-8000-0000000000AA"
cat > "$SUPPORT/settings.json" <<JSON
{"mixedPort": $PORT, "apiPort": $API, "apiSecret": "$SECRET", "setSystemProxy": $SYSTEM_PROXY,
 "connectOnLaunch": false, "onboardingDone": true, "autoCheckAppUpdates": false, "autoCheckCoreUpdates": false,
 "autoUpdateRules": false, "hotKeyEnabled": false, "selectedProfileID": "$PROFILE_ID",
 "favoriteNodes": ["CI-Fav"],
 "customRuleSets": [{"id": "$RULE_ID", "name": "CI 拦截", "url": "http://127.0.0.1:$SUBPORT/block.yaml", "target": "reject", "enabled": true}]}
JSON
cat > "$SUPPORT/profiles.json" <<JSON
[{"id": "$PROFILE_ID", "name": "CI", "url": "http://127.0.0.1:$SUBPORT/sub.yaml", "nodeCount": 0, "skipped": 0}]
JSON

step "启动 /Applications/KongPrism.app"
open "$APP"
wait_for 20 pgrep -x KongPrism
APP_PID="$(pgrep -x KongPrism | head -1)"
sleep 3
test -f "$SUPPORT/running.marker" && echo "运行标记已创建"

step "更新订阅"
link update
wait_for 40 python3 -c "import json,sys; p=json.load(open(sys.argv[1])); sys.exit(0 if p[0]['nodeCount']==2 else 1)" "$SUPPORT/profiles.json"
python3 -c "import json,sys; p=json.load(open(sys.argv[1]))[0]; print('订阅：', p['nodeCount'], '个节点，格式', p.get('format'), '，UA', p.get('workingUserAgent'))" "$SUPPORT/profiles.json"

step "更新规则集（含自定义远程规则集）"
link rules
wait_for 90 test -f "$SUPPORT/rules/custom-5e7b1c2d.json"
python3 -c "import json,sys; print('自定义规则集：', json.load(open(sys.argv[1])))" "$SUPPORT/rules/custom-5e7b1c2d.json"

step "开启代理"
link connect
wait_for 40 api /version
api /version; echo
python3 - "$SUPPORT/runtime/config.json" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
tags = [o.get("tag") for o in c["outbounds"]]
assert "CI-SS" in tags and "CI-Fav" in tags, tags
sets = [s["tag"] for s in c["route"]["rule_set"]]
assert "custom-5e7b1c2d" in sets, sets
print("配置：节点", [t for t in tags if t.startswith("CI-")], "，规则集", sets)
PY
if [[ "$SYSTEM_PROXY" == true ]]; then
  scutil --proxy | tee "$work/proxy.txt"
  grep -q "HTTPProxy : 127.0.0.1" "$work/proxy.txt"
  grep -q "HTTPPort : $PORT" "$work/proxy.txt"
  echo "✅ 系统代理指向 127.0.0.1:$PORT"
fi

step "经 KongPrism 访问 Google（走节点）"
code="$(curl -sS -m 20 -x "http://127.0.0.1:$PORT" -o /dev/null -w '%{http_code}' https://www.google.com/generate_204)"
echo "HTTP $code"; test "$code" = 204
api /connections | python3 -c 'import json,sys; c=json.load(sys.stdin); print("经过内核的下载字节：", c["downloadTotal"]); assert c["downloadTotal"] > 0'

step "自定义规则集拦截 example.com"
# Through the HTTP proxy a rejected connection comes back as 502 (or no response at all).
code="$(curl -sS -m 10 -x "http://127.0.0.1:$PORT" -o /dev/null -w '%{http_code}' http://www.example.com/ 2>"$work/reject.txt" || true)"
echo "example.com 经代理：HTTP ${code} $(cat "$work/reject.txt")"
case "$code" in 2*|3*) echo "❌ example.com 没有被拦截"; exit 1 ;; esac
echo "✅ 已拦截"

step "切换节点（收藏的 CI-Fav）"
link "node/CI-Fav"
now_selected() { api /proxies | python3 -c 'import json,sys; print(json.load(sys.stdin)["proxies"]["节点选择"].get("now",""))'; }
selected_is_fav() { [[ "$(now_selected)" == CI-Fav ]]; }
if ! wait_for 15 selected_is_fav; then echo "节点选择现在是：$(now_selected)"; exit 1; fi
echo "✅ 节点选择 → CI-Fav"
code="$(curl -sS -m 20 -x "http://127.0.0.1:$PORT" -o /dev/null -w '%{http_code}' https://www.google.com/generate_204)"
echo "经 CI-Fav：HTTP $code"; test "$code" = 204

step "全局模式"
link "mode/global"
mode_is_global() { api /configs | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin)["mode"].lower()=="global" else 1)'; }
if ! wait_for 10 mode_is_global; then api /configs; exit 1; fi
echo "✅ 出站模式：全局"
link "mode/rule"

step "内存（已连接）"
CORE_PID="$(pgrep -f "$SUPPORT/runtime/config.json" | head -1 || pgrep -x sing-box | grep -v "^$SS_PID$" | head -1)"
app_mb="$(rss_mb "$APP_PID")"; core_mb="$(rss_mb "$CORE_PID")"
echo "KongPrism ${app_mb} MB，sing-box ${core_mb} MB"
test "$app_mb" -lt 250 || { echo "❌ KongPrism 占用内存过多"; exit 1; }
test "$core_mb" -lt 150 || { echo "❌ sing-box 占用内存过多"; exit 1; }

step "设置窗口各页截图"
for tab in profiles nodes rules network stats general updates; do
  link "settings/$tab"
  shot "settings-$tab"
done
link onboarding
shot onboarding

step "问题报告"
rm -f "$HOME"/Desktop/KongPrism-问题报告-*.zip
link report
wait_for 60 bash -c 'ls "$HOME"/Desktop/KongPrism-问题报告-*.zip'
zip="$(ls "$HOME"/Desktop/KongPrism-问题报告-*.zip | head -1)"
unzip -l "$zip"
mkdir -p "$work/report" && (cd "$work/report" && unzip -q "$zip")
cat "$work"/report/*/诊断.txt
grep -q "经 KongPrism 访问 Google（走节点）：成功" "$work"/report/*/诊断.txt
grep -q "CI 拦截→拦截" "$work"/report/*/设置摘要.txt
test -f "$work"/report/*/订阅样本*.yaml
if grep -q "ci-password" "$work"/report/*/订阅样本*.yaml; then echo "❌ 订阅样本没有脱敏"; exit 1; fi
echo "✅ 问题报告完整且已脱敏"

step "关闭代理，系统代理复原"
link disconnect
wait_for 15 bash -c "! curl -s -m 2 http://127.0.0.1:$API/version"
if [[ "$SYSTEM_PROXY" == true ]]; then
  scutil --proxy | tee "$work/proxy2.txt"
  if grep -q "HTTPPort : $PORT" "$work/proxy2.txt"; then echo "❌ 系统代理没有复原"; exit 1; fi
  echo "✅ 系统代理已复原"
fi

step "异常退出记录"
kill -9 "$APP_PID"
sleep 1
test -f "$SUPPORT/running.marker"
open "$APP"
wait_for 20 grep -q "上次异常退出" "$SUPPORT/logs/app.log"
echo "✅ 重新打开后识别到上次异常退出"
sleep 2
quit_app
test ! -f "$SUPPORT/running.marker"
echo "✅ 正常退出后运行标记已删除"

step "全部通过"
ls -la "$SHOTS"
