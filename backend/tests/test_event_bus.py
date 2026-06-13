"""
EventBus 单元测试
运行: cd /Users/xiaohu/Downloads/AIVideo/backend && python -m pytest tests/test_event_bus.py -v
或者: python -m tests.test_event_bus
"""
import asyncio
import sys
import os

# 让 tests 目录能 import 上层模块
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from services.event_bus import EventBus


async def test_basic_publish_subscribe():
    """基本发布-订阅：发布后订阅者能收到。"""
    bus = EventBus()
    sid = bus.new_subscriber()

    received = []
    async def collect():
        async for eid, event in bus.subscribe(sid):
            received.append((eid, event))
            if len(received) >= 2:
                break
    task = asyncio.create_task(collect())

    # 等待订阅者进入 wait 状态
    await asyncio.sleep(0.05)
    await bus.publish({"event": "text", "data": "hello"})
    await bus.publish({"event": "end", "data": "bye"})

    try:
        await asyncio.wait_for(task, timeout=2.0)
    except asyncio.TimeoutError:
        task.cancel()
        raise

    assert len(received) == 2
    assert received[0] == (1, {"event": "text", "data": "hello"})
    assert received[1] == (2, {"event": "end", "data": "bye"})
    print("✓ test_basic_publish_subscribe")


async def test_replay_on_resubscribe():
    """续传：显式 last_id=0 可从开头重放历史。"""
    bus = EventBus()

    # 先发布几个事件（无订阅者）
    await bus.publish({"event": "a", "data": "1"})
    await bus.publish({"event": "b", "data": "2"})
    await bus.publish({"event": "c", "data": "3"})

    # 新订阅者显式传 last_id=0，从头重放
    sid = bus.new_subscriber()
    received = []
    async def collect():
        async for eid, event in bus.subscribe(sid, last_id=0):
            received.append((eid, event))
            if len(received) >= 3:
                break
    task = asyncio.create_task(collect())
    try:
        await asyncio.wait_for(task, timeout=2.0)
    except asyncio.TimeoutError:
        task.cancel()
        raise

    assert len(received) == 3
    assert received[0] == (1, {"event": "a", "data": "1"})
    assert received[2] == (3, {"event": "c", "data": "3"})
    print("✓ test_replay_on_resubscribe")


async def test_last_event_id_continue():
    """Last-Event-ID 续传：传入 last_id=2，只重放 2 之后的事件。"""
    bus = EventBus()
    for i in range(5):
        await bus.publish({"event": f"e{i}", "data": str(i)})

    sid = bus.new_subscriber()
    received = []
    async def collect():
        async for eid, event in bus.subscribe(sid, last_id=2):
            received.append((eid, event))
            if len(received) >= 3:
                break
    task = asyncio.create_task(collect())
    try:
        await asyncio.wait_for(task, timeout=2.0)
    except asyncio.TimeoutError:
        task.cancel()
        raise

    assert len(received) == 3
    assert received[0][0] == 3
    assert received[2][0] == 5
    print("✓ test_last_event_id_continue")


async def test_multiple_subscribers():
    """多订阅者：发布的事件对所有订阅者可见。"""
    bus = EventBus()
    sid_a = bus.new_subscriber()
    sid_b = bus.new_subscriber()

    received_a, received_b = [], []

    async def collect(sid, store, target):
        async for eid, event in bus.subscribe(sid):
            store.append((eid, event))
            if len(store) >= target:
                break

    # 让两个订阅者都先订阅（确保它们都在 wait）
    task_a = asyncio.create_task(collect(sid_a, received_a, 3))
    task_b = asyncio.create_task(collect(sid_b, received_b, 3))
    await asyncio.sleep(0.1)

    for i in range(3):
        await bus.publish({"event": f"e{i}", "data": str(i)})

    try:
        await asyncio.wait_for(asyncio.gather(task_a, task_b), timeout=2.0)
    except asyncio.TimeoutError:
        task_a.cancel()
        task_b.cancel()
        raise

    assert len(received_a) == 3
    assert len(received_b) == 3
    assert received_a == received_b
    print("✓ test_multiple_subscribers")


async def test_trim_releases_memory():
    """trim 释放已确认事件。"""
    bus = EventBus()
    sid = bus.new_subscriber()

    # 发布 10 个事件
    for i in range(10):
        await bus.publish({"event": f"e{i}", "data": str(i)})

    # 订阅者消费 10 个
    received = []
    async def collect():
        async for eid, event in bus.subscribe(sid):
            received.append((eid, event))
            if len(received) >= 10:
                break
    task = asyncio.create_task(collect())
    try:
        await asyncio.wait_for(task, timeout=2.0)
    except asyncio.TimeoutError:
        task.cancel()
        raise

    assert bus.size == 10
    await bus.trim()
    # 订阅者已确认 id=10，10 条全部可被 trim
    assert bus.size == 0
    print("✓ test_trim_releases_memory")


async def test_close_stops_subscribers():
    """close() 后订阅者协程能正常返回。"""
    bus = EventBus()
    sid = bus.new_subscriber()

    received = []
    async def collect():
        async for eid, event in bus.subscribe(sid):
            received.append((eid, event))

    task = asyncio.create_task(collect())
    await asyncio.sleep(0.05)
    await bus.close()

    try:
        await asyncio.wait_for(task, timeout=2.0)
    except asyncio.TimeoutError:
        task.cancel()
        raise

    assert received == []
    print("✓ test_close_stops_subscribers")


async def test_publish_after_close_returns_neg1():
    """close() 后 publish 不应崩溃，返回 -1。"""
    bus = EventBus()
    await bus.close()
    eid = await bus.publish({"event": "x", "data": "y"})
    assert eid == -1
    print("✓ test_publish_after_close_returns_neg1")


async def test_late_subscriber_no_replay():
    """晚到的订阅者不重放（new_subscriber 初始化确认位置=最新 id）。"""
    bus = EventBus()
    for i in range(3):
        await bus.publish({"event": f"e{i}", "data": str(i)})

    # 新订阅者默认从 id=3 之后开始订阅
    sid = bus.new_subscriber()
    received = []
    async def collect():
        async for eid, event in bus.subscribe(sid):
            received.append((eid, event))
            if len(received) >= 2:
                break
    task = asyncio.create_task(collect())
    await asyncio.sleep(0.1)

    await bus.publish({"event": "new1", "data": "a"})
    await bus.publish({"event": "new2", "data": "b"})

    try:
        await asyncio.wait_for(task, timeout=2.0)
    except asyncio.TimeoutError:
        task.cancel()
        raise

    # 不应包含 e0/e1/e2，应只有 new1/new2（id=4, 5）
    assert len(received) == 2
    assert received[0] == (4, {"event": "new1", "data": "a"})
    print("✓ test_late_subscriber_no_replay")


async def main():
    await test_basic_publish_subscribe()
    await test_replay_on_resubscribe()
    await test_last_event_id_continue()
    await test_multiple_subscribers()
    await test_trim_releases_memory()
    await test_close_stops_subscribers()
    await test_publish_after_close_returns_neg1()
    await test_late_subscriber_no_replay()
    print("\n✓ All EventBus tests passed.")


if __name__ == "__main__":
    asyncio.run(main())
