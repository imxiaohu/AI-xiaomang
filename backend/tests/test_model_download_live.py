"""Live HTTP smoke test: spin up uvicorn on port 8766 from THIS process (monkey-patched),
then curl the new endpoints. Avoids the unrelated marketplace_db SQLAlchemyError.
"""
import os, sys, time, json, signal, threading, asyncio, socket, urllib.request, urllib.error

# Patch sqlmodel SQLAlchemyError before any backend import
import sqlmodel
if not hasattr(sqlmodel, 'SQLAlchemyError'):
    import sqlalchemy.exc
    sqlmodel.SQLAlchemyError = sqlalchemy.exc.SQLAlchemyError
    print('[smoke] monkey-patched SQLAlchemyError')

backend = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(backend)
sys.path.insert(0, backend)

# Import the app object directly (avoids the "import main" subprocess indirection)
from main import app  # noqa: E402

# Start uvicorn in a background thread
import uvicorn

HOST = '127.0.0.1'
PORT = 8766
config = uvicorn.Config(app, host=HOST, port=PORT, log_level='warning', lifespan='on')
server = uvicorn.Server(config)

t = threading.Thread(target=server.run, daemon=True)
t.start()
print(f'[smoke] started uvicorn thread, waiting for port {PORT}...')

# Wait for server to be ready
base = f'http://{HOST}:{PORT}'
deadline = time.time() + 15
ok = False
while time.time() < deadline:
    try:
        urllib.request.urlopen(f'{base}/health', timeout=1)
        ok = True
        break
    except Exception:
        time.sleep(0.2)
if not ok:
    print('[smoke] server failed to start')
    server.should_exit = True
    t.join(timeout=3)
    sys.exit(1)
print('[smoke] server ready')

# ── Smoke tests ──
def get(path, headers=None):
    req = urllib.request.Request(base + path, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return r.status, dict(r.headers), r.read()
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers), e.read()

try:
    print('\n=== /health ===')
    s, h, b = get('/health')
    print(f'  status={s} body={b.decode()}')

    print('\n=== /models/manifest ===')
    s, h, b = get('/models/manifest')
    print(f'  status={s}')
    data = json.loads(b)
    for m in data['models']:
        a = m['size'] / 1024 / 1024
        print(f"  - {m['name']:25s} source={m['source']:8s} size={a:7.1f}MB")

    print('\n=== /models/qwen-vl-q4km — first 1 byte (Range on assets) ===')
    s, h, b = get('/models/qwen-vl-q4km', {'Range': 'bytes=0-0'})
    print(f'  status={s} content-length={h.get("content-length")} '
          f'content-range={h.get("content-range")} x-model-source={h.get("x-model-source")}')
    assert s == 206 and h.get('x-model-source') == 'assets'
    print(f'  ✓ first byte from assets file (hex: {b.hex()})')

    print('\n=== /models/qwen-vl-q4km — first 1MB ===')
    s, h, b = get('/models/qwen-vl-q4km', {'Range': 'bytes=0-1048575'})
    print(f'  status={s} content-length={h.get("content-length")} '
          f'content-range={h.get("content-range")} time={time.process_time():.1f}s')
    assert s == 206 and int(h['content-length']) == 1048576
    # Verify md5 matches disk
    import hashlib
    md5_server = hashlib.md5(b).hexdigest()
    with open('/Users/xiaohu/Downloads/AIVideo/backend/assets/models/Qwen2-VL-2B-Instruct-Q4_K_M.gguf', 'rb') as f:
        expected = f.read(1048576)
    md5_disk = hashlib.md5(expected).hexdigest()
    print(f'  server md5: {md5_server}')
    print(f'  disk   md5: {md5_disk}')
    assert md5_server == md5_disk
    print('  ✓ first 1MB from assets matches disk byte-for-byte')

    print('\n=== /models/qwen-vl-q4km — middle 1MB (200-201 MB offset) ===')
    s, h, b = get('/models/qwen-vl-q4km', {'Range': 'bytes=209715200-210763775'})
    print(f'  status={s} content-length={h.get("content-length")} time={time.process_time():.1f}s')
    assert s == 206
    md5_server = hashlib.md5(b).hexdigest()
    with open('/Users/xiaohu/Downloads/AIVideo/backend/assets/models/Qwen2-VL-2B-Instruct-Q4_K_M.gguf', 'rb') as f:
        f.seek(209715200)
        expected = f.read(1048576)
    md5_disk = hashlib.md5(expected).hexdigest()
    assert md5_server == md5_disk
    print(f'  ✓ middle 1MB matches disk byte-for-byte (md5={md5_server})')

    print('\n=== /models/qwen-vl-mmproj-f16 — first 1 byte ===')
    s, h, b = get('/models/qwen-vl-mmproj-f16', {'Range': 'bytes=0-0'})
    print(f'  status={s} x-model-source={h.get("x-model-source")} content-length={h.get("content-length")}')
    assert s == 206 and h.get('x-model-source') == 'assets'
    print('  ✓ mmproj served from assets')

    print('\n=== /models/_cache/stats ===')
    s, h, b = get('/models/_cache/stats')
    data = json.loads(b)
    print(f'  total_assets_bytes: {data["total_assets_bytes"]/1024/1024:.1f}MB')
    print(f'  total_cache_bytes:  {data["total_cache_bytes"]} bytes')
    for m in data['models']:
        a = m['assets_size']/1024/1024
        c = m['cache_size']
        print(f"  - {m['name']:25s} source={m['source']:8s} assets={a:7.1f}MB cache={c}B")

    print('\n=== /models/vosk-cn/info (no assets zip, no cache → missing) ===')
    s, h, b = get('/models/vosk-cn/info')
    info = json.loads(b)
    print(f'  info: source={info["source"]} resolved_path={info["resolved_path"]}')
    assert info['source'] == 'missing'
    print('  ✓ vosk-cn correctly reports source=missing')

    print('\n✅ Live smoke test passed — assets resolution works end-to-end via real HTTP')
finally:
    server.should_exit = True
    t.join(timeout=3)

