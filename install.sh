#!/usr/bin/env bash
# =====================================================================
#  내 토렌트 (MyTorrent) 설치 스크립트
#  - Ubuntu 24.04 (또는 22.04) 클라우드 서버에서 root 로 실행:
#        bash install.sh
#  - 다시 실행하면 업데이트만 하고, 비밀번호는 그대로 유지됩니다.
# =====================================================================
set -euo pipefail

APP=/opt/mytorrent
DATA=/srv/torrents
STATE=/var/lib/mytorrent
ENVF=/etc/mytorrent.env
SVC=mytorrent
TPORT=6881

say()  { printf '\n\033[1;32m▶ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m! %s\033[0m\n' "$*"; }

if [ "$(id -u)" -ne 0 ]; then
  echo "root 권한이 필요해요. 'sudo bash install.sh' 로 다시 실행하세요."; exit 1
fi
if ! command -v apt-get >/dev/null; then
  echo "Ubuntu/Debian 서버에서만 동작해요."; exit 1
fi

say "1/6 필요한 프로그램 설치 (1~3분)"
export DEBIAN_FRONTEND=noninteractive
apt-get -o DPkg::Lock::Timeout=600 update -y -qq
apt-get -o DPkg::Lock::Timeout=600 install -y -qq python3 python3-libtorrent python3-flask python3-waitress curl ca-certificates >/dev/null
if ! apt-get -o DPkg::Lock::Timeout=600 install -y -qq caddy >/dev/null 2>&1; then
  # 22.04 처럼 기본 저장소에 caddy 가 없는 경우 공식 저장소 추가
  apt-get -o DPkg::Lock::Timeout=600 install -y -qq debian-keyring debian-archive-keyring apt-transport-https gnupg >/dev/null
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list
  apt-get -o DPkg::Lock::Timeout=600 update -y -qq
  apt-get -o DPkg::Lock::Timeout=600 install -y -qq caddy >/dev/null
fi
python3 -c "import libtorrent, flask, waitress" || { echo "파이썬 패키지 설치 실패"; exit 1; }

say "2/6 사용자와 폴더 준비"
id -u mytorrent >/dev/null 2>&1 || useradd --system --home "$STATE" --shell /usr/sbin/nologin mytorrent
mkdir -p "$APP/static" "$DATA" "$STATE"
chown -R mytorrent:mytorrent "$DATA" "$STATE"

say "3/6 앱 파일 설치"
cat > "$APP/app.py" <<'__MT_EOF__'
#!/usr/bin/env python3
"""MyTorrent - 나 혼자 쓰는 아이폰용 토렌트 다운로더 (서버 쪽).

서버가 토렌트를 받고, 아이폰은 사파리(홈 화면 앱)로 조작/재생한다.
필요 패키지(Ubuntu): python3-libtorrent python3-flask python3-waitress
"""
import hmac
import json
import os
import secrets
import shutil
import threading
import time
from functools import wraps

import libtorrent as lt
from flask import (Flask, abort, jsonify, redirect, request, send_file,
                   send_from_directory, session)
from itsdangerous import BadSignature, URLSafeTimedSerializer
from urllib.parse import quote

# ---------------------------------------------------------------- 설정
APP_DIR = os.path.dirname(os.path.abspath(__file__))
DOWNLOAD_DIR = os.environ.get("MT_DOWNLOAD_DIR", "/srv/torrents")
STATE_DIR = os.environ.get("MT_STATE_DIR", "/var/lib/mytorrent")
PASSWORD = os.environ.get("MT_PASSWORD", "")
SECRET_KEY = os.environ.get("MT_SECRET_KEY") or secrets.token_hex(32)
LISTEN_PORT = int(os.environ.get("MT_TORRENT_PORT", "6881"))
HTTP_HOST = os.environ.get("MT_HTTP_HOST", "127.0.0.1")
HTTP_PORT = int(os.environ.get("MT_HTTP_PORT", "8080"))

os.makedirs(DOWNLOAD_DIR, exist_ok=True)
os.makedirs(os.path.join(STATE_DIR, "torrents"), exist_ok=True)
STATE_FILE = os.path.join(STATE_DIR, "state.json")
SETTINGS_FILE = os.path.join(STATE_DIR, "settings.json")

DEFAULT_SETTINGS = {
    "stop_when_done": True,   # 다 받으면 업로드(시딩) 멈춤
    "max_download_kbps": 0,   # 0 = 무제한
    "max_upload_kbps": 0,
}

# ---------------------------------------------------------------- 상태 저장
_lock = threading.RLock()


def _load_json(path, default):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def _save_json(path, data):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=1)
    os.replace(tmp, path)


state = _load_json(STATE_FILE, {})          # hash -> {"magnet"/"file", "paused", "added"}
settings = {**DEFAULT_SETTINGS, **_load_json(SETTINGS_FILE, {})}


def save_state():
    with _lock:
        _save_json(STATE_FILE, state)

# ---------------------------------------------------------------- libtorrent


ses = lt.session({
    "listen_interfaces": f"0.0.0.0:{LISTEN_PORT},[::]:{LISTEN_PORT}",
    "alert_mask": lt.alert.category_t.status_notification
    | lt.alert.category_t.error_notification,
    "enable_dht": True,
    "enable_lsd": False,
    "enable_upnp": False,
    "enable_natpmp": False,
})
handles = {}  # hash -> torrent_handle


def apply_rate_limits():
    ses.apply_settings({
        "download_rate_limit": int(settings["max_download_kbps"]) * 1024,
        "upload_rate_limit": int(settings["max_upload_kbps"]) * 1024,
    })


def hash_of(h):
    try:
        return str(h.info_hashes().get_best())
    except AttributeError:
        return str(h.info_hash())


def is_paused(st):
    flags = getattr(st, "flags", None)
    if flags is not None and hasattr(lt, "torrent_flags"):
        return bool(flags & lt.torrent_flags.paused)
    return bool(getattr(st, "paused", False))


def do_pause(h):
    if hasattr(lt, "torrent_flags"):
        h.unset_flags(lt.torrent_flags.auto_managed)
    else:
        h.auto_managed(False)
    h.pause()


def do_resume(h):
    h.resume()


def add_to_session(magnet=None, tfile=None, paused=False):
    if magnet:
        atp = lt.parse_magnet_uri(magnet)
    else:
        with open(tfile, "rb") as f:
            atp = lt.add_torrent_params()
            atp.ti = lt.torrent_info(lt.bdecode(f.read()))
    atp.save_path = DOWNLOAD_DIR
    h = ses.add_torrent(atp)
    if paused:
        do_pause(h)
    key = hash_of(h)
    handles[key] = h
    return key, h


def restore():
    for key, item in list(state.items()):
        try:
            tfile = item.get("file")
            if tfile and os.path.exists(tfile):
                add_to_session(tfile=tfile, paused=item.get("paused", False))
            elif item.get("magnet"):
                add_to_session(magnet=item["magnet"], paused=item.get("paused", False))
        except Exception as e:  # 깨진 항목은 건너뜀
            print("restore failed", key, e)


def save_metadata(h):
    """마그넷으로 추가한 토렌트의 메타데이터를 .torrent 로 저장(재시작 대비)."""
    try:
        ti = h.torrent_file()
        if ti is None:
            return
        key = hash_of(h)
        path = os.path.join(STATE_DIR, "torrents", key + ".torrent")
        data = lt.bencode(lt.create_torrent(ti).generate())
        with open(path, "wb") as f:
            f.write(data)
        with _lock:
            if key in state:
                state[key]["file"] = path
        save_state()
    except Exception as e:
        print("save metadata failed", e)


def alert_loop():
    while True:
        ses.wait_for_alert(1000)
        for a in ses.pop_alerts():
            if isinstance(a, lt.metadata_received_alert):
                save_metadata(a.handle)
            elif isinstance(a, lt.torrent_finished_alert):
                if settings.get("stop_when_done"):
                    do_pause(a.handle)
                    with _lock:
                        k = hash_of(a.handle)
                        if k in state:
                            state[k]["paused"] = True
                    save_state()


apply_rate_limits()
restore()
threading.Thread(target=alert_loop, daemon=True).start()

# ---------------------------------------------------------------- 웹 앱
app = Flask(__name__, static_folder=None)
app.config.update(
    SECRET_KEY=SECRET_KEY,
    SESSION_COOKIE_HTTPONLY=True,
    SESSION_COOKIE_SAMESITE="Lax",
    SESSION_COOKIE_SECURE=os.environ.get("MT_SECURE_COOKIE", "1") == "1",
    PERMANENT_SESSION_LIFETIME=60 * 60 * 24 * 30,
    MAX_CONTENT_LENGTH=10 * 1024 * 1024,
)

_fail = {"count": 0, "until": 0.0}
# VLC 같은 외부 앱은 로그인 쿠키가 없으므로, 파일 주소에 12시간짜리 서명 토큰을 붙인다
signer = URLSafeTimedSerializer(SECRET_KEY, salt="file-link")
LINK_MAX_AGE = 60 * 60 * 12


def login_required(fn):
    @wraps(fn)
    def wrapper(*a, **kw):
        if not session.get("ok"):
            if request.path.startswith("/api/") or request.path.startswith("/files/"):
                return jsonify(error="login"), 401
            return redirect("/login")
        return fn(*a, **kw)
    return wrapper


def static_page(name):
    return send_from_directory(os.path.join(APP_DIR, "static"), name)


@app.after_request
def no_cache_api(resp):
    if request.path.startswith("/api/"):
        resp.headers["Cache-Control"] = "no-store"
    return resp


@app.get("/login")
def login_page():
    return static_page("login.html")


@app.post("/login")
def login_post():
    now = time.time()
    if now < _fail["until"]:
        return jsonify(error="잠시 후 다시 시도하세요"), 429
    pw = (request.get_json(silent=True) or request.form).get("password", "")
    if PASSWORD and hmac.compare_digest(pw.encode(), PASSWORD.encode()):
        _fail["count"] = 0
        session.permanent = True
        session["ok"] = True
        return jsonify(ok=True)
    _fail["count"] += 1
    if _fail["count"] >= 5:
        _fail["until"] = now + 60 * min(_fail["count"] - 4, 30)
    return jsonify(error="비밀번호가 틀렸어요"), 403


@app.post("/logout")
def logout():
    session.clear()
    return jsonify(ok=True)


@app.get("/")
@login_required
def index():
    return static_page("index.html")


@app.get("/manifest.webmanifest")
def manifest():
    return static_page("manifest.webmanifest")


@app.get("/icon-<int:size>.png")
def icon(size):
    if size not in (180, 192, 512):
        abort(404)
    return static_page(f"icon-{size}.png")


STATE_NAMES = {
    0: "대기", 1: "확인 중", 2: "정보 받는 중", 3: "받는 중",
    4: "완료", 5: "공유 중", 6: "준비", 7: "확인 중",
}


def torrent_json(key, h):
    st = h.status()
    paused = is_paused(st)
    if st.errc and st.errc.value():
        label = "오류"
    elif paused:
        label = "완료" if st.is_finished else "일시정지"
    elif not st.has_metadata:
        label = "정보 받는 중"
    else:
        label = STATE_NAMES.get(int(st.state), "")
    remaining = max(st.total_wanted - st.total_wanted_done, 0)
    eta = int(remaining / st.download_rate) if st.download_rate > 0 and not paused else None
    return {
        "hash": key,
        "name": st.name or "(이름 받는 중…)",
        "progress": round(st.progress, 4),
        "done": st.total_wanted_done,
        "size": st.total_wanted,
        "down": st.download_rate,
        "up": st.upload_rate,
        "peers": st.num_peers,
        "seeds": st.num_seeds,
        "paused": paused,
        "finished": bool(st.is_finished),
        "state": label,
        "eta": eta,
        "error": st.errc.message() if st.errc and st.errc.value() else "",
        "added": state.get(key, {}).get("added", 0),
    }


@app.get("/api/torrents")
@login_required
def list_torrents():
    items = [torrent_json(k, h) for k, h in list(handles.items()) if h.is_valid()]
    items.sort(key=lambda x: x["added"], reverse=True)
    du = shutil.disk_usage(DOWNLOAD_DIR)
    return jsonify(torrents=items, disk={"free": du.free, "total": du.total},
                   settings=settings)


def fetch_torrent(url):
    """.torrent 파일 주소(https://…)를 서버가 대신 내려받는다 (최대 10MB)."""
    import urllib.request
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 MyTorrent"})
    with urllib.request.urlopen(req, timeout=20) as r:
        data = r.read(10 * 1024 * 1024 + 1)
    if len(data) > 10 * 1024 * 1024:
        raise ValueError("파일이 너무 커요")
    if not data.startswith(b"d"):
        raise ValueError("이 주소는 .torrent 파일이 아니에요")
    return data


@app.post("/api/add")
@login_required
def add():
    magnet = (request.form.get("magnet") or "").strip()
    upload = request.files.get("torrent")
    try:
        data = None
        if upload:
            data = upload.read()
        elif magnet.lower().startswith(("http://", "https://")):
            data = fetch_torrent(magnet)
        if data is not None:
            ti = lt.torrent_info(lt.bdecode(data))  # 형식 검사
            tmp_key = secrets.token_hex(8)
            path = os.path.join(STATE_DIR, "torrents", tmp_key + ".torrent")
            with open(path, "wb") as f:
                f.write(data)
            key, h = add_to_session(tfile=path)
            final = os.path.join(STATE_DIR, "torrents", key + ".torrent")
            os.replace(path, final)
            entry = {"file": final}
            del ti
        elif magnet.startswith("magnet:?"):
            key, h = add_to_session(magnet=magnet)
            entry = {"magnet": magnet}
        else:
            return jsonify(error="마그넷 링크, .torrent 주소, 또는 파일을 넣어 주세요"), 400
    except Exception as e:
        return jsonify(error=f"추가하지 못했어요: {e}"), 400
    with _lock:
        if key not in state:
            entry.update(paused=False, added=time.time())
            state[key] = entry
    save_state()
    return jsonify(ok=True, hash=key)


def get_handle(key):
    h = handles.get(key)
    if not h or not h.is_valid():
        abort(404)
    return h


@app.post("/api/torrents/<key>/pause")
@login_required
def pause(key):
    do_pause(get_handle(key))
    with _lock:
        state.setdefault(key, {})["paused"] = True
    save_state()
    return jsonify(ok=True)


@app.post("/api/torrents/<key>/resume")
@login_required
def resume(key):
    do_resume(get_handle(key))
    with _lock:
        state.setdefault(key, {})["paused"] = False
    save_state()
    return jsonify(ok=True)


@app.post("/api/torrents/<key>/delete")
@login_required
def delete(key):
    h = get_handle(key)
    if request.args.get("files") == "1":
        opt = getattr(lt.session, "delete_files", None)
        if opt is None:
            opt = lt.options_t.delete_files
        ses.remove_torrent(h, opt)
    else:
        ses.remove_torrent(h)
    handles.pop(key, None)
    with _lock:
        item = state.pop(key, {})
    save_state()
    tfile = item.get("file")
    if tfile and os.path.exists(tfile):
        os.remove(tfile)
    return jsonify(ok=True)


@app.get("/api/torrents/<key>/files")
@login_required
def files(key):
    h = get_handle(key)
    ti = h.torrent_file()
    if ti is None:
        return jsonify(files=[])
    fs = ti.files()
    prog = h.file_progress()
    out = []
    for i in range(fs.num_files()):
        size = fs.file_size(i)
        name = os.path.basename(fs.file_path(i))
        token = signer.dumps([key, i])
        out.append({
            "url": f"/files/{key}/{i}/{quote(name)}?t={token}",
            "index": i,
            "path": fs.file_path(i),
            "size": size,
            "done": prog[i] if i < len(prog) else 0,
            "complete": size > 0 and i < len(prog) and prog[i] >= size,
        })
    return jsonify(files=out)


def resolve_file(key, idx):
    h = get_handle(key)
    ti = h.torrent_file()
    if ti is None:
        abort(404)
    fs = ti.files()
    if idx < 0 or idx >= fs.num_files():
        abort(404)
    base = os.path.realpath(DOWNLOAD_DIR)
    path = os.path.realpath(os.path.join(DOWNLOAD_DIR, fs.file_path(idx)))
    if not path.startswith(base + os.sep) or not os.path.isfile(path):
        abort(404)
    return path


@app.get("/files/<key>/<int:idx>/<path:_name>")
def get_file(key, idx, _name):
    if not session.get("ok"):
        try:
            if signer.loads(request.args.get("t", ""), max_age=LINK_MAX_AGE) != [key, idx]:
                abort(403)
        except BadSignature:
            abort(403)
    path = resolve_file(key, idx)
    # conditional=True → Range 요청 지원(사파리에서 영상 바로 재생/탐색)
    return send_file(path, conditional=True,
                     as_attachment=request.args.get("dl") == "1",
                     download_name=os.path.basename(path))


@app.post("/api/settings")
@login_required
def update_settings():
    data = request.get_json(silent=True) or {}
    with _lock:
        if "stop_when_done" in data:
            settings["stop_when_done"] = bool(data["stop_when_done"])
        for k in ("max_download_kbps", "max_upload_kbps"):
            if k in data:
                settings[k] = max(0, int(data[k] or 0))
        _save_json(SETTINGS_FILE, settings)
    apply_rate_limits()
    return jsonify(ok=True, settings=settings)


if __name__ == "__main__":
    if not PASSWORD:
        raise SystemExit("MT_PASSWORD 환경변수를 설정하세요")
    try:
        from waitress import serve
        serve(app, host=HTTP_HOST, port=HTTP_PORT, threads=8)
    except ImportError:
        app.run(host=HTTP_HOST, port=HTTP_PORT, threaded=True)
__MT_EOF__
cat > "$APP/static/index.html" <<'__MT_EOF__'
<!doctype html>
<html lang="ko">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="default">
<meta name="apple-mobile-web-app-title" content="내 토렌트">
<meta name="theme-color" content="#f4f4f1" media="(prefers-color-scheme: light)">
<meta name="theme-color" content="#121312" media="(prefers-color-scheme: dark)">
<link rel="apple-touch-icon" href="/icon-180.png">
<link rel="manifest" href="/manifest.webmanifest">
<title>내 토렌트</title>
<style>
:root{
  --bg:#f4f4f1; --card:#ffffff; --ink:#191a18; --sub:#6b6d68; --line:#e4e4df;
  --accent:#1f7a5c; --accent-ink:#ffffff; --track:#e9e9e4; --warn:#b4471f;
  --sheet:#ffffff; --shade:rgba(0,0,0,.35);
}
@media (prefers-color-scheme: dark){
  :root{
    --bg:#121312; --card:#1c1d1b; --ink:#eeeee9; --sub:#9a9c96; --line:#2a2b29;
    --accent:#4cc196; --accent-ink:#0d1a14; --track:#2b2d2a; --warn:#f08a62;
    --sheet:#1f201e; --shade:rgba(0,0,0,.6);
  }
}
*{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
html,body{margin:0;background:var(--bg);color:var(--ink);
  font:16px/1.45 -apple-system,BlinkMacSystemFont,"Apple SD Gothic Neo","Pretendard",system-ui,sans-serif}
body{padding:env(safe-area-inset-top) 0 calc(96px + env(safe-area-inset-bottom))}
header{display:flex;align-items:flex-end;justify-content:space-between;padding:20px 16px 8px}
h1{font-size:30px;line-height:1.1;margin:0;letter-spacing:-.02em}
.disk{font-size:13px;color:var(--sub);margin:2px 0 0}
.icon-btn{border:0;background:var(--card);color:var(--ink);width:40px;height:40px;border-radius:12px;
  display:grid;place-items:center;border:1px solid var(--line)}
.icon-btn svg{width:20px;height:20px}
main{padding:8px 16px;display:flex;flex-direction:column;gap:10px}
.empty{color:var(--sub);text-align:center;padding:64px 16px;font-size:15px}
.card{background:var(--card);border:1px solid var(--line);border-radius:16px;padding:14px 14px 12px}
.row{display:flex;align-items:center;gap:10px}
.name{font-weight:600;font-size:15px;word-break:break-all;flex:1;
  display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden}
.badge{font-size:12px;padding:3px 8px;border-radius:999px;background:var(--track);color:var(--sub);white-space:nowrap}
.badge.on{background:var(--accent);color:var(--accent-ink)}
.badge.err{background:var(--warn);color:#fff}
.bar{height:6px;background:var(--track);border-radius:3px;margin:10px 0 8px;overflow:hidden}
.bar>i{display:block;height:100%;background:var(--accent);border-radius:3px;transition:width .4s}
.meta{font-size:13px;color:var(--sub);display:flex;flex-wrap:wrap;gap:4px 12px;font-variant-numeric:tabular-nums}
.actions{display:flex;gap:8px;margin-top:10px}
.btn{flex:1;border:1px solid var(--line);background:transparent;color:var(--ink);border-radius:10px;
  padding:9px 10px;font:inherit;font-size:14px}
.btn.primary{background:var(--accent);border-color:var(--accent);color:var(--accent-ink);font-weight:600}
.btn.danger{color:var(--warn)}
.files{margin-top:10px;border-top:1px solid var(--line);padding-top:6px}
.file{padding:9px 0;border-bottom:1px solid var(--line)}
.file:last-child{border-bottom:0}
.fname{font-size:14px;word-break:break-all}
.fmeta{font-size:12px;color:var(--sub);margin-top:2px}
.flinks{display:flex;gap:6px;margin-top:6px;flex-wrap:wrap}
.flinks a{font-size:13px;text-decoration:none;color:var(--accent);border:1px solid var(--line);
  border-radius:8px;padding:5px 10px}
.fab{position:fixed;right:16px;bottom:calc(20px + env(safe-area-inset-bottom));height:56px;padding:0 22px;
  border:0;border-radius:28px;background:var(--accent);color:var(--accent-ink);font:600 16px/1 inherit;
  display:flex;align-items:center;gap:8px;box-shadow:0 6px 20px rgba(0,0,0,.18)}
.fab svg{width:20px;height:20px}
.shade{position:fixed;inset:0;background:var(--shade);opacity:0;pointer-events:none;transition:opacity .2s}
.shade.open{opacity:1;pointer-events:auto}
.sheet{position:fixed;left:0;right:0;bottom:0;background:var(--sheet);border-radius:20px 20px 0 0;
  padding:10px 16px calc(20px + env(safe-area-inset-bottom));transform:translateY(105%);transition:transform .25s ease}
.sheet.open{transform:none}
.grab{width:36px;height:5px;border-radius:3px;background:var(--line);margin:0 auto 12px}
.sheet h2{font-size:18px;margin:0 0 12px}
textarea,input[type=number]{width:100%;border:1px solid var(--line);background:var(--bg);color:var(--ink);
  border-radius:12px;padding:12px;font:inherit;font-size:16px}
textarea{height:96px;resize:none}
.or{text-align:center;color:var(--sub);font-size:13px;margin:12px 0}
.filepick{display:block;text-align:center;border:1.5px dashed var(--line);border-radius:12px;padding:14px;color:var(--sub);font-size:15px}
.filepick input{display:none}
.sheet .actions{margin-top:14px}
.setting{display:flex;justify-content:space-between;align-items:center;gap:12px;padding:12px 0;border-bottom:1px solid var(--line)}
.setting small{display:block;color:var(--sub);font-size:12px}
.setting input[type=number]{width:110px;text-align:right}
.switch{position:relative;width:51px;height:31px;flex:none}
.switch input{opacity:0;width:0;height:0}
.switch span{position:absolute;inset:0;background:var(--track);border-radius:16px;transition:.2s}
.switch span:before{content:"";position:absolute;width:27px;height:27px;left:2px;top:2px;background:#fff;border-radius:50%;transition:.2s;box-shadow:0 1px 3px rgba(0,0,0,.25)}
.switch input:checked+span{background:var(--accent)}
.switch input:checked+span:before{transform:translateX(20px)}
.toast{position:fixed;left:50%;top:calc(12px + env(safe-area-inset-top));transform:translate(-50%,-150%);
  background:var(--ink);color:var(--bg);padding:10px 16px;border-radius:12px;font-size:14px;transition:transform .25s;max-width:90vw}
.toast.show{transform:translate(-50%,0)}
</style>
</head>
<body>
<header>
  <div>
    <h1>내 토렌트</h1>
    <p class="disk" id="disk">&nbsp;</p>
  </div>
  <button class="icon-btn" id="openSettings" aria-label="설정">
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z"/></svg>
  </button>
</header>

<main id="list"><div class="empty">불러오는 중…</div></main>

<button class="fab" id="openAdd"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round"><path d="M12 5v14M5 12h14"/></svg>추가</button>

<div class="shade" id="shade"></div>

<section class="sheet" id="addSheet" aria-label="토렌트 추가">
  <div class="grab"></div>
  <h2>토렌트 추가</h2>
  <textarea id="magnet" placeholder="마그넷 링크나 .torrent 파일 주소(https://…)를 붙여 넣으세요" autocapitalize="off" autocorrect="off" spellcheck="false"></textarea>
  <div class="or">또는</div>
  <label class="filepick" id="pickLabel">.torrent 파일 선택<input type="file" id="tfile"></label>
  <div class="actions">
    <button class="btn" data-close>취소</button>
    <button class="btn primary" id="addBtn">받기 시작</button>
  </div>
</section>

<section class="sheet" id="setSheet" aria-label="설정">
  <div class="grab"></div>
  <h2>설정</h2>
  <div class="setting">
    <div>다 받으면 공유 멈추기<small>완료 후 업로드를 자동으로 멈춰요</small></div>
    <label class="switch"><input type="checkbox" id="sStop"><span></span></label>
  </div>
  <div class="setting">
    <div>다운로드 속도 제한<small>KB/s · 0이면 무제한</small></div>
    <input type="number" id="sDown" inputmode="numeric" min="0">
  </div>
  <div class="setting">
    <div>업로드 속도 제한<small>KB/s · 0이면 무제한</small></div>
    <input type="number" id="sUp" inputmode="numeric" min="0">
  </div>
  <div class="actions">
    <button class="btn danger" id="logout">로그아웃</button>
    <button class="btn primary" id="saveSet">저장</button>
  </div>
</section>

<div class="toast" id="toast"></div>

<script>
const $ = s => document.querySelector(s);
const list = $('#list');
const openFiles = new Set();
let lastSettings = null;

function fmtBytes(n){
  if(!n) return '0 B';
  const u=['B','KB','MB','GB','TB']; let i=0;
  while(n>=1024 && i<u.length-1){n/=1024;i++}
  return (n>=100||i===0?n.toFixed(0):n.toFixed(1))+' '+u[i];
}
function fmtEta(s){
  if(s==null) return '';
  if(s<60) return s+'초';
  if(s<3600) return Math.round(s/60)+'분';
  const h=Math.floor(s/3600), m=Math.round((s%3600)/60);
  return h+'시간'+(m?' '+m+'분':'');
}
function esc(s){return String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]))}
function toast(msg){const t=$('#toast');t.textContent=msg;t.classList.add('show');clearTimeout(t._h);t._h=setTimeout(()=>t.classList.remove('show'),2400)}

async function api(path, opts={}){
  const r = await fetch(path, {credentials:'same-origin', ...opts});
  if(r.status===401){location.href='/login';throw new Error('login')}
  const j = await r.json().catch(()=>({}));
  if(!r.ok) throw new Error(j.error||('오류 '+r.status));
  return j;
}

const PLAYABLE = /\.(mp4|m4v|mov|mp3|m4a|aac|wav|jpg|jpeg|png|gif|pdf|txt)$/i;

function renderCard(t){
  const pct = Math.floor(t.progress*1000)/10;
  const cls = t.error?'err':(!t.paused && !t.finished?'on':'');
  const speed = !t.paused && !t.finished ? `<span>↓ ${fmtBytes(t.down)}/s</span>` : '';
  const up = t.up>0 ? `<span>↑ ${fmtBytes(t.up)}/s</span>` : '';
  const eta = t.eta!=null && !t.finished ? `<span>${fmtEta(t.eta)} 남음</span>` : '';
  const peers = !t.paused ? `<span>연결 ${t.peers} · 시드 ${t.seeds}</span>` : '';
  return `<article class="card" data-hash="${t.hash}">
    <div class="row"><div class="name">${esc(t.name)}</div><span class="badge ${cls}">${esc(t.state)}</span></div>
    <div class="bar"><i style="width:${pct}%"></i></div>
    <div class="meta"><span>${pct}%</span><span>${fmtBytes(t.done)} / ${fmtBytes(t.size)}</span>${speed}${up}${eta}${peers}</div>
    ${t.error?`<div class="meta" style="color:var(--warn)">${esc(t.error)}</div>`:''}
    <div class="actions">
      <button class="btn" data-act="files">${openFiles.has(t.hash)?'파일 닫기':'파일 보기'}</button>
      <button class="btn" data-act="${t.paused?'resume':'pause'}">${t.paused?(t.finished?'다시 공유':'계속'):'일시정지'}</button>
      <button class="btn danger" data-act="delete">삭제</button>
    </div>
    <div class="files" data-files ${openFiles.has(t.hash)?'':'hidden'}></div>
  </article>`;
}

async function loadFiles(card){
  const hash = card.dataset.hash;
  const box = card.querySelector('[data-files]');
  try{
    const {files} = await api(`/api/torrents/${hash}/files`);
    if(!files.length){box.innerHTML='<div class="fmeta">파일 정보를 받는 중이에요…</div>';return}
    box.innerHTML = files.map(f=>{
      const full = location.origin + f.url;
      const links = f.complete ? `
        ${PLAYABLE.test(f.path)?`<a href="${f.url}" target="_blank">▶︎ 열기</a>`:''}
        <a href="vlc-x-callback://x-callback-url/stream?url=${encodeURIComponent(full)}">VLC로 재생</a>
        <a href="${f.url}&dl=1">저장</a>
        <a href="#" data-copy="${esc(full)}">주소 복사</a>` : '';
      return `<div class="file"><div class="fname">${esc(f.path.split('/').pop())}</div>
        <div class="fmeta">${fmtBytes(f.size)} · ${f.complete?'완료':Math.floor(f.done/Math.max(f.size,1)*100)+'%'}</div>
        ${links?`<div class="flinks">${links}</div>`:''}</div>`;
    }).join('');
  }catch(e){box.innerHTML=`<div class="fmeta">${esc(e.message)}</div>`}
}

async function refresh(){
  try{
    const d = await api('/api/torrents');
    lastSettings = d.settings;
    $('#disk').textContent = `남은 공간 ${fmtBytes(d.disk.free)} / ${fmtBytes(d.disk.total)}`;
    if(!d.torrents.length){list.innerHTML='<div class="empty">아직 받은 게 없어요.<br>아래 <b>추가</b>를 눌러 시작하세요.</div>';return}
    // 열려 있는 파일 목록은 유지하면서 카드만 갱신
    const keep = {};
    list.querySelectorAll('.card').forEach(c=>{const b=c.querySelector('[data-files]'); if(!b.hidden) keep[c.dataset.hash]=b.innerHTML});
    list.innerHTML = d.torrents.map(renderCard).join('');
    list.querySelectorAll('.card').forEach(c=>{
      if(openFiles.has(c.dataset.hash)){
        const b=c.querySelector('[data-files]');
        if(keep[c.dataset.hash]) b.innerHTML=keep[c.dataset.hash];
      }
    });
  }catch(e){ if(e.message!=='login') $('#disk').textContent='서버에 연결할 수 없어요'; }
}

list.addEventListener('click', async e=>{
  const copy = e.target.closest('[data-copy]');
  if(copy){e.preventDefault();try{await navigator.clipboard.writeText(copy.dataset.copy);toast('주소를 복사했어요 (12시간 유효)')}catch{toast('복사하지 못했어요')}return}
  const btn = e.target.closest('[data-act]'); if(!btn) return;
  const card = btn.closest('.card'); const hash = card.dataset.hash; const act = btn.dataset.act;
  if(act==='files'){
    const box = card.querySelector('[data-files]');
    if(openFiles.has(hash)){openFiles.delete(hash);box.hidden=true;btn.textContent='파일 보기'}
    else{openFiles.add(hash);box.hidden=false;btn.textContent='파일 닫기';box.innerHTML='<div class="fmeta">불러오는 중…</div>';loadFiles(card)}
    return;
  }
  if(act==='delete'){
    if(!confirm('목록에서 지울까요?')) return;
    const withFiles = confirm('받은 파일도 서버에서 지울까요?\n(확인 = 파일까지 삭제, 취소 = 목록에서만 삭제)');
    try{await api(`/api/torrents/${hash}/delete?files=${withFiles?1:0}`,{method:'POST'});toast(withFiles?'파일까지 지웠어요':'목록에서 지웠어요')}catch(e){toast(e.message)}
  } else {
    try{await api(`/api/torrents/${hash}/${act}`,{method:'POST'})}catch(e){toast(e.message)}
  }
  refresh();
});

// 파일 목록은 4초마다 따로 새로고침(진행률)
setInterval(()=>{list.querySelectorAll('.card').forEach(c=>{if(openFiles.has(c.dataset.hash)) loadFiles(c)})},4000);

// 시트
function openSheet(id){$('#shade').classList.add('open');$(id).classList.add('open')}
function closeSheets(){$('#shade').classList.remove('open');document.querySelectorAll('.sheet').forEach(s=>s.classList.remove('open'))}
$('#shade').onclick=closeSheets;
document.querySelectorAll('[data-close]').forEach(b=>b.onclick=closeSheets);
$('#openAdd').onclick=()=>{openSheet('#addSheet')};
$('#tfile').onchange=e=>{const f=e.target.files[0];$('#pickLabel').firstChild.textContent=f?f.name:'.torrent 파일 선택'};
$('#addBtn').onclick=async()=>{
  const fd=new FormData(); const f=$('#tfile').files[0]; const m=$('#magnet').value.trim();
  if(f) fd.append('torrent',f); else if(m) fd.append('magnet',m); else {toast('링크나 파일을 넣어 주세요');return}
  $('#addBtn').disabled=true;
  try{await api('/api/add',{method:'POST',body:fd});toast('받기 시작했어요');$('#magnet').value='';$('#tfile').value='';$('#pickLabel').firstChild.textContent='.torrent 파일 선택';closeSheets();refresh()}
  catch(e){toast(e.message)}
  finally{$('#addBtn').disabled=false}
};
$('#openSettings').onclick=()=>{
  if(lastSettings){$('#sStop').checked=lastSettings.stop_when_done;$('#sDown').value=lastSettings.max_download_kbps;$('#sUp').value=lastSettings.max_upload_kbps}
  openSheet('#setSheet');
};
$('#saveSet').onclick=async()=>{
  try{await api('/api/settings',{method:'POST',headers:{'Content-Type':'application/json'},
    body:JSON.stringify({stop_when_done:$('#sStop').checked,max_download_kbps:+$('#sDown').value||0,max_upload_kbps:+$('#sUp').value||0})});
    toast('저장했어요');closeSheets();refresh()}catch(e){toast(e.message)}
};
$('#logout').onclick=async()=>{await fetch('/logout',{method:'POST'});location.href='/login'};

refresh(); setInterval(()=>{if(!document.hidden) refresh()},2000);
document.addEventListener('visibilitychange',()=>{if(!document.hidden) refresh()});
</script>
</body>
</html>
__MT_EOF__
cat > "$APP/static/login.html" <<'__MT_EOF__'
<!doctype html>
<html lang="ko">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-title" content="내 토렌트">
<link rel="apple-touch-icon" href="/icon-180.png">
<link rel="manifest" href="/manifest.webmanifest">
<title>내 토렌트 · 로그인</title>
<style>
:root{--bg:#f4f4f1;--card:#fff;--ink:#191a18;--sub:#6b6d68;--line:#e4e4df;--accent:#1f7a5c;--accent-ink:#fff;--warn:#b4471f}
@media (prefers-color-scheme: dark){:root{--bg:#121312;--card:#1c1d1b;--ink:#eeeee9;--sub:#9a9c96;--line:#2a2b29;--accent:#4cc196;--accent-ink:#0d1a14;--warn:#f08a62}}
*{box-sizing:border-box}
body{margin:0;min-height:100vh;display:grid;place-items:center;background:var(--bg);color:var(--ink);
  font:16px/1.45 -apple-system,BlinkMacSystemFont,"Apple SD Gothic Neo",system-ui,sans-serif;padding:16px}
form{width:100%;max-width:340px;background:var(--card);border:1px solid var(--line);border-radius:20px;padding:24px}
img{width:56px;height:56px;border-radius:14px;display:block;margin-bottom:14px}
h1{font-size:24px;margin:0 0 4px}
p{color:var(--sub);margin:0 0 18px;font-size:14px}
input{width:100%;border:1px solid var(--line);background:var(--bg);color:var(--ink);border-radius:12px;padding:13px;font:inherit}
button{width:100%;margin-top:12px;border:0;border-radius:12px;padding:13px;background:var(--accent);color:var(--accent-ink);font:600 16px inherit}
.err{color:var(--warn);font-size:14px;min-height:20px;margin-top:10px}
</style>
</head>
<body>
<form id="f">
  <img src="/icon-180.png" alt="">
  <h1>내 토렌트</h1>
  <p>설치할 때 받은 비밀번호를 입력하세요.</p>
  <input type="password" name="password" id="pw" placeholder="비밀번호" autocomplete="current-password" required>
  <button>들어가기</button>
  <div class="err" id="err"></div>
</form>
<script>
document.getElementById('f').onsubmit=async e=>{
  e.preventDefault();
  const r=await fetch('/login',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({password:document.getElementById('pw').value})});
  if(r.ok) location.href='/';
  else{const j=await r.json().catch(()=>({}));document.getElementById('err').textContent=j.error||'로그인 실패'}
};
</script>
</body>
</html>
__MT_EOF__
cat > "$APP/static/manifest.webmanifest" <<'__MT_EOF__'
{
  "name": "내 토렌트",
  "short_name": "내 토렌트",
  "start_url": "/",
  "display": "standalone",
  "background_color": "#121312",
  "theme_color": "#1f7a5c",
  "icons": [
    {"src": "/icon-192.png", "sizes": "192x192", "type": "image/png"},
    {"src": "/icon-512.png", "sizes": "512x512", "type": "image/png"}
  ]
}
__MT_EOF__
base64 -d > "$APP/static/icon-180.png" <<'__MT_EOF__'
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
AAAAAElFTkSuQmCC
__MT_EOF__
base64 -d > "$APP/static/icon-192.png" <<'__MT_EOF__'
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
lGBASMn/AavJMj3PE9h4AAAAAElFTkSuQmCC
__MT_EOF__
base64 -d > "$APP/static/icon-512.png" <<'__MT_EOF__'
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
AElFTkSuQmCC
__MT_EOF__
chmod 644 "$APP"/app.py "$APP"/static/*

say "4/6 비밀번호와 서비스 설정"
if [ -f "$ENVF" ] && grep -q '^MT_PASSWORD=' "$ENVF"; then
  echo "기존 비밀번호를 그대로 사용해요."
else
  PW="${MT_PASSWORD:-$(python3 -c "import secrets;print(''.join(secrets.choice('abcdefghjkmnpqrstuvwxyz23456789') for _ in range(12)))")}"
  SECRET="$(python3 -c 'import secrets;print(secrets.token_hex(32))')"
  umask 077
  cat > "$ENVF" <<EOF
MT_PASSWORD=$PW
MT_SECRET_KEY=$SECRET
MT_DOWNLOAD_DIR=$DATA
MT_STATE_DIR=$STATE
MT_TORRENT_PORT=$TPORT
MT_HTTP_HOST=127.0.0.1
MT_HTTP_PORT=8080
EOF
  umask 022
fi
chown root:mytorrent "$ENVF"; chmod 640 "$ENVF"

cat > /etc/systemd/system/$SVC.service <<EOF
[Unit]
Description=MyTorrent (personal torrent downloader)
After=network-online.target
Wants=network-online.target

[Service]
User=mytorrent
Group=mytorrent
EnvironmentFile=$ENVF
WorkingDirectory=$APP
ExecStart=/usr/bin/python3 $APP/app.py
Restart=always
RestartSec=3
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=$DATA $STATE

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now $SVC >/dev/null 2>&1
systemctl restart $SVC

say "5/6 HTTPS 주소 만들기"
IP="$(curl -4 -fsS --max-time 8 https://api.ipify.org || curl -4 -fsS --max-time 8 https://ifconfig.me || true)"
if [ -z "$IP" ]; then
  IP="$(hostname -I | awk '{print $1}')"
  warn "공인 IP 를 자동으로 찾지 못했어요. ($IP 로 진행)"
fi
DOMAIN="${MT_DOMAIN:-${IP//./-}.sslip.io}"
cat > /etc/caddy/Caddyfile <<EOF
$DOMAIN {
    encode gzip
    reverse_proxy 127.0.0.1:8080
}
EOF
systemctl enable caddy >/dev/null 2>&1 || true
systemctl restart caddy

say "6/6 방화벽 열기 (80, 443, $TPORT)"
if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
  ufw allow 80/tcp >/dev/null; ufw allow 443/tcp >/dev/null
  ufw allow $TPORT/tcp >/dev/null; ufw allow $TPORT/udp >/dev/null
fi
# 오라클 클라우드 우분투 이미지는 iptables 로 막혀 있음 → 허용 규칙 추가
if iptables -S INPUT 2>/dev/null | grep -q -- '-j REJECT'; then
  for rule in "-p tcp --dport 80" "-p tcp --dport 443" "-p tcp --dport $TPORT" "-p udp --dport $TPORT"; do
    # shellcheck disable=SC2086
    iptables -C INPUT $rule -j ACCEPT 2>/dev/null || iptables -I INPUT 1 $rule -j ACCEPT
  done
  command -v netfilter-persistent >/dev/null && netfilter-persistent save >/dev/null 2>&1 || true
fi

sleep 3
PW_NOW="$(grep '^MT_PASSWORD=' "$ENVF" | cut -d= -f2-)"
if systemctl is-active --quiet $SVC; then OK="정상 실행 중"; else OK="실행 실패 → journalctl -u $SVC 확인"; fi

cat <<EOF

=====================================================
  설치 완료!  ($OK)

  아이폰 사파리에서 열 주소:
      https://$DOMAIN

  비밀번호:
      $PW_NOW

  * 처음 접속은 HTTPS 인증서 발급 때문에 30초쯤 걸릴 수 있어요.
  * 안 열리면 클라우드 콘솔의 '보안 그룹/방화벽'에서
    TCP 80, 443 과 TCP/UDP $TPORT 를 열어 주세요.
  * 비밀번호 다시 보기:  grep PASSWORD $ENVF
=====================================================
EOF
