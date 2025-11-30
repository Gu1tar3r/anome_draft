from fastapi import FastAPI, Depends, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, EmailStr
from pathlib import Path
import os
import secrets
import json
import time
from typing import Optional, Dict
from passlib.hash import bcrypt
import jwt
import io
import re
import zipfile
from urllib import request as urlrequest

# FastAPI应用初始化
app = FastAPI(title="AI阅读助手API", version="1.0.0")

# 环境变量加载
try:
    from dotenv import load_dotenv
    load_dotenv()
except ImportError:
    pass

# 基础配置
ALGORITHM = "HS256"
BASE_DIR = Path(__file__).resolve().parent
SECRET_KEY = os.environ.get("SECRET_KEY", "dev-secret-key-change-this")
ACCESS_TOKEN_EXPIRE_SECONDS = int(os.environ.get("ACCESS_TOKEN_EXPIRE_SECONDS", "86400"))
REFRESH_TOKEN_EXPIRE_SECONDS = int(os.environ.get("REFRESH_TOKEN_EXPIRE_SECONDS", "2592000"))

# 数据目录配置
DATA_DIR = Path(os.environ.get("DATA_DIR", str(BASE_DIR / "data")))
USERS_FILE = DATA_DIR / "users.json"
CODES_FILE = DATA_DIR / "codes.json"
DATA_DIR.mkdir(parents=True, exist_ok=True)

# 初始化数据文件
if not USERS_FILE.exists():
    USERS_FILE.write_text(json.dumps({}, ensure_ascii=False))
if not CODES_FILE.exists():
    CODES_FILE.write_text(json.dumps({}, ensure_ascii=False))

# CORS配置
cors_env = os.environ.get("CORS_ORIGINS", "")
if cors_env.strip():
    origins = [o.strip() for o in cors_env.split(",") if o.strip()]
else:
    origins = [
        "http://localhost:55119",
        "http://127.0.0.1:55119",
        "http://localhost:5500",
        "http://127.0.0.1:5500",
    ]

app.add_middleware(
    CORSMiddleware,
    allow_origins=origins,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# 导入存储适配器和AI模块
from storage_adapter import StorageAdapter
from ai.routes import router as ai_router

# 初始化核心组件
storage = StorageAdapter()

# 将AI引擎挂载到应用状态
@app.on_event("startup")
async def startup_event():
    from ai.reading_ai import ReadingAI
    app.state.ai_engine = ReadingAI(storage)

# 包含AI路由
app.include_router(ai_router, prefix="/ai", tags=["AI"])

# 数据操作函数
def load_users() -> Dict[str, dict]:
    try:
        return json.loads(USERS_FILE.read_text())
    except Exception:
        return {}

def save_users(users: Dict[str, dict]):
    USERS_FILE.write_text(json.dumps(users, ensure_ascii=False, indent=2))

def load_codes() -> Dict[str, dict]:
    try:
        return json.loads(CODES_FILE.read_text())
    except Exception:
        return {}

def save_codes(codes: Dict[str, dict]):
    CODES_FILE.write_text(json.dumps(codes, ensure_ascii=False, indent=2))

# Token相关函数
def create_access_token(sub: str) -> str:
    payload = {
        "type": "access",
        "sub": sub,
        "iat": int(time.time()),
        "exp": int(time.time()) + ACCESS_TOKEN_EXPIRE_SECONDS,
    }
    return jwt.encode(payload, SECRET_KEY, algorithm=ALGORITHM)

def create_refresh_token(sub: str) -> str:
    payload = {
        "type": "refresh",
        "sub": sub,
        "jti": secrets.token_hex(16),
        "iat": int(time.time()),
        "exp": int(time.time()) + REFRESH_TOKEN_EXPIRE_SECONDS,
    }
    return jwt.encode(payload, SECRET_KEY, algorithm=ALGORITHM)

def _decode_token(token: str) -> dict:
    try:
        return jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM])
    except jwt.ExpiredSignatureError:
        raise HTTPException(status_code=401, detail="Token已过期")
    except jwt.InvalidTokenError:
        raise HTTPException(status_code=401, detail="Token无效")

def decode_access_token(token: str) -> dict:
    payload = _decode_token(token)
    if payload.get("type") != "access":
        raise HTTPException(status_code=401, detail="Token类型错误")
    return payload

def decode_refresh_token(token: str) -> dict:
    payload = _decode_token(token)
    if payload.get("type") != "refresh":
        raise HTTPException(status_code=401, detail="Token类型错误")
    return payload

# 请求模型
class RegisterBody(BaseModel):
    email: EmailStr
    password: str
    name: Optional[str] = None
    code: str

class LoginBody(BaseModel):
    email: EmailStr
    password: str

class LoginCodeBody(BaseModel):
    email: EmailStr
    code: str

class PresignPutBody(BaseModel):
    key: str
    contentType: Optional[str] = None

# 工具函数
def _now_ts() -> int:
    return int(time.time())

def _gen_code() -> str:
    if os.environ.get("DEV_STABLE_CODE") == "1":
        return f"{int(time.time() % 1000000):06d}"
    return f"{int.from_bytes(os.urandom(3), 'big') % 1000000:06d}"

CODE_TTL_SECONDS = int(os.environ.get("CODE_TTL_SECONDS", "600"))
CODE_RATE_LIMIT_SECONDS = int(os.environ.get("CODE_RATE_LIMIT_SECONDS", "60"))

# 邮件配置
SMTP_HOST = os.environ.get("SMTP_HOST", "")
SMTP_PORT = int(os.environ.get("SMTP_PORT", "587"))
SMTP_USER = os.environ.get("SMTP_USER", "")
SMTP_PASS = os.environ.get("SMTP_PASS", "")
SMTP_FROM = os.environ.get("SMTP_FROM", SMTP_USER or "")
SMTP_TLS = os.environ.get("SMTP_TLS", "true").lower() in {"1", "true", "yes"}

def _send_code_email(to_email: str, code: str):
    if not SMTP_HOST or not SMTP_FROM:
        print(f"[DEV] 验证码发送到 {to_email}: {code}")
        return
    
    import smtplib
    from email.mime.text import MIMEText
    from email.header import Header
    
    subject = "您的注册验证码"
    body = f"您正在注册AI阅读助手，验证码：{code}，{CODE_TTL_SECONDS//60}分钟内有效。"
    
    msg = MIMEText(body, "plain", "utf-8")
    msg["Subject"] = Header(subject, "utf-8")
    msg["From"] = SMTP_FROM
    msg["To"] = to_email
    
    try:
        if SMTP_TLS:
            server = smtplib.SMTP(SMTP_HOST, SMTP_PORT)
            server.starttls()
        else:
            server = smtplib.SMTP(SMTP_HOST, SMTP_PORT)
        
        if SMTP_USER and SMTP_PASS:
            server.login(SMTP_USER, SMTP_PASS)
        
        server.sendmail(SMTP_FROM, [to_email], msg.as_string())
        server.quit()
    except Exception as e:
        print(f"邮件发送失败: {e}")

# 认证依赖
def get_current_user(request: Request) -> dict:
    auth = request.headers.get("Authorization")
    if not auth or not auth.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="缺少授权")
    
    token = auth.split(" ", 1)[1]
    payload = decode_access_token(token)
    email = payload.get("sub")
    users = load_users()
    user = users.get(email)
    
    if not user:
        raise HTTPException(status_code=401, detail="用户不存在")
    return user

# 认证路由
@app.post("/auth/register")
def register(body: RegisterBody):
    users = load_users()
    email = body.email.lower()
    
    if email in users:
        raise HTTPException(status_code=400, detail="该邮箱已注册")
    
    if len(body.password) < 6:
        raise HTTPException(status_code=400, detail="密码至少6位")
    
    codes = load_codes()
    entry = codes.get(email)
    if not entry:
        raise HTTPException(status_code=400, detail="请先获取验证码")
    
    if entry.get("expires", 0) < _now_ts():
        raise HTTPException(status_code=400, detail="验证码已过期")
    
    if not bcrypt.verify(body.code, entry.get("hash", "")):
        raise HTTPException(status_code=400, detail="验证码错误")
    
    hashed = bcrypt.hash(body.password)
    user = {
        "id": str(int(time.time() * 1000)),
        "name": body.name or email.split("@")[0],
        "email": email,
        "avatarUrl": "",
        "passwordHash": hashed,
        "createdAt": int(time.time()),
    }
    
    users[email] = user
    save_users(users)
    
    codes.pop(email, None)
    save_codes(codes)
    
    access = create_access_token(email)
    refresh = create_refresh_token(email)
    
    return {
        "accessToken": access,
        "refreshToken": refresh,
        "user": {k: v for k, v in user.items() if k != "passwordHash"},
    }

@app.post("/auth/login")
def login(body: LoginBody):
    users = load_users()
    email = body.email.lower()
    user = users.get(email)
    
    if not user:
        raise HTTPException(status_code=401, detail="邮箱或密码错误")
    
    if not bcrypt.verify(body.password, user.get("passwordHash", "")):
        raise HTTPException(status_code=401, detail="邮箱或密码错误")
    
    access = create_access_token(email)
    refresh = create_refresh_token(email)
    
    return {
        "accessToken": access,
        "refreshToken": refresh,
        "user": {k: v for k, v in user.items() if k != "passwordHash"},
    }

@app.post("/auth/login-code")
def login_code(body: LoginCodeBody):
    email = body.email.lower()
    codes = load_codes()
    entry = codes.get(email)
    
    if not entry:
        raise HTTPException(status_code=400, detail="请先获取验证码")
    
    if entry.get("expires", 0) < _now_ts():
        raise HTTPException(status_code=400, detail="验证码已过期")
    
    if not bcrypt.verify(body.code, entry.get("hash", "")):
        raise HTTPException(status_code=400, detail="验证码错误")
    
    users = load_users()
    user = users.get(email)
    if not user:
        raise HTTPException(status_code=404, detail="用户不存在，请先注册")
    
    codes.pop(email, None)
    save_codes(codes)
    
    access = create_access_token(email)
    refresh = create_refresh_token(email)
    
    return {
        "accessToken": access,
        "refreshToken": refresh,
        "user": {k: v for k, v in user.items() if k != "passwordHash"},
    }

@app.get("/auth/me")
def me(current_user: dict = Depends(get_current_user)):
    return {k: v for k, v in current_user.items() if k != "passwordHash"}

@app.post("/auth/logout")
def logout():
    return {"ok": True}

@app.post("/auth/refresh")
def refresh(request: Request):
    auth = request.headers.get("Authorization")
    if not auth or not auth.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="缺少授权")
    
    token = auth.split(" ", 1)[1]
    payload = decode_refresh_token(token)
    email = payload.get("sub")
    users = load_users()
    
    if email not in users:
        raise HTTPException(status_code=401, detail="用户不存在")
    
    access = create_access_token(email)
    return {"accessToken": access}

@app.post("/auth/request-code")
def request_code(body: LoginBody):
    email = body.email.lower()
    now = _now_ts()
    codes = load_codes()
    entry = codes.get(email)
    
    if entry and now - int(entry.get("sentAt", 0)) < CODE_RATE_LIMIT_SECONDS:
        raise HTTPException(status_code=429, detail="请求过于频繁，请稍后再试")
    
    code = _gen_code()
    codes[email] = {
        "hash": bcrypt.hash(code),
        "sentAt": now,
        "expires": now + CODE_TTL_SECONDS,
    }
    save_codes(codes)
    
    try:
        _send_code_email(email, code)
    except Exception:
        print(f"[WARN] 邮件发送失败，但验证码已生成：{email} -> {code}")
    
    if not SMTP_HOST or not SMTP_FROM:
        return {"ok": True, "devCode": code}
    return {"ok": True}

# 存储预签名URL路由
@app.get("/storage/presign/get")
def storage_presign_get(key: str, current_user: dict = Depends(get_current_user)):
    try:
        from storage_adapter import _presign_get_url
        url = _presign_get_url(key)
        return {"url": url}
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"生成下载链接失败: {e}")

@app.post("/storage/presign/put")
def storage_presign_put(body: PresignPutBody, current_user: dict = Depends(get_current_user)):
    try:
        from storage_adapter import _presign_put_url
        url, headers = _presign_put_url(body.key, body.contentType or "application/octet-stream")
        return {"url": url, "headers": headers}
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"生成上传链接失败: {e}")

# 文本处理函数
def _extract_text(file_bytes: bytes, file_type: str) -> str:
    ft = file_type.lower()
    
    if ft in {"txt", "md"}:
        for enc in ("utf-8", "gb18030", "latin-1"):
            try:
                return file_bytes.decode(enc)
            except Exception:
                pass
        return file_bytes.decode("utf-8", errors="ignore")
    
    if ft in {"html", "htm"}:
        txt = file_bytes.decode("utf-8", errors="ignore")
        txt = re.sub(r"<script[\s\S]*?</script>", " ", txt, flags=re.IGNORECASE)
        txt = re.sub(r"<style[\s\S]*?</style>", " ", txt, flags=re.IGNORECASE)
        txt = re.sub(r"<[^>]+>", " ", txt)
        txt = re.sub(r"\s+", " ", txt)
        return txt.strip()
    
    if ft == "epub":
        try:
            zf = zipfile.ZipFile(io.BytesIO(file_bytes))
            texts = []
            for name in zf.namelist():
                if name.lower().endswith((".xhtml", ".html", ".htm")):
                    try:
                        raw = zf.read(name).decode("utf-8", errors="ignore")
                        clean = re.sub(r"<script[\s\S]*?</script>", " ", raw, flags=re.IGNORECASE)
                        clean = re.sub(r"<style[\s\S]*?</style>", " ", clean, flags=re.IGNORECASE)
                        clean = re.sub(r"<[^>]+>", " ", clean)
                        clean = re.sub(r"\s+", " ", clean)
                        texts.append(clean.strip())
                    except Exception:
                        pass
            return "\n".join(texts)
        except Exception:
            return ""
    
    return ""

def _chunk_text(text: str, max_chars: int = 2000, overlap: int = 200) -> list:
    chunks = []
    i = 0
    n = len(text)
    
    while i < n:
        end = min(i + max_chars, n)
        chunks.append(text[i:end])
        i = end - overlap
        if i < 0:
            i = 0
    
    return [c.strip() for c in chunks if c.strip()]

# 应用启动
if __name__ == "__main__":
    import uvicorn
    host = os.environ.get("HOST", "0.0.0.0")
    port = int(os.environ.get("PORT", "8000"))
    reload_flag = os.environ.get("RELOAD", "true").lower() in {"1", "true", "yes"}
    uvicorn.run("main:app", host=host, port=port, reload=reload_flag)
