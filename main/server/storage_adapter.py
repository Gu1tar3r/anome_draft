import os
from typing import Optional, Tuple
from urllib import request as urlrequest

from fastapi import HTTPException

# Optional: MinIO (S3-compatible)
try:
    from minio import Minio
    _MINIO_AVAILABLE = True
except Exception:
    Minio = None  # type: ignore
    _MINIO_AVAILABLE = False

# Optional: Tencent Cloud COS
try:
    from qcloud_cos import CosConfig, CosS3Client  # type: ignore
    _COS_AVAILABLE = True
except Exception:
    CosConfig = None  # type: ignore
    CosS3Client = None  # type: ignore
    _COS_AVAILABLE = False

# ------------------------------
# Cloud/Object Storage Settings
# ------------------------------
STORAGE_BACKEND = os.environ.get("STORAGE_BACKEND", "none").lower()

# MinIO/S3-compatible settings
STORAGE_ENDPOINT = os.environ.get("STORAGE_ENDPOINT", "")
STORAGE_BUCKET = os.environ.get("STORAGE_BUCKET", "")
STORAGE_ACCESS_KEY = os.environ.get("STORAGE_ACCESS_KEY", "")
STORAGE_SECRET_KEY = os.environ.get("STORAGE_SECRET_KEY", "")
STORAGE_REGION = os.environ.get("STORAGE_REGION", "")
STORAGE_SECURE = os.environ.get("STORAGE_SECURE", "true").lower() in {"1", "true", "yes"}
STORAGE_URL_EXPIRES = int(os.environ.get("STORAGE_URL_EXPIRES", "600"))  # seconds

# COS-specific settings
COS_BUCKET = os.environ.get("COS_BUCKET", "")
COS_REGION = os.environ.get("COS_REGION", "")
COS_SECRET_ID = os.environ.get("COS_SECRET_ID", "")
COS_SECRET_KEY = os.environ.get("COS_SECRET_KEY", "")
COS_SCHEME = os.environ.get("COS_SCHEME", "https")

_minio_client: Optional[Minio] = None
_cos_client: Optional[CosS3Client] = None

def _ensure_storage_ready():
    global _minio_client, _cos_client
    if STORAGE_BACKEND == "none":
        raise HTTPException(status_code=501, detail="未启用云存储")
    if STORAGE_BACKEND == "minio":
        if not _MINIO_AVAILABLE:
            raise HTTPException(status_code=500, detail="后端未安装 MinIO 依赖包")
        if not (_minio_client and STORAGE_BUCKET):
            if not STORAGE_ENDPOINT or not STORAGE_BUCKET or not STORAGE_ACCESS_KEY or not STORAGE_SECRET_KEY:
                raise HTTPException(status_code=500, detail="云存储配置不完整")
            _minio_client = Minio(
                STORAGE_ENDPOINT,
                access_key=STORAGE_ACCESS_KEY,
                secret_key=STORAGE_SECRET_KEY,
                secure=STORAGE_SECURE,
                region=STORAGE_REGION or None,
            )
        # Ensure bucket exists (no-op if already)
        try:
            found = _minio_client.bucket_exists(STORAGE_BUCKET)
            if not found:
                _minio_client.make_bucket(STORAGE_BUCKET)
        except Exception:
            # If permission denied to create, we ignore here
            pass
    else:
        if STORAGE_BACKEND == "cos":
            if not _COS_AVAILABLE:
                raise HTTPException(status_code=500, detail="后端未安装 COS 依赖包")
            if not (_cos_client and COS_BUCKET):
                if not COS_REGION or not COS_BUCKET or not COS_SECRET_ID or not COS_SECRET_KEY:
                    raise HTTPException(status_code=500, detail="COS 配置不完整")
                cfg = CosConfig(
                    Region=COS_REGION,
                    SecretId=COS_SECRET_ID,
                    SecretKey=COS_SECRET_KEY,
                    Scheme=COS_SCHEME,
                )
                _cos_client = CosS3Client(cfg)
        else:
            raise HTTPException(status_code=500, detail=f"未知存储后端: {STORAGE_BACKEND}")

def _presign_get_url(object_key: str) -> str:
    _ensure_storage_ready()
    if STORAGE_BACKEND == "minio":
        assert _minio_client is not None
        return _minio_client.presigned_get_object(STORAGE_BUCKET, object_key, expires=STORAGE_URL_EXPIRES)
    if STORAGE_BACKEND == "cos":
        assert _cos_client is not None
        return _cos_client.get_presigned_url(
            "get_object",
            Bucket=COS_BUCKET,
            Key=object_key,
            Expired=STORAGE_URL_EXPIRES,
        )
    raise HTTPException(status_code=500, detail="未实现的存储后端")

def _presign_put_url(object_key: str, content_type: str = "application/octet-stream") -> Tuple[str, dict]:
    _ensure_storage_ready()
    if STORAGE_BACKEND == "minio":
        assert _minio_client is not None
        url = _minio_client.presigned_put_object(STORAGE_BUCKET, object_key, expires=STORAGE_URL_EXPIRES)
        return url, {"Content-Type": content_type}
    if STORAGE_BACKEND == "cos":
        assert _cos_client is not None
        url = _cos_client.get_presigned_url(
            "put_object",
            Bucket=COS_BUCKET,
            Key=object_key,
            Expired=STORAGE_URL_EXPIRES,
        )
        return url, {"Content-Type": content_type}
    raise HTTPException(status_code=500, detail="未实现的存储后端")

def _storage_download(key: str) -> bytes:
    _ensure_storage_ready()
    if STORAGE_BACKEND == "minio":
        assert _minio_client is not None
        try:
            resp = _minio_client.get_object(STORAGE_BUCKET, key)
            data = resp.read()
            resp.close()
            resp.release_conn()
            return data
        except Exception:
            url = _presign_get_url(key)
            with urlrequest.urlopen(url) as r:
                return r.read()
    if STORAGE_BACKEND == "cos":
        assert _cos_client is not None
        try:
            resp = _cos_client.get_object(Bucket=COS_BUCKET, Key=key)
            body = resp.get("Body")
            data = body.read() if hasattr(body, "read") else body.get_raw_stream().read()
            return data
        except Exception:
            url = _presign_get_url(key)
            with urlrequest.urlopen(url) as r:
                return r.read()
    raise HTTPException(status_code=500, detail="未实现的存储后端")

def _storage_upload(key: str, data: bytes, content_type: str = "application/octet-stream"):
    _ensure_storage_ready()
    if STORAGE_BACKEND == "minio":
        assert _minio_client is not None
        import io as _io
        _minio_client.put_object(
            STORAGE_BUCKET,
            key,
            _io.BytesIO(data),
            length=len(data),
            content_type=content_type,
        )
        return
    if STORAGE_BACKEND == "cos":
        assert _cos_client is not None
        try:
            _cos_client.put_object(
                Bucket=COS_BUCKET,
                Key=key,
                Body=data,
                ContentType=content_type,
            )
            return
        except Exception as e:
            raise HTTPException(status_code=500, detail=f"COS 上传失败: {e}")
    raise HTTPException(status_code=500, detail="未实现的存储后端")

