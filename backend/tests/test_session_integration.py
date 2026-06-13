"""
EventBus + SessionManager 集成测试
模拟 SSE 消费者断线重连场景，验证事件不丢失

运行: cd /Users/xiaohu/Downloads/AIVideo/backend && python -m tests.test_session_integration
"""
import asyncio
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from services.session_manager import session_manager, Session


async def test_simulate_disconnect_during_inference():
    """
    模拟核心场景：
    1. SSE 消费者连接，订阅事件
    2. 推理开始，发布一些事件
    3. SSE 消费者断开（模拟 hot restart / 弱网）
    4. 推理继续完成，发布剩余事件
    5. SSE 消费者重连，传入 lastEventId
    6. 验证：重连后能补送所有遗漏事件
    """
    ctx_id = "test-disconnect-123"
    session = await session_manager.get_or_create(ctx_id)

    # Step 1: SSE 消费者连接
    sid1 = session.register_sse_subscriber()

    received_1 = []
    consumer_1_done = asyncio.Event()

    async def consumer_1():
        async for eid, event in session.event_bus.subscribe(sid1):
            received_1.append((eid, event))
            # 模拟：收到前 2 个事件后断开
            if len(received_1) >= 2:
                consumer_1_done.set()
                return

    task_1 = asyncio.create_task(consumer_1())

    # 等订阅者进入 wait
    await asyncio.sleep(0.05)

    # Step 2: 推理开始，发布 2 个事件
    await session.event_bus.publish({"event": "text", "data": '{"text": "你"}'})
    await session.event_bus.publish({"event": "text", "data": '{"text": "好"}'})

    # 等待消费者收到 2 个事件后断开
    try:
        await asyncio.wait_for(consumer_1_done.wait(), timeout=2.0)
    except asyncio.TimeoutError:
        task_1.cancel()
        raise
    task_1.cancel()
    try:
        await task_1
    except asyncio.CancelledError:
        pass
    session.unregister_sse_subscriber(sid1)

    assert len(received_1) == 2
    assert received_1[0] == (1, {"event": "text", "data": '{"text": "你"}'})
    assert received_1[1] == (2, {"event": "text", "data": '{"text": "好"}'})
    print("✓ Step 1-2: First consumer received 2 events, then disconnected")

    # Step 3-4: 推理继续，发布剩余事件（消费者已断）
    await session.event_bus.publish({"event": "text", "data": '{"text": "呀"}'})
    await session.event_bus.publish({"event": "text", "data": '{"text": "。"}'})
    await session.event_bus.publish({"event": "end", "data": '{"full_text": "你好呀。"}'})

    print("✓ Step 3-4: Inference published 3 more events while no consumer")

    # Step 5: 新 SSE 消费者重连，传入 lastEventId=2
    sid2 = session.register_sse_subscriber()
    received_2 = []

    async def consumer_2():
        async for eid, event in session.event_bus.subscribe(sid2, last_id=2):
            received_2.append((eid, event))
            if len(received_2) >= 3:
                return

    task_2 = asyncio.create_task(consumer_2())
    try:
        await asyncio.wait_for(task_2, timeout=2.0)
    except asyncio.TimeoutError:
        task_2.cancel()
        raise
    session.unregister_sse_subscriber(sid2)

    # Step 6: 验证补送
    assert len(received_2) == 3
    assert received_2[0][0] == 3  # 从 id=3 开始重放
    assert received_2[2] == (5, {"event": "end", "data": '{"full_text": "你好呀。"}'})
    print("✓ Step 5-6: Reconnected consumer resumed from lastEventId, got all 3 missed events")
    print("  Replayed events: 3, 4, 5 (text, text, end)")

    # 清理
    await session_manager.remove(ctx_id)


async def test_concurrent_consumers():
    """
    模拟多消费者并存：
    - 一个 SSE 消费者（前端显示）
    - 一个监控/日志消费者（内部服务）
    两者都应能收到全部事件
    """
    ctx_id = "test-concurrent-456"
    session = await session_manager.get_or_create(ctx_id)

    sid_a = session.register_sse_subscriber()
    sid_b = session.register_sse_subscriber()

    received_a, received_b = [], []

    async def make_consumer(sid, store, target):
        async for eid, event in session.event_bus.subscribe(sid):
            store.append((eid, event))
            if len(store) >= target:
                return

    task_a = asyncio.create_task(make_consumer(sid_a, received_a, 3))
    task_b = asyncio.create_task(make_consumer(sid_b, received_b, 3))
    await asyncio.sleep(0.1)

    for i in range(3):
        await session.event_bus.publish({"event": "text", "data": f"event {i}"})

    try:
        await asyncio.wait_for(asyncio.gather(task_a, task_b), timeout=2.0)
    except asyncio.TimeoutError:
        task_a.cancel()
        task_b.cancel()
        raise

    assert received_a == received_b
    assert len(received_a) == 3
    print("✓ test_concurrent_consumers: both consumers received all 3 events")

    session.unregister_sse_subscriber(sid_a)
    session.unregister_sse_subscriber(sid_b)
    await session_manager.remove(ctx_id)


async def test_publish_after_session_remove():
    """
    验证 session 移除后，事件总线关闭，publish 不崩溃
    """
    ctx_id = "test-remove-789"
    session = await session_manager.get_or_create(ctx_id)

    await session.event_bus.publish({"event": "x", "data": "y"})

    # 移除 session
    await session_manager.remove(ctx_id)

    # 模拟"对已移除 session 的 publish"——但实际上引用还在，只是 session_manager 不再持有
    eid = await session.event_bus.publish({"event": "z", "data": "w"})
    assert eid == -1  # closed bus returns -1
    print("✓ test_publish_after_session_remove: publish on removed session returns -1 gracefully")


async def test_trim_prevents_memory_leak():
    """
    验证 trim 释放已确认事件，避免内存泄漏
    """
    ctx_id = "test-trim-leak"
    session = await session_manager.get_or_create(ctx_id)
    sid = session.register_sse_subscriber()

    # 发布 1000 个事件
    for i in range(1000):
        await session.event_bus.publish({"event": "x", "data": str(i)})

    assert session.event_bus.size == 1000

    # 订阅并消费 1000 个
    received = []
    async def consumer():
        async for eid, event in session.event_bus.subscribe(sid):
            received.append((eid, event))
            if len(received) >= 1000:
                return
    task = asyncio.create_task(consumer())
    try:
        await asyncio.wait_for(task, timeout=3.0)
    except asyncio.TimeoutError:
        task.cancel()
        raise

    # 确认后 trim
    await session.event_bus.trim()
    assert session.event_bus.size == 0, f"Expected size=0, got {session.event_bus.size}"
    print(f"✓ test_trim_prevents_memory_leak: 1000 events published and trimmed, size={session.event_bus.size}")

    session.unregister_sse_subscriber(sid)
    await session_manager.remove(ctx_id)


async def main():
    await test_simulate_disconnect_during_inference()
    print()
    await test_concurrent_consumers()
    print()
    await test_publish_after_session_remove()
    print()
    await test_trim_prevents_memory_leak()
    print()
    print("✓ All Session integration tests passed.")


if __name__ == "__main__":
    asyncio.run(main())
