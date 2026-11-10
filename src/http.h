#pragma once

#include <map>
#include <string>

namespace mico {

struct HttpRequest {
    std::string method = "GET";
    std::string url;
    std::map<std::string, std::string> headers;
    std::string body;
    long timeout_ms = 30000;
};

struct HttpResponse {
    long status = 0;      // 0 = transport error
    std::string body;
    std::string error;    // non-empty on transport error
};

// Global libcurl init/cleanup; call once at program start/end.
void http_global_init();
void http_global_cleanup();

HttpResponse http_do(const HttpRequest& req);

}  // namespace mico
