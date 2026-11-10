#pragma once

// "边播边存": stream an online track straight from its upstream URL into a
// WebDAV PUT (no temp file). Runs in a forked child; progress goes to a tiny
// status file that the Lua side polls.

#include <sys/types.h>

#include <map>
#include <string>
#include <vector>

namespace mico {

// Fixed-capacity byte ring buffer (single-threaded).
class RingBuffer {
public:
    explicit RingBuffer(size_t cap) : buf_(cap ? cap : 1) {}
    size_t size() const { return len_; }
    size_t capacity() const { return buf_.size(); }
    size_t free_space() const { return buf_.size() - len_; }
    // Copies as much as fits; returns bytes written.
    size_t write(const char* p, size_t n);
    // Copies up to n bytes out; returns bytes read.
    size_t read(char* p, size_t n);
    // Grows capacity (keeps content).
    void reserve(size_t cap);

private:
    std::vector<char> buf_;
    size_t head_ = 0;  // read position
    size_t len_ = 0;
};

struct SaveJob {
    std::string src_url;
    std::map<std::string, std::string> src_headers;
    std::string dav_base;  // percent-encoded directory URL, ends with '/'
    std::string name;      // percent-encoded file name; "{ext}" is replaced by the content-type extension
    std::string user, pass;
    long long max_bytes = 200LL * 1024 * 1024;
    size_t buffer_bytes = 1024 * 1024;
    std::string status_path;  // optional progress file
};

struct SaveResult {
    std::string status;  // done | skipped | failed
    std::string reason;
    long long bytes = 0;
    long long total = -1;
    std::string final_name;  // encoded
};

// Blocking: MKCOL base, fetch upstream headers, HEAD final (dedupe), PUT
// <final>.part streamed through a bounded ring buffer, verify, MOVE.
SaveResult save_run(const SaveJob& job);

// Forks a child running save_run; the result is written to job.status_path as
// "status\tbytes\ttotal\treason\tname". Returns pid or -1.
pid_t save_spawn(const SaveJob& job);

std::string ext_for_content_type(const std::string& ctype);

struct DavTestResult {
    bool ok = false;
    long status = 0;
    std::string error;
};
// PROPFIND Depth 0 on base; MKCOL when missing.
DavTestResult dav_test(const std::string& base, const std::string& user, const std::string& pass);

}  // namespace mico
