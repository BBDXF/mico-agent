#include "llm.h"

#include "http.h"

namespace mico {

LlmResult llm_chat(const LlmConfig& cfg, const json& messages, const json& tools) {
    LlmResult r;
    json body = {{"model", cfg.model}, {"messages", messages}};
    if (tools.is_array() && !tools.empty()) body["tools"] = tools;
    if (cfg.extra.is_object()) {
        for (auto it = cfg.extra.begin(); it != cfg.extra.end(); ++it) body[it.key()] = it.value();
    }

    HttpRequest req;
    req.method = "POST";
    std::string base = cfg.base_url;
    while (!base.empty() && base.back() == '/') base.pop_back();
    req.url = base + "/chat/completions";
    req.headers["Content-Type"] = "application/json";
    if (!cfg.api_key.empty()) req.headers["Authorization"] = "Bearer " + cfg.api_key;
    req.body = body.dump(-1, ' ', false, json::error_handler_t::replace);
    req.timeout_ms = cfg.timeout_ms;

    HttpResponse resp = http_do(req);
    if (!resp.error.empty()) {
        r.error = "http: " + resp.error;
        return r;
    }
    if (resp.status != 200) {
        r.error = "http " + std::to_string(resp.status) + ": " + resp.body.substr(0, 500);
        return r;
    }
    json j = json::parse(resp.body, nullptr, false);
    if (j.is_discarded() || !j.contains("choices") || !j["choices"].is_array() ||
        j["choices"].empty() || !j["choices"][0].contains("message")) {
        r.error = "bad response: " + resp.body.substr(0, 500);
        return r;
    }
    r.message = j["choices"][0]["message"];
    if (!r.message.contains("role")) r.message["role"] = "assistant";
    r.ok = true;
    return r;
}

}  // namespace mico
