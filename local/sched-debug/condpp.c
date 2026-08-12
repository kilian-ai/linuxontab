/*
 * condpp.c — pthread mutex+cond ping-pong.
 *
 * Companion to futexpp.c (raw futex, PASSES). CPython's threading.Lock/Event
 * on this build use the mutex+cond emulation, and the guest repro corrupts
 * musl's condvar waiter list (__private_cond_signal reads an unaligned
 * _c_head) on about the 3rd handoff. This exercises the exact same musl
 * machinery from plain C: if it fails, the bug is platform-level (musl port /
 * kernel / asyncify); if it passes, the python *binary* build is the suspect
 * (asyncify -O2 post-pass).
 *
 * Markers: getpriority(0, N) — visible in the ?debuglog syscall trace as
 * nr=141 a1=N even though N is not a valid pid.
 */
#include <pthread.h>
#include <stdio.h>
#include <sys/resource.h>

#define ROUNDS 10

static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t cv = PTHREAD_COND_INITIALIZER;
static int turn; /* 0 = main's turn, 1 = worker's turn */

static void *worker(void *arg)
{
	(void)arg;
	for (int i = 0; i < ROUNDS; i++) {
		getpriority(PRIO_PROCESS, 200 + i);
		pthread_mutex_lock(&mu);
		while (turn != 1)
			pthread_cond_wait(&cv, &mu);
		turn = 0;
		pthread_cond_signal(&cv);
		pthread_mutex_unlock(&mu);
	}
	return 0;
}

int main(void)
{
	pthread_t t;
	setvbuf(stdout, 0, _IONBF, 0);
	if (pthread_create(&t, 0, worker, 0)) {
		printf("condpp: pthread_create failed\n");
		return 1;
	}
	for (int i = 0; i < ROUNDS; i++) {
		getpriority(PRIO_PROCESS, 300 + i);
		pthread_mutex_lock(&mu);
		turn = 1;
		pthread_cond_signal(&cv);
		while (turn != 0)
			pthread_cond_wait(&cv, &mu);
		pthread_mutex_unlock(&mu);
		printf("condpp round %d ok\n", i);
	}
	pthread_join(t, 0);
	printf("condpp DONE %d/%d\n", ROUNDS, ROUNDS);
	return 0;
}
