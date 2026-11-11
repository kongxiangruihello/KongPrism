#!/bin/bash
# KongPrism 增强模式（TUN）辅助程序：由 KongPrism 通过 sudo 调用，只接受 start / stop / status。
set -u
ROOT="/Library/Application Support/KongPrismTUN"
CORE="/Library/PrivilegedHelperTools/com.kongxiangrui.KongPrism.sing-box"
PIDFILE="$ROOT/sing-box.pid"
user="${SUDO_USER:-}"
if [[ ! "$user" =~ ^[A-Za-z0-9._-]+$ ]]; then echo "只能由 KongPrism 通过 sudo 调用"; exit 2; fi
home="$(/usr/bin/dscl . -read "/Users/$user" NFSHomeDirectory 2>/dev/null | /usr/bin/awk '{print $2}')"
SRC="$home/Library/Application Support/KongPrism/runtime/config.json"

running() { [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; }
stop_core() {
  if running; then
    pid="$(cat "$PIDFILE")"
    kill "$pid" 2>/dev/null
    for _ in $(seq 1 30); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
    kill -9 "$pid" 2>/dev/null
    # Only return once it is gone: KongPrism starts the next core on the same ports right after.
    for _ in $(seq 1 30); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
  fi
  rm -f "$PIDFILE"
}

case "${1:-}" in
  start)
    stop_core
    /bin/mkdir -p "$ROOT"; /bin/chmod 755 "$ROOT"
    if [[ ! -f "$SRC" || -L "$SRC" ]]; then echo "找不到配置：$SRC"; exit 3; fi
    /bin/cp "$SRC" "$ROOT/config.json"; /bin/chmod 600 "$ROOT/config.json"
    # Whatever the user-writable config says, the core only writes inside $ROOT.
    /usr/bin/osascript -l JavaScript - "$ROOT/config.json" "$ROOT" <<'JXA' || { echo "配置无法解析"; exit 5; }
function run(argv) {
  ObjC.import('Foundation');
  var path = argv[0], root = argv[1];
  var text = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null).js;
  var c = JSON.parse(text);
  c.log = c.log || {};
  c.log.output = root + '/core.log';
  c.experimental = c.experimental || {};
  if (c.experimental.cache_file) { c.experimental.cache_file.path = root + '/cache.db'; }
  if (c.experimental.clash_api) { delete c.experimental.clash_api.external_ui; delete c.experimental.clash_api.external_ui_download_url; }
  $(JSON.stringify(c)).writeToFileAtomicallyEncodingError(path, true, $.NSUTF8StringEncoding, null);
}
JXA
    /usr/bin/touch "$ROOT/core.log"; /bin/chmod 644 "$ROOT/core.log"
    cd "$ROOT" || exit 6
    # Every connection of every program is a file here: the default limit (256) runs out with a busy
    # browser ("too many open files", seen in CI). Raise it for the core.
    ulimit -n 65536 2>/dev/null || ulimit -n 10240 2>/dev/null || true
    nohup "$CORE" run -c "$ROOT/config.json" -D "$ROOT" --disable-color >>"$ROOT/stderr.log" 2>&1 &
    echo $! > "$PIDFILE"; /bin/chmod 644 "$PIDFILE"
    sleep 0.6
    if ! running; then /usr/bin/tail -n 5 "$ROOT/stderr.log"; exit 4; fi
    ;;
  stop) stop_core ;;
  status) if running; then echo running; else echo stopped; fi ;;
  *) echo "用法：start | stop | status"; exit 1 ;;
esac
