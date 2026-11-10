#include "instruction.h"

#include "json.hpp"

namespace mico {

using json = nlohmann::json;

static std::string trim(const std::string& s) {
    const char* ws = " \t\r\n";
    size_t b = s.find_first_not_of(ws);
    if (b == std::string::npos) return "";
    size_t e = s.find_last_not_of(ws);
    return s.substr(b, e - b + 1);
}

static bool parse_recognition_impl(const std::string& line, Recognition& out) {
    size_t i = line.find('{');
    if (i == std::string::npos) return false;
    json j = json::parse(line.begin() + static_cast<long>(i), line.end(), nullptr, false);
    if (j.is_discarded() || !j.is_object()) return false;
    const json& h = j.value("header", json::object());
    if (!h.is_object() || h.value("namespace", "") != "SpeechRecognizer" ||
        h.value("name", "") != "RecognizeResult") {
        return false;
    }
    const json& p = j.value("payload", json::object());
    if (!p.is_object()) return false;
    const json& results = p.value("results", json::array());
    if (!results.is_array() || results.empty() || !results[0].is_object()) return false;
    std::string text = trim(results[0].value("text", ""));
    if (text.empty()) return false;
    out.dialog_id = h.value("dialog_id", "");
    out.text = text;
    out.final = p.value("is_final", false);
    return true;
}

bool parse_recognition(const std::string& line, Recognition& out) {
    try {
        return parse_recognition_impl(line, out);
    } catch (const std::exception&) {
        return false;  // unexpected field types
    }
}

}  // namespace mico
