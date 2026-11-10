"""启动入口：python run.py

默认只监听 127.0.0.1，不给局域网留口子——这个程序手里有你的证书和密码。
"""

from __future__ import annotations

import argparse
import threading
import time
import webbrowser

import uvicorn

from app import config


def main() -> None:
    parser = argparse.ArgumentParser(description="iOS 自签名工具")
    parser.add_argument("--port", type=int, default=None, help="监听端口")
    parser.add_argument("--host", default=None, help="监听地址，默认 127.0.0.1")
    parser.add_argument("--no-browser", action="store_true", help="不自动打开浏览器")
    args = parser.parse_args()

    cfg = config.load()
    if args.port:
        cfg.port = args.port
    if args.host:
        cfg.host = args.host
    config.save(cfg)

    url = f"http://{cfg.host}:{cfg.port}"
    if not args.no_browser:
        def open_later() -> None:
            time.sleep(1.2)
            webbrowser.open(url)

        threading.Thread(target=open_later, daemon=True).start()

    print(f"\n  自签名工具已启动 → {url}\n  按 Ctrl+C 停止\n")
    uvicorn.run("app.main:app", host=cfg.host, port=cfg.port, log_level="warning")


if __name__ == "__main__":
    main()
