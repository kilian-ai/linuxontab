import threading, time, os
work, done = threading.Event(), threading.Event()
def worker():
    for i in range(5):
        os.getpriority(0, 200+i)   # marker: worker pre-wait  (nr=141 a1=200+i)
        work.wait(); work.clear()
        os.getpriority(0, 210+i)   # marker: worker got work
        done.set()
threading.Thread(target=worker, daemon=True).start()
for i in range(5):
    time.sleep(0.3)
    os.getpriority(0, 300+i)       # marker: main pre-set-work
    work.set()
    os.getpriority(0, 310+i)       # marker: main wait-done
    ok = done.wait(timeout=5)
    os.getpriority(0, 320+i if ok else 390+i)  # 320+i=ok, 390+i=TIMEOUT
    done.clear()
os.getpriority(0, 399)             # marker: main all done
