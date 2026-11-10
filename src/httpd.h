#pragma once

#include <sys/types.h>

#include <functional>
#include <map>
#include <string>
#include <utility>
#include <vector>

namespace mico {

struct WebRequest {
    std::string method;
    std::string path;   // raw (still percent-encoded), without query
    std::string query;  // raw query string, without '?'
    std::map<std::string, std::string> headers;  // lower-case names
    std::string body;
};

struct WebResponse {
    int status = 200;
    std::vector<std::pair<std::string, std::string>> headers;
    std::string body;
    // Stream proxy: when set, the server fetches proxy_url (with proxy_headers
    // and the client's Range header) in a forked child and relays it.
    bool proxy = false;
    std::string proxy_url;
    std::map<std::string, std::string> proxy_headers;
    size_t proxy_buffer = 1024 * 1024;  // read-ahead bound in bytes
};

// Tiny single-threaded HTTP/1.1 server (Connection: close). poll() is meant
// to be called from the main loop, so the handler (Lua) always runs on the
// main thread.
class HttpServer {
public:
    using Handler = std::function<WebResponse(const WebRequest&)>;

    HttpServer() = default;
    ~HttpServer();
    HttpServer(const HttpServer&) = delete;
    HttpServer& operator=(const HttpServer&) = delete;

    // addr: "host:port" or ":port" / "port". Port 0 picks a free port.
    bool listen(const std::string& addr, std::string& err);
    int port() const { return port_; }
    bool listening() const { return fd_ >= 0; }

    // Waits up to timeout_ms for network activity and serves complete requests.
    void poll(int timeout_ms, const Handler& handler);

    size_t max_body = 2 * 1024 * 1024;

private:
    struct Conn {
        int fd;
        std::string buf;
        long started_ms;
    };
    // Returns 1 when a full request is parsed, 0 when more data is needed,
    // or an HTTP error status (400/413/431).
    int parse(const std::string& buf, WebRequest& req);
    void respond(int fd, const WebResponse& resp);
    void start_proxy(int fd, const WebRequest& req, const WebResponse& resp);
    void reap();

    int fd_ = -1;
    int port_ = 0;
    std::vector<Conn> conns_;
    std::vector<pid_t> children_;
};

// Relays url to an already-connected client socket (blocking). Exposed for tests.
// Upstream data is forwarded as it arrives; up to buffer_bytes are read ahead
// while the client is slow, after which upstream reading blocks.
void proxy_stream(int client_fd, const std::string& url, const std::map<std::string, std::string>& headers,
                  size_t buffer_bytes = 1024 * 1024);

}  // namespace mico
