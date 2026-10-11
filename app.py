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
