#include "common/hangWatchdog.h"

#include "common/common.h"
#include "common/logging/log.h"

#include <array>
#include <atomic>
#include <chrono>
#include <cstring>
#include <fmt/format.h>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

#if KYTY_PLATFORM == KYTY_PLATFORM_LINUX
#include <csignal>
#endif

namespace Common::HangWatchdog {
namespace {

constexpr uint32_t MAX_THREAD_SLOTS = 512;

struct ThreadSlot {
	std::atomic<const char*> library {nullptr};
	std::atomic<const char*> module {nullptr};
	std::atomic<const char*> function {nullptr};
	std::atomic<const char*> wait_kind {nullptr};
	std::atomic<uint64_t>    wait_arg0 {0};
	std::atomic<uint64_t>    wait_arg1 {0};
	std::atomic<uint64_t>    host_lwp {0};
	std::atomic<int32_t>     guest_id {-1};
	std::atomic<const char*> name {nullptr};
	std::atomic<uint64_t>    last_progress_ns {0};
	std::atomic<uint64_t>    call_arg0 {0};
	std::atomic<uint64_t>    call_arg1 {0};
	std::atomic<bool>        has_call_args {false};
	std::atomic<bool>        in_wait {false};
	std::atomic<bool>        primary {false};
};

std::array<ThreadSlot, MAX_THREAD_SLOTS> g_slots;
std::mutex                               g_slot_mutex;
std::vector<int32_t>                     g_free_slots;
int32_t                                  g_next_slot = 0;

std::atomic<bool>     g_enabled {false};
std::atomic<bool>     g_running {false};
std::atomic<bool>     g_dump_requested {false};
std::atomic<uint64_t> g_progress {0};
std::atomic<int32_t>  g_primary_slot {-1};
Options               g_options {};

std::mutex                          g_named_objects_mutex;
std::unordered_map<uint64_t, std::string> g_named_objects;

std::thread g_monitor;

thread_local int32_t t_slot = -1;

uint64_t NowNs() {
	return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(
	                                 std::chrono::steady_clock::now().time_since_epoch())
	                                 .count());
}

int32_t AllocSlot() {
	std::lock_guard lock(g_slot_mutex);
	if (!g_free_slots.empty()) {
		const auto index = g_free_slots.back();
		g_free_slots.pop_back();
		return index;
	}
	if (g_next_slot >= static_cast<int32_t>(MAX_THREAD_SLOTS)) {
		return -1;
	}
	return g_next_slot++;
}

void FreeSlot(int32_t index) {
	if (index < 0 || index >= static_cast<int32_t>(MAX_THREAD_SLOTS)) {
		return;
	}

	auto& slot = g_slots[static_cast<size_t>(index)];
	slot.library.store(nullptr);
	slot.module.store(nullptr);
	slot.function.store(nullptr);
	slot.wait_kind.store(nullptr);
	slot.wait_arg0.store(0);
	slot.wait_arg1.store(0);
	slot.host_lwp.store(0);
	slot.guest_id.store(-1);
	slot.name.store(nullptr);
	slot.last_progress_ns.store(0);
	slot.call_arg0.store(0);
	slot.call_arg1.store(0);
	slot.has_call_args.store(false);
	slot.in_wait.store(false);
	slot.primary.store(false);

	if (g_primary_slot.load() == index) {
		g_primary_slot.store(-1);
	}

	std::lock_guard lock(g_slot_mutex);
	g_free_slots.push_back(index);
}

ThreadSlot* CurrentSlot() {
	if (t_slot < 0) {
		t_slot = AllocSlot();
	}
	if (t_slot < 0) {
		return nullptr;
	}
	return &g_slots[static_cast<size_t>(t_slot)];
}

// Scheduling/polling helpers that spin or sleep in a loop. Entering them is not
// forward progress, otherwise a usleep poll loop would keep the watchdog quiet.
bool IsIdleFunction(const char* function) {
	static constexpr const char* k_idle_functions[] = {
	    "KernelUsleep",
	    "KernelSleep",
	    "KernelNanosleep",
	    "PthreadGetprio",
	    "PthreadSetprio",
	    "PthreadGetaffinity",
	    "PthreadSetaffinity",
	    "PthreadYield",
	    "PthreadSemWait",
	    "PthreadSemTimedwait",
	    "PthreadSemTrywait",
	    "KernelGetProcessTime",
	    "KernelGetProcessTimeCounter",
	    "KernelGetProcessTimeCounterFrequency",
	    "KernelReadTsc",
	    "KernelGetTscFrequency",
	    "KernelGetCurrentCpu",
	    "KernelWaitEventFlag",
	    "KernelPollEventFlag",
	    "KernelWaitEqueue",
	    "KernelWaitSema",
	    "KernelPollSema",
	};

	for (const auto* name: k_idle_functions) {
		if (std::strcmp(function, name) == 0) {
			return true;
		}
	}
	return false;
}

std::string DescribeObject(uint64_t address) {
	if (address == 0) {
		return {};
	}
	std::lock_guard lock(g_named_objects_mutex);
	const auto      it = g_named_objects.find(address);
	if (it == g_named_objects.end()) {
		return {};
	}
	return it->second;
}

std::string FormatSlot(size_t index) {
	const auto& slot = g_slots[index];

	const auto guest_id = slot.guest_id.load();
	if (guest_id < 0) {
		return {};
	}

	const auto format_arg = [](uint64_t value) {
		const auto name = DescribeObject(value);
		if (name.empty()) {
			return fmt::format("0x{:x}", value);
		}
		return fmt::format("0x{:x} ({})", value, name);
	};

	const auto now       = NowNs();
	const auto last      = slot.last_progress_ns.load();
	const auto idle_ms   = last != 0 ? (now - last) / 1000000ull : 0;
	const auto* name     = slot.name.load();
	const auto* library  = slot.library.load();
	const auto* function = slot.function.load();

	std::string text =
	    fmt::format("  [{}] guest_id={} lwp={} name={}{} idle={}{}\n", index, guest_id,
	                slot.host_lwp.load(), name != nullptr ? name : "?",
	                slot.primary.load() ? " [primary]" : "",
	                last != 0 ? std::to_string(idle_ms) : "n/a", last != 0 ? "ms" : "");

	if (library != nullptr && function != nullptr) {
		text += fmt::format("        last call: {}::{}::{}()\n", library, slot.module.load(), function);
		if (slot.has_call_args.load()) {
			text += fmt::format("        last call args: {}, 0x{:x}\n", format_arg(slot.call_arg0.load()),
			                    slot.call_arg1.load());
		}
	} else {
		text += "        last call: <none>\n";
	}

	if (slot.in_wait.load()) {
		const auto* kind = slot.wait_kind.load();
		text += fmt::format("        waiting on: {}({}, 0x{:x})\n", kind != nullptr ? kind : "?",
		                    format_arg(slot.wait_arg0.load()), slot.wait_arg1.load());
	} else if (slot.wait_kind.load() != nullptr) {
		const auto* kind = slot.wait_kind.load();
		text += fmt::format("        last wait: {}({}, 0x{:x})\n", kind,
		                    format_arg(slot.wait_arg0.load()), slot.wait_arg1.load());
	} else {
		text += "        waiting on: <not waiting>\n";
	}

	return text;
}

void MonitorLoop() {
	auto     last_progress  = g_progress.load();
	auto     last_change    = std::chrono::steady_clock::now();
	auto     last_heartbeat = last_change;
	bool     reported       = false;

	while (g_running.load(std::memory_order_relaxed)) {
		std::this_thread::sleep_for(std::chrono::milliseconds(100));
		if (!g_running.load(std::memory_order_relaxed)) {
			break;
		}

		if (g_dump_requested.exchange(false)) {
			Dump("manual request (SIGUSR1)");
			last_progress = g_progress.load();
			last_change   = std::chrono::steady_clock::now();
			reported      = true;
			continue;
		}

		const auto now = std::chrono::steady_clock::now();

		if (g_options.heartbeat &&
		    std::chrono::duration_cast<std::chrono::milliseconds>(now - last_heartbeat).count() >=
		        1000) {
			last_heartbeat = now;
			const auto primary = g_primary_slot.load();
			if (primary >= 0) {
				Log::WriteToConsoleAndLog(
				    fmt::format("[watchdog heartbeat] {}", FormatSlot(static_cast<size_t>(primary))));
			}
		}

		const auto progress = g_progress.load();
		if (progress != last_progress) {
			last_progress = progress;
			last_change   = now;
			reported      = false;
			continue;
		}

		const auto idle_ms =
		    std::chrono::duration_cast<std::chrono::milliseconds>(now - last_change).count();
		if (!reported && idle_ms >= static_cast<int64_t>(g_options.timeout_ms)) {
			Dump(fmt::format("no guest progress for {} ms", idle_ms).c_str());
			reported = true;
		}
	}
}

#if KYTY_PLATFORM == KYTY_PLATFORM_LINUX
void OnDumpSignal(int) {
	g_dump_requested.store(true);
}

void InstallDumpSignalHandler() {
	struct sigaction action {};
	action.sa_handler = OnDumpSignal;
	sigemptyset(&action.sa_mask);
	action.sa_flags = SA_RESTART;
	sigaction(SIGUSR1, &action, nullptr);
}
#endif

} // namespace

void Configure(const Options& options) {
	g_options = options;
	g_enabled.store(options.enabled);
}

void Start() {
	if (!g_options.enabled || g_running.exchange(true)) {
		return;
	}

#if KYTY_PLATFORM == KYTY_PLATFORM_LINUX
	InstallDumpSignalHandler();
#endif

	// Detached: the emulator exits with std::quick_exit(), which skips static
	// destructors, so there is nothing to join against.
	g_monitor = std::thread(MonitorLoop);
	g_monitor.detach();
}

void Stop() {
	g_running.store(false);
}

void RecordCall(const char* library, const char* module, const char* function, bool idle) {
	if (!g_enabled.load(std::memory_order_relaxed)) {
		return;
	}

	auto* slot = CurrentSlot();
	if (slot == nullptr) {
		return;
	}

	slot->library.store(library, std::memory_order_relaxed);
	slot->module.store(module, std::memory_order_relaxed);
	slot->function.store(function, std::memory_order_relaxed);

	// Only real work counts as progress, and only on the primary guest thread, so
	// background services (audio, HTTP, ...) cannot keep the watchdog quiet while
	// the game's main loop is stalled.
	if (!idle && !IsIdleFunction(function)) {
		slot->last_progress_ns.store(NowNs(), std::memory_order_relaxed);
		if (slot->primary.load(std::memory_order_relaxed)) {
			g_progress.fetch_add(1, std::memory_order_relaxed);
		}
	}
}

void RecordCallArgs(uint64_t arg0, uint64_t arg1) {
	if (!g_enabled.load(std::memory_order_relaxed)) {
		return;
	}

	auto* slot = CurrentSlot();
	if (slot == nullptr) {
		return;
	}

	slot->call_arg0.store(arg0, std::memory_order_relaxed);
	slot->call_arg1.store(arg1, std::memory_order_relaxed);
	slot->has_call_args.store(true, std::memory_order_relaxed);
}

void RegisterNamedObject(uint64_t address, const char* name) {
	if (!g_enabled.load(std::memory_order_relaxed) || address == 0) {
		return;
	}
	std::lock_guard lock(g_named_objects_mutex);
	g_named_objects.insert_or_assign(address, name != nullptr ? name : "");
}

void UnregisterNamedObject(uint64_t address) {
	if (!g_enabled.load(std::memory_order_relaxed) || address == 0) {
		return;
	}
	std::lock_guard lock(g_named_objects_mutex);
	g_named_objects.erase(address);
}

void EnterWait(const char* kind, uint64_t arg0, uint64_t arg1) {
	if (!g_enabled.load(std::memory_order_relaxed)) {
		return;
	}

	auto* slot = CurrentSlot();
	if (slot == nullptr) {
		return;
	}

	slot->wait_kind.store(kind, std::memory_order_relaxed);
	slot->wait_arg0.store(arg0, std::memory_order_relaxed);
	slot->wait_arg1.store(arg1, std::memory_order_relaxed);
	slot->in_wait.store(true, std::memory_order_relaxed);
}

void LeaveWait() {
	if (!g_enabled.load(std::memory_order_relaxed)) {
		return;
	}

	auto* slot = CurrentSlot();
	if (slot == nullptr) {
		return;
	}

	slot->in_wait.store(false, std::memory_order_relaxed);
}

void RegisterThread(int guest_id, const char* name, uint64_t host_lwp, bool primary) {
	if (!g_enabled.load(std::memory_order_relaxed)) {
		return;
	}

	auto* slot = CurrentSlot();
	if (slot == nullptr) {
		return;
	}

	slot->guest_id.store(guest_id, std::memory_order_relaxed);
	slot->name.store(name, std::memory_order_relaxed);
	slot->host_lwp.store(host_lwp, std::memory_order_relaxed);
	slot->primary.store(primary, std::memory_order_relaxed);

	if (primary) {
		g_primary_slot.store(t_slot, std::memory_order_relaxed);
	}
}

void UnregisterThread() {
	if (!g_enabled.load(std::memory_order_relaxed)) {
		return;
	}

	if (t_slot >= 0) {
		FreeSlot(t_slot);
		t_slot = -1;
	}
}

void Ping() {
	if (!g_enabled.load(std::memory_order_relaxed)) {
		return;
	}
	g_progress.fetch_add(1, std::memory_order_relaxed);
}

void Dump(const char* reason) {
	Log::WriteToConsoleAndLog(BuildDump(reason));
}

std::string BuildDump(const char* reason) {
	std::string text;
	text += "\n=== Kyty hang watchdog: guest thread dump ===\n";
	text += fmt::format("reason: {}\n", reason != nullptr ? reason : "unknown");
	text += fmt::format("progress counter: {}\n", g_progress.load());

	int shown = 0;
	for (size_t i = 0; i < MAX_THREAD_SLOTS; i++) {
		auto entry = FormatSlot(i);
		if (!entry.empty()) {
			text += entry;
			shown++;
		}
	}

	if (shown == 0) {
		text += "  <no guest threads registered>\n";
	}

	text += "=== end hang watchdog dump ===\n";

	return text;
}

} // namespace Common::HangWatchdog
