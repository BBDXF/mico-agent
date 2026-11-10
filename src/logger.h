#pragma once

// Single bounded log sink: optional file with size-based rotation
// (file -> file.1 -> ... file.<keep>) plus optional echo to stderr.
// Forked children must not use it (they write nothing or plain stderr).

#include <string>
#include <vector>

namespace mico {

struct LogConfig {
    std::string file;         // "" = stderr only
    long long max_bytes = 512 * 1024;
    int keep = 1;
    bool echo_stderr = true;
};

void log_configure(const LogConfig& c);
const LogConfig& log_config();
// Writes one line (a timestamp is prepended; trailing newline added).
void log_line(const std::string& msg);
void logf(const char* fmt, ...) __attribute__((format(printf, 1, 2)));
// Last n lines of the current log file (or of the in-memory ring when no file).
std::vector<std::string> log_tail(size_t n);
long long log_size();

}  // namespace mico
