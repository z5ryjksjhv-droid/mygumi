"""자막(.smi / .srt / .vtt)을 사파리가 읽는 WebVTT 로 바꾼다."""
import html
import re

SUB_EXT = (".smi", ".sami", ".srt", ".vtt")
VIDEO_EXT = (".mp4", ".m4v", ".mov", ".webm", ".mkv", ".avi", ".wmv", ".ts")
WEB_VIDEO_EXT = (".mp4", ".m4v", ".mov", ".webm")  # 사파리가 직접 재생 가능

LANGS = {
    "kr": ("한국어", "ko"), "ko": ("한국어", "ko"), "kor": ("한국어", "ko"),
    "en": ("English", "en"), "eng": ("English", "en"), "us": ("English", "en"),
    "jp": ("日本語", "ja"), "ja": ("日本語", "ja"), "jpn": ("日本語", "ja"),
    "cn": ("中文", "zh"), "zh": ("中文", "zh"), "chi": ("中文", "zh"),
}


def decode_bytes(data: bytes) -> str:
    if data.startswith(b"\xef\xbb\xbf"):
        return data[3:].decode("utf-8", "replace")
    if data.startswith((b"\xff\xfe", b"\xfe\xff")):
        return data.decode("utf-16", "replace")
    for enc in ("utf-8", "cp949"):
        try:
            return data.decode(enc)
        except UnicodeDecodeError:
            pass
    return data.decode("cp949", "replace")


def _ts(ms: int) -> str:
    ms = max(0, int(ms))
    h, ms = divmod(ms, 3600000)
    m, ms = divmod(ms, 60000)
    s, ms = divmod(ms, 1000)
    return f"{h:02d}:{m:02d}:{s:02d}.{ms:03d}"


def _vtt_text(s: str) -> str:
    s = s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    lines = [ln.strip() for ln in s.split("\n")]
    s = "\n".join(ln for ln in lines if ln)
    return s.replace("-->", "->")


def _lang_of(cls: str):
    c = cls.lower()
    for k in (c, c[:-2] if c.endswith("cc") else c, c[:2]):
        if k in LANGS:
            return LANGS[k]
    return (cls, "und")


_SYNC = re.compile(r"<sync\b[^>]*?start\s*=\s*[\"']?(-?\d+)[^>]*>", re.I)
_P = re.compile(r"<p\b([^>]*)>", re.I)
_CLASS = re.compile(r"class\s*=\s*[\"']?([\w-]+)", re.I)
_BR = re.compile(r"<br\s*/?>", re.I)
_TAG = re.compile(r"<[^>]+>")


def smi_to_tracks(text: str):
    body = re.split(r"<body\b[^>]*>", text, maxsplit=1, flags=re.I)[-1]
    parts = _SYNC.split(body)
    # parts = [앞부분, start1, 내용1, start2, 내용2, ...]
    entries = {}  # class -> [(start, text)]
    for i in range(1, len(parts) - 1, 2):
        start = int(parts[i])
        chunk = parts[i + 1]
        pieces = _P.split(chunk)
        if len(pieces) == 1:
            blocks = [("default", pieces[0])]
        else:
            blocks = []
            for j in range(1, len(pieces) - 1, 2):
                m = _CLASS.search(pieces[j])
                blocks.append((m.group(1) if m else "default", pieces[j + 1]))
        for cls, raw in blocks:
            t = _BR.sub("\n", raw)
            t = _TAG.sub("", t)
            t = html.unescape(t).replace("\xa0", " ")
            t = re.sub(r"[ \t\r]+", " ", t)
            entries.setdefault(cls, []).append((start, t.strip()))

    tracks = []
    for cls, items in entries.items():
        items.sort(key=lambda x: x[0])
        cues = []
        for n, (start, t) in enumerate(items):
            if not t:
                continue
            end = items[n + 1][0] if n + 1 < len(items) else start + 5000
            if end <= start:
                continue
            cues.append(f"{_ts(start)} --> {_ts(end)}\n{_vtt_text(t)}")
        if cues:
            label, lang = _lang_of(cls) if cls != "default" else ("자막", "und")
            tracks.append((label, lang, "WEBVTT\n\n" + "\n\n".join(cues) + "\n"))
    # 한국어를 맨 앞으로
    tracks.sort(key=lambda t: 0 if t[1] == "ko" else 1)
    return tracks


_SRT_TIME = re.compile(r"(\d{1,2}):(\d{2}):(\d{2})[,.](\d{1,3})")


def srt_to_vtt(text: str) -> str:
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    text = re.sub(r"\{\\[^}]*\}", "", text)  # {\an8} 같은 태그 제거
    out = []
    for block in re.split(r"\n\s*\n", text.strip()):
        lines = block.split("\n")
        for k, ln in enumerate(lines):
            if "-->" in ln:
                a, _, b = ln.partition("-->")
                ma, mb = _SRT_TIME.search(a), _SRT_TIME.search(b)
                if not (ma and mb):
                    break
                def ms(m):
                    return ((int(m.group(1)) * 60 + int(m.group(2))) * 60 + int(m.group(3))) * 1000 + int(m.group(4).ljust(3, "0"))
                body = "\n".join(lines[k + 1:])
                body = _TAG.sub(lambda t: t.group(0) if re.fullmatch(r"</?[ibu]>", t.group(0), re.I) else "", body)
                body = body.replace("&", "&amp;").replace("-->", "->")
                if body.strip():
                    out.append(f"{_ts(ms(ma))} --> {_ts(ms(mb))}\n{body.strip()}")
                break
    return "WEBVTT\n\n" + "\n\n".join(out) + "\n"


def file_to_tracks(path: str):
    """자막 파일 → [(label, srclang, vtt_text), ...]"""
    with open(path, "rb") as f:
        data = f.read(8 * 1024 * 1024)
    text = decode_bytes(data)
    low = path.lower()
    if low.endswith((".smi", ".sami")):
        return smi_to_tracks(text)
    if low.endswith(".srt"):
        return [("자막", "und", srt_to_vtt(text))]
    if low.endswith(".vtt"):
        return [("자막", "und", text if text.lstrip().startswith("WEBVTT") else "WEBVTT\n\n" + text)]
    return []


def _stem(p: str) -> str:
    name = p.replace("\\", "/").rsplit("/", 1)[-1]
    return name.rsplit(".", 1)[0].lower() if "." in name else name.lower()


def match_subs(paths, video_idx):
    """토렌트 안의 파일 목록에서 해당 영상과 짝이 맞는 자막 인덱스들을 찾는다."""
    vstem = _stem(paths[video_idx])
    subs = [i for i, p in enumerate(paths) if p.lower().endswith(SUB_EXT)]
    exact = [i for i in subs if _stem(paths[i]) == vstem or _stem(paths[i]).startswith(vstem + ".")]
    if exact:
        return exact
    videos = [i for i, p in enumerate(paths) if p.lower().endswith(VIDEO_EXT)]
    if len(videos) == 1:  # 영상이 하나뿐이면 들어 있는 자막을 전부 사용
        return subs
    return []
