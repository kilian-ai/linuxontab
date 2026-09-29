/* Two threads ping-pong ROUNDS times through one mutex + condvar. Run two
 * copies at once: with futexes keyed by address alone, one process's
 * FUTEX_WAKE lands on the other's waiter and a handoff is lost (both hang,
 * all threads in S). */
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static pthread_mutex_t m = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t c = PTHREAD_COND_INITIALIZER;
static int turn, rounds;

static void *player(void *arg)
{
	int me = (int)(long)arg;
	for (int i = 0; i < rounds; i++) {
		pthread_mutex_lock(&m);
		while (turn != me)
			pthread_cond_wait(&c, &m);
		turn = !me;
		pthread_cond_signal(&c);
		pthread_mutex_unlock(&m);
	}
	return 0;
}

int main(int argc, char **argv)
{
	pthread_t a, b;
	rounds = argc > 1 ? atoi(argv[1]) : 2000;
	pthread_create(&a, 0, player, (void *)0L);
	pthread_create(&b, 0, player, (void *)1L);
	pthread_join(a, 0);
	pthread_join(b, 0);
	printf("condpp pid %d: %d rounds: OK\n", getpid(), rounds);
	return 0;
}
