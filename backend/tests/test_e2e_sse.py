"""
端到端测试：验证 EventBus 修复 SSE 事件丢失的核心机制

注意：完整的 SSE 流式测试需要 httpx.AsyncClient + 异步编程，
本测试聚焦在核心 EventBus 逻辑（这是修复的核心）。

运行: cd /Users/xiaohu/Downloads/AIVideo/backend && python -m tests.test_e2e_sse
"""
import asyncio
import json
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# 必须在导入 main 前设置环境变量
os.environ.setdefault("TEST_MODE", "true")
os.environ.setdefault("OMNI_MODE", "false")
os.environ.setdefault("DEBUG", "true")

from fastapi.testclient import TestClient
import main as main_module
from main import app
from services.session_manager import session_manager

client = TestClient(app)


def test_health_check():
    response = client.get("/health")
    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "ok"
    print(f"✓ test_health_check: {body}")


def test_upload_audio_chunk():
    ctx_id = "e2e-test-audio"
    response = client.post(
        "/upload/audio_chunk",
        json={"ctxId": ctx_id, "audio": "aGVsbG8=", "end": False},
    )
    assert response.status_code == 200
    body = response.json()
    assert body["code"] == 0
    print(f"✓ test_upload_audio_chunk: {body}")
    asyncio.run(session_manager.remove(ctx_id))


async def test_event_bus_preserves_events_after_subscriber_unregister():
    """
    关键回归测试：EventBus 在订阅者断开后保留事件。
    （这是修复 SSE 事件丢失的核心机制）
    """
    ctx_id = "e2e-bus-preserve"

    session = await session_manager.get_or_create(ctx_id)
    sid = session.register_sse_subscriber()

    received = []
    async def consumer():
        async for eid, event in session.event_bus.subscribe(sid):
            received.append((eid, event))
            if len(received) >= 1:
                return
    task = asyncio.create_task(consumer())
    await asyncio.sleep(0.05)
    await session.event_bus.publish({"event": "x", "data": "y"})
    try:
        await asyncio.wait_for(task, timeout=2.0)
    except asyncio.TimeoutError:
        task.cancel()
        raise

    # 模拟订阅者断开
    session.unregister_sse_subscriber(sid)

    # 推理继续 publish 事件
    for i in range(5):
        await session.event_bus.publish({"event": "x", "data": f"z{i}"})

    assert session.event_bus.size == 6, f"Expected 6, got {session.event_bus.size}"
    print(f"✓ test_event_bus_preserves_events_after_subscriber_unregister: {session.event_bus.size} events retained")

    await session_manager.remove(ctx_id)


async def test_reconnect_resume_with_last_id():
    """
    断线重连：第二次订阅时传入 last_id，能补送所有遗漏事件。
    """
    ctx_id = "e2e-reconnect"

    session = await session_manager.get_or_create(ctx_id)

    # 1. 第一轮：发布 3 个事件
    for i in range(3):
        await session.event_bus.publish({"event": "x", "data": f"a{i}"})

    # 2. 第一个消费者传入 last_id=0 重放
    sid1 = session.register_sse_subscriber()
    received1 = []
    async def consumer1():
        async for eid, event in session.event_bus.subscribe(sid1, last_id=0):
            received1.append((eid, event))
            if len(received1) >= 3:
                return
    await asyncio.wait_for(consumer1(), timeout=2.0)
    session.unregister_sse_subscriber(sid1)

    assert len(received1) == 3
    last_id = received1[-1][0]
    assert last_id == 3

    # 3. 断开期间：发布 2 个事件
    for i in range(2):
        await session.event_bus.publish({"event": "x", "data": f"b{i}"})

    # 4. 重连：传入 last_id=3
    sid2 = session.register_sse_subscriber()
    received2 = []
    async def consumer2():
        async for eid, event in session.event_bus.subscribe(sid2, last_id=last_id):
            received2.append((eid, event))
            if len(received2) >= 2:
                return
    await asyncio.wait_for(consumer2(), timeout=2.0)
    session.unregister_sse_subscriber(sid2)

    assert len(received2) == 2
    assert received2[0][0] == 4
    assert received2[1][0] == 5
    print(f"✓ test_reconnect_resume_with_last_id: reconnected consumer resumed from id={last_id}, got {len(received2)} missed events")

    await session_manager.remove(ctx_id)


async def test_inference_does_not_block_on_no_consumer():
    """
    关键回归测试：推理任务不再因 SSE 消费者不存在而失败/超时。
    （旧版本会 wait sse_ready 10 秒后放弃）
    """
    ctx_id = "e2e-no-consumer"

    session = await session_manager.get_or_create(ctx_id)
    # 不注册任何订阅者

    start = asyncio.get_event_loop().time()
    for i in range(5):
        await session.event_bus.publish({"event": "x", "data": str(i)})
    elapsed = asyncio.get_event_loop().time() - start

    # publish 应该立即完成（< 0.1 秒），不需要等待任何消费者
    assert elapsed < 0.1, f"publish took {elapsed}s, expected <0.1s"
    print(f"✓ test_inference_does_not_block_on_no_consumer: 5 publishes took {elapsed*1000:.1f}ms (no consumer waiting)")

    await session_manager.remove(ctx_id)


async def test_sse_event_stream_yields_with_id():
    """
    验证 sse_event_stream 正确产生带 id 字段的 SSE 事件。
    （这是 Last-Event-ID 续传的协议基础）
    """
    from routers.sse_chat import sse_event_stream

    ctx_id = "e2e-stream-yield"
    # 预先创建 session 并 publish 几个事件
    session = await session_manager.get_or_create(ctx_id)
    for i in range(3):
        await session.event_bus.publish({
            "event": "text",
            "data": json.dumps({"text": f"event {i}"}),
        })

    # 调用 sse_event_stream，传入 last_event_id=0 触发 replay
    events_received = []
    async def collect():
        async for event in sse_event_stream(ctx_id, "dev_token", last_event_id=0):
            events_received.append(event)
            if len(events_received) >= 3:
                break

    try:
        await asyncio.wait_for(collect(), timeout=2.0)
    except asyncio.TimeoutError:
        pass

    # 验证：每个事件都有 id 字段
    assert len(events_received) >= 1, "Expected at least 1 event"
    for ev in events_received:
        assert "id" in ev, f"Event missing 'id' field: {ev}"
        assert "event" in ev
        assert "data" in ev
        # id 应该是可解析的整数
        eid = int(ev["id"])
        assert eid >= 1
    print(f"✓ test_sse_event_stream_yields_with_id: {len(events_received)} events, all have id field")
    print(f"  First event: id={events_received[0]['id']} event={events_received[0]['event']}")

    await session_manager.remove(ctx_id)


def main():
    print("=" * 60)
    print("E2E tests for EventBus + SSE delivery")
    print("=" * 60)
    print()
    test_health_check()
    test_upload_audio_chunk()
    asyncio.run(test_event_bus_preserves_events_after_subscriber_unregister())
    asyncio.run(test_reconnect_resume_with_last_id())
    asyncio.run(test_inference_does_not_block_on_no_consumer())
    asyncio.run(test_sse_event_stream_yields_with_id())
    print()
    print("✓ All E2E tests passed.")


if __name__ == "__main__":
    main()
