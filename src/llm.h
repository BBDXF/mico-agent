#pragma once

#include <string>

#include "json.hpp"

namespace mico {

using json = nlohmann::json;

struct LlmConfig {
    std::string base_url;  // e.g. https://api.siliconflow.cn/v1
    std::string api_key;
    std::string model;
    long timeout_ms = 60000;
    json extra = json::object();  // merged into the request body (e.g. enable_thinking)
};

struct LlmResult {
    bool ok = false;
    std::string error;
    json message;  // assistant message: {role, content, tool_calls?}
};

// One OpenAI-compatible /chat/completions call (non-streaming).
LlmResult llm_chat(const LlmConfig& cfg, const json& messages, const json& tools);

}  // namespace mico
