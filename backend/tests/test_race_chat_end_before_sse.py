"""
回归测试：客户端先发 /chat/end、后连 SSE 时仍能收到所有事件

复现日志场景：
1. 客户端先发 audio chunks + chat/end
2. 后端 _omni_inference 开始推理并 publish 事件
3. 客户端**之后**才连上 SSE
4. 验证：SSE 消费者能补送所有遗漏事件

运行: cd /Users/xiaohu/Downloads/AIVideo/backend && python -m tests.test_race_chat_end_before_sse
"""
import asyncio
import json
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

os.environ.setdefault("TEST_MODE", "true")
os.environ.setdefault("OMNI_MODE", "false")
os.environ.setdefault("DEBUG", "true")

from services.session_manager import session_manager


async def test_chat_end_before_sse():
    """
    关键回归：客户端先发 /chat/end，后连 SSE 仍能收到本轮所有事件。
    """
    ctx_id = "race-test-1"
    session = await session_manager.get_or_create(ctx_id)

    # 模拟 /chat/end 处理器：同步设置 turn_start_id
    session.turn_active = True
    session.turn_start_id = session.event_bus.next_id  # 此时 next_id 是下一个要分配的 id
    # 此时 _next_id=0, turn_start_id=0（首轮）

    # 模拟推理任务开始 publish 事件
    inference_task = asyncio.create_task(_simulate_inference(session))

    # 给推理 100ms 时间，确保它在 SSE 连接前 publish 了几个事件
    await asyncio.sleep(0.1)

    # 现在模拟客户端连上 SSE（这才是"晚了"的关键时点）
    sid = session.register_sse_subscriber()

    received = []
    async def consumer():
        async for eid, event in session.event_bus.subscribe(sid):
            received.append((eid, event))
            if len(received) >= 5:
                return

    try:
        await asyncio.wait_for(consumer(), timeout=3.0)
    except asyncio.TimeoutError:
        pass

    # 等待推理完成
    try:
        await inference_task
    except asyncio.CancelledError:
        pass

    # 验证：客户端能补送所有事件
    print(f"  Received {len(received)} events via SSE")
    for r in received:
        print(f"    id={r[0]} event={r[1]['event']}")

    # 应该有 5 个事件（3 text + 1 audio + 1 end）
    assert len(received) >= 5, f"Expected at least 5 events, got {len(received)}"
    # 第一个事件 id 应该 >= turn_start_id
    first_id = received[0][0]
    assert first_id >= 1, f"First event id should be >=1, got {first_id}"
    print(f"✓ test_chat_end_before_sse: client connected after /chat/end, got {len(received)} events")

    await session_manager.remove(ctx_id)


async def _simulate_inference(session):
    """模拟 _omni_inference：连续 publish 5 个事件"""
    event_bus = session.event_bus
    await event_bus.publish({"event": "text", "data": json.dumps({"text": "你"})})
    await asyncio.sleep(0.05)
    await event_bus.publish({"event": "text", "data": json.dumps({"text": "好"})})
    await asyncio.sleep(0.05)
    await event_bus.publish({"event": "text", "data": json.dumps({"text": "呀"})})
    await asyncio.sleep(0.05)
    await event_bus.publish({"event": "audio", "data": json.dumps({"audio": "xxx", "index": 1})})
    await asyncio.sleep(0.05)
    await event_bus.publish({"event": "end", "data": json.dumps({"full_text": "你好呀。", "audio_seconds": 1.0})})
    session.turn_start_id = 0
    session.turn_active = False


async def test_no_active_turn_means_no_replay():
    """
    没有进行中的 turn（turn_start_id=0）时，新 SSE 订阅者不应该重放历史。
    """
    ctx_id = "no-turn-test"
    session = await session_manager.get_or_create(ctx_id)

    # 先 publish 几个事件
    for i in range(3):
        await session.event_bus.publish({"event": "x", "data": str(i)})

    # 客户端连 SSE（无 turn）
    sid = session.register_sse_subscriber()
    # 此时 turn_start_id=0，应从 _next_id 开始（不重放）
    received = []
    async def consumer():
        # 等 0.3s 应该没有事件过来
        await asyncio.sleep(0.3)
        return
    await consumer()
    # 现在 publish 新事件
    await session.event_bus.publish({"event": "y", "data": "new"})

    # 等消费者收到这个新事件
    received = []
    async def consumer2():
        async for eid, event in session.event_bus.subscribe(sid):
            received.append((eid, event))
            return
    try:
        await asyncio.wait_for(consumer2(), timeout=1.0)
    except asyncio.TimeoutError:
        pass

    assert len(received) == 1
    assert received[0][0] == 4  # 4=3+1（新事件）
    print(f"✓ test_no_active_turn_means_no_replay: no replay when no active turn (id={received[0][0]})")

    await session_manager.remove(ctx_id)


async def main():
    print("=" * 60)
    print("Race regression tests for /chat/end → SSE delivery")
    print("=" * 60)
    print()
    await test_chat_end_before_sse()
    print()
    await test_no_active_turn_means_no_replay()
    print()
    print("✓ All race regression tests passed.")


if __name__ == "__main__":
    asyncio.run(main())
