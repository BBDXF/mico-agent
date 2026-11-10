#include <poll.h>
#include "logger.h"

#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#include <cerrno>
#include <cstdarg>
#include <cstdio>
#include <ctime>
#include <deque>

namespace mico {

namespace {
LogConfig g_cfg;
int g_fd = -1;
long long g_size = 0;
std::deque<std::string> g_ring;  // fallback when no file
const size_t kRing = 1000;

void write_all(int fd, const char* p, size_t n) {
    while (n > 0) {
        ssize_t w = write(fd, p, n);
        if (w < 0 && errno == EINTR) continue;
        if (w <= 0) return;
        p += w;
        n -= static_cast<size_t>(w);
    }
}

// Echo to stderr without ever blocking the agent: if stderr is a pipe that
// nobody reads (e.g. started from a script), lines are dropped instead.
void echo_stderr(const char* p, size_t n) {
    struct pollfd pf = {2, POLLOUT, 0};
    while (n > 0) {
        if (poll(&pf, 1, 0) <= 0 || !(pf.revents & POLLOUT)) return;
        ssize_t w = write(2, p, n < 4096 ? n : 4096);
        if (w < 0 && errno == EINTR) continue;
        if (w <= 0) return;
        p += w;
        n -= static_cast<size_t>(w);
    }
}

void open_file() {
    if (g_fd >= 0) close(g_fd);
    g_fd = -1;
    g_size = 0;
    if (g_cfg.file.empty()) return;
    g_fd = open(g_cfg.file.c_str(), O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
    if (g_fd < 0) return;
    struct stat st;
    if (fstat(g_fd, &st) == 0) g_size = st.st_size;
}

void rotate() {
    const std::string& f = g_cfg.file;
    if (g_cfg.keep <= 0) {
        unlink(f.c_str());
    } else {
        unlink((f + "." + std::to_string(g_cfg.keep)).c_str());
        for (int i = g_cfg.keep - 1; i >= 1; --i)
            rename((f + "." + std::to_string(i)).c_str(), (f + "." + std::to_string(i + 1)).c_str());
        rename(f.c_str(), (f + ".1").c_str());
    }
    open_file();
}
}  // namespace

void log_configure(const LogConfig& c) {
    bool reopen = c.file != g_cfg.file || g_fd < 0;
    g_cfg = c;
    if (g_cfg.max_bytes < 4096) g_cfg.max_bytes = 4096;
    if (g_cfg.keep < 0) g_cfg.keep = 0;
    if (g_cfg.keep > 5) g_cfg.keep = 5;
    if (reopen) open_file();
    if (g_fd >= 0 && g_size > g_cfg.max_bytes) rotate();
}

const LogConfig& log_config() { return g_cfg; }

void log_line(const std::string& msg) {
    std::time_t t = std::time(nullptr);
    char ts[32];
    std::strftime(ts, sizeof ts, "[%H:%M:%S] ", std::localtime(&t));
    std::string line = ts + msg;
    if (line.empty() || line.back() != '\n') line += '\n';
    if (g_cfg.echo_stderr || g_fd < 0) echo_stderr(line.data(), line.size());
    if (g_fd >= 0) {
        if (g_size + static_cast<long long>(line.size()) > g_cfg.max_bytes) rotate();
        if (g_fd >= 0) {
            write_all(g_fd, line.data(), line.size());
            g_size += static_cast<long long>(line.size());
        }
    } else {
        g_ring.push_back(line.substr(0, line.size() - 1));
        while (g_ring.size() > kRing) g_ring.pop_front();
    }
}

void logf(const char* fmt, ...) {
    char buf[4096];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    log_line(buf);
}

long long log_size() { return g_fd >= 0 ? g_size : 0; }

std::vector<std::string> log_tail(size_t n) {
    std::vector<std::string> out;
    if (g_fd < 0 || g_cfg.file.empty()) {
        size_t start = g_ring.size() > n ? g_ring.size() - n : 0;
        for (size_t i = start; i < g_ring.size(); ++i) out.push_back(g_ring[i]);
        return out;
    }
    int fd = open(g_cfg.file.c_str(), O_RDONLY | O_CLOEXEC);
    if (fd < 0) return out;
    off_t end = lseek(fd, 0, SEEK_END);
    std::string data;
    size_t newlines = 0;
    off_t pos = end;
    const off_t chunk = 8192;
    while (pos > 0 && newlines <= n) {
        off_t len = pos < chunk ? pos : chunk;
        pos -= len;
        std::string buf(static_cast<size_t>(len), '\0');
        if (pread(fd, &buf[0], static_cast<size_t>(len), pos) != len) break;
        for (char c : buf) if (c == '\n') ++newlines;
        data = buf + data;
    }
    close(fd);
    size_t i = 0;
    std::vector<std::string> all;
    while (i < data.size()) {
        size_t nl = data.find('\n', i);
        if (nl == std::string::npos) nl = data.size();
        all.push_back(data.substr(i, nl - i));
        i = nl + 1;
    }
    if (pos > 0 && !all.empty()) all.erase(all.begin());  // partial first line
    size_t start = all.size() > n ? all.size() - n : 0;
    out.assign(all.begin() + static_cast<long>(start), all.end());
    return out;
}

}  // namespace mico
