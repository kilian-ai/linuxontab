// C++ exception handling on the wasm guest (toolchain/cpp-eh-sysroot).
// Each check prints "ok <name>"; the last line is "ehtest: N/N OK".
#include <cstdio>
#include <exception>
#include <memory>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>
#include <atomic>

static int passed, total;
static void check(const char *name, bool ok) {
	total++; if (ok) passed++;
	std::printf("%s %s\n", ok ? "ok" : "FAIL", name);
}

struct Guard { int *n; ~Guard() { ++*n; } };
struct MyError : std::runtime_error { int code; MyError(int c) : std::runtime_error("mine"), code(c) {} };

__attribute__((noinline)) static void deep(int depth, int *dtors) {
	Guard g{dtors};
	if (depth == 0) throw MyError(42);
	deep(depth - 1, dtors);
}

struct Base { virtual ~Base() = default; virtual void f() = 0; };
struct Thrower : Base { void f() override { throw std::string("virtual"); } };

int main() {
	// 1. by type through 20 frames, every destructor runs
	int dtors = 0, code = 0;
	try { deep(20, &dtors); } catch (const MyError &e) { code = e.code; }
	check("throw-through-frames", code == 42 && dtors == 21);

	// 2. thrown inside libc++ itself
	bool caught = false;
	try { std::vector<int> v(3); (void)v.at(10); } catch (const std::out_of_range &) { caught = true; }
	check("libcxx-out_of_range", caught);

	// 3. catch base class, what()
	std::string what;
	try { throw MyError(1); } catch (const std::exception &e) { what = e.what(); }
	check("catch-by-base", what == "mine");

	// 4. rethrow + catch(...)
	int stage = 0;
	try { try { throw 7; } catch (int) { stage = 1; throw; } } catch (...) { stage = stage == 1 ? 2 : 0; }
	check("rethrow", stage == 2);

	// 5. exception_ptr across threads
	std::exception_ptr ep;
	std::thread t([&] { try { throw std::logic_error("from thread"); } catch (...) { ep = std::current_exception(); } });
	t.join();
	std::string msg;
	try { std::rethrow_exception(ep); } catch (const std::logic_error &e) { msg = e.what(); }
	check("exception_ptr-across-threads", msg == "from thread");

	// 6. through a virtual call
	std::unique_ptr<Base> b(new Thrower);
	std::string s;
	try { b->f(); } catch (const std::string &x) { s = x; }
	check("through-virtual-call", s == "virtual");

	// 7. many threads throwing concurrently (per-thread __cxa_eh_globals)
	std::atomic<int> good{0};
	std::vector<std::thread> ts;
	for (int i = 0; i < 4; i++)
		ts.emplace_back([&, i] {
			for (int k = 0; k < 200; k++) {
				try { int d = 0; deep(5 + i, &d); } catch (const MyError &e) { if (e.code == 42) good++; }
			}
		});
	for (auto &x : ts) x.join();
	check("concurrent-threads", good == 800);

	// 8. nested exception while unwinding is handled (caught inside a destructor)
	struct Inner { ~Inner() { try { throw 1; } catch (int) {} } };
	bool outer = false;
	try { Inner in; throw 2.0; } catch (double) { outer = true; }
	check("throw-inside-destructor-during-unwind", outer);

	std::printf("ehtest: %d/%d %s\n", passed, total, passed == total ? "OK" : "FAIL");
	return passed != total;
}
