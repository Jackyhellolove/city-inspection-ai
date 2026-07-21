"""启动城市巡查 AI 助手的本地网页界面。"""

from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
from pathlib import Path
import os
import threading
import webbrowser


HOST = "127.0.0.1"
PORT = 8000


def main():
    os.chdir(Path(__file__).resolve().parent)
    address = f"http://{HOST}:{PORT}/index.html"
    server = ThreadingHTTPServer((HOST, PORT), SimpleHTTPRequestHandler)
    print(f"城市巡查 AI 助手已启动：{address}")
    print("关闭时请在终端按 Control + C")
    threading.Timer(0.8, lambda: webbrowser.open(address)).start()
    server.serve_forever()


if __name__ == "__main__":
    main()
