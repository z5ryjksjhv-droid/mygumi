#!/usr/bin/env python3
"""app.py + static/* 를 하나의 install.sh 로 묶는다."""
import base64, os

HERE = os.path.dirname(os.path.abspath(__file__))
TEXT = ["app.py", "static/index.html", "static/login.html", "static/manifest.webmanifest"]
BIN = ["static/icon-180.png", "static/icon-192.png", "static/icon-512.png"]

parts = []
for rel in TEXT:
    body = open(os.path.join(HERE, rel), encoding="utf-8").read()
    assert "__MT_EOF__" not in body
    parts.append(f"cat > \"$APP/{rel}\" <<'__MT_EOF__'\n{body}{'' if body.endswith(chr(10)) else chr(10)}__MT_EOF__\n")
for rel in BIN:
    b64 = base64.b64encode(open(os.path.join(HERE, rel), "rb").read()).decode()
    lines = "\n".join(b64[i:i + 76] for i in range(0, len(b64), 76))
    parts.append(f"base64 -d > \"$APP/{rel}\" <<'__MT_EOF__'\n{lines}\n__MT_EOF__\n")

tpl = open(os.path.join(HERE, "install.template.sh"), encoding="utf-8").read()
out = tpl.replace("#__FILES__\n", "".join(parts))
dst = os.path.join(HERE, "dist", "install.sh")
os.makedirs(os.path.dirname(dst), exist_ok=True)
open(dst, "w", encoding="utf-8", newline="\n").write(out)
os.chmod(dst, 0o755)
print(dst, len(out), "bytes")
