# 내 토렌트 (MyTorrent)

아이폰에서 쓰는 개인용 토렌트 다운로더. 클라우드 서버가 대신 받고, 아이폰은 사파리 홈 화면 앱으로 조작·재생합니다.

## 설치 (Ubuntu 24.04 서버, root)

```bash
curl -fsSL https://raw.githubusercontent.com/z5ryjksjhv-droid/mygumi/main/install.sh | bash
```

끝나면 접속 주소(`https://…sslip.io`)와 비밀번호가 표시됩니다. 같은 명령을 다시 실행하면 업데이트(비밀번호 유지).

## 구성
- `app.py` — Flask + libtorrent 서버
- `static/` — 아이폰용 웹앱 화면
- `install.template.sh` + `build_installer.py` — `install.sh` 생성기 (`python3 build_installer.py && cp dist/install.sh .`)

합법적인 파일에만 사용하세요.
