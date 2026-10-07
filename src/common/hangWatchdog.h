#ifndef KYTY_COMMON_HANG_WATCHDOG_H_
#define KYTY_COMMON_HANG_WATCHDOG_H_

#include <cstdint>
#include <string>

// Lightweight guest-progress watchdog.
//
// The emulator can end up in a state where every guest thread is parked on a
// wait (event flag, equeue, usleep poll loop, ...) and no frame is ever
// presented. From the outside that looks like a black-screen hang with no
// crash and no useful log tail.
//
// This module keeps a tiny per-thread record of the last guest library call and
// the wait it is currently blocked on. Forward progress is measured on the
// primary guest thread (the one that runs the game's entry point) plus completed
// frame flips, so busy background services (audio, HTTP, ...) cannot mask a
// stalled main loop. A monitor thread dumps the state of every registered guest
// thread once no progress has been observed for a configurable timeout.
//
// A manual dump can be requested at any time with SIGUSR1 on Linux, which is
// handy when attached to a live process.
namespace Common::HangWatchdog {

struct Options {
	bool     enabled    = false;
	uint32_t timeout_ms = 30000;
	// Log the primary thread's last call/wait every second, even while progress
	// continues. Useful for short-lived hangs that end before the timeout fires.
	bool heartbeat = false;
};

// Store the configuration. Must be called before Start().
void Configure(const Options& options);

// Start the monitor thread (no-op when the watchdog is disabled).
void Start();

// Ask the monitor thread to stop. Safe to call more than once.
void Stop();

// Hot path: called on entry to every guest library function. `idle` marks
// scheduling/polling helpers (usleep, getprio, ...) that must not be treated as
// forward progress. Cheap and safe to call when the watchdog is disabled.
void RecordCall(const char* library, const char* module, const char* function, bool idle);

// Describe the wait a thread is about to block on. `kind` must be a string
// literal with static storage duration.
void EnterWait(const char* kind, uint64_t arg0 = 0, uint64_t arg1 = 0);
void LeaveWait();

// Record two extra arguments for the current thread's last call without
// changing its wait state (e.g. the event flag handle and bit pattern). Useful
// for non-blocking polls that would otherwise only show the function name.
void RecordCallArgs(uint64_t arg0, uint64_t arg1);

// Associate a kernel object handle (event flag, equeue, ...) with its guest
// name so dumps can resolve raw pointers. The name is copied.
void RegisterNamedObject(uint64_t address, const char* name);
void UnregisterNamedObject(uint64_t address);

// Guest thread identity. Called when a guest thread starts and ends. Exactly one
// thread should be registered as `primary` (the game's main/entry thread).
void RegisterThread(int guest_id, const char* name, uint64_t host_lwp, bool primary = false);
void UnregisterThread();

// Signal forward progress from outside the guest dispatch path (e.g. a
// presented frame).
void Ping();

// Write a snapshot of all registered guest threads to the log and stdout.
void Dump(const char* reason);

// Build the same snapshot as text without writing it. Exposed for tests.
std::string BuildDump(const char* reason);

} // namespace Common::HangWatchdog

#endif /* KYTY_COMMON_HANG_WATCHDOG_H_ */
