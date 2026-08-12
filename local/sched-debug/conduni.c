/* conduni.c — UNIDIRECTIONAL cond: worker waits N times, main signals N times.
 * Simplest possible cond usage. Markers: getpriority(0,N). */
#include <pthread.h>
#include <stdio.h>
#include <sys/resource.h>

#define ROUNDS 6
static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t  cv = PTHREAD_COND_INITIALIZER;
static int ready;   /* incremented by main, consumed by worker */
static int done;    /* worker acks each round */

static void *worker(void *a)
{
	(void)a;
	for (int i = 0; i < ROUNDS; i++) {
		getpriority(PRIO_PROCESS, 200 + i);
		pthread_mutex_lock(&mu);
		while (ready <= i)
			pthread_cond_wait(&cv, &mu);
		pthread_mutex_unlock(&mu);
		printf("worker got %d\n", i);
	}
	return 0;
}

int main(void)
{
	pthread_t t;
	setvbuf(stdout, 0, _IONBF, 0);
	pthread_create(&t, 0, worker, 0);
	for (int i = 0; i < ROUNDS; i++) {
		getpriority(PRIO_PROCESS, 300 + i);
		/* let the worker park first */
		struct timespec ts = { 0, 50 * 1000 * 1000 };
		nanosleep(&ts, 0);
		pthread_mutex_lock(&mu);
		ready = i + 1;
		pthread_cond_signal(&cv);
		pthread_mutex_unlock(&mu);
		printf("main sent %d\n", i);
	}
	pthread_join(t, 0);
	printf("CONDUNI DONE\n");
	return 0;
}
