#include "httpd.h"

#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <signal.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include <cctype>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include <curl/curl.h>

namespace mico {

static long mono_ms() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000L + ts.tv_nsec / 1000000L;
}

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

static bool send_all(int fd, const char* p, size_t n) {
    while (n > 0) {
        ssize_t w = send(fd, p, n, MSG_NOSIGNAL);
        if (w < 0 && errno == EINTR) continue;
        if (w <= 0) return false;
        p += w;
        n -= static_cast<size_t>(w);
    }
    return true;
}

static const char* reason(int status) {
    switch (status) {
    case 200: return "OK";
    case 204: return "No Content";
    case 206: return "Partial Content";
    case 302: return "Found";
    case 400: return "Bad Request";
    case 401: return "Unauthorized";
    case 403: return "Forbidden";
    case 404: return "Not Found";
    case 405: return "Method Not Allowed";
    case 413: return "Payload Too Large";
    case 416: return "Range Not Satisfiable";
    case 431: return "Request Header Fields Too Large";
    case 500: return "Internal Server Error";
    case 502: return "Bad Gateway";
    case 503: return "Service Unavailable";
    default: return "OK";
    }
}

static void set_blocking(int fd, long send_timeout_s) {
    int fl = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, fl & ~O_NONBLOCK);
    struct timeval tv = {send_timeout_s, 0};
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
}

HttpServer::~HttpServer() {
    for (auto& c : conns_) close(c.fd);
    if (fd_ >= 0) close(fd_);
    for (pid_t p : children_) kill(p, SIGTERM);
    reap();
}

bool HttpServer::listen(const std::string& addr, std::string& err) {
    std::string host = "0.0.0.0", port = addr;
    size_t colon = addr.rfind(':');
    if (colon != std::string::npos) {
        host = addr.substr(0, colon);
        port = addr.substr(colon + 1);
        if (host.empty()) host = "0.0.0.0";
    }
    struct sockaddr_in sa;
    std::memset(&sa, 0, sizeof sa);
    sa.sin_family = AF_INET;
    sa.sin_port = htons(static_cast<uint16_t>(std::atoi(port.c_str())));
    if (inet_pton(AF_INET, host.c_str(), &sa.sin_addr) != 1) {
        err = "bad listen address " + addr;
        return false;
    }
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        err = std::strerror(errno);
        return false;
    }
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    fcntl(fd, F_SETFD, FD_CLOEXEC);
    if (bind(fd, reinterpret_cast<struct sockaddr*>(&sa), sizeof sa) != 0 || ::listen(fd, 16) != 0) {
        err = std::string("bind ") + addr + ": " + std::strerror(errno);
        close(fd);
        return false;
    }
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
    socklen_t len = sizeof sa;
    getsockname(fd, reinterpret_cast<struct sockaddr*>(&sa), &len);
    port_ = ntohs(sa.sin_port);
    fd_ = fd;
    return true;
}

int HttpServer::parse(const std::string& buf, WebRequest& req) {
    size_t end = buf.find("\r\n\r\n");
    if (end == std::string::npos) return buf.size() > 65536 ? 431 : 0;
    size_t line_end = buf.find("\r\n");
    std::string line = buf.substr(0, line_end);
    size_t s1 = line.find(' '), s2 = line.rfind(' ');
    if (s1 == std::string::npos || s2 == s1) return 400;
    req.method = line.substr(0, s1);
    std::string target = line.substr(s1 + 1, s2 - s1 - 1);
    size_t q = target.find('?');
    req.path = target.substr(0, q);
    req.query = q == std::string::npos ? "" : target.substr(q + 1);
    req.headers.clear();
    size_t pos = line_end + 2;
    while (pos < end) {
        size_t nl = buf.find("\r\n", pos);
        std::string h = buf.substr(pos, nl - pos);
        pos = nl + 2;
        size_t c = h.find(':');
        if (c == std::string::npos) continue;
        req.headers[lower(trim(h.substr(0, c)))] = trim(h.substr(c + 1));
    }
    size_t clen = 0;
    auto it = req.headers.find("content-length");
    if (it != req.headers.end()) clen = static_cast<size_t>(std::strtoul(it->second.c_str(), nullptr, 10));
    if (clen > max_body) return 413;
    if (buf.size() < end + 4 + clen) return 0;
    req.body = buf.substr(end + 4, clen);
    return 1;
}

void HttpServer::respond(int fd, const WebResponse& resp) {
    std::string h = "HTTP/1.1 " + std::to_string(resp.status) + " " + reason(resp.status) + "\r\n";
    bool has_type = false;
    for (const auto& kv : resp.headers) {
        if (lower(kv.first) == "content-type") has_type = true;
        if (lower(kv.first) == "content-length" || lower(kv.first) == "connection") continue;
        h += kv.first + ": " + kv.second + "\r\n";
    }
    if (!has_type) h += "Content-Type: text/plain; charset=utf-8\r\n";
    h += "Content-Length: " + std::to_string(resp.body.size()) + "\r\nConnection: close\r\n\r\n";
    set_blocking(fd, 10);
    if (send_all(fd, h.data(), h.size())) send_all(fd, resp.body.data(), resp.body.size());
    close(fd);
}

void HttpServer::start_proxy(int fd, const WebRequest& req, const WebResponse& resp) {
    std::map<std::string, std::string> headers = resp.proxy_headers;
    auto r = req.headers.find("range");
    if (r != req.headers.end()) headers["Range"] = r->second;
    pid_t pid = fork();
    if (pid < 0) {
        WebResponse e;
        e.status = 503;
        e.body = "fork failed";
        respond(fd, e);
        return;
    }
    if (pid == 0) {
        signal(SIGINT, SIG_DFL);
        signal(SIGTERM, SIG_DFL);
        if (fd_ >= 0) close(fd_);
        for (auto& c : conns_) if (c.fd != fd) close(c.fd);
        proxy_stream(fd, resp.proxy_url, headers, resp.proxy_buffer);
        _exit(0);
    }
    close(fd);
    children_.push_back(pid);
}

void HttpServer::reap() {
    for (size_t i = 0; i < children_.size();) {
        int st;
        pid_t w = waitpid(children_[i], &st, WNOHANG);
        if (w == children_[i] || (w < 0 && errno == ECHILD)) {
            children_.erase(children_.begin() + static_cast<long>(i));
        } else {
            ++i;
        }
    }
}

void HttpServer::poll(int timeout_ms, const Handler& handler) {
    reap();
    if (fd_ < 0) {
        usleep(static_cast<useconds_t>(timeout_ms) * 1000);
        return;
    }
    std::vector<struct pollfd> pfds;
    pfds.push_back({fd_, POLLIN, 0});
    for (auto& c : conns_) pfds.push_back({c.fd, POLLIN, 0});
    int n = ::poll(pfds.data(), pfds.size(), timeout_ms);
    if (n < 0) return;

    if (pfds[0].revents & POLLIN) {
        for (;;) {
            int c = accept(fd_, nullptr, nullptr);
            if (c < 0) break;
            fcntl(c, F_SETFL, fcntl(c, F_GETFL, 0) | O_NONBLOCK);
            fcntl(c, F_SETFD, FD_CLOEXEC);
            if (conns_.size() >= 32) {
                close(c);
                continue;
            }
            conns_.push_back({c, std::string(), mono_ms()});
        }
    }

    long now = mono_ms();
    std::vector<Conn> keep;
    for (size_t i = 0; i < conns_.size(); ++i) {
        Conn& c = conns_[i];
        bool closed = false;
        if (i + 1 < pfds.size() && (pfds[i + 1].revents & (POLLIN | POLLHUP | POLLERR))) {
            char buf[8192];
            for (;;) {
                ssize_t r = recv(c.fd, buf, sizeof buf, 0);
                if (r > 0) {
                    c.buf.append(buf, static_cast<size_t>(r));
                    if (c.buf.size() > max_body + 70000) break;
                    continue;
                }
                if (r == 0 || (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)) closed = true;
                break;
            }
        }
        WebRequest req;
        int st = c.buf.empty() ? 0 : parse(c.buf, req);
        if (st == 1) {
            WebResponse resp;
            try {
                resp = handler(req);
            } catch (const std::exception& e) {
                resp = WebResponse();
                resp.status = 500;
                resp.body = e.what();
            }
            if (resp.proxy) {
                start_proxy(c.fd, req, resp);
            } else {
                respond(c.fd, resp);
            }
        } else if (st > 1) {
            WebResponse e;
            e.status = st;
            e.body = reason(st);
            respond(c.fd, e);
        } else if (closed || now - c.started_ms > 15000) {
            close(c.fd);
        } else {
            keep.push_back(c);
        }
    }
    conns_.swap(keep);
}

// ---------------------------------------------------------------- proxy child

namespace {
struct ProxyState {
    int fd;
    long status = 0;
    std::vector<std::string> headers;
    bool sent = false;
    size_t limit = 1024 * 1024;
    std::string buf;  // pending bytes not yet accepted by the client
    size_t off = 0;
};

// Sends pending bytes. block=false: only what the socket takes right now.
bool flush(ProxyState* s, bool block) {
    while (s->off < s->buf.size()) {
        ssize_t w = send(s->fd, s->buf.data() + s->off, s->buf.size() - s->off,
                         MSG_NOSIGNAL | (block ? 0 : MSG_DONTWAIT));
        if (w < 0 && errno == EINTR) continue;
        if (w < 0 && !block && (errno == EAGAIN || errno == EWOULDBLOCK)) break;
        if (w <= 0) return false;
        s->off += static_cast<size_t>(w);
    }
    if (s->off == s->buf.size()) {
        s->buf.clear();
        s->off = 0;
    } else if (s->off > 65536) {
        s->buf.erase(0, s->off);
        s->off = 0;
    }
    return true;
}

const char* const kForward[] = {"content-type:", "content-length:", "content-range:", "accept-ranges:",
                                "last-modified:", "etag:"};

bool send_head(ProxyState* s) {
    s->sent = true;
    long status = s->status ? s->status : 502;
    std::string h = "HTTP/1.1 " + std::to_string(status) + " " + reason(static_cast<int>(status)) + "\r\n";
    for (const auto& l : s->headers) h += l + "\r\n";
    h += "Connection: close\r\n\r\n";
    return send_all(s->fd, h.data(), h.size());
}

size_t header_cb(char* p, size_t size, size_t n, void* ud) {
    ProxyState* s = static_cast<ProxyState*>(ud);
    std::string line = trim(std::string(p, size * n));
    if (line.compare(0, 5, "HTTP/") == 0) {  // new response (redirects reset)
        s->headers.clear();
        size_t sp = line.find(' ');
        s->status = sp == std::string::npos ? 0 : std::atol(line.c_str() + sp + 1);
    } else {
        std::string l = lower(line);
        for (const char* f : kForward) {
            if (l.compare(0, std::strlen(f), f) == 0) s->headers.push_back(line);
        }
    }
    return size * n;
}

size_t body_cb(char* p, size_t size, size_t n, void* ud) {
    ProxyState* s = static_cast<ProxyState*>(ud);
    if (!s->sent && !send_head(s)) return 0;
    s->buf.append(p, size * n);
    if (!flush(s, false)) return 0;
    // Bounded read-ahead: block on the client until we are under the limit.
    while (s->buf.size() - s->off > s->limit) {
        struct pollfd pf = {s->fd, POLLOUT, 0};
        if (::poll(&pf, 1, 300000) <= 0) return 0;
        if (!flush(s, false)) return 0;
    }
    return size * n;
}
}  // namespace

void proxy_stream(int client_fd, const std::string& url, const std::map<std::string, std::string>& headers,
                  size_t buffer_bytes) {
    set_blocking(client_fd, 300);
    ProxyState st;
    st.fd = client_fd;
    st.limit = buffer_bytes < 16384 ? 16384 : buffer_bytes;
    CURL* c = curl_easy_init();
    struct curl_slist* hl = nullptr;
    for (const auto& kv : headers) hl = curl_slist_append(hl, (kv.first + ": " + kv.second).c_str());
    CURLcode rc = CURLE_FAILED_INIT;
    if (c) {
        curl_easy_setopt(c, CURLOPT_URL, url.c_str());
        curl_easy_setopt(c, CURLOPT_HTTPHEADER, hl);
        curl_easy_setopt(c, CURLOPT_FOLLOWLOCATION, 1L);
        curl_easy_setopt(c, CURLOPT_NOSIGNAL, 1L);
        curl_easy_setopt(c, CURLOPT_CONNECTTIMEOUT_MS, 10000L);
        curl_easy_setopt(c, CURLOPT_LOW_SPEED_LIMIT, 1L);
        curl_easy_setopt(c, CURLOPT_LOW_SPEED_TIME, 60L);
        curl_easy_setopt(c, CURLOPT_HEADERFUNCTION, header_cb);
        curl_easy_setopt(c, CURLOPT_HEADERDATA, &st);
        curl_easy_setopt(c, CURLOPT_WRITEFUNCTION, body_cb);
        curl_easy_setopt(c, CURLOPT_WRITEDATA, &st);
        rc = curl_easy_perform(c);
    }
    if (!st.sent) {
        if (rc != CURLE_OK) {
            std::string msg = curl_easy_strerror(rc);
            std::string h = "HTTP/1.1 502 Bad Gateway\r\nContent-Type: text/plain\r\nContent-Length: " +
                            std::to_string(msg.size()) + "\r\nConnection: close\r\n\r\n" + msg;
            send_all(client_fd, h.data(), h.size());
        } else {
            send_head(&st);
        }
    }
    flush(&st, true);
    curl_slist_free_all(hl);
    if (c) curl_easy_cleanup(c);
    shutdown(client_fd, SHUT_WR);
    close(client_fd);
}

}  // namespace mico
