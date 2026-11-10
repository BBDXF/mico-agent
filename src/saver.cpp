#include "saver.h"

#include <fcntl.h>
#include <signal.h>
#include <time.h>
#include <unistd.h>

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include <curl/curl.h>

namespace mico {

// ---------------------------------------------------------------- ring buffer

size_t RingBuffer::write(const char* p, size_t n) {
    n = std::min(n, free_space());
    size_t cap = buf_.size();
    size_t tail = (head_ + len_) % cap;
    size_t first = std::min(n, cap - tail);
    std::memcpy(&buf_[tail], p, first);
    if (n > first) std::memcpy(&buf_[0], p + first, n - first);
    len_ += n;
    return n;
}

size_t RingBuffer::read(char* p, size_t n) {
    n = std::min(n, len_);
    size_t cap = buf_.size();
    size_t first = std::min(n, cap - head_);
    std::memcpy(p, &buf_[head_], first);
    if (n > first) std::memcpy(p + first, &buf_[0], n - first);
    head_ = (head_ + n) % cap;
    len_ -= n;
    if (len_ == 0) head_ = 0;
    return n;
}

void RingBuffer::reserve(size_t cap) {
    if (cap <= buf_.size()) return;
    std::vector<char> nb(cap);
    size_t n = len_;
    read(nb.data(), n);
    buf_.swap(nb);
    head_ = 0;
    len_ = n;
}

// ---------------------------------------------------------------- helpers

static std::string lower(std::string s) {
    for (auto& c : s) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return s;
}

static std::string trim(const std::string& s) {
    size_t b = s.find_first_not_of(" \t\r\n");
    if (b == std::string::npos) return "";
    size_t e = s.find_last_not_of(" \t\r\n");
    return s.substr(b, e - b + 1);
}

std::string ext_for_content_type(const std::string& ctype) {
    std::string t = lower(trim(ctype.substr(0, ctype.find(';'))));
    if (t == "audio/mpeg" || t == "audio/mp3") return "mp3";
    if (t == "audio/flac" || t == "audio/x-flac") return "flac";
    if (t == "audio/ogg" || t == "application/ogg" || t == "audio/opus") return "ogg";
    return "m4a";  // audio/mp4, video/mp4, octet-stream, unknown
}

static size_t discard_cb(char*, size_t s, size_t n, void*) { return s * n; }

static void set_auth(CURL* c, const std::string& user, const std::string& pass) {
    if (user.empty() && pass.empty()) return;
    curl_easy_setopt(c, CURLOPT_HTTPAUTH, CURLAUTH_BASIC);
    curl_easy_setopt(c, CURLOPT_USERNAME, user.c_str());
    curl_easy_setopt(c, CURLOPT_PASSWORD, pass.c_str());
}

namespace {
struct HeadInfo {
    long long clen = -1;
};
size_t head_cb(char* p, size_t s, size_t n, void* ud) {
    std::string l = lower(trim(std::string(p, s * n)));
    if (l.compare(0, 15, "content-length:") == 0) static_cast<HeadInfo*>(ud)->clen = std::atoll(l.c_str() + 15);
    if (l.compare(0, 5, "http/") == 0) static_cast<HeadInfo*>(ud)->clen = -1;
    return s * n;
}
}  // namespace

// Simple synchronous WebDAV request. Returns HTTP status, 0 on transport error.
static long dav(const std::string& method, const std::string& url, const std::string& user, const std::string& pass,
                const std::vector<std::string>& headers, std::string& err, long long* clen = nullptr) {
    CURL* c = curl_easy_init();
    if (!c) {
        err = "curl init failed";
        return 0;
    }
    struct curl_slist* hl = nullptr;
    for (const auto& h : headers) hl = curl_slist_append(hl, h.c_str());
    HeadInfo hi;
    curl_easy_setopt(c, CURLOPT_URL, url.c_str());
    if (method == "HEAD") {
        curl_easy_setopt(c, CURLOPT_NOBODY, 1L);
    } else {
        curl_easy_setopt(c, CURLOPT_CUSTOMREQUEST, method.c_str());
    }
    curl_easy_setopt(c, CURLOPT_HTTPHEADER, hl);
    curl_easy_setopt(c, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(c, CURLOPT_CONNECTTIMEOUT_MS, 10000L);
    curl_easy_setopt(c, CURLOPT_TIMEOUT_MS, 30000L);
    curl_easy_setopt(c, CURLOPT_WRITEFUNCTION, discard_cb);
    curl_easy_setopt(c, CURLOPT_HEADERFUNCTION, head_cb);
    curl_easy_setopt(c, CURLOPT_HEADERDATA, &hi);
    set_auth(c, user, pass);
    long status = 0;
    CURLcode rc = curl_easy_perform(c);
    if (rc != CURLE_OK) {
        err = curl_easy_strerror(rc);
    } else {
        curl_easy_getinfo(c, CURLINFO_RESPONSE_CODE, &status);
    }
    if (clen) *clen = hi.clen;
    curl_slist_free_all(hl);
    curl_easy_cleanup(c);
    return status;
}

static long mono_ms() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000L + ts.tv_nsec / 1000000L;
}

static void write_status(const std::string& path, const std::string& status, long long bytes, long long total,
                         const std::string& reason, const std::string& name) {
    if (path.empty()) return;
    std::string tmp = path + ".tmp";
    FILE* f = std::fopen(tmp.c_str(), "w");
    if (!f) return;
    std::string r = reason;
    for (auto& ch : r) if (ch == '\t' || ch == '\n') ch = ' ';
    std::fprintf(f, "%s\t%lld\t%lld\t%s\t%s\n", status.c_str(), bytes, total, r.c_str(), name.c_str());
    std::fclose(f);
    std::rename(tmp.c_str(), path.c_str());
}

// ---------------------------------------------------------------- transfer

namespace {
struct Xfer {
    explicit Xfer(size_t cap) : ring(cap) {}
    RingBuffer ring;
    long long max = 0, down = 0, up = 0, total = -1;
    long dl_status = 0;
    std::string ctype;
    bool headers_done = false, dl_done = false, dl_failed = false, too_big = false;
    bool dl_paused = false, ul_paused = false;
    const SaveJob* job = nullptr;
    long last_status_ms = 0;
};

size_t dl_header(char* p, size_t s, size_t n, void* ud) {
    Xfer* x = static_cast<Xfer*>(ud);
    std::string line = trim(std::string(p, s * n));
    std::string l = lower(line);
    if (l.compare(0, 5, "http/") == 0) {
        size_t sp = l.find(' ');
        x->dl_status = sp == std::string::npos ? 0 : std::atol(l.c_str() + sp + 1);
        x->total = -1;
        x->ctype.clear();
    } else if (l.compare(0, 15, "content-length:") == 0) {
        x->total = std::atoll(l.c_str() + 15);
    } else if (l.compare(0, 13, "content-type:") == 0) {
        x->ctype = trim(line.substr(13));
    } else if (line.empty() && x->dl_status >= 200 && (x->dl_status < 300 || x->dl_status >= 400)) {
        x->headers_done = true;
    }
    return s * n;
}

size_t dl_write(char* p, size_t s, size_t n, void* ud) {
    Xfer* x = static_cast<Xfer*>(ud);
    size_t len = s * n;
    if (x->dl_status < 200 || x->dl_status >= 300) return len;  // error body: discard
    if (len > x->ring.capacity()) x->ring.reserve(len);
    if (x->ring.free_space() < len) {
        x->dl_paused = true;
        return CURL_WRITEFUNC_PAUSE;
    }
    if (x->down + static_cast<long long>(len) > x->max) {
        x->too_big = true;
        return 0;
    }
    x->down += static_cast<long long>(len);
    x->ring.write(p, len);
    return len;
}

size_t ul_read(char* p, size_t s, size_t n, void* ud) {
    Xfer* x = static_cast<Xfer*>(ud);
    size_t got = x->ring.read(p, s * n);
    if (got > 0) {
        x->up += static_cast<long long>(got);
        return got;
    }
    if (x->dl_done) return x->dl_failed ? CURL_READFUNC_ABORT : 0;
    x->ul_paused = true;
    return CURL_READFUNC_PAUSE;
}
}  // namespace

static SaveResult result(const char* status, const std::string& reason, const Xfer* x, const std::string& name) {
    SaveResult r;
    r.status = status;
    r.reason = reason;
    if (x) {
        r.bytes = x->up;
        r.total = x->total;
    }
    r.final_name = name;
    return r;
}

SaveResult save_run(const SaveJob& job) {
    std::string err;
    const std::string& U = job.user;
    const std::string& P = job.pass;
    // 1. Base collection (405 = already exists).
    long st = dav("MKCOL", job.dav_base, U, P, {}, err);
    if (st == 0) return result("failed", "WebDAV: " + err, nullptr, "");
    if (st == 401 || st == 403) return result("failed", "WebDAV 认证失败 HTTP " + std::to_string(st), nullptr, "");
    if (!((st >= 200 && st < 300) || st == 301 || st == 405))
        return result("failed", "WebDAV MKCOL HTTP " + std::to_string(st), nullptr, "");

    Xfer x(job.buffer_bytes < 65536 ? 65536 : job.buffer_bytes);
    x.max = job.max_bytes;
    x.job = &job;
    CURLM* m = curl_multi_init();
    CURL* dl = curl_easy_init();
    struct curl_slist* dlh = nullptr;
    for (const auto& kv : job.src_headers) dlh = curl_slist_append(dlh, (kv.first + ": " + kv.second).c_str());
    curl_easy_setopt(dl, CURLOPT_URL, job.src_url.c_str());
    curl_easy_setopt(dl, CURLOPT_HTTPHEADER, dlh);
    curl_easy_setopt(dl, CURLOPT_FOLLOWLOCATION, 1L);
    curl_easy_setopt(dl, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(dl, CURLOPT_CONNECTTIMEOUT_MS, 10000L);
    curl_easy_setopt(dl, CURLOPT_LOW_SPEED_LIMIT, 1L);
    curl_easy_setopt(dl, CURLOPT_LOW_SPEED_TIME, 120L);
    curl_easy_setopt(dl, CURLOPT_HEADERFUNCTION, dl_header);
    curl_easy_setopt(dl, CURLOPT_HEADERDATA, &x);
    curl_easy_setopt(dl, CURLOPT_WRITEFUNCTION, dl_write);
    curl_easy_setopt(dl, CURLOPT_WRITEDATA, &x);
    curl_multi_add_handle(m, dl);

    CURL* ul = nullptr;
    struct curl_slist* ulh = nullptr;
    CURLcode dl_rc = CURLE_OK, ul_rc = CURLE_OK;
    bool ul_done = false, dl_in_multi = true;
    std::string final_name, part_url;
    SaveResult out;
    bool have_out = false;

    auto finish = [&](const char* status, const std::string& reason) {
        out = result(status, reason, &x, final_name);
        have_out = true;
    };

    auto drive = [&]() {
        int running = 0;
        curl_multi_perform(m, &running);
        int q;
        while (CURLMsg* msg = curl_multi_info_read(m, &q)) {
            if (msg->msg != CURLMSG_DONE) continue;
            if (msg->easy_handle == dl) {
                x.dl_done = true;
                dl_rc = msg->data.result;
                x.dl_failed = dl_rc != CURLE_OK || x.too_big;
                curl_multi_remove_handle(m, dl);
                dl_in_multi = false;
            } else if (msg->easy_handle == ul) {
                ul_done = true;
                ul_rc = msg->data.result;
            }
        }
        if (x.dl_paused && dl_in_multi && x.ring.free_space() >= x.ring.capacity() / 2) {
            x.dl_paused = false;
            curl_easy_pause(dl, CURLPAUSE_CONT);
        }
        if (ul && !ul_done && x.ul_paused && (x.ring.size() > 0 || x.dl_done)) {
            x.ul_paused = false;
            curl_easy_pause(ul, CURLPAUSE_CONT);
        }
        int nfds;
        curl_multi_wait(m, nullptr, 0, 100, &nfds);
    };

    // 2. Upstream headers.
    while (!x.headers_done && !x.dl_done) drive();
    if (!x.headers_done || x.dl_status < 200 || x.dl_status >= 300) {
        std::string why = x.dl_status ? ("上游 HTTP " + std::to_string(x.dl_status)) : ("上游: " + std::string(curl_easy_strerror(dl_rc)));
        finish("failed", why);
    } else {
        if (x.dl_status != 200) x.total = -1;
        final_name = job.name;
        size_t pos = final_name.find("{ext}");
        if (pos != std::string::npos) final_name.replace(pos, 5, ext_for_content_type(x.ctype));
        if (x.total > x.max) {
            finish("skipped", "文件过大 " + std::to_string(x.total / (1024 * 1024)) + "MB");
        } else {
            // 3. Dedupe.
            long hs = dav("HEAD", job.dav_base + final_name, U, P, {}, err);
            if (hs >= 200 && hs < 300) {
                finish("skipped", "已存在");
            } else if (hs != 404) {
                finish("failed", hs ? "WebDAV HEAD HTTP " + std::to_string(hs) : "WebDAV: " + err);
            }
        }
    }

    if (!have_out) {
        // 4. Stream into PUT <final>.part.
        part_url = job.dav_base + final_name + ".part";
        ul = curl_easy_init();
        ulh = curl_slist_append(ulh, "Expect:");
        if (x.total < 0) ulh = curl_slist_append(ulh, "Transfer-Encoding: chunked");
        curl_easy_setopt(ul, CURLOPT_URL, part_url.c_str());
        curl_easy_setopt(ul, CURLOPT_UPLOAD, 1L);
        curl_easy_setopt(ul, CURLOPT_HTTPHEADER, ulh);
        curl_easy_setopt(ul, CURLOPT_READFUNCTION, ul_read);
        curl_easy_setopt(ul, CURLOPT_READDATA, &x);
        if (x.total >= 0) curl_easy_setopt(ul, CURLOPT_INFILESIZE_LARGE, static_cast<curl_off_t>(x.total));
        curl_easy_setopt(ul, CURLOPT_WRITEFUNCTION, discard_cb);
        curl_easy_setopt(ul, CURLOPT_NOSIGNAL, 1L);
        curl_easy_setopt(ul, CURLOPT_CONNECTTIMEOUT_MS, 10000L);
        set_auth(ul, U, P);
        curl_multi_add_handle(m, ul);
        long last = 0;
        while (!ul_done) {
            drive();
            if (ul_done && dl_in_multi) {
                curl_multi_remove_handle(m, dl);  // server stopped the upload early
                dl_in_multi = false;
            }
            long now = mono_ms();
            if (now - last >= 500) {
                last = now;
                write_status(job.status_path, "running", x.up, x.total, "", final_name);
            }
        }
        long ul_code = 0;
        curl_easy_getinfo(ul, CURLINFO_RESPONSE_CODE, &ul_code);
        if (x.too_big) {
            finish("failed", "超过大小上限");
        } else if (ul_code >= 300) {
            finish("failed", "WebDAV PUT HTTP " + std::to_string(ul_code));
        } else if (!x.dl_done || dl_rc != CURLE_OK) {
            finish("failed", x.dl_done ? ("上游: " + std::string(curl_easy_strerror(dl_rc))) : "上传提前结束 HTTP " + std::to_string(ul_code));
        } else if (ul_rc != CURLE_OK && !(ul_code >= 400)) {
            finish("failed", "上传: " + std::string(curl_easy_strerror(ul_rc)));
        } else if (ul_code < 200 || ul_code >= 300) {
            finish("failed", "WebDAV PUT HTTP " + std::to_string(ul_code));
        } else if (x.total >= 0 && x.up != x.total) {
            finish("failed", "大小不符");
        } else {
            // 5. Verify and move into place.
            long long rlen = -1;
            long hs = dav("HEAD", part_url, U, P, {}, err, &rlen);
            if (hs >= 200 && hs < 300 && rlen >= 0 && rlen != x.up) {
                finish("failed", "校验失败：服务器大小 " + std::to_string(rlen) + " ≠ " + std::to_string(x.up));
            } else {
                long ms = dav("MOVE", part_url, U, P,
                              {"Destination: " + job.dav_base + final_name, "Overwrite: F"}, err);
                if (ms >= 200 && ms < 300) {
                    finish("done", "");
                } else if (ms == 412) {
                    finish("skipped", "已存在");
                } else {
                    finish("failed", ms ? "WebDAV MOVE HTTP " + std::to_string(ms) : "WebDAV: " + err);
                }
            }
        }
        if (out.status != "done") {
            long ds = dav("DELETE", part_url, U, P, {}, err);
            out.reason += (ds >= 200 && ds < 300) || ds == 404 ? "；已清理 .part"
                          : "；清理 .part 失败 " + (ds ? "HTTP " + std::to_string(ds) : err);
        }
        curl_multi_remove_handle(m, ul);
    }
    if (dl_in_multi) curl_multi_remove_handle(m, dl);
    if (ul) curl_easy_cleanup(ul);
    curl_easy_cleanup(dl);
    curl_slist_free_all(dlh);
    curl_slist_free_all(ulh);
    curl_multi_cleanup(m);
    return out;
}

pid_t save_spawn(const SaveJob& job) {
    pid_t pid = fork();
    if (pid != 0) return pid;
    signal(SIGINT, SIG_DFL);
    signal(SIGTERM, SIG_DFL);
    long maxfd = sysconf(_SC_OPEN_MAX);
    if (maxfd < 0 || maxfd > 4096) maxfd = 4096;
    for (int fd = 3; fd < maxfd; ++fd) close(fd);  // sockets of the web server etc.
    write_status(job.status_path, "running", 0, -1, "", "");
    SaveResult r = save_run(job);
    write_status(job.status_path, r.status, r.bytes, r.total, r.reason, r.final_name);
    _exit(0);
}

DavTestResult dav_test(const std::string& base, const std::string& user, const std::string& pass) {
    DavTestResult r;
    std::string err;
    long st = dav("PROPFIND", base, user, pass, {"Depth: 0"}, err);
    if (st == 404) {
        st = dav("MKCOL", base, user, pass, {}, err);
        r.status = st;
        r.ok = st >= 200 && st < 300;
        if (!r.ok) r.error = st ? "目录不存在且创建失败 HTTP " + std::to_string(st) : err;
        return r;
    }
    r.status = st;
    r.ok = st == 207 || (st >= 200 && st < 300);
    if (!r.ok) r.error = st == 0 ? err : (st == 401 ? "认证失败" : "HTTP " + std::to_string(st));
    return r;
}

}  // namespace mico
