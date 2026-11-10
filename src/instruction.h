#pragma once

#include <string>

namespace mico {

// Recognized user speech from a SpeechRecognizer.RecognizeResult directive in
// /tmp/mico_aivs_lab/instruction.log.
struct Recognition {
    std::string dialog_id;
    std::string text;
    bool final = false;
};

// Parses one log line. Lines may carry a non-JSON prefix before the first '{'.
bool parse_recognition(const std::string& line, Recognition& out);

}  // namespace mico
