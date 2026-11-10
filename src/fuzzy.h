#pragma once

#include <map>
#include <string>
#include <vector>

#include "json.hpp"

namespace mico {

using json = nlohmann::json;

// One comparable unit: a CJK character (with pinyin readings) or an
// ASCII/latin word.
struct Unit {
    std::string text;       // the character or lowercased word
    unsigned short py[2];   // syllable ids (0 = none)
    std::string fz[2];      // fuzzy-normalized pinyin (zh->z, ang->an, n->l ...)
};

// Splits text into units. Punctuation and spaces are dropped. With
// drop_brackets, content inside ()（）[]【】 is ignored (e.g. "晴天 (Live)").
std::vector<Unit> tokenize(const std::string& text, bool drop_brackets = false);

// Toneless pinyin of text, syllables separated by spaces (non-CJK kept).
std::string to_pinyin(const std::string& text);

struct FuzzyHit {
    size_t index;
    double score;      // 0..1
    double title;      // title coverage
    double artist;     // best artist coverage
    double album;
    double query;      // fraction of the query explained by matched fields
};

// In-memory song index tolerant to ASR errors: homophones (周杰轮 -> 周杰伦),
// fuzzy pinyin (z/zh, n/l, an/ang), partial titles and "artist + title" queries.
class FuzzyIndex {
public:
    void clear() { items_.clear(); }
    size_t size() const { return items_.size(); }
    // Artists may be joined with / , & 、 ; and are matched separately.
    void add(const std::string& title, const std::string& artist, const std::string& album, json payload);
    std::vector<FuzzyHit> search(const std::string& query, size_t limit, double min_score = 0.3) const;
    const json& payload(size_t i) const { return items_[i].payload; }

private:
    struct Item {
        std::vector<Unit> title;
        std::vector<std::vector<Unit>> artists;
        std::vector<Unit> album;
        json payload;
    };
    std::vector<Item> items_;
};

}  // namespace mico
