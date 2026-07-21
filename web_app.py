"""启动城市巡查 AI 助手的本地网页界面。"""

from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
from pathlib import Path
import os
import socket
import threading
import webbrowser


HOST = "0.0.0.0"
PORT = 8000


def get_lan_ip():
    """获取 Mac 在当前局域网中的地址。"""
    connection = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        connection.connect(("8.8.8.8", 80))
        return connection.getsockname()[0]
    except OSError:
        return socket.gethostbyname(socket.gethostname())
    finally:
        connection.close()


def main():
    os.chdir(Path(__file__).resolve().parent)
    local_address = f"http://127.0.0.1:{PORT}/index.html"
    lan_address = f"http://{get_lan_ip()}:{PORT}/index.html"
    server = ThreadingHTTPServer((HOST, PORT), SimpleHTTPRequestHandler)
    print(f"Mac 访问地址：{local_address}")
    print(f"同一 Wi-Fi 下手机访问地址：{lan_address}")
    print("关闭时请在终端按 Control + C")
    threading.Timer(0.8, lambda: webbrowser.open(local_address)).start()
    server.serve_forever()


if __name__ == "__main__":
    main()
