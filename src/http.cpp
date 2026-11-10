#include "http.h"

#include <curl/curl.h>

namespace mico {

void http_global_init() { curl_global_init(CURL_GLOBAL_DEFAULT); }
void http_global_cleanup() { curl_global_cleanup(); }

static size_t write_cb(char* ptr, size_t size, size_t nmemb, void* userdata) {
    static_cast<std::string*>(userdata)->append(ptr, size * nmemb);
    return size * nmemb;
}

HttpResponse http_do(const HttpRequest& req) {
    HttpResponse resp;
    CURL* c = curl_easy_init();
    if (!c) {
        resp.error = "curl_easy_init failed";
        return resp;
    }
    struct curl_slist* hdrs = nullptr;
    for (const auto& kv : req.headers) {
        hdrs = curl_slist_append(hdrs, (kv.first + ": " + kv.second).c_str());
    }
    curl_easy_setopt(c, CURLOPT_URL, req.url.c_str());
    curl_easy_setopt(c, CURLOPT_CUSTOMREQUEST, req.method.c_str());
    curl_easy_setopt(c, CURLOPT_HTTPHEADER, hdrs);
    curl_easy_setopt(c, CURLOPT_TIMEOUT_MS, req.timeout_ms);
    curl_easy_setopt(c, CURLOPT_CONNECTTIMEOUT_MS, 10000L);
    curl_easy_setopt(c, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(c, CURLOPT_FOLLOWLOCATION, 1L);
    curl_easy_setopt(c, CURLOPT_WRITEFUNCTION, write_cb);
    curl_easy_setopt(c, CURLOPT_WRITEDATA, &resp.body);
    if (!req.body.empty() || req.method == "POST" || req.method == "PUT") {
        curl_easy_setopt(c, CURLOPT_POSTFIELDS, req.body.c_str());
        curl_easy_setopt(c, CURLOPT_POSTFIELDSIZE, static_cast<long>(req.body.size()));
    }
    CURLcode rc = curl_easy_perform(c);
    if (rc != CURLE_OK) {
        resp.error = curl_easy_strerror(rc);
    } else {
        curl_easy_getinfo(c, CURLINFO_RESPONSE_CODE, &resp.status);
    }
    curl_slist_free_all(hdrs);
    curl_easy_cleanup(c);
    return resp;
}

}  // namespace mico
