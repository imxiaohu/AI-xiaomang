"""
Live 复现测试 V2：让 client 把每次 recv 都立刻 flush 到 stdout
"""
import asyncio
import httpx
import time
import sys
import os
import base64

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

BASE_URL = "http://127.0.0.1:8000"
TOKEN = "dev_token"
CTX_ID = f"live-race-v2-{int(time.time())}"


def make_pcm(seconds: float = 1.0) -> str:
    pcm_bytes = b"\x00\x00" * int(16000 * seconds)
    return base64.b64encode(pcm_bytes).decode()


async def main():
    print(f"=== Live race test V2: ctx_id={CTX_ID} ===", flush=True)
    print(flush=True)

    received = 0
    sse_connected_time = None
    done_event = asyncio.Event()

    async def sse_consumer():
        nonlocal received, sse_connected_time
        await asyncio.sleep(0.5)
        sse_connected_time = time.time()
        print(f"  [client] SSE connecting at t={time.time():.3f}", flush=True)
        try:
            async with httpx.AsyncClient(timeout=30.0) as client:
                async with client.stream(
                    "GET",
                    f"{BASE_URL}/sse/chat",
                    params={"ctxId": CTX_ID, "token": TOKEN},
                    headers={"Accept": "text/event-stream"},
                ) as resp:
                    print(f"  [client] SSE status={resp.status_code}", flush=True)
                    if resp.status_code != 200:
                        print(f"  [client] SSE error: {await resp.aread()}", flush=True)
                        return
                    buffer = ""
                    async for chunk in resp.aiter_text():
                        if done_event.is_set():
                            break
                        buffer += chunk
                        # 修复：CRLF 行尾
                        import re
                        while True:
                            m = re.search(r'\r\n\r\n|\n\n', buffer)
                            if m is None:
                                break
                            event_text = buffer[:m.start()]
                            buffer = buffer[m.end():]
                            event_type = None
                            event_data = None
                            event_id = None
                            for raw_line in event_text.split("\n"):
                                line = raw_line[:-1] if raw_line.endswith("\r") else raw_line
                                if line.startswith("event:"):
                                    event_type = line[6:].strip()
                                elif line.startswith("data:"):
                                    event_data = line[5:].strip()
                                elif line.startswith("id:"):
                                    event_id = line[3:].strip()
                            if event_type and event_data:
                                received += 1
                                print(f"  [client] SSE recv #{received}: id={event_id} event={event_type} data_len={len(event_data)}", flush=True)
                                if event_type == "end":
                                    done_event.set()
                                    return
        except Exception as e:
            print(f"  [client] SSE exception: {type(e).__name__}: {e}", flush=True)

    consumer_task = asyncio.create_task(sse_consumer())

    print(f"  [client] sending 3 audio chunks", flush=True)
    async with httpx.AsyncClient(timeout=10.0) as client:
        for i in range(3):
            await client.post(
                f"{BASE_URL}/upload/audio_chunk",
                json={"ctxId": CTX_ID, "audio": make_pcm(0.5), "end": False},
            )
        print(f"  [client] sending chat/end at t={time.time():.3f}", flush=True)
        r = await client.post(
            f"{BASE_URL}/upload/chat/end",
            json={"ctxId": CTX_ID},
        )
        print(f"  [client] chat/end resp: {r.json()}", flush=True)

    try:
        await asyncio.wait_for(consumer_task, timeout=20.0)
    except asyncio.TimeoutError:
        print(f"  [client] TIMEOUT (received={received})", flush=True)
        consumer_task.cancel()
        try:
            await consumer_task
        except asyncio.CancelledError:
            pass

    print(flush=True)
    print(f"=== Result: received {received} events ===", flush=True)


if __name__ == "__main__":
    asyncio.run(main())
