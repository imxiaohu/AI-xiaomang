"""
Test for 3-tier model resolution: assets → cache → upstream

Strategy:
  1) Real assets/models/ has qwen-vl-q4km and qwen-vl-mmproj-f16 pre-installed.
     We DON'T touch these (they're 2.3GB).
  2) For vosk-cn: assets has the unzipped directory but no .zip. We test the
     "missing assets_filename" path by leaving MODELS_ASSETS_DIR's vosk.zip absent.
  3) For Range tests, we use small fake files written to cache and assert
     the source is "cache".
"""
import sys, os, hashlib
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# Monkey-patch: marketplace_db imports SQLAlchemyError from sqlmodel, which doesn't exist
# (unrelated to model_download — needed only when running the full app)
import sqlmodel
if not hasattr(sqlmodel, 'SQLAlchemyError'):
    import sqlalchemy.exc
    sqlmodel.SQLAlchemyError = sqlalchemy.exc.SQLAlchemyError
    print('[test] monkey-patched SQLAlchemyError into sqlmodel')

from fastapi import FastAPI
from fastapi.testclient import TestClient

import routers.model_download as md

app = FastAPI()
app.include_router(md.router)
client = TestClient(app)


def section(title):
    print(f"\n=== {title} ===")


def cleanup():
    """Remove any test-created cache files and fake assets overrides."""
    for n in md.MODEL_REGISTRY:
        cp = md._cache_path(n)
        if cp.exists():
            cp.unlink()
        mp = md._meta_path(n)
        if mp.exists():
            mp.unlink()


# ───────────────────────────────────────────────────────────────────────
section("1) Real assets/models/ has qwen-vl-q4km & mmproj pre-installed")
print(f"  MODELS_ASSETS_DIR = {md.MODELS_ASSETS_DIR}")
print(f"  MODELS_CACHE_DIR  = {md.MODELS_CACHE_DIR}")
assets_files = os.listdir(md.MODELS_ASSETS_DIR) if os.path.isdir(md.MODELS_ASSETS_DIR) else []
print(f"  assets contents: {sorted(assets_files)}")

# Verify the actual files exist (size check, don't read)
qwen_path = md._assets_path("qwen-vl-q4km")
mmproj_path = md._assets_path("qwen-vl-mmproj-f16")
print(f"  qwen-vl-q4km assets path: {qwen_path}, exists={qwen_path.exists() if qwen_path else False}")
print(f"  qwen-vl-mmproj-f16 assets path: {mmproj_path}, exists={mmproj_path.exists() if mmproj_path else False}")
assert qwen_path and qwen_path.exists(), "qwen-vl-q4km should be in assets/"
assert mmproj_path and mmproj_path.exists(), "qwen-vl-mmproj-f16 should be in assets/"
print("  ✓ both GGUF files present in assets/")

# vosk: assets has the unzipped directory but the registry says filename=zip
# Since the zip doesn't exist, _assets_path returns None → cache hit or upstream
vosk_assets = md._assets_path("vosk-cn")
print(f"  vosk-cn assets path: {vosk_assets} (expected None: zip not pre-installed)")
assert vosk_assets is None
print("  ✓ vosk-cn correctly has no assets zip")


# ───────────────────────────────────────────────────────────────────────
section("2) GET /models/manifest — source field reflects 3-tier resolution")
cleanup()
r = client.get("/models/manifest")
assert r.status_code == 200
data = r.json()
print(f"  manifest_version: {data['manifest_version']}")
for m in data["models"]:
    sz = m['size'] / 1024 / 1024
    print(f"  - {m['name']:25s} source={m['source']:8s} size={sz:7.1f}MB "
          f"cached={m['cached']} assets_filename={m['local_assets_filename']!r}")
# qwen-vl-q4km and qwen-vl-mmproj-f16 should both be in "assets"
sources_by_name = {m["name"]: m["source"] for m in data["models"]}
assert sources_by_name["qwen-vl-q4km"] == "assets", \
    f"expected 'assets' for qwen-vl-q4km, got {sources_by_name['qwen-vl-q4km']}"
assert sources_by_name["qwen-vl-mmproj-f16"] == "assets", \
    f"expected 'assets' for qwen-vl-mmproj-f16, got {sources_by_name['qwen-vl-mmproj-f16']}"
# vosk-cn: no zip in assets, no cache → 'missing'
assert sources_by_name["vosk-cn"] == "missing", \
    f"expected 'missing' for vosk-cn, got {sources_by_name['vosk-cn']}"
print("  ✓ manifest reports correct source for all 3 models")


# ───────────────────────────────────────────────────────────────────────
section("3) GET /models/{name}/info — shows full resolution details")
for n in ("qwen-vl-q4km", "qwen-vl-mmproj-f16", "vosk-cn"):
    r = client.get(f"/models/{n}/info")
    assert r.status_code == 200
    info = r.json()
    print(f"  {n:25s} source={info['source']:8s} resolved={info['resolved_path']!s:80.80}")
    if n.startswith("qwen") or n == "qwen-vl-mmproj-f16" or "qwen" in n:
        assert info["source"] == "assets"
print("  ✓ /info endpoint correctly reports source & resolved_path")


# ───────────────────────────────────────────────────────────────────────
section("4) GET /models/qwen-vl-q4km — first 1MB partial (Range on assets)")

# 4a) Tiny probe to verify streaming works (no actual bytes)
r = client.get("/models/qwen-vl-q4km", headers={"Range": "bytes=0-0"})
print(f"  Probe Range 0-0: status={r.status_code} content-length={r.headers.get('content-length')} "
      f"accept-ranges={r.headers.get('accept-ranges')} source={r.headers.get('x-model-source')}")
assert r.status_code == 206
assert r.headers.get("accept-ranges") == "bytes"
assert r.headers.get("x-model-source") == "assets"
assert r.headers.get("content-length") == "1"
# Read the first byte from disk to verify byte-for-byte match
with open(md._assets_path("qwen-vl-q4km"), "rb") as f:
    expected = f.read(1)
assert r.content == expected, "Range bytes from server must match disk file"
print(f"  ✓ first byte matches disk file (md5: {hashlib.md5(r.content).hexdigest()})")

# 4b) Range: bytes=0-1023 (first 1KB)
r = client.get("/models/qwen-vl-q4km", headers={"Range": "bytes=0-1023"})
print(f"  Range 0-1023: status={r.status_code} content-length={r.headers.get('content-length')} "
      f"content-range={r.headers.get('content-range')} source={r.headers.get('x-model-source')}")
assert r.status_code == 206
assert r.headers.get("x-model-source") == "assets"
assert r.headers.get("content-length") == "1024"
assert len(r.content) == 1024
# Read the same range from disk to verify byte-for-byte match
with open(md._assets_path("qwen-vl-q4km"), "rb") as f:
    f.seek(0)
    expected = f.read(1024)
assert r.content == expected, "Range bytes from server must match disk file"
print(f"  ✓ first 1KB matches disk file (md5 check)")
print(f"    server md5: {hashlib.md5(r.content).hexdigest()}")
print(f"    disk md5:   {hashlib.md5(expected).hexdigest()}")

# 4c) Range: bytes=1MB-1MB+1023 (middle of file)
mid_start = 1024 * 1024
r = client.get("/models/qwen-vl-q4km", headers={"Range": f"bytes={mid_start}-{mid_start + 1023}"})
print(f"  Range {mid_start}-{mid_start+1023}: status={r.status_code} content-length={r.headers.get('content-length')}")
assert r.status_code == 206
assert r.headers.get("content-length") == "1024"
assert r.headers.get("x-model-source") == "assets"
with open(md._assets_path("qwen-vl-q4km"), "rb") as f:
    f.seek(mid_start)
    expected = f.read(1024)
assert r.content == expected
print(f"  ✓ middle 1KB matches disk file")

# 4d) Range: bytes=-100 (last 100 bytes)
r = client.get("/models/qwen-vl-q4km", headers={"Range": "bytes=-100"})
print(f"  Range -100: status={r.status_code} content-length={r.headers.get('content-length')}")
assert r.status_code == 206
assert r.headers.get("content-length") == "100"
print(f"  ✓ suffix range works")

# 4e) Range out of bounds → 416
file_size = md._assets_path("qwen-vl-q4km").stat().st_size
r = client.get("/models/qwen-vl-q4km", headers={"Range": f"bytes={file_size + 1000000}-{file_size + 2000000}"})
print(f"  Range OOB: status={r.status_code}")
assert r.status_code == 416
print(f"  ✓ out-of-bounds → 416")


# ───────────────────────────────────────────────────────────────────────
section("5) Cache-tier test: drop fake file in cache, verify source='cache'")
cleanup()  # 清理上一步
# 5a) Create a small fake cache file for "vosk-cn"
fake_data = b"VOSK_FAKE_" * 100  # 1.1KB
cp = md._cache_path("vosk-cn")
cp.write_bytes(fake_data)
md._write_meta("vosk-cn", "0.22", len(fake_data), "deadbeef" * 8)

# 5b) Hit /models/manifest — vosk-cn should now be source=cache
r = client.get("/models/manifest")
data = r.json()
vosk_entry = next(m for m in data["models"] if m["name"] == "vosk-cn")
print(f"  manifest: vosk-cn source={vosk_entry['source']} cached={vosk_entry['cached']}")
assert vosk_entry["source"] == "cache"
assert vosk_entry["cached"] is True
print("  ✓ cache-hit reflected in manifest")

# 5c) GET it back, verify X-Model-Source header
r = client.get("/models/vosk-cn")
print(f"  GET: status={r.status_code} source={r.headers.get('x-model-source')} content-length={r.headers.get('content-length')}")
assert r.status_code == 200
assert r.headers.get("x-model-source") == "cache"
assert r.content == fake_data
print("  ✓ cache file served with X-Model-Source: cache")

# 5d) Range on cache
r = client.get("/models/vosk-cn", headers={"Range": "bytes=10-19"})
print(f"  Range 10-19 on cache: status={r.status_code} source={r.headers.get('x-model-source')}")
assert r.status_code == 206
assert r.headers.get("x-model-source") == "cache"
assert r.content == fake_data[10:20]
print("  ✓ Range works on cache file")


# ───────────────────────────────────────────────────────────────────────
section("6) Missing both assets and cache → source='missing' in manifest")
# Use a model name that's in registry but with no assets/cache file
# (vosk-cn has cache, so it would be 'cache'; just verify the missing path)
# Trick: temporarily remove vosk from cache to see it go to 'missing'
cleanup()
r = client.get("/models/manifest")
data = r.json()
vosk_entry = next(m for m in data["models"] if m["name"] == "vosk-cn")
print(f"  vosk-cn source after cleanup: {vosk_entry['source']}")
assert vosk_entry["source"] == "missing"
print("  ✓ source=missing when neither assets nor cache present")

# /info should show resolved_path=null
r = client.get("/models/vosk-cn/info")
info = r.json()
print(f"  vosk-cn info: source={info['source']} resolved_path={info['resolved_path']}")
assert info["source"] == "missing"
assert info["resolved_path"] is None
print("  ✓ /info returns resolved_path=null when missing")


# ───────────────────────────────────────────────────────────────────────
section("7) /models/_cache/stats — shows assets + cache separately")
# Drop a fake cache file to make the cache stats more interesting
md._cache_path("vosk-cn").write_bytes(b"X" * 5000)
md._write_meta("vosk-cn", "0.22", 5000, "")
r = client.get("/models/_cache/stats")
data = r.json()
print(f"  assets_dir: {data['assets_dir']}")
print(f"  cache_dir:  {data['cache_dir']}")
print(f"  total_assets_bytes: {data['total_assets_bytes']/1024/1024:.1f}MB")
print(f"  total_cache_bytes:  {data['total_cache_bytes']} bytes")
for m in data["models"]:
    a = m['assets_size'] / 1024 / 1024
    c = m['cache_size']
    print(f"  - {m['name']:25s} source={m['source']:8s} assets={a:7.1f}MB cache={c}B")
assert data["total_assets_bytes"] > 0  # qwen-vl + mmproj
print("  ✓ /_cache/stats shows assets + cache separately")


# ───────────────────────────────────────────────────────────────────────
section("8) ETag on assets hit")
# Use a Range to get the full content-length info + ETag header
r = client.get("/models/qwen-vl-q4km", headers={"Range": "bytes=0-0"})
etag = r.headers.get("etag")
print(f"  ETag: {etag}")
assert etag and etag.startswith('"') and etag.endswith('"')
# If-None-Match → 304
r = client.get("/models/qwen-vl-q4km", headers={"If-None-Match": etag})
print(f"  If-None-Match (assets): status={r.status_code}")
assert r.status_code == 304
print("  ✓ ETag works on assets file")

# Cleanup
cleanup()
print("\n✅ All 3-tier resolution tests passed")
