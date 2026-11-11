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
step() { echo; echo "=== $* === $(date +%H:%M:%S)"; }
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
# download.ci.test → 127.0.0.1 on the "provider" side, so a download can go through the node to the local server.
cat > "$work/ss.json" <<JSON
{"log":{"level":"warn"},
 "dns":{"servers":[{"type":"hosts","tag":"hosts","predefined":{"download.ci.test":["127.0.0.1"]}},{"type":"local","tag":"local"}]},
 "inbounds":[{"type":"shadowsocks","listen":"0.0.0.0","listen_port":$SSPORT,"method":"aes-128-gcm","password":"ci-password"}],
 "outbounds":[{"type":"direct"}],
 "route":{"default_domain_resolver":"local","rules":[{"domain":["download.ci.test"],"action":"resolve","server":"hosts"}]}}
JSON
"$CORE" run -c "$work/ss.json" > "$work/ss.log" 2>&1 &
SS_PID=$!
mkdir -p "$work/www"
cat > "$work/www/sub.yaml" <<YAML
proxies:
  - name: 有效期2029-11-09, 剩余 168.16 GB
    type: ss
    server: $IP
    port: $SSPORT
    cipher: aes-128-gcm
    password: ci-password
  - name: CI-Expensive 倍率:3
    type: ss
    server: $IP
    port: $SSPORT
    cipher: aes-128-gcm
    password: ci-password
  - name: CI 日本 01
    type: ss
    server: $IP
    port: $SSPORT
    cipher: aes-128-gcm
    password: ci-password
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
cp "$work/www/block.yaml" "$work/www/block2.yaml"
mkfile -n 200m "$work/www/big.bin"
python3 scripts/ci-server.py "$SUBPORT" "$work/www" > "$work/http.log" 2>&1 &
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
LIMITED_ID="7A1D2C3B-0000-4000-8000-00000000C2C2"
FLAKY_ID="7A1D2C3B-0000-4000-8000-00000000C4C4"
REFUSED_ID="7A1D2C3B-0000-4000-8000-00000000C3C3"
# A stand-in iCloud Drive folder (the runner has no iCloud account): ICloudSync only needs the folder.
CLOUD="$HOME/Library/Mobile Documents/com~apple~CloudDocs"
mkdir -p "$CLOUD"
rm -rf "$CLOUD/KongPrism"
NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat > "$SUPPORT/settings.json" <<JSON
{"mixedPort": $PORT, "apiPort": $API, "apiSecret": "$SECRET", "setSystemProxy": $SYSTEM_PROXY,
 "connectOnLaunch": false, "onboardingDone": true, "autoCheckAppUpdates": false, "autoCheckCoreUpdates": false,
 "autoUpdateRules": false, "hotKeyEnabled": false, "selectedProfileID": "$PROFILE_ID",
 "favoriteNodes": ["CI-Fav"], "maxMultiplier": 1, "iCloudSync": true, "proxyDomains": ["ci.test"], "githubToken": "ci-token-123",
 "customRuleSets": [{"id": "$RULE_ID", "name": "CI 拦截", "url": "http://127.0.0.1:$SUBPORT/block.yaml", "target": "reject", "enabled": true}]}
JSON
cat > "$SUPPORT/profiles.json" <<JSON
[{"id": "$PROFILE_ID", "name": "CI", "url": "http://127.0.0.1:$SUBPORT/sub.yaml", "nodeCount": 0, "skipped": 0},
 {"id": "$LIMITED_ID", "name": "CI 限流", "url": "http://127.0.0.1:$SUBPORT/limited.yaml", "nodeCount": 0, "skipped": 0, "updatedAt": "$NOW_ISO"},
 {"id": "$REFUSED_ID", "name": "CI 拒绝", "url": "http://127.0.0.1:$SUBPORT/refused.yaml", "nodeCount": 0, "skipped": 0, "updatedAt": "$NOW_ISO"},
 {"id": "$FLAKY_ID", "name": "CI 偶发", "url": "http://127.0.0.1:$SUBPORT/flaky.yaml", "nodeCount": 0, "skipped": 0, "updatedAt": "$NOW_ISO"}]
JSON
defaults write com.kongxiangrui.KongPrism lastSeenVersion 0.6.0
defaults write com.kongxiangrui.KongPrism subscriptionRetrySeconds -float 5
defaults write com.kongxiangrui.KongPrism ciTestActions -bool true

step "启动 /Applications/KongPrism.app"
open "$APP"
wait_for 20 pgrep -x KongPrism
APP_PID="$(pgrep -x KongPrism | head -1)"
sleep 3
test -f "$SUPPORT/running.marker" && echo "运行标记已创建"

step "订阅链接和令牌的存放方式"
# Ad-hoc signed (CI and current releases): kept in the files, because the keychain would ask for the
# password after every update. With a Developer ID signature they move to the keychain.
wait_for 10 grep -q "敏感信息：" "$SUPPORT/logs/app.log"
grep "敏感信息：" "$SUPPORT/logs/app.log" | tail -1 | cut -c21-
if codesign -dv "$APP" 2>&1 | grep -q "TeamIdentifier=not set"; then
  grep -q "这一版没有开发者 ID 签名" "$SUPPORT/logs/app.log"
  python3 -c "import json,sys; p=json.load(open(sys.argv[1])); assert p[0]['url'].endswith('/sub.yaml') and not p[0].get('urlInKeychain')" "$SUPPORT/profiles.json"
  echo "✅ 未用开发者 ID 签名：链接留在本机文件（不会每次更新都要密码）"
else
  python3 -c "import json,sys; p=json.load(open(sys.argv[1])); assert 'url' not in p[0] and p[0]['urlInKeychain']" "$SUPPORT/profiles.json"
  echo "✅ 开发者 ID 签名：链接已移进钥匙串"
fi
stat -f "%Sp %N" "$SUPPORT/profiles.json" "$SUPPORT/settings.json"

step "更新订阅"
link update
wait_for 40 python3 -c "import json,sys; p=json.load(open(sys.argv[1])); sys.exit(0 if p[0]['nodeCount']==5 else 1)" "$SUPPORT/profiles.json"
python3 - "$SUPPORT/profiles.json" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))[0]
print("订阅：", p["nodeCount"], "个条目，格式", p.get("format"), "，UA", p.get("workingUserAgent"), "，用量", p.get("usage"))
usage = p.get("usage") or {}
assert usage.get("remaining", 0) > 168 * 1024**3, "没有从信息条目读出剩余流量"
assert "expire" in usage, "没有从信息条目读出到期日"
print("✅ 从“有效期…, 剩余…”条目读出了到期日和剩余流量")
PY

step "更新规则集（含自定义远程规则集）"
link rules
wait_for 90 test -f "$SUPPORT/rules/custom-5e7b1c2d.json"
python3 -c "import json,sys; print('自定义规则集：', json.load(open(sys.argv[1])))" "$SUPPORT/rules/custom-5e7b1c2d.json"

step "内核日志轮换"
python3 - "$SUPPORT/logs/core.log" <<'PY'
import sys
line = "+0800 2026-01-01 00:00:00 ERROR [1 5.0s] connection: open connection to rotation.example:443 using outbound/trojan[轮换前的节点]: dial tcp 203.0.113.1:443: i/o timeout\n"
with open(sys.argv[1], "w") as f:
    f.write(line * (6_000_000 // len(line.encode()) + 1))
PY
ls -la "$SUPPORT/logs"

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
groups = {o["tag"]: o.get("outbounds", []) for o in c["outbounds"] if o.get("type") in ("urltest", "selector")}
auto = groups["自动选择"]
assert "CI-Expensive 倍率:3" not in auto and "CI-SS" in auto, auto
assert "CI-Expensive 倍率:3" in groups["节点选择"], groups["节点选择"]
assert not any(t.startswith("有效期") for t in tags), "信息条目不应进配置"
print("✅ 倍率上限 1：自动选择不含 CI-Expensive（3 倍），手选列表里仍有")
PY
test -f "$SUPPORT/logs/core.log.1" && grep -q "轮换前的节点" "$SUPPORT/logs/core.log.1"
test "$(stat -f %z "$SUPPORT/logs/core.log")" -lt 1000000
echo "✅ 超过 5 MB 的内核日志变成 core.log.1 保留，新日志从头写"
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

step "订阅被拒后自动更新暂停（模拟 429 和 403）"
hits() { curl -s "http://127.0.0.1:$SUBPORT/count?path=$1"; }
l0="$(hits /limited.yaml)"; r0="$(hits /refused.yaml)"
link "update?auto=1"
paused() { python3 - "$SUPPORT/profiles.json" "$1" <<'PY'
import json, sys, datetime
p = {x["id"]: x for x in json.load(open(sys.argv[1]))}[sys.argv[2]]
until = p.get("pausedUntil")
if not until: sys.exit(1)
left = datetime.datetime.fromisoformat(until.replace("Z", "+00:00")) - datetime.datetime.now(datetime.timezone.utc)
print(f"{p['name']}：暂停 {left.total_seconds() / 60:.0f} 分钟；错误：{p.get('lastError', '')[:90]}")
PY
}
wait_for 30 paused "$LIMITED_ID"
wait_for 30 paused "$REFUSED_ID"
paused "$LIMITED_ID"; paused "$REFUSED_ID"
l1="$(hits /limited.yaml)"; r1="$(hits /refused.yaml)"
echo "自动更新的请求数：限流 $((l1 - l0)) 次，拒绝 $((r1 - r0)) 次"
test $((l1 - l0)) -eq 1 || { echo "❌ 429 之后不应再换身份或线路重试"; exit 1; }
test $((r1 - r0)) -ge 1 && test $((r1 - r0)) -le 6 || { echo "❌ 403 时自动更新最多试 3 种身份 × 2 条线路"; exit 1; }
grep -q "订阅“CI 限流”被拒绝，自动更新暂停 10 分钟" "$SUPPORT/logs/app.log"
grep -q "订阅“CI 拒绝”被拒绝，自动更新暂停 180 分钟" "$SUPPORT/logs/app.log"
python3 -c "import json,sys; p={x['id']:x for x in json.load(open(sys.argv[1]))}; assert '访问受限 REF: CI-TEST' in p[sys.argv[2]]['lastError']" "$SUPPORT/profiles.json" "$REFUSED_ID"
link "update?auto=1"
sleep 6
test "$(hits /limited.yaml)" = "$l1" && test "$(hits /refused.yaml)" = "$r1" || { echo "❌ 暂停期间又请求了"; exit 1; }
echo "✅ 429 只请求 1 次并按 Retry-After 暂停（最短 10 分钟）；403 暂停 3 小时并记下“访问受限”；暂停期间不再请求"

step "网络一时出错：稍后自动重试（模拟 503）"
retried() { python3 -c "import json,sys; p={x['id']:x for x in json.load(open(sys.argv[1]))}[sys.argv[2]]; sys.exit(0 if p['nodeCount'] == 5 and not p.get('lastError') else 1)" "$SUPPORT/profiles.json" "$FLAKY_ID"; }
wait_for 40 retried
grep -q "订阅“CI 偶发”暂时连不上，5 秒后重试" "$SUPPORT/logs/app.log"
echo "✅ 503 后没有暂停，5 秒（正式版为 10 分钟）后重试成功，旧错误已清除；请求 $(hits /flaky.yaml) 次"

step "断开旧连接（唤醒 / 切网后的恢复）"
# -p: a CONNECT tunnel, like browsers use for HTTPS (a plain-HTTP proxy request is kept alive by the inbound).
curl -sS -p -m 70 -x "http://127.0.0.1:$PORT" -o /dev/null "http://127.0.0.1:$SUBPORT/slow" 2>/dev/null &
SLOW=$!
sleep 3
api /connections | python3 -c 'import json,sys; c=json.load(sys.stdin)["connections"] or []; print("当前连接", len(c)); assert any(x["metadata"].get("destinationPort") in ("18080", 18080) for x in c)'
link recover
if ! wait_for 10 bash -c "! kill -0 $SLOW 2>/dev/null"; then
  api /connections | python3 -c 'import json,sys; c=json.load(sys.stdin)["connections"] or []; print("仍在的连接：", [(x["metadata"].get("host") or x["metadata"].get("destinationIP"), x["metadata"].get("destinationPort")) for x in c])'
  echo "❌ 旧连接没有被断开"; exit 1
fi
wait_for 15 grep -q "链接动作后已断开旧连接并重新测速" "$SUPPORT/logs/app.log"
echo "✅ 长连接被断开（应用会立即重连），并重新测速：$(grep "链接动作后已断开旧连接" "$SUPPORT/logs/app.log" | tail -1 | cut -c21-)"

step "多次改动合并成一次重载，并测断线时长"
n0="$(grep -c "sing-box 已启动" "$SUPPORT/logs/app.log")"
# In parallel (all within the 1.2 s window); wait only for these three, not the servers in the background.
open "kongprism://reload" & r1=$!; open "kongprism://reload" & r2=$!; open "kongprism://reload" & r3=$!
wait "$r1" "$r2" "$r3"
python3 - "$API" "$SECRET" <<'PY'
import sys, time, urllib.request
port, secret = sys.argv[1], sys.argv[2]
def up():
    try:
        request = urllib.request.Request(f"http://127.0.0.1:{port}/version", headers={"Authorization": f"Bearer {secret}"})
        urllib.request.urlopen(request, timeout=0.5)
        return True
    except Exception:
        return False
start = time.time(); down = None
while time.time() - start < 20:
    if down is None and not up(): down = time.time()
    elif down is not None and up(): break
    time.sleep(0.05)
assert down is not None, "内核没有重载"
gap = time.time() - down
print(f"重载断线 {gap:.2f} 秒")
assert gap < 5, "重载断线超过 5 秒"
PY
sleep 4
n1="$(grep -c "sing-box 已启动" "$SUPPORT/logs/app.log")"
echo "3 次重载请求 → 内核重启 $((n1 - n0)) 次"
test $((n1 - n0)) -eq 1 || { echo "❌ 应合并成一次重启"; exit 1; }
wait_for 20 api /version
echo "✅ 3 次改动只重启 1 次"

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

step "有流量时的耗电：经节点下载 200 MB"
cpu() { ps -o cputime= -p "$1" | python3 -c 'import sys; p=sys.stdin.read().strip().replace(",",".").split(":"); print(sum(float(x)*60**i for i,x in enumerate(reversed(p))))'; }
CORE_PID="$(pgrep -f "$SUPPORT/runtime/config.json" | head -1)"
a0="$(cpu "$APP_PID")"; c0="$(cpu "$CORE_PID")"; s0="$(cpu "$SS_PID")"; t0="$(python3 -c 'import time; print(time.time())')"
result="$(curl -sS -m 120 -x "http://127.0.0.1:$PORT" -o /dev/null -w '%{http_code} %{size_download}' "http://download.ci.test:$SUBPORT/big.bin")"
t1="$(python3 -c 'import time; print(time.time())')"
a1="$(cpu "$APP_PID")"; c1="$(cpu "$CORE_PID")"; s1="$(cpu "$SS_PID")"
python3 - "$result" "$t0" "$t1" "$a0" "$a1" "$c0" "$c1" "$s0" "$s1" "$(rss_mb "$APP_PID")" "$(rss_mb "$CORE_PID")" <<'PY'
import sys
code, size = sys.argv[1].split()
t0, t1, a0, a1, c0, c1, s0, s1 = map(float, sys.argv[2:10])
app_mb, core_mb = sys.argv[10:12]
mb = int(size) / 1024 / 1024
print(f"下载 {mb:.0f} MB，HTTP {code}，用时 {t1 - t0:.1f} 秒（{mb / (t1 - t0):.0f} MB/s）")
print(f"CPU 时间：KongPrism {a1 - a0:.2f} 秒，sing-box（KongPrism 内核）{c1 - c0:.2f} 秒，节点端 {s1 - s0:.2f} 秒；内存 App {app_mb} MB，内核 {core_mb} MB")
assert code == "200" and int(size) == 200 * 1024 * 1024, "下载不完整"
assert s1 - s0 > 0.05, "流量没有经过节点"
assert a1 - a0 < 1.0, "下载时 KongPrism 本身不应占用 CPU（流量只经过内核）"
assert c1 - c0 < 20, "内核转发 200 MB 用的 CPU 过多"
assert int(core_mb) < 200, "下载时内核内存过多"
print("✅ 下载走节点；App 几乎不占 CPU；内核 CPU 与内存在上限内")
PY

step "设置窗口各页截图"
for tab in profiles nodes rules network stats general updates; do
  link "settings/$tab"
  shot "settings-$tab"
done
link onboarding
shot onboarding
link whatsnew
shot whatsnew

step "问题报告"
# Use a node whose name says Japan: the exit (GitHub's Mac runners are in the US) should be flagged.
link "node/CI 日本 01"
sleep 2
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
python3 - "$work"/report/*/core.log "$work"/report/*/app.log "$work"/report/*/诊断.txt <<'PY'
import ipaddress, re, sys
found = set()
for path in sys.argv[1:]:
    for text in re.findall(r"(?<![0-9.])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![0-9.])", open(path, encoding="utf-8").read()):
        try:
            address = ipaddress.ip_address(text)
        except ValueError:
            continue
        if address.is_global:
            found.add(text)
assert not found, f"报告里还有公网地址：{sorted(found)[:5]}"
print("✅ 报告里的日志和诊断没有公网 IP（已替换成 ip-1、ip-2…）")
PY
grep -q "出口：" "$work"/report/*/诊断.txt
grep -q "AI 服务出口：" "$work"/report/*/诊断.txt
test "$(grep -c "体检 " "$work"/report/*/诊断.txt)" -eq 8
grep -q "体检 www.baidu.com → 直连" "$work"/report/*/诊断.txt
grep -q "体检 www.google.com → 节点选择" "$work"/report/*/诊断.txt
echo "✅ 诊断含 AI 服务出口和 8 个常用网站体检（百度直连、Google 走节点）"
grep -q "节点名称是日本，出口 IP 归属" "$work"/report/*/诊断.txt || echo "（出口没有判为不一致：$(grep "出口：" "$work"/report/*/诊断.txt)）"
echo "出口查询服务：$(defaults read com.kongxiangrui.KongPrism exitLookupService)"
echo "✅ 问题报告完整、日志已脱敏，诊断含出口信息"

step "iCloud 同步（模拟另一台 Mac 写入）"
REMOTE_RULE="6A7B8C9D-0000-4000-8000-0000000000BB"
python3 - "$CLOUD/KongPrism/sync.json" "$RULE_ID" "$REMOTE_RULE" "$SUBPORT" <<'PY'
import json, sys, datetime, os
path, local_rule, remote_rule, port = sys.argv[1:5]
future = (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
os.makedirs(os.path.dirname(path), exist_ok=True)
json.dump({"version": 1, "updatedAt": future, "device": "另一台 Mac", "profiles": [],
           "directDomains": ["example.cn"], "proxyDomains": [], "rulesChangedAt": future,
           "favoriteNodes": ["CI-SS"], "serviceTargets": {"ai": "no-hk"},
           "customRuleSets": [
               {"id": local_rule, "name": "CI 拦截", "url": f"http://127.0.0.1:{port}/block.yaml", "target": "reject", "enabled": True},
               {"id": remote_rule, "name": "另一台 Mac 的规则", "url": f"http://127.0.0.1:{port}/block2.yaml", "target": "direct", "enabled": True}]},
          open(path, "w"), ensure_ascii=False)
PY
link sync
wait_for 30 test -f "$SUPPORT/rules/custom-6a7b8c9d.json"
python3 - "$SUPPORT/settings.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
assert s["favoriteNodes"] == ["CI-SS"], s["favoriteNodes"]
assert s["serviceTargets"].get("ai") == "no-hk", s["serviceTargets"]
assert [r["name"] for r in s["customRuleSets"]] == ["CI 拦截", "另一台 Mac 的规则"], s["customRuleSets"]
assert s["directDomains"] == ["example.cn"]
print("✅ 收到另一台 Mac 的收藏、按服务分流和自定义规则集（新规则集已下载）")
PY
written_back() { python3 -c "import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))['device'] != '另一台 Mac' else 1)" "$CLOUD/KongPrism/sync.json"; }
wait_for 20 written_back
python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert d['device'] != '另一台 Mac' and d['favoriteNodes'] == ['CI-SS'] and len(d['customRuleSets']) == 2; print('✅ 本机写回 iCloud：', d['device'])" "$CLOUD/KongPrism/sync.json"

step "菜单内容"
sleep 3   # the iCloud sync above reloads the core
wait_for 20 api /version
rm -f "$SUPPORT/menu.txt"
link menu
wait_for 15 test -f "$SUPPORT/menu.txt"
cat "$SUPPORT/menu.txt"
python3 - "$SUPPORT/menu.txt" <<'PY'
import sys
lines = open(sys.argv[1], encoding="utf-8").read().split("\n")
top = [l for l in lines if not l.startswith("  ")]
print("第一层", len(top), "项（含分隔线）")
assert len(top) <= 14, "第一层菜单太长"
assert any(l.startswith("工具") for l in top)
for name in ["诊断连接", "生成问题报告", "复制终端代理命令"]:
    assert not any(l.startswith(name) for l in top), f"{name} 应在“工具”里"
    assert any(l.strip().startswith(name) for l in lines), name
nodes = [l.strip() for l in lines if l.startswith("  ")]
fav = next(i for i, l in enumerate(nodes) if l.startswith("★ CI-SS"))
other = next(i for i, l in enumerate(nodes) if l.startswith("CI-Fav"))
assert fav < other, "收藏的节点排在前面"
print("✅ 菜单：第一层精简，工具在子菜单，收藏排在最前")
assert any(l.startswith("✨ ") for l in top), "更新后的新功能提示"
assert any("被机场限流" in l for l in lines), "订阅错误用简短说法"
timing = dict(part.split("=") for part in next(l for l in lines if l.startswith("#timing")).split()[1:])
print(f"菜单构建 {float(timing['build_ms']):.1f} ms，向内核取数据 {float(timing['refresh_ms']):.1f} ms")
assert float(timing["build_ms"]) < 100, "菜单构建太慢"
assert float(timing["refresh_ms"]) < 500, "向内核取数据太慢"
print("✅ 有新功能提示；订阅错误简短；菜单打开快")
PY

step "AI 服务出口检测入口"
python3 - "$SUPPORT/runtime/config.json" "$API" <<'PY'
import json, sys
c = json.load(open(sys.argv[1])); port = int(sys.argv[2]) + 1
inbound = next(i for i in c["inbounds"] if i["tag"] == "ai-check")
assert inbound["listen"] == "127.0.0.1" and inbound["listen_port"] == port, inbound
rule = next(r for r in c["route"]["rules"] if r.get("inbound") == ["ai-check"])
assert rule["outbound"] == "🤖 AI 服务", rule   # iCloud set AI to “自动（排除香港）” above
print("✅ 检测入口只在本机监听，流量按 AI 服务的线路出去")
PY
country="$(curl -sS -m 15 -x "http://127.0.0.1:$((API + 1))" https://ipinfo.io/json | python3 -c 'import json,sys; print(json.load(sys.stdin).get("country"))')"
echo "AI 服务出口国家：$country"; test -n "$country"

step "用电池时少测速"
interval() { python3 -c "import json,sys; c=json.load(open(sys.argv[1])); print(next(o['interval'] for o in c['outbounds'] if o['tag'] == '自动选择'))" "$SUPPORT/runtime/config.json"; }
echo "接电源：$(interval)"; test "$(interval)" = "10m"
defaults write com.kongxiangrui.KongPrism forcePowerSaving -bool true
link reload
sleep 4; wait_for 20 api /version
echo "用电池（模拟）：$(interval)"; test "$(interval)" = "30m"
defaults delete com.kongxiangrui.KongPrism forcePowerSaving
link reload
sleep 4; wait_for 20 api /version
test "$(interval)" = "10m"
echo "✅ 用电池时自动选择每 30 分钟测一次，接电源恢复 10 分钟"

step "设置导出与导入"
link "export?path=$work/backup-nolinks.json"
link "export?path=$work/backup.json&links=1"
wait_for 10 test -f "$work/backup.json"
wait_for 10 test -f "$work/backup-nolinks.json"
python3 - "$work/backup.json" "$work/backup-nolinks.json" "$SUBPORT" <<'PY'
import json, sys, uuid
full = json.load(open(sys.argv[1])); bare = json.load(open(sys.argv[2]))
assert full["includesLinks"] and any(p.get("url", "").endswith("/sub.yaml") for p in full["profiles"])
assert not bare["includesLinks"] and not any(p.get("url") for p in bare["profiles"]), "不含链接的导出里不应有订阅链接"
assert full["customRuleSets"] and "fileExtension" not in full["customRuleSets"][0]
full["profiles"].append({"id": str(uuid.uuid4()).upper(), "name": "CI 导入", "url": f"http://127.0.0.1:{sys.argv[3]}/sub.yaml?imported=1"})
full["favoriteNodes"] = ["CI 日本 01"]
json.dump(full, open(sys.argv[1], "w"), ensure_ascii=False)
print("✅ 导出：含链接 / 不含链接两种都对")
PY
link "import?path=$work/backup.json"
imported() { python3 -c "import json,sys; p=[x for x in json.load(open(sys.argv[1])) if x['name']=='CI 导入']; sys.exit(0 if p and p[0]['nodeCount']==5 else 1)" "$SUPPORT/profiles.json"; }
wait_for 30 imported
python3 -c "import json,sys; assert json.load(open(sys.argv[1]))['favoriteNodes'] == ['CI 日本 01']" "$SUPPORT/settings.json"
echo "✅ 导入：新增的订阅已下载（5 个节点），收藏按文件替换"

step "增强模式（TUN）：在 App 里开启"
link "tun/on"
wait_for 60 bash -c 'test -f /etc/sudoers.d/kongprism'
wait_for 40 bash -c 'route -n get 1.1.1.1 | grep -q "interface: utun"'
route -n get 1.1.1.1 | grep interface
sleep 3
code="$(curl -sS -m 20 -o /dev/null -w '%{http_code}' https://www.apple.com/library/test/success.html)"
echo "不设代理直接访问：HTTP $code"; test "$code" = 200
api /connections | python3 -c 'import json,sys; c=json.load(sys.stdin); print("经过（root）内核的下载字节：", c["downloadTotal"]); assert c["downloadTotal"] > 0'
TUN_PID="$(sudo cat "/Library/Application Support/KongPrismTUN/sing-box.pid")"
t0="$(ps -o cputime= -p "$TUN_PID" | python3 -c 'import sys; p=sys.stdin.read().strip().replace(",",".").split(":"); print(sum(float(x)*60**i for i,x in enumerate(reversed(p))))')"
sleep 30
t1="$(ps -o cputime= -p "$TUN_PID" | python3 -c 'import sys; p=sys.stdin.read().strip().replace(",",".").split(":"); print(sum(float(x)*60**i for i,x in enumerate(reversed(p))))')"
python3 -c "import sys; d=float(sys.argv[2])-float(sys.argv[1]); print(f'增强模式空闲 30 秒：root 内核 CPU {d:.2f} 秒'); assert d < 1.5" "$t0" "$t1"
link "tun/off"
wait_for 30 bash -c '! route -n get 1.1.1.1 | grep -q "interface: utun"'
wait_for 30 api /version
echo "✅ App 内开启增强模式：全部流量经过内核、空闲省电；关闭后路由恢复、回到系统代理模式"

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

step "深色模式截图"
defaults write com.kongxiangrui.KongPrism appearance dark
open "$APP"
wait_for 20 pgrep -x KongPrism
sleep 3
link connect
wait_for 40 api /version
u0="$(grep -c "订阅 127.0.0.1：Clash，5 个节点" "$SUPPORT/logs/app.log")"
link update
wait_for 30 bash -c "test \$(grep -c '订阅 127.0.0.1：Clash，5 个节点' '$SUPPORT/logs/app.log') -gt $u0"
echo "✅ 重新打开后读出保存的订阅链接，订阅更新成功"
for tab in profiles nodes rules network general updates; do
  link "settings/$tab"
  shot "dark-settings-$tab"
done
link onboarding
shot dark-onboarding
quit_app
defaults delete com.kongxiangrui.KongPrism appearance

step "更新后连续启动失败 → 提供退回上一个版本"
# Pretend 0.6.0 was the last good version and the installer kept it as the backup.
mkdir -p "$SUPPORT/updates/previous"
ditto "$APP" "$SUPPORT/updates/previous/KongPrism.app"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 0.6.0" "$SUPPORT/updates/previous/KongPrism.app/Contents/Info.plist"
defaults write com.kongxiangrui.KongPrism lastGoodVersion 0.6.0
defaults write com.kongxiangrui.KongPrism abnormalLaunches -int 0
for attempt in 1 2 3; do
  open "$APP"
  wait_for 20 pgrep -x KongPrism
  sleep 4
  if [[ $attempt -lt 3 ]]; then pkill -9 -x KongPrism; sleep 1; fi
done
wait_for 15 grep -q "连续 2 次没有正常运行，提供退回 0.6.0" "$SUPPORT/logs/app.log"
shot rollback-offer 3
echo "✅ 同一版本连续 2 次异常退出后，提示退回 0.6.0（截图 rollback-offer）"
pkill -9 -x KongPrism || true
sleep 1
rm -rf "$SUPPORT/updates/previous" "$SUPPORT/running.marker"
defaults delete com.kongxiangrui.KongPrism lastGoodVersion || true
defaults delete com.kongxiangrui.KongPrism abnormalLaunches || true
for account in "subscription:$PROFILE_ID" "subscription:$LIMITED_ID" "subscription:$REFUSED_ID" "subscription:$FLAKY_ID" github-token; do
  security delete-generic-password -s com.kongxiangrui.KongPrism -a "$account" >/dev/null 2>&1 || true
done
defaults delete com.kongxiangrui.KongPrism lastSeenVersion >/dev/null 2>&1 || true
defaults delete com.kongxiangrui.KongPrism subscriptionRetrySeconds >/dev/null 2>&1 || true

step "在线更新：内核没变时只下载精简包"
open "$APP"
wait_for 20 pgrep -x KongPrism
sleep 3
feed="$work/www/feed"; mkdir -p "$feed"
new="$work/new/KongPrism.app"; mkdir -p "$work/new"
ditto "$APP" "$new"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 9.9.9" -c "Set :CFBundleVersion 999" "$new/Contents/Info.plist"
codesign --force --sign - --identifier com.kongxiangrui.KongPrism "$new"   # the core inside stays as it is
codesign --verify --deep --strict "$new"
(cd "$work/new" && ditto -c -k --keepParent KongPrism.app "$feed/KongPrism-9.9.9.zip")
rm "$new/Contents/MacOS/sing-box"
(cd "$work/new" && ditto -c -k --keepParent KongPrism.app "$feed/KongPrism-9.9.9-lite.zip")
python3 - "$feed" "$APP/Contents/MacOS/sing-box" <<'PY'
import hashlib, json, os, sys
feed, core = sys.argv[1:3]
sha = lambda p: hashlib.sha256(open(p, "rb").read()).hexdigest()
json.dump({"version": "9.9.9", "build": 999, "notes": "CI", "asset": "KongPrism-9.9.9.zip", "sha256": sha(f"{feed}/KongPrism-9.9.9.zip"),
           "liteAsset": "KongPrism-9.9.9-lite.zip", "liteSha256": sha(f"{feed}/KongPrism-9.9.9-lite.zip"), "coreSha256": sha(core)},
          open(f"{feed}/latest.json", "w"))
for name in ("KongPrism-9.9.9.zip", "KongPrism-9.9.9-lite.zip"):
    print(f"{name}: {os.path.getsize(f'{feed}/{name}') / 1048576:.1f} MB")
PY
defaults write com.kongxiangrui.KongPrism updateFeedURL "http://127.0.0.1:$SUBPORT/feed/"
link install-update
wait_for 90 bash -c 'test "$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" /Applications/KongPrism.app/Contents/Info.plist)" = 9.9.9'
wait_for 30 grep -q "已更新到 9.9.9" "$SUPPORT/logs/app.log"
grep "精简更新包" "$SUPPORT/logs/app.log" | tail -1 | cut -c21-
test "$(hits /feed/KongPrism-9.9.9-lite.zip)" = 1 && test "$(hits /feed/KongPrism-9.9.9.zip)" = 0
codesign --verify --deep --strict /Applications/KongPrism.app
echo "✅ 只下载了精简包，放回内核后签名完整，已更新并重新打开 9.9.9"
defaults delete com.kongxiangrui.KongPrism updateFeedURL

step "完全卸载"
sleep 3
link uninstall
wait_for 30 bash -c '! pgrep -x KongPrism'
test ! -e "$SUPPORT"
! defaults read com.kongxiangrui.KongPrism >/dev/null 2>&1
test ! -e /Library/PrivilegedHelperTools/com.kongxiangrui.KongPrism.tun
test ! -e /etc/sudoers.d/kongprism
if [[ "$SYSTEM_PROXY" == true ]]; then ! scutil --proxy | grep -q "HTTPPort : $PORT"; fi
! pgrep -f "KongPrism.app/Contents/MacOS/sing-box" >/dev/null
echo "✅ 已恢复系统代理、移除辅助程序和授权文件、删除数据与设置，程序已退出"

step "全部通过"
ls -la "$SHOTS"
