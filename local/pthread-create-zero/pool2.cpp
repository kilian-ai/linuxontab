// comphelper::ThreadPool + osl thread start, in miniature (see sal/osl/unx/thread.cxx,
// comphelper/source/misc/threadpool.cxx). Two "filter passes" per round, each joining.
#include <pthread.h>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <mutex>
#include <vector>
#include <time.h>
#include <unistd.h>
#include <sys/syscall.h>
#include <signal.h>
#include <string.h>
static int V = 0;
// in-memory event ring, dumped by SIGUSR1 (no syscalls on the hot path)
struct Ev { int tid; const char *what; int a, b; };
static Ev ring[4096]; static volatile unsigned ridx;
static thread_local int mytid;
static void ev(const char *what, int a = 0, int b = 0) {
    if (!mytid) mytid = (int)syscall(SYS_gettid);
    unsigned i = __atomic_fetch_add(&ridx, 1, __ATOMIC_SEQ_CST) & 4095;
    ring[i].tid = mytid; ring[i].what = what; ring[i].a = a; ring[i].b = b;
}
static void dump(int) {
    char buf[160]; unsigned n = ridx, from = n > 400 ? n - 400 : 0;
    for (unsigned k = from; k < n; k++) { Ev &e = ring[k & 4095];
        int l = snprintf(buf, sizeof buf, "%u [%d] %s %d %d\n", k, e.tid, e.what, e.a, e.b); write(2, buf, l); }
}
#define T(...) ev(__VA_ARGS__)

// ---- osl thread ----
enum { STARTUP = 1, ACTIVE = 2, SUSPENDED = 4 };
struct OslThread {
    pthread_t h; pthread_mutex_t lock; pthread_cond_t cond; int flags;
    void (*fn)(void *); void *arg;
};
static void *osl_start(void *p) {
    OslThread *t = (OslThread *)p;
    T("start");
    pthread_mutex_lock(&t->lock);
    t->flags &= ~STARTUP; t->flags |= ACTIVE;
    pthread_cond_signal(&t->cond);
    while (t->flags & SUSPENDED) { T("suspended wait"); pthread_cond_wait(&t->cond, &t->lock); T("suspended woke"); }
    pthread_mutex_unlock(&t->lock);
    t->fn(t->arg);
    T("exit");
    return nullptr;
}
static OslThread *osl_create_suspended(void (*fn)(void *), void *arg) {
    OslThread *t = new OslThread();
    pthread_mutex_init(&t->lock, nullptr); pthread_cond_init(&t->cond, nullptr);
    t->flags = STARTUP | SUSPENDED; t->fn = fn; t->arg = arg;
    pthread_mutex_lock(&t->lock);
    pthread_attr_t a; pthread_attr_init(&a); pthread_attr_setstacksize(&a, 4 << 20);
    if (pthread_create(&t->h, &a, osl_start, t)) { perror("pthread_create"); exit(2); }
    pthread_attr_destroy(&a);
    while (t->flags & STARTUP) pthread_cond_wait(&t->cond, &t->lock);
    pthread_mutex_unlock(&t->lock);
    return t;
}
static void osl_resume(OslThread *t) {
    pthread_mutex_lock(&t->lock);
    if (t->flags & SUSPENDED) { t->flags &= ~SUSPENDED; pthread_cond_signal(&t->cond); }
    pthread_mutex_unlock(&t->lock);
}

// ---- comphelper::ThreadPool ----
struct Tag {
    std::mutex m; std::condition_variable done; int working = 0;
    void pushed() { std::lock_guard<std::mutex> g(m); working++; }
    void finished() { std::lock_guard<std::mutex> g(m); if (--working == 0) done.notify_all(); }
    bool isDone() { std::lock_guard<std::mutex> g(m); return working == 0; }
    void wait() { std::unique_lock<std::mutex> g(m); while (working > 0) done.wait(g); }
};
struct Task { std::shared_ptr<Tag> tag; int n; void exec() { volatile long x = 0; for (int k = 0; k < n; k++) x += k; } };
struct Pool;
struct Worker { Pool *pool; OslThread *t; };
struct Pool {
    std::mutex m; std::condition_variable changed;
    std::vector<std::unique_ptr<Task>> tasks; std::vector<Worker *> workers;
    bool terminate = true; size_t maxw; int busy = 0;
    explicit Pool(size_t n) : maxw(n) {}
    std::unique_ptr<Task> pop(std::unique_lock<std::mutex> &g, bool wait) {
        do {
            if (!tasks.empty()) { auto t = std::move(tasks.back()); tasks.pop_back(); return t; }
            else if (!wait || terminate) return nullptr;
            T("worker wait"); changed.wait(g); T("worker woke term ntasks", (int)terminate, (int)tasks.size());
        } while (!terminate);
        return nullptr;
    }
    static void run(void *p) {
        Pool *pl = (Pool *)p;
        std::unique_lock<std::mutex> g(pl->m);
        while (!pl->terminate) {
            auto t = pl->pop(g, true);
            if (t) { auto tag = t->tag; pl->busy++; g.unlock(); t->exec(); t.reset(); g.lock(); pl->busy--; tag->finished(); }
        }
    }
    void push(std::unique_ptr<Task> t) {
        std::lock_guard<std::mutex> g(m);
        terminate = false;
        if (workers.size() < maxw && workers.size() <= tasks.size() + busy) {
            Worker *w = new Worker{this, nullptr};
            T("create worker"); w->t = osl_create_suspended(run, this);
            T("resume"); osl_resume(w->t);
            workers.push_back(w);
        }
        t->tag->pushed();
        tasks.insert(tasks.begin(), std::move(t));
        changed.notify_one();
    }
    void shutdownLocked(std::unique_lock<std::mutex> &g) {
        while (!tasks.empty()) { changed.wait(g); changed.notify_one(); }
        terminate = true;
        T("notify_all nworkers", (int)workers.size());
        changed.notify_all();
        auto ws = std::move(workers); workers.clear();
        g.unlock();
        while (!ws.empty()) { Worker *w = ws.back(); ws.pop_back(); T("join"); pthread_join(w->t->h, nullptr); T("joined"); delete w; }
    }
    void waitUntilDone(const std::shared_ptr<Tag> &tag) {
        tag->wait();
        std::unique_lock<std::mutex> g(m);
        if (tasks.empty() && busy == 0) shutdownLocked(g);
    }
};

int main(int argc, char **argv) {
    int rounds = argc > 1 ? atoi(argv[1]) : 20, nw = argc > 2 ? atoi(argv[2]) : 4, strips = argc > 3 ? atoi(argv[3]) : 24;
    V = getenv("V") != nullptr; signal(SIGUSR1, dump);
    Pool pool(nw);
    for (int r = 0; r < rounds; r++) {
        for (int pass = 0; pass < 2; pass++) {
            auto tag = std::make_shared<Tag>();
            for (int s = 0; s < strips; s++) pool.push(std::unique_ptr<Task>(new Task{tag, 30000}));
            Task{tag, 30000}.exec();                    // the last strip on the main thread
            pool.waitUntilDone(tag);
        }
        T("round done", r + 1); printf("round %d ok\n", r + 1); fflush(stdout);
    }
    printf("POOL2 DONE\n");
    return 0;
}
