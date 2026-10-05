/* wasm_cxa_thread_atexit.c — __cxa_thread_atexit_impl for musl on wasm32.
 *
 * libc++abi's __cxa_thread_atexit (destructors of C++ thread_local objects)
 * calls the libc's __cxa_thread_atexit_impl, which glibc has and musl does
 * not. Keep a per-thread list in a pthread key whose destructor runs it at
 * thread exit, newest first. The main thread's list is not run at exit()
 * (pthread key destructors only run when a thread exits), which only skips
 * destructors at process end. */
#include <pthread.h>
#include <stdlib.h>

struct tls_dtor { void (*fn)(void *); void *obj; struct tls_dtor *next; };
static pthread_key_t dtor_key;
static pthread_once_t dtor_once = PTHREAD_ONCE_INIT;

static void run_dtors(void *p)
{
    struct tls_dtor *d = p;
    while (d) {
        struct tls_dtor *next = d->next;
        d->fn(d->obj);
        free(d);
        d = next;
    }
}
static void make_key(void) { pthread_key_create(&dtor_key, run_dtors); }

int __cxa_thread_atexit_impl(void (*fn)(void *), void *obj, void *dso)
{
    (void)dso;
    pthread_once(&dtor_once, make_key);
    struct tls_dtor *d = malloc(sizeof *d);
    if (!d) return -1;
    d->fn = fn; d->obj = obj;
    d->next = pthread_getspecific(dtor_key);
    pthread_setspecific(dtor_key, d);
    return 0;
}
