"""启动城市巡查 AI 助手的本地网页界面，并安全代理照片 AI 识别请求。"""

from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urlparse
from urllib.request import Request, urlopen
import argparse
import base64
import json
import math
import mimetypes
import os
import re
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
    "/command-center.html": "command-center.html",
    "/vendor/leaflet.css": "vendor/leaflet.css",
    "/vendor/leaflet.js": "vendor/leaflet.js",
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
        "recommended_standard_code": {"type": "string", "pattern": "^(|[0-9]{5})$"},
        "recommended_standard_name": {"type": "string"},
        "issue_regions": {
            "type": "array",
            "maxItems": 5,
            "items": {
                "type": "object",
                "additionalProperties": False,
                "properties": {
                    "label": {"type": "string"},
                    "x": {"type": "integer", "minimum": 0, "maximum": 1000},
                    "y": {"type": "integer", "minimum": 0, "maximum": 1000},
                    "width": {"type": "integer", "minimum": 1, "maximum": 1000},
                    "height": {"type": "integer", "minimum": 1, "maximum": 1000},
                },
                "required": ["label", "x", "y", "width", "height"],
            },
        },
    },
    "required": ["category", "issue_summary", "risk_level", "department", "recommended_action", "confidence", "caution", "recommended_standard_code", "recommended_standard_name", "issue_regions"],
}
SITUATION_SCHEMA = {
    "type": "object",
    "additionalProperties": False,
    "properties": {
        "overall_assessment": {"type": "string"},
        "risk_level": {"type": "string", "enum": ["低", "中", "较高", "高"]},
        "key_findings": {"type": "array", "items": {"type": "string"}},
        "recommended_actions": {"type": "array", "items": {"type": "string"}},
        "data_cautions": {"type": "array", "items": {"type": "string"}},
    },
    "required": [
        "overall_assessment", "risk_level", "key_findings", "recommended_actions", "data_cautions"
    ],
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


def valid_header_value(value):
    """HTTP 请求头只接受可安全编码的 ASCII 配置值。"""
    return bool(value) and value.isascii() and not any(ord(char) < 32 or ord(char) == 127 for char in value)


def require_header_value(name, value):
    """在发出请求前拦截中文占位符，避免底层抛出 latin-1 编码错误。"""
    if not valid_header_value(value or ""):
        raise RuntimeError(f"{name} 配置无效：请填写控制台提供的英文、数字格式值，不要填写中文说明文字")
    return value


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
    config["key"] = require_header_value("AI_API_KEY", config["key"].strip())
    if not config["model"] or not config["base_url"]:
        raise RuntimeError("请在 .env 中填写 AI_MODEL 和 AI_BASE_URL")
    return config


def situation_ai_models():
    """返回管理员在环境变量中明确开放的态势研判模型。"""
    default_model = os.environ.get("SITUATION_AI_MODEL", "qwen3.7-plus").strip()
    configured = os.environ.get("SITUATION_AI_MODELS", "").split(",")
    models = []
    for candidate in [default_model, *configured]:
        model = candidate.strip()
        if not model or model in models:
            continue
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:/-]{0,119}", model):
            raise RuntimeError("SITUATION_AI_MODEL(S) 包含无效的模型名称")
        models.append(model)
    if not models:
        raise RuntimeError("请至少配置一个态势研判模型")
    return {"default": default_model, "models": models}


def situation_ai_config(requested_model=None):
    """态势研判使用独立文本模型，默认复用照片识别的百炼密钥。"""
    provider = os.environ.get("SITUATION_AI_PROVIDER", "dashscope").strip().lower()
    if provider != "dashscope":
        raise RuntimeError("SITUATION_AI_PROVIDER 当前仅支持 dashscope")
    model_options = situation_ai_models()
    model = str(requested_model or model_options["default"]).strip()
    if model not in model_options["models"]:
        raise ValueError("所选态势研判模型未在服务器配置中开放")
    config = {
        "key": (
            os.environ.get("SITUATION_AI_API_KEY")
            or os.environ.get("AI_API_KEY")
            or os.environ.get("DASHSCOPE_API_KEY")
        ),
        "model": model,
        "base_url": os.environ.get(
            "SITUATION_AI_BASE_URL", "https://dashscope.aliyuncs.com/compatible-mode/v1"
        ).strip(),
        "label": "通义千问态势研判（百炼）",
    }
    if not config["key"]:
        raise RuntimeError("未配置百炼 API Key，请检查 AI_API_KEY 或 SITUATION_AI_API_KEY")
    config["key"] = require_header_value("SITUATION_AI_API_KEY / AI_API_KEY", config["key"].strip())
    if not config["model"] or not config["base_url"]:
        raise RuntimeError("请填写 SITUATION_AI_MODEL 和 SITUATION_AI_BASE_URL")
    return config


def normalized_issue_regions(value):
    """将模型给出的归一化识别框约束在图片范围内；无可靠坐标时宁可不展示。"""
    if not isinstance(value, list):
        return []
    regions = []
    for item in value[:5]:
        if not isinstance(item, dict):
            continue
        values = []
        for key in ("x", "y", "width", "height"):
            raw_value = item.get(key)
            if isinstance(raw_value, bool):
                values = []
                break
            try:
                raw_number = float(raw_value)
            except (TypeError, ValueError):
                values = []
                break
            if not math.isfinite(raw_number):
                values = []
                break
            values.append(int(round(raw_number)))
        if len(values) != 4:
            continue
        x, y, width, height = values
        if not 0 <= x < 1000 or not 0 <= y < 1000 or width <= 0 or height <= 0:
            continue
        width = min(width, 1000 - x)
        height = min(height, 1000 - y)
        if width < 12 or height < 12:
            continue
        label = re.sub(r"\s+", " ", str(item.get("label") or "问题区域").strip())[:40]
        regions.append({"label": label or "问题区域", "x": x, "y": y, "width": width, "height": height})
    return regions


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
    for field in ("issue_summary", "recommended_action", "caution", "recommended_standard_code", "recommended_standard_name"):
        if not isinstance(result[field], str) or not result[field].strip():
            if field in {"recommended_standard_code", "recommended_standard_name"} and result[field] == "":
                continue
            raise ValueError(f"AI 返回的 {field} 无效，请更换模型或重试")
    if result["recommended_standard_code"] and not re.fullmatch(r"\d{5}", result["recommended_standard_code"]):
        raise ValueError("AI 返回的国标事项代码无效，请更换模型或重试")
    parsed = {field: result[field] for field in required if field != "issue_regions"}
    parsed["issue_regions"] = normalized_issue_regions(result.get("issue_regions"))
    return parsed


def analyze_photo(image_data):
    if not image_data.startswith("data:image/") or ";base64," not in image_data:
        raise ValueError("仅支持上传图片进行识别")
    config = ai_config()

    instruction = (
        "你是城市巡查照片辅助分析员。只根据可见证据分析城市公共设施、环境卫生、园林绿化问题。"
        "不可臆测；照片模糊、与巡查无关或证据不足时，category 填‘无法判断’，risk_level 和 department 均填‘待确认’，"
        "confidence 设为低值，并在 caution 中明确要求人工复核。不要识别或推断人物身份、车牌或任何个人信息。"
        "issue_regions 必须始终返回数组：仅对能明确看见的问题目标给出最多 5 个框，坐标使用图片左上角为原点、0 到 1000 的归一化整数（x、y、width、height）；"
        "目标边界无法可靠判断时返回空数组，绝不猜测坐标。"
        "如能基于照片内容明确对应 GB/T 47678.5-2026 的管理事项，可在 recommended_standard_code 返回五位代码、"
        "recommended_standard_name 返回事项名称；只要任一项不能确认，两项都返回空字符串。该候选仅供前端与本地国标目录核验，不得猜测。"
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


def analyze_situation(issues, mode="quick", model=None):
    """只把问题类型、描述和同类数量交给文本模型，并返回结果与用量。"""
    if mode not in {"quick", "deep"}:
        raise ValueError("研判模式无效")
    if not isinstance(issues, list) or not issues:
        raise ValueError("问题分析数据为空或格式无效")
    cleaned_issues = []
    for item in issues[:120]:
        if not isinstance(item, dict):
            continue
        issue_type = str(item.get("issue_type") or "其他问题").strip()[:80]
        description = str(item.get("issue_description") or "未填写问题描述").strip()[:300]
        try:
            count = max(1, int(item.get("count") or 1))
        except (TypeError, ValueError):
            count = 1
        cleaned_issues.append({"issue_type": issue_type, "issue_description": description, "count": count})
    if not cleaned_issues:
        raise ValueError("没有可供研判的问题数据")
    encoded_issues = json.dumps(cleaned_issues, ensure_ascii=False)
    if len(encoded_issues) > 80_000:
        raise ValueError("问题分析数据过大，请缩小统计范围")
    config = situation_ai_config(model)
    instruction = (
        "你是城市管理问题辅助研判员。只能依据用户提供的问题类型、问题描述和数量进行归纳，"
        "识别高频问题与共同特征，不得虚构地点、部门、政策、原因或案件事实。"
        "建议应简短、具体、可执行，所有结论都需要人工复核。"
    )
    body = {
        "model": config["model"],
        "temperature": 0.2,
        "enable_thinking": mode == "deep",
        "response_format": {"type": "json_object"},
        "messages": [
            {"role": "system", "content": instruction + "必须只返回 JSON 对象，格式：" + json.dumps(SITUATION_SCHEMA, ensure_ascii=False)},
            {"role": "user", "content": "请研判以下城市管理问题汇总：\n" + encoded_issues},
        ],
    }
    if mode == "quick":
        body["max_tokens"] = 1200
    request = Request(
        f"{config['base_url'].rstrip('/')}/chat/completions",
        data=json.dumps(body, ensure_ascii=False).encode("utf-8"),
        headers={"Authorization": f"Bearer {config['key']}", "Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urlopen(request, timeout=120) as api_response:
            payload = json.loads(api_response.read().decode("utf-8"))
    except HTTPError as error:
        try:
            error_payload = json.loads(error.read().decode("utf-8"))
            detail = error_payload.get("message") or error_payload.get("error", {}).get("message")
        except (UnicodeDecodeError, json.JSONDecodeError, AttributeError):
            detail = None
        if error.code == 401:
            raise RuntimeError("百炼 API 密钥无效或无权调用态势研判模型") from error
        if error.code == 429:
            raise RuntimeError("态势研判调用过多或账户额度不足，请稍后重试") from error
        suffix = f"：{str(detail)[:300]}" if detail else ""
        raise RuntimeError(f"态势研判请求失败（HTTP {error.code}）{suffix}") from error
    except URLError as error:
        raise RuntimeError("无法连接百炼态势研判服务，请检查网络") from error

    result = parse_json_object(chat_completion_text(payload))
    required = SITUATION_SCHEMA["required"]
    missing = [field for field in required if field not in result]
    if missing:
        raise ValueError(f"态势研判结果缺少字段：{', '.join(missing)}")
    if result["risk_level"] not in SITUATION_SCHEMA["properties"]["risk_level"]["enum"]:
        raise ValueError("态势研判风险等级无效")
    if not isinstance(result["overall_assessment"], str) or not result["overall_assessment"].strip():
        raise ValueError("态势研判总体判断无效")
    for field in required[2:]:
        if not isinstance(result[field], list) or not all(isinstance(item, str) for item in result[field]):
            raise ValueError(f"态势研判字段 {field} 格式无效")
        result[field] = [item.strip() for item in result[field] if item.strip()][:8]
    usage_payload = payload.get("usage") if isinstance(payload, dict) else {}
    usage_payload = usage_payload if isinstance(usage_payload, dict) else {}

    def token_count(name):
        try:
            return max(0, int(usage_payload.get(name) or 0))
        except (TypeError, ValueError):
            return 0

    usage = {
        "prompt_tokens": token_count("prompt_tokens"),
        "completion_tokens": token_count("completion_tokens"),
        "total_tokens": token_count("total_tokens"),
    }
    return {
        "analysis": {field: result[field] for field in required},
        "usage": usage,
        "model": str(payload.get("model") or config["model"])[:120],
    }


def parse_json_object(text):
    """解析纯 JSON 或 Markdown 代码块包裹的 JSON 对象。"""
    text = text.strip()
    if text.startswith("```"):
        text = text.split("\n", 1)[-1]
        if text.endswith("```"):
            text = text[:-3]
    result = json.loads(text.strip())
    if not isinstance(result, dict):
        raise ValueError("AI 返回的态势研判格式无效")
    return result


def supabase_public_config():
    """云端从环境变量提供公开配置；本机继续兼容 supabase-config.js。"""
    url = os.environ.get("SUPABASE_URL", "").strip()
    key = os.environ.get("SUPABASE_PUBLISHABLE_KEY", "").strip()
    parsed_url = urlparse(url)
    if parsed_url.scheme in {"http", "https"} and parsed_url.netloc and valid_header_value(key):
        return url, key

    # 本机允许从已存在的公开 JS 配置回退，避免 .env 中的中文占位符破坏登录鉴权。
    if not (os.environ.get("RENDER") or os.environ.get("APP_ENV") == "production"):
        config_path = Path(__file__).resolve().parent / "supabase-config.js"
        if config_path.is_file():
            source = config_path.read_text(encoding="utf-8")
            url_match = re.search(r"\burl\s*:\s*['\"]([^'\"]+)['\"]", source)
            key_match = re.search(r"\bpublishableKey\s*:\s*['\"]([^'\"]+)['\"]", source)
            local_url = url_match.group(1).strip() if url_match else ""
            local_key = key_match.group(1).strip() if key_match else ""
            parsed_local_url = urlparse(local_url)
            if parsed_local_url.scheme in {"http", "https"} and parsed_local_url.netloc and valid_header_value(local_key):
                return local_url, local_key
    return "", ""


def amap_public_config():
    """向驾驶舱提供高德 Web 端公开配置；不要在这里放 Web 服务私钥。"""
    return {
        "key": (os.environ.get("AMAP_WEB_KEY") or os.environ.get("AMAP_KEY") or "").strip(),
        "securityJsCode": (
            os.environ.get("AMAP_SECURITY_JS_CODE") or os.environ.get("AMAP_SECURITY_CODE") or ""
        ).strip(),
        "serviceHost": os.environ.get("AMAP_SERVICE_HOST", "").strip(),
        "coordinateSystem": os.environ.get("AMAP_COORDINATE_SYSTEM", "WGS84").strip().upper(),
    }


def verify_user_token(authorization):
    """使用 Supabase Auth 验证网页登录令牌，避免公开 AI 接口被匿名调用。"""
    supabase_url, publishable_key = supabase_public_config()
    if not supabase_url or not publishable_key:
        # 本机旧配置仍可运行；正式部署必须通过环境变量配置 Supabase。
        if os.environ.get("RENDER") or os.environ.get("APP_ENV") == "production":
            raise RuntimeError("服务器未配置 Supabase 登录验证")
        return
    if not authorization or not authorization.startswith("Bearer "):
        raise PermissionError("请先登录后再使用 AI 功能")
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
    return user


def verify_admin_token(authorization):
    """态势研判涉及全局数据并产生模型费用，只允许管理员调用。"""
    user = verify_user_token(authorization)
    supabase_url, publishable_key = supabase_public_config()
    if not supabase_url or not publishable_key:
        if os.environ.get("RENDER") or os.environ.get("APP_ENV") == "production":
            raise RuntimeError("服务器未配置 Supabase 管理员验证")
        return user
    token = authorization.removeprefix("Bearer ").strip()
    profile_url = (
        f"{supabase_url.rstrip('/')}/rest/v1/profiles"
        f"?id=eq.{user['id']}&select=role&limit=1"
    )
    request = Request(
        profile_url,
        headers={"apikey": publishable_key, "Authorization": f"Bearer {token}"},
    )
    try:
        with urlopen(request, timeout=15) as response:
            profiles = json.loads(response.read().decode("utf-8"))
    except HTTPError as error:
        raise PermissionError("无法验证管理员权限，请重新登录") from error
    except URLError as error:
        raise RuntimeError("暂时无法验证管理员权限，请稍后重试") from error
    if not profiles or profiles[0].get("role") != "admin":
        raise PermissionError("仅管理员可以使用城市运行态势 AI 研判")
    return user


def reverse_geocode(latitude, longitude):
    """把设备坐标反查为适合填写在巡查表单中的道路名称。"""
    try:
        latitude = float(latitude)
        longitude = float(longitude)
    except (TypeError, ValueError) as error:
        raise ValueError("位置坐标格式无效") from error
    if not -90 <= latitude <= 90 or not -180 <= longitude <= 180:
        raise ValueError("位置坐标超出有效范围")

    query = urlencode({
        "format": "jsonv2",
        "lat": f"{latitude:.6f}",
        "lon": f"{longitude:.6f}",
        "zoom": "18",
        "addressdetails": "1",
        "layer": "address",
        "accept-language": "zh-CN,zh,en",
    })
    request = Request(
        f"https://nominatim.openstreetmap.org/reverse?{query}",
        headers={
            "Accept": "application/json",
            "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.6",
            "User-Agent": "city-inspection-ai/1.0 (https://city-inspection-ai.onrender.com/)",
        },
    )
    try:
        with urlopen(request, timeout=12) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except HTTPError as error:
        raise RuntimeError(f"道路名称查询失败（HTTP {error.code}）") from error
    except (URLError, TimeoutError) as error:
        raise RuntimeError("暂时无法查询道路名称") from error
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise RuntimeError("道路名称查询结果无法读取") from error

    address = payload.get("address") if isinstance(payload, dict) else None
    address = address if isinstance(address, dict) else {}
    road = next((address.get(key) for key in (
        "road", "pedestrian", "residential", "service", "footway", "path", "cycleway"
    ) if address.get(key)), "")
    house_number = str(address.get("house_number") or "").strip()
    area = next((address.get(key) for key in (
        "neighbourhood", "quarter", "suburb", "city_district", "district", "borough"
    ) if address.get(key)), "")
    city = next((address.get(key) for key in ("city", "town", "village", "county") if address.get(key)), "")

    if road:
        road_label = f"{road}{house_number + '号' if house_number and not house_number.endswith('号') else house_number}"
        parts = [part for part in (city, area, road_label) if part]
        label = " · ".join(dict.fromkeys(parts))
        return {"address": label, "road": road, "resolved": True}

    fallback_parts = [part for part in (city, area) if part]
    if not fallback_parts and isinstance(payload, dict):
        fallback_parts = [part.strip() for part in str(payload.get("display_name") or "").split(",")[:3] if part.strip()]
    return {
        "address": " · ".join(dict.fromkeys(fallback_parts)),
        "road": "",
        "resolved": False,
    }


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
        if path == "/api/situation-models":
            try:
                verify_admin_token(self.headers.get("Authorization", ""))
                self.send_json(200, situation_ai_models())
            except PermissionError as error:
                self.send_json(401, {"error": str(error)})
            except (ValueError, RuntimeError) as error:
                self.send_json(400, {"error": str(error)})
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
        if path == "/amap-config.js":
            config = amap_public_config()
            local_config = Path("amap-config.js")
            if not config["key"] and local_config.is_file():
                self.path = "/amap-config.js"
                super().do_GET()
                return
            body = ("window.AMAP_CONFIG = " + json.dumps(config) + ";").encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/javascript; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
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
        if path in {"/supabase-config.js", "/amap-config.js"}:
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
        path = urlparse(self.path).path
        if path not in {"/api/analyze-photo", "/api/reverse-geocode", "/api/analyze-situation"}:
            self.send_json(404, {"error": "接口不存在"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if length <= 0 or length > MAX_REQUEST_BYTES:
                raise ValueError("请求内容过大或无效")
            payload = json.loads(self.rfile.read(length).decode("utf-8"))
            authorization = self.headers.get("Authorization", "")
            if path == "/api/analyze-situation":
                verify_admin_token(authorization)
                mode = payload.get("mode", "quick") if isinstance(payload, dict) else "quick"
                model = payload.get("model") if isinstance(payload, dict) else None
                issues = payload.get("issues") if isinstance(payload, dict) else None
                started_at = time.monotonic()
                result = analyze_situation(issues, mode, model)
                self.send_json(200, {
                    "analysis": result["analysis"],
                    "usage": result["usage"],
                    "model": result["model"],
                    "mode": mode,
                    "elapsed_seconds": round(time.monotonic() - started_at, 1),
                })
                return
            verify_user_token(authorization)
            if path == "/api/reverse-geocode":
                if not isinstance(payload, dict):
                    raise ValueError("位置请求格式无效")
                self.send_json(200, reverse_geocode(payload.get("latitude"), payload.get("longitude")))
                return
            image_data = payload.get("image") if isinstance(payload, dict) else None
            analysis = analyze_photo(image_data or "")
            config = ai_config()
            self.send_json(200, {
                "analysis": analysis,
                "model": config["model"],
                "provider": os.environ.get("AI_PROVIDER", "openai").strip().lower(),
            })
        except PermissionError as error:
            self.send_json(401, {"error": str(error)})
        except (ValueError, RuntimeError) as error:
            self.send_json(400, {"error": str(error)})
        except Exception:
            if path == "/api/reverse-geocode":
                message = "道路名称查询暂时不可用，请稍后重试"
            elif path == "/api/analyze-situation":
                message = "城市运行态势 AI 研判暂时不可用，请稍后重试"
            else:
                message = "AI 识别暂时不可用，请稍后重试"
            self.send_json(500, {"error": message})

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


def test_situation_ai_connection():
    """使用极小的脱敏统计摘要验证态势研判模型配置。"""
    config = situation_ai_config()
    print(f"正在测试：{config['label']} / {config['model']}…")
    sample = [
        {"issue_type": "环境卫生", "issue_description": "垃圾桶满溢并有垃圾散落", "count": 2},
        {"issue_type": "市政设施", "issue_description": "人行道路面砖破损", "count": 1},
    ]
    started_at = time.monotonic()
    result = analyze_situation(sample, "quick")
    elapsed = time.monotonic() - started_at
    print("态势研判模型测试成功：已收到结构化结果。")
    print(f"耗时：{elapsed:.1f} 秒")
    print("Token 用量：" + json.dumps(result["usage"], ensure_ascii=False))
    print("研判结果：" + json.dumps(result["analysis"], ensure_ascii=False, indent=2))


def main():
    parser = argparse.ArgumentParser(description="城市巡查 AI 助手")
    parser.add_argument("--test-ai", nargs="?", const="", metavar="图片路径", help="测试当前模型后退出；可指定巡查照片比较识别效果")
    parser.add_argument("--test-situation-ai", action="store_true", help="测试城市运行态势研判模型后退出")
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
    if args.test_situation_ai:
        try:
            test_situation_ai_connection()
        except (ValueError, RuntimeError) as error:
            print(f"态势研判模型测试失败：{error}")
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
    try:
        config = situation_ai_config()
        print(f"态势 AI 研判：已配置（{config['label']} / {config['model']}）")
    except RuntimeError:
        print("态势 AI 研判：未配置（请检查 SITUATION_AI_*）")
    print("关闭时请在终端按 Control + C")
    if not production:
        threading.Timer(0.8, lambda: webbrowser.open(local_address)).start()
    server.serve_forever()


if __name__ == "__main__":
    main()
