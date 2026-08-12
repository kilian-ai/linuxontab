"""WebFuse in-guest self-test: serve + request in one asyncio process."""
import asyncio, sys
sys.path[:0] = ['/opt/webfuse-libs', '/opt/webfuse']
import os
os.chdir('/opt/webfuse')
from app.main import app
import uvicorn

async def main():
    config = uvicorn.Config(app, host='127.0.0.1', port=8000, log_level='warning', access_log=False)
    server = uvicorn.Server(config)
    task = asyncio.create_task(server.serve())
    for _ in range(60):
        await asyncio.sleep(1)
        if server.started:
            break
    print('SERVER_STARTED', server.started, flush=True)
    r, w = await asyncio.open_connection('127.0.0.1', 8000)
    w.write(b'GET /api/sources HTTP/1.0\r\nHost: localhost\r\n\r\n')
    await w.drain()
    data = await asyncio.wait_for(r.read(400), 40)
    print('RESPONSE:', data[:250], flush=True)
    server.should_exit = True
    try:
        await asyncio.wait_for(task, 10)
    except Exception:
        pass

asyncio.run(main())
print('SELFTEST_DONE', flush=True)
