import sys
f = sys.argv[1]
t = open(f).read()

helper = r'''#if ENABLE_HUSH_TICK && !BB_MMU
/* LinuxOnTab: wasm-musl provides no vfork() (it needs asyncify magic), so route
 * $() command substitution through clone(fn,...) — the same NOMMU spawn the
 * pipe/heredoc paths already use successfully on this kernel. */
struct gen_stream_child_args { const char *s; int ch0; int ch1; };
static int gen_stream_child(void *argp)
{
	struct gen_stream_child_args *a = (struct gen_stream_child_args *)argp;
	const char *s = a->s;
	char **to_free = NULL;
	disable_restore_tty_pgrp_on_exit();
	bb_signals(0 + (1 << SIGTSTP) + (1 << SIGTTIN) + (1 << SIGTTOU), SIG_IGN);
	close(a->ch0);
	xmove_fd(a->ch1, 1);
# if ENABLE_HUSH_TRAP
	s = skip_whitespace(s);
	if (is_prefixed_with(s, "trap") && skip_whitespace(s + 4)[0] == '\0') {
		static const char *const argv[] ALIGN_PTR = { NULL, NULL };
		builtin_trap((char**)argv);
		fflush_all();
		_exit(0);
	}
# endif
	re_execute_shell(&to_free, s, G.global_argv[0], G.global_argv + 1, NULL);
	_exit(127);
	return 0;
}
#endif
'''

fn_marker = "static int generate_stream_from_string(const char *s, pid_t *pid_p)"
assert fn_marker in t, "fn marker not found"
t = t.replace(fn_marker, helper + "\n" + fn_marker, 1)

start_marker = "\tpid = BB_MMU ? xfork() : xvfork();"
end_marker = "\n\n\t/* parent */"
si = t.index(start_marker)
ei = t.index(end_marker, si)
newblock = r'''# if BB_MMU
	pid = xfork();
	if (pid == 0) { /* child (MMU path; not built on this NOMMU target) */
		disable_restore_tty_pgrp_on_exit();
		bb_signals(0 + (1 << SIGTSTP) + (1 << SIGTTIN) + (1 << SIGTTOU), SIG_IGN);
		close(channel[0]);
		xmove_fd(channel[1], 1);
		IF_HUSH_JOB(G.run_list_level = 1;)
		CLEAR_RANDOM_T(&G.random_gen);
		reset_traps_to_defaults();
		IF_HUSH_MODE_X(G.x_mode_depth++;)
		parse_and_run_string(s);
		_exit(G.last_exitcode);
	}
# else
	{
		struct gen_stream_child_args csa;
		char child_stack[4096];
		csa.s = s; csa.ch0 = channel[0]; csa.ch1 = channel[1];
		pid = clone(gen_stream_child, child_stack, CLONE_VM | CLONE_VFORK | SIGCHLD, &csa);
	}
# endif'''
t = t[:si] + newblock + t[ei:]
open(f, "w").write(t)
print("hush.c patched: gen_stream_child + clone-based $()")
