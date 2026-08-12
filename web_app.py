"""启动城市巡查 AI 助手的本地网页界面，并安全代理照片 AI 识别请求。"""

from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urlparse
from urllib.request import Request, urlopen
import argparse
import base64
import json
import mimetypes
import os
import socket
import threading
import time
import webbrowser


HOST = "0.0.0.0"
DEFAULT_PORT = 8000
MAX_REQUEST_BYTES = 5 * 1024 * 1024
PUBLIC_FILES = {
    "/": "index.html",
    "/index.html": "index.html",
    "/manifest.json": "manifest.json",
    "/service-worker.js": "service-worker.js",
    "/icon-192.png": "icon-192.png",
    "/icon-512.png": "icon-512.png",
}
ANALYSIS_SCHEMA = {
    "type": "object",
    "additionalProperties": False,
    "properties": {
        "category": {"type": "string", "enum": ["市政设施", "环境卫生", "园林绿化", "其他问题", "无法判断"]},
        "issue_summary": {"type": "string"},
        "risk_level": {"type": "string", "enum": ["高", "中", "低", "待确认"]},
        "department": {"type": "string", "enum": ["市政管理部门", "环卫部门", "园林部门", "城市管理部门", "待人工确认"]},
        "recommended_action": {"type": "string"},
        "confidence": {"type": "integer", "minimum": 0, "maximum": 100},
        "caution": {"type": "string"},
    },
    "required": ["category", "issue_summary", "risk_level", "department", "recommended_action", "confidence", "caution"],
}


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


def chat_completion_text(payload):
    """读取 OpenAI 兼容 Chat Completions 的文本结果。"""
    choices = payload.get("choices", [])
    if choices and isinstance(choices[0].get("message", {}).get("content"), str):
        return choices[0]["message"]["content"]
    raise ValueError("AI 服务未返回可读取的识别结果")


def ai_config():
    """从 .env 读取模型供应商配置，并兼容旧版 OpenAI 配置。"""
    provider = os.environ.get("AI_PROVIDER", "openai").strip().lower()
    configs = {
        "openai": {
            "key": os.environ.get("AI_API_KEY") or os.environ.get("OPENAI_API_KEY"),
            "model": os.environ.get("AI_MODEL") or os.environ.get("OPENAI_VISION_MODEL", "gpt-5.6"),
            "base_url": os.environ.get("AI_BASE_URL", "https://api.openai.com/v1"),
            "api": "responses",
            "label": "OpenAI",
        },
        "dashscope": {
            "key": os.environ.get("AI_API_KEY") or os.environ.get("DASHSCOPE_API_KEY"),
            "model": os.environ.get("AI_MODEL", "qwen3-vl-plus"),
            "base_url": os.environ.get("AI_BASE_URL", "https://dashscope.aliyuncs.com/compatible-mode/v1"),
            "api": "chat_completions",
            "label": "通义千问（百炼）",
        },
        "compatible": {
            "key": os.environ.get("AI_API_KEY"),
            "model": os.environ.get("AI_MODEL"),
            "base_url": os.environ.get("AI_BASE_URL"),
            "api": "chat_completions",
            "label": "OpenAI 兼容模型",
        },
    }
    if provider not in configs:
        raise RuntimeError("AI_PROVIDER 仅支持 openai、dashscope 或 compatible")
    config = configs[provider]
    if not config["key"]:
        raise RuntimeError(f"未配置 {config['label']} 的 API 密钥，请检查 .env")
    if not config["model"] or not config["base_url"]:
        raise RuntimeError("请在 .env 中填写 AI_MODEL 和 AI_BASE_URL")
    return config


def parse_analysis(text):
    """解析模型返回的 JSON，兼容少数模型把 JSON 包在 Markdown 代码块中的情况。"""
    text = text.strip()
    if text.startswith("```"):
        text = text.split("\n", 1)[-1]
        if text.endswith("```"):
            text = text[:-3]
    result = json.loads(text.strip())
    if not isinstance(result, dict):
        raise ValueError("AI 返回格式无效，请重试")
    required = ANALYSIS_SCHEMA["required"]
    missing = [field for field in required if field not in result]
    if missing:
        raise ValueError(f"AI 返回结果缺少字段：{', '.join(missing)}；请重试或更换模型")
    if result["category"] not in ANALYSIS_SCHEMA["properties"]["category"]["enum"]:
        raise ValueError("AI 返回的问题类别不符合巡查台账格式，请更换模型或重试")
    if result["risk_level"] not in ANALYSIS_SCHEMA["properties"]["risk_level"]["enum"]:
        raise ValueError("AI 返回的风险等级不符合巡查台账格式，请更换模型或重试")
    if result["department"] not in ANALYSIS_SCHEMA["properties"]["department"]["enum"]:
        raise ValueError("AI 返回的处置部门不符合巡查台账格式，请更换模型或重试")
    if isinstance(result["confidence"], bool) or not isinstance(result["confidence"], int) or not 0 <= result["confidence"] <= 100:
        raise ValueError("AI 返回的置信度无效，请更换模型或重试")
    for field in ("issue_summary", "recommended_action", "caution"):
        if not isinstance(result[field], str) or not result[field].strip():
            raise ValueError(f"AI 返回的 {field} 无效，请更换模型或重试")
    return {field: result[field] for field in required}


def analyze_photo(image_data):
    if not image_data.startswith("data:image/") or ";base64," not in image_data:
        raise ValueError("仅支持上传图片进行识别")
    config = ai_config()

    instruction = (
        "你是城市巡查照片辅助分析员。只根据可见证据分析城市公共设施、环境卫生、园林绿化问题。"
        "不可臆测；照片模糊、与巡查无关或证据不足时，category 填‘无法判断’，risk_level 和 department 均填‘待确认’，"
        "confidence 设为低值，并在 caution 中明确要求人工复核。不要识别或推断人物身份、车牌或任何个人信息。"
    )
    if config["api"] == "responses":
        endpoint = f"{config['base_url'].rstrip('/')}/responses"
        body = {
            "model": config["model"], "store": False, "instructions": instruction,
            "input": [{"role": "user", "content": [
                {"type": "input_text", "text": "请识别这张巡查现场照片，并按指定 JSON 格式返回。"},
                {"type": "input_image", "image_url": image_data, "detail": "low"}
            ]}],
            "text": {"format": {"type": "json_schema", "name": "inspection_photo_analysis", "strict": True, "schema": ANALYSIS_SCHEMA}},
        }
        get_text = response_text
    else:
        endpoint = f"{config['base_url'].rstrip('/')}/chat/completions"
        json_rule = "必须只返回一个 JSON 对象，不要 Markdown。字段和约束如下：" + json.dumps(ANALYSIS_SCHEMA, ensure_ascii=False)
        body = {
            "model": config["model"], "temperature": 0.1,
            "messages": [{"role": "system", "content": instruction + json_rule}, {"role": "user", "content": [
                {"type": "text", "text": "请识别这张巡查现场照片。"},
                {"type": "image_url", "image_url": {"url": image_data}}
            ]}],
        }
        get_text = chat_completion_text
    request = Request(
        endpoint,
        data=json.dumps(body, ensure_ascii=False).encode("utf-8"),
        headers={"Authorization": f"Bearer {config['key']}", "Content-Type": "application/json"},
        method="POST"
    )
    try:
        with urlopen(request, timeout=60) as api_response:
            payload = json.loads(api_response.read().decode("utf-8"))
    except HTTPError as error:
        try:
            error_payload = json.loads(error.read().decode("utf-8"))
            detail = error_payload.get("message") or error_payload.get("error", {}).get("message")
        except (UnicodeDecodeError, json.JSONDecodeError, AttributeError):
            detail = None
        if error.code == 401:
            raise RuntimeError("API 密钥无效或已失效") from error
        if error.code == 429:
            raise RuntimeError("AI 服务请求过多或账户额度不足，请稍后重试") from error
        suffix = f"：{str(detail)[:300]}" if detail else ""
        raise RuntimeError(f"AI 服务请求失败（HTTP {error.code}）{suffix}") from error
    except URLError as error:
        raise RuntimeError("无法连接 AI 服务，请检查网络或代理设置") from error

    return parse_analysis(get_text(payload))


def supabase_public_config():
    """云端从环境变量提供公开配置；本机继续兼容 supabase-config.js。"""
    url = os.environ.get("SUPABASE_URL", "").strip()
    key = os.environ.get("SUPABASE_PUBLISHABLE_KEY", "").strip()
    return url, key


def verify_user_token(authorization):
    """使用 Supabase Auth 验证网页登录令牌，避免公开 AI 接口被匿名调用。"""
    supabase_url, publishable_key = supabase_public_config()
    if not supabase_url or not publishable_key:
        # 本机旧配置仍可运行；正式部署必须通过环境变量配置 Supabase。
        if os.environ.get("RENDER") or os.environ.get("APP_ENV") == "production":
            raise RuntimeError("服务器未配置 Supabase 登录验证")
        return
    if not authorization or not authorization.startswith("Bearer "):
        raise PermissionError("请先登录后再使用照片 AI 识别")
    token = authorization.removeprefix("Bearer ").strip()
    request = Request(
        f"{supabase_url.rstrip('/')}/auth/v1/user",
        headers={"apikey": publishable_key, "Authorization": f"Bearer {token}"},
    )
    try:
        with urlopen(request, timeout=15) as response:
            user = json.loads(response.read().decode("utf-8"))
    except HTTPError as error:
        raise PermissionError("登录状态已失效，请重新登录") from error
    except URLError as error:
        raise RuntimeError("暂时无法验证登录状态，请稍后重试") from error
    if not user.get("id"):
        raise PermissionError("登录状态无效，请重新登录")


class InspectionHandler(SimpleHTTPRequestHandler):
    """静态网页 + 仅供本机服务读取密钥的 AI 识别接口。"""

    def send_json(self, status, payload):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def end_headers(self):
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "same-origin")
        self.send_header("Permissions-Policy", "camera=(self), geolocation=(self)")
        if self.headers.get("X-Forwarded-Proto") == "https":
            self.send_header("Strict-Transport-Security", "max-age=31536000; includeSubDomains")
        super().end_headers()

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/healthz":
            self.send_json(200, {"status": "ok"})
            return
        if path == "/supabase-config.js":
            supabase_url, publishable_key = supabase_public_config()
            if supabase_url and publishable_key:
                body = (
                    "window.SUPABASE_CONFIG = "
                    + json.dumps({"url": supabase_url, "publishableKey": publishable_key})
                    + ";"
                ).encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "application/javascript; charset=utf-8")
                self.send_header("Cache-Control", "no-store")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            local_config = Path("supabase-config.js")
            if local_config.is_file():
                self.path = "/supabase-config.js"
                super().do_GET()
                return
            self.send_json(404, {"error": "Supabase 配置不存在"})
            return
        file_name = PUBLIC_FILES.get(path)
        if not file_name:
            self.send_json(404, {"error": "文件不存在"})
            return
        self.path = f"/{file_name}"
        super().do_GET()

    def do_HEAD(self):
        """HEAD 请求也只允许访问公开文件，避免探测本机配置或 SQL 文件。"""
        path = urlparse(self.path).path
        if path == "/healthz":
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.end_headers()
            return
        if path == "/supabase-config.js":
            self.send_response(200)
            self.send_header("Content-Type", "application/javascript; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            return
        file_name = PUBLIC_FILES.get(path)
        if not file_name:
            self.send_response(404)
            self.end_headers()
            return
        self.path = f"/{file_name}"
        super().do_HEAD()

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
            verify_user_token(self.headers.get("Authorization", ""))
            result = analyze_photo(image_data or "")
            self.send_json(200, {"analysis": result})
        except PermissionError as error:
            self.send_json(401, {"error": str(error)})
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
        try:
            return socket.gethostbyname(socket.gethostname())
        except OSError:
            return "127.0.0.1"
    finally:
        connection.close()


def image_file_to_data_url(image_path):
    """读取测试图片；只接受与网页上传一致的常见图片格式。"""
    path = Path(image_path).expanduser().resolve()
    if not path.is_file():
        raise ValueError(f"找不到测试图片：{path}")
    if path.stat().st_size > MAX_REQUEST_BYTES:
        raise ValueError("测试图片超过 5 MB，请先压缩后再测试")
    mime_type, _ = mimetypes.guess_type(path.name)
    if mime_type not in {"image/jpeg", "image/png", "image/webp", "image/gif"}:
        raise ValueError("测试图片仅支持 JPG、PNG、WebP 或 GIF")
    encoded = base64.b64encode(path.read_bytes()).decode("ascii")
    return f"data:{mime_type};base64,{encoded}"


def test_ai_connection(image_path=None):
    """验证模型配置；指定图片时可用于横向比较视觉识别结果。"""
    config = ai_config()
    print(f"正在测试：{config['label']} / {config['model']}…")
    # 百炼等视觉模型要求图片宽高达到最小限制；项目图标可作为无业务含义的合规测试图。
    default_image = Path(__file__).resolve().parent / "icon-192.png"
    image_data = image_file_to_data_url(image_path) if image_path else image_file_to_data_url(default_image)
    started_at = time.monotonic()
    result = analyze_photo(image_data)
    elapsed = time.monotonic() - started_at
    print("模型测试成功：已收到结构化识别结果。")
    print(f"耗时：{elapsed:.1f} 秒")
    print("识别结果：" + json.dumps(result, ensure_ascii=False, indent=2))


def main():
    parser = argparse.ArgumentParser(description="城市巡查 AI 助手")
    parser.add_argument("--test-ai", nargs="?", const="", metavar="图片路径", help="测试当前模型后退出；可指定巡查照片比较识别效果")
    args = parser.parse_args()
    os.chdir(Path(__file__).resolve().parent)
    load_dotenv()
    port = int(os.environ.get("PORT", DEFAULT_PORT))
    if args.test_ai is not None:
        try:
            test_ai_connection(args.test_ai or None)
        except (ValueError, RuntimeError) as error:
            print(f"模型测试失败：{error}")
            raise SystemExit(1)
        return
    production = bool(os.environ.get("RENDER")) or os.environ.get("APP_ENV") == "production"
    local_address = f"http://127.0.0.1:{port}/index.html"
    server = ThreadingHTTPServer((HOST, port), InspectionHandler)
    if production:
        print(f"服务已监听：0.0.0.0:{port}")
    else:
        print(f"Mac 访问地址：{local_address}")
        print(f"同一 Wi-Fi 下手机访问地址：http://{get_lan_ip()}:{port}/index.html")
    try:
        config = ai_config()
        print(f"照片 AI 识别：已配置（{config['label']} / {config['model']}）")
    except RuntimeError:
        print("照片 AI 识别：未配置（请先创建 .env）")
    print("关闭时请在终端按 Control + C")
    if not production:
        threading.Timer(0.8, lambda: webbrowser.open(local_address)).start()
    server.serve_forever()


if __name__ == "__main__":
    main()
