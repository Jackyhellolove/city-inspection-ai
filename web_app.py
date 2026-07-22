"""启动城市巡查 AI 助手的本地网页界面，并安全代理照片 AI 识别请求。"""

from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen
import json
import os
import socket
import threading
import webbrowser


HOST = "0.0.0.0"
PORT = 8000
MAX_REQUEST_BYTES = 5 * 1024 * 1024


def load_dotenv():
    """加载本机 .env；该文件已被 Git 忽略，密钥不会上传。"""
    env_path = Path(__file__).resolve().parent / ".env"
    if not env_path.exists():
        return
    for raw_line in env_path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        os.environ.setdefault(key.strip(), value.strip().strip('"').strip("'"))


def response_text(payload):
    """兼容 Responses API 的 output_text 和 output 内容结构。"""
    if isinstance(payload.get("output_text"), str):
        return payload["output_text"]
    for item in payload.get("output", []):
        for content in item.get("content", []):
            if content.get("type") == "output_text" and isinstance(content.get("text"), str):
                return content["text"]
    raise ValueError("AI 服务未返回可读取的识别结果")


def analyze_photo(image_data):
    api_key = os.environ.get("OPENAI_API_KEY")
    if not api_key:
        raise RuntimeError("未配置 OPENAI_API_KEY；请按 README 创建本机 .env 文件后重启服务")
    if not image_data.startswith("data:image/") or ";base64," not in image_data:
        raise ValueError("仅支持上传图片进行识别")

    schema = {
        "type": "object",
        "additionalProperties": False,
        "properties": {
            "category": {"type": "string", "enum": ["市政设施", "环境卫生", "园林绿化", "其他问题", "无法判断"]},
            "issue_summary": {"type": "string"},
            "risk_level": {"type": "string", "enum": ["高", "中", "低", "待确认"]},
            "department": {"type": "string", "enum": ["市政管理部门", "环卫部门", "园林部门", "城市管理部门", "待人工确认"]},
            "recommended_action": {"type": "string"},
            "confidence": {"type": "integer", "minimum": 0, "maximum": 100},
            "caution": {"type": "string"}
        },
        "required": ["category", "issue_summary", "risk_level", "department", "recommended_action", "confidence", "caution"]
    }
    instruction = (
        "你是城市巡查照片辅助分析员。只根据可见证据分析城市公共设施、环境卫生、园林绿化问题。"
        "不可臆测；照片模糊、与巡查无关或证据不足时，category 填‘无法判断’，risk_level 和 department 均填‘待确认’，"
        "confidence 设为低值，并在 caution 中明确要求人工复核。不要识别或推断人物身份、车牌或任何个人信息。"
    )
    body = {
        "model": os.environ.get("OPENAI_VISION_MODEL", "gpt-5.6"),
        "store": False,
        "instructions": instruction,
        "input": [{
            "role": "user",
            "content": [
                {"type": "input_text", "text": "请识别这张巡查现场照片，并按指定 JSON 格式返回。"},
                {"type": "input_image", "image_url": image_data, "detail": "low"}
            ]
        }],
        "text": {"format": {"type": "json_schema", "name": "inspection_photo_analysis", "strict": True, "schema": schema}}
    }
    request = Request(
        "https://api.openai.com/v1/responses",
        data=json.dumps(body, ensure_ascii=False).encode("utf-8"),
        headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"},
        method="POST"
    )
    try:
        with urlopen(request, timeout=60) as api_response:
            payload = json.loads(api_response.read().decode("utf-8"))
    except HTTPError as error:
        if error.code == 401:
            raise RuntimeError("API 密钥无效或已失效") from error
        if error.code == 429:
            raise RuntimeError("AI 服务请求过多或账户额度不足，请稍后重试") from error
        raise RuntimeError(f"AI 服务请求失败（HTTP {error.code}）") from error
    except URLError as error:
        raise RuntimeError("无法连接 AI 服务，请检查网络或代理设置") from error

    result = json.loads(response_text(payload))
    if not isinstance(result, dict):
        raise ValueError("AI 返回格式无效，请重试")
    return result


class InspectionHandler(SimpleHTTPRequestHandler):
    """静态网页 + 仅供本机服务读取密钥的 AI 识别接口。"""

    def send_json(self, status, payload):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if self.path != "/api/analyze-photo":
            self.send_json(404, {"error": "接口不存在"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if length <= 0 or length > MAX_REQUEST_BYTES:
                raise ValueError("图片过大或请求无效，请重新选择照片")
            payload = json.loads(self.rfile.read(length).decode("utf-8"))
            image_data = payload.get("image") if isinstance(payload, dict) else None
            result = analyze_photo(image_data or "")
            self.send_json(200, {"analysis": result})
        except (ValueError, RuntimeError) as error:
            self.send_json(400, {"error": str(error)})
        except Exception:
            self.send_json(500, {"error": "AI 识别暂时不可用，请稍后重试"})

    def log_message(self, format_string, *args):
        # 不记录请求正文，避免将现场照片或密钥相关信息写进终端日志。
        print("[网页服务]", format_string % args)


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
    load_dotenv()
    local_address = f"http://127.0.0.1:{PORT}/index.html"
    lan_address = f"http://{get_lan_ip()}:{PORT}/index.html"
    server = ThreadingHTTPServer((HOST, PORT), InspectionHandler)
    print(f"Mac 访问地址：{local_address}")
    print(f"同一 Wi-Fi 下手机访问地址：{lan_address}")
    print("照片 AI 识别：" + ("已配置" if os.environ.get("OPENAI_API_KEY") else "未配置（请先创建 .env）"))
    print("关闭时请在终端按 Control + C")
    threading.Timer(0.8, lambda: webbrowser.open(local_address)).start()
    server.serve_forever()


if __name__ == "__main__":
    main()
