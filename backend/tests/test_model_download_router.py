"""Standalone test for routers/model_download.py — bypasses main.py's broken sqlmodel import."""
import sys, os
# Add backend root to sys.path so 'routers' and 'config' are importable
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# Monkey-patch: marketplace_db imports SQLAlchemyError from sqlmodel, which doesn't exist
# This is unrelated to the new model_download router; we patch to make the test runnable.
import sqlmodel
if not hasattr(sqlmodel, 'SQLAlchemyError'):
    import sqlalchemy.exc
    sqlmodel.SQLAlchemyError = sqlalchemy.exc.SQLAlchemyError
    print('[test] monkey-patched SQLAlchemyError into sqlmodel')

# Build a minimal FastAPI app that mounts ONLY the model_download router
from fastapi import FastAPI
from fastapi.responses import JSONResponse
from fastapi.testclient import TestClient

import routers.model_download as md

app = FastAPI(title="model_download test harness")
app.include_router(md.router)


@app.get("/health")
async def health():
    return {"ok": True}


print(f"[test] MODELS_CACHE_DIR = {md.MODELS_CACHE_DIR}")
print(f"[test] manifest version = {md.MANIFEST_VERSION}")
print(f"[test] registered models = {list(md.MODEL_REGISTRY.keys())}")

client = TestClient(app)

# ── 1) /models/manifest ──
print("\n=== GET /models/manifest ===")
r = client.get("/models/manifest")
print(f"status: {r.status_code}")
import json
data = r.json()
print(f"manifest_version: {data['manifest_version']}")
for m in data["models"]:
    print(f"  - {m['name']:25s} kind={m['kind']:5s} version={m['version']:8s} "
          f"size={m['size']/1024/1024:7.1f}MB cached={m['cached']}")
assert r.status_code == 200
assert "models" in data and len(data["models"]) == 3
print("✓ /models/manifest OK")

# ── 2) /models/_cache/stats ──
print("\n=== GET /models/_cache/stats ===")
r = client.get("/models/_cache/stats")
print(f"status: {r.status_code}")
data = r.json()
print(f"cache_dir: {data['cache_dir']}")
print(f"total_bytes: {data['total_bytes']}")
for m in data["models"]:
    print(f"  - {m['name']:25s} size={m['size']/1024/1024:7.2f}MB")
assert r.status_code == 200
print("✓ /models/_cache/stats OK")

# ── 3) /models/{name}/info (one of them) ──
print("\n=== GET /models/vosk-cn/info ===")
r = client.get("/models/vosk-cn/info")
print(f"status: {r.status_code}")
data = r.json()
print(f"name={data['name']} version={data['version']} size={data['size']/1024/1024:.1f}MB cached={data['cached']}")
assert r.status_code == 200
print("✓ /models/vosk-cn/info OK")

# ── 5) /models/bogus → 404 ──
print("\n=== GET /models/bogus ===")
r = client.get("/models/bogus")
print(f"status: {r.status_code} body={r.json()}")
assert r.status_code == 404
print("✓ 404 on unknown model")

# ── 5b) /models/{bad..name} → 400 (path traversal inside the param) ──
print("\n=== GET /models/has..dot (path traversal inside name) ===")
# %2E%2E decodes to ".." — _safe_name must reject dots in awkward positions
# Our _safe_name allows . - _ but requires at least one alphanumeric
# Test with name containing '..' (which is not a path traversal when it stays inside the route)
r = client.get("/models/foo..bar")
print(f"status: {r.status_code} body={r.json()}")
# foo..bar passes the safe check (all chars are in allowed set)
# but is not a registered model → 404 expected
assert r.status_code == 404
print("✓ unknown name with dots → 404")

# True path traversal: encoding slash in name → caught by FastAPI routing → 404
r = client.get("/models/..%2Fetc%2Fpasswd")
print(f"path-traversal status: {r.status_code}")
assert r.status_code == 404  # FastAPI's own routing blocks it
print("✓ path traversal blocked at routing layer")

# ── 6) Test disk cache path: drop a fake file in cache and verify Range works ──
print("\n=== Disk cache + Range test ===")
import os, time
fake_data = b"X" * (10 * 1024 * 1024 + 17)  # 10MB + 17 bytes
test_name = "qwen-vl-q4km"  # use real registered name
cache_p = md._cache_path(test_name)
# Ensure cache dir exists and write fake data
os.makedirs(md.MODELS_CACHE_DIR, exist_ok=True)
cache_p.write_bytes(fake_data)
md._write_meta(test_name, "Q4_K_M", len(fake_data), "deadbeef" * 8)
print(f"wrote {len(fake_data)} bytes to {cache_p}")

# 6a) Full GET
r = client.get(f"/models/{test_name}")
print(f"  full GET status: {r.status_code} content-length: {r.headers.get('content-length')} accept-ranges: {r.headers.get('accept-ranges')}")
assert r.status_code == 200
assert len(r.content) == len(fake_data)
assert r.headers["accept-ranges"] == "bytes"
assert r.headers["content-length"] == str(len(fake_data))
print("  ✓ full GET OK")

# 6b) Range: bytes=100-199 (100 bytes)
r = client.get(f"/models/{test_name}", headers={"Range": "bytes=100-199"})
print(f"  range=100-199 status: {r.status_code} content-range: {r.headers.get('content-range')} content-length: {r.headers.get('content-length')}")
assert r.status_code == 206
assert r.headers["content-range"] == f"bytes 100-199/{len(fake_data)}"
assert r.headers["content-length"] == "100"
assert r.content == b"X" * 100
print("  ✓ Range 100-199 OK")

# 6c) Range: bytes=2M- (open-ended, 2MB onwards)
start = 2 * 1024 * 1024
r = client.get(f"/models/{test_name}", headers={"Range": f"bytes={start}-"})
print(f"  range={start}- status: {r.status_code} content-range: {r.headers.get('content-range')} content-length: {r.headers.get('content-length')}")
assert r.status_code == 206
assert r.headers["content-length"] == str(len(fake_data) - start)
assert len(r.content) == len(fake_data) - start
print("  ✓ Range open-ended OK")

# 6d) Range: out of bounds → 416
r = client.get(f"/models/{test_name}", headers={"Range": f"bytes={len(fake_data)+1000}-{len(fake_data)+2000}"})
print(f"  range out-of-bounds status: {r.status_code}")
assert r.status_code == 416
print("  ✓ Range out-of-bounds 416 OK")

# 6e) If-None-Match → 304
meta = md._read_meta(test_name)
expected_etag = '"' + meta["version"] + "-" + str(len(fake_data)) + '"'
r = client.get(f"/models/{test_name}", headers={"If-None-Match": expected_etag})
print(f"  if-none-match status: {r.status_code} etag: {r.headers.get('etag')}")
assert r.status_code == 304
print("  ✓ If-None-Match 304 OK")

# 6f) Bad range syntax → 400
r = client.get(f"/models/{test_name}", headers={"Range": "bytes=abc-def"})
print(f"  bad-range status: {r.status_code}")
assert r.status_code == 400
print("  ✓ bad Range 400 OK")

# Cleanup
os.unlink(cache_p)
md._meta_path(test_name).unlink()
print("\n✅ All tests passed")
