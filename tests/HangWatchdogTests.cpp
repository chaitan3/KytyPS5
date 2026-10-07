#include "common/hangWatchdog.h"

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <sstream>
#include <string>
#include <thread>

namespace {

void Check(bool value, const char* text) {
	if (!value) {
		std::fprintf(stderr, "HangWatchdogTests: failed: %s\n", text);
		std::abort();
	}
}

bool Contains(const std::string& text, const std::string& needle) {
	return text.find(needle) != std::string::npos;
}

uint64_t ParseProgress(const std::string& text) {
	const std::string key = "progress counter: ";
	const auto        pos = text.find(key);
	if (pos == std::string::npos) {
		return 0;
	}
	return std::strtoull(text.c_str() + pos + key.size(), nullptr, 10);
}

void TestDisabledIsSilent() {
	Common::HangWatchdog::Options options;
	options.enabled = false;
	Common::HangWatchdog::Configure(options);

	Common::HangWatchdog::RegisterThread(1, "Ignored", 42);
	Common::HangWatchdog::RecordCall("libkernel", "libkernel", "KernelUsleep", false);

	const auto dump = Common::HangWatchdog::BuildDump("disabled");
	Check(!Contains(dump, "Ignored"), "disabled watchdog must not register threads");
}

void TestThreadSnapshot() {
	Common::HangWatchdog::Options options;
	options.enabled    = true;
	options.timeout_ms = 1000000;
	Common::HangWatchdog::Configure(options);
	Common::HangWatchdog::Start();

	Common::HangWatchdog::RegisterThread(7, "TestThread", 0x1234, true);

	Common::HangWatchdog::RecordCall("libkernel", "libkernel", "KernelWaitEventFlag", false);
	const auto after_call = ParseProgress(Common::HangWatchdog::BuildDump("call"));

	// Polling helpers must not count as forward progress.
	Common::HangWatchdog::RecordCall("libkernel", "libkernel", "KernelUsleep", false);
	Common::HangWatchdog::RecordCall("libkernel", "libkernel", "PthreadGetprio", false);
	const auto after_idle = ParseProgress(Common::HangWatchdog::BuildDump("idle"));
	Check(after_call == after_idle, "idle helpers must not bump the progress counter");

	// A real library call does.
	Common::HangWatchdog::RecordCall("libSceAgc", "agc", "AgcCreateShader", false);
	const auto after_real = ParseProgress(Common::HangWatchdog::BuildDump("real"));
	Check(after_real == after_idle + 1, "primary-thread real calls must bump the progress counter");

	// A background service thread must not keep the watchdog quiet.
	Common::HangWatchdog::UnregisterThread();
	Common::HangWatchdog::RegisterThread(8, "AudioService", 0x2345, false);
	Common::HangWatchdog::RecordCall("libSceAudioOut2", "AudioOut2", "AudioOut2ContextPush", false);
	const auto after_service = ParseProgress(Common::HangWatchdog::BuildDump("service"));
	Check(after_service == after_real,
	      "non-primary real calls must not bump the progress counter");

	Common::HangWatchdog::EnterWait("equeue", 0x2, 1024);
	auto dump = Common::HangWatchdog::BuildDump("waiting");
	Check(Contains(dump, "guest_id=8"), "dump must include the guest thread id");
	Check(Contains(dump, "name=AudioService"), "dump must include the thread name");
	Check(Contains(dump, "last call: libSceAudioOut2::AudioOut2::AudioOut2ContextPush"),
	      "dump must include the last library call");
	Check(Contains(dump, "waiting on: equeue(0x2, 0x400)"),
	      "dump must describe the current wait");

	Common::HangWatchdog::LeaveWait();
	dump = Common::HangWatchdog::BuildDump("running");
	Check(Contains(dump, "waiting on: <not waiting>"), "dump must clear the wait state");

	Common::HangWatchdog::UnregisterThread();
	dump = Common::HangWatchdog::BuildDump("unregistered");
	Check(!Contains(dump, "AudioService"), "unregistered threads must not appear in the dump");

	Common::HangWatchdog::Stop();
	// Let the detached monitor observe the stop flag before the process exits.
	std::this_thread::sleep_for(std::chrono::milliseconds(300));
}

std::string ReadFile(const char* path) {
	std::ifstream file(path);
	std::stringstream buffer;
	buffer << file.rdbuf();
	return buffer.str();
}

void TestAutoDumpOnStall() {
	// The monitor writes through Log, which falls back to stdout before Log is
	// initialized. Capture it to a file so the automatic dump can be asserted.
	const char* dump_path = "hang_watchdog_auto_dump.txt";
	std::fflush(stdout);
	std::freopen(dump_path, "w", stdout);

	Common::HangWatchdog::Options options;
	options.enabled    = true;
	options.timeout_ms = 300;
	Common::HangWatchdog::Configure(options);
	Common::HangWatchdog::Start();

	Common::HangWatchdog::RegisterThread(9, "Stalled", 1, true);
	Common::HangWatchdog::RecordCall("libSceAgc", "agc", "AgcCreateShader", false);

	// No further progress: the monitor must notice and dump automatically.
	std::this_thread::sleep_for(std::chrono::milliseconds(1500));

	Common::HangWatchdog::Stop();
	std::this_thread::sleep_for(std::chrono::milliseconds(300));
	std::fflush(stdout);

	const auto dump = ReadFile(dump_path);
	std::remove(dump_path);

	Check(Contains(dump, "reason: no guest progress"),
	      "watchdog must dump automatically once progress stalls");
	Check(Contains(dump, "guest_id=9"), "automatic dump must include the stalled thread");
	Check(Contains(dump, "name=Stalled"), "automatic dump must include the thread name");
}

} // namespace

int main() {
	TestDisabledIsSilent();
	TestThreadSnapshot();
	TestAutoDumpOnStall();

	std::fprintf(stderr, "HangWatchdogTests: ok\n");
	return 0;
}
