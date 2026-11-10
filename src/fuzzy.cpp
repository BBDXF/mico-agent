#include "fuzzy.h"

#include <algorithm>
#include <cctype>

namespace mico {

#include "pinyin_data.inc"

namespace {

// Decodes one UTF-8 code point; advances i. Invalid bytes yield U+FFFD.
unsigned next_cp(const std::string& s, size_t& i) {
    unsigned char c = static_cast<unsigned char>(s[i]);
    int len = c < 0x80 ? 1 : (c >> 5) == 6 ? 2 : (c >> 4) == 14 ? 3 : (c >> 3) == 30 ? 4 : 0;
    if (len == 0 || i + len > s.size()) {
        ++i;
        return 0xFFFD;
    }
    unsigned cp = len == 1 ? c : len == 2 ? (c & 0x1F) : len == 3 ? (c & 0x0F) : (c & 0x07);
    for (int k = 1; k < len; ++k) cp = (cp << 6) | (static_cast<unsigned char>(s[i + k]) & 0x3F);
    i += len;
    return cp;
}

void append_utf8(std::string& out, unsigned cp) {
    if (cp < 0x80) {
        out += static_cast<char>(cp);
    } else if (cp < 0x800) {
        out += static_cast<char>(0xC0 | (cp >> 6));
        out += static_cast<char>(0x80 | (cp & 0x3F));
    } else if (cp < 0x10000) {
        out += static_cast<char>(0xE0 | (cp >> 12));
        out += static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
        out += static_cast<char>(0x80 | (cp & 0x3F));
    } else {
        out += static_cast<char>(0xF0 | (cp >> 18));
        out += static_cast<char>(0x80 | ((cp >> 12) & 0x3F));
        out += static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
        out += static_cast<char>(0x80 | (cp & 0x3F));
    }
}

// Fuzzy pinyin: merges the confusions typical of accents and ASR.
std::string fuzzy_syllable(const std::string& s) {
    std::string r = s;
    if (r.compare(0, 2, "zh") == 0 || r.compare(0, 2, "ch") == 0 || r.compare(0, 2, "sh") == 0) r.erase(1, 1);
    if (!r.empty() && r[0] == 'n' && r != "n" && r != "ng") r[0] = 'l';
    size_t n = r.size();
    if (n >= 3 && r.compare(n - 2, 2, "ng") == 0 && (r[n - 3] == 'a' || r[n - 3] == 'e' || r[n - 3] == 'i')) {
        r.erase(n - 1);
    }
    return r;
}

bool is_cjk(unsigned cp) {
    return (cp >= 0x3400 && cp <= 0x4DBF) || (cp >= 0x4E00 && cp <= 0x9FFF) || (cp >= 0xF900 && cp <= 0xFAFF) ||
           (cp >= 0x20000 && cp <= 0x2FA1F) || (cp >= 0x3040 && cp <= 0x30FF) || (cp >= 0xAC00 && cp <= 0xD7AF);
}

bool is_word_char(unsigned cp) {
    return (cp < 0x80 && std::isalnum(static_cast<int>(cp))) || (cp >= 0xC0 && cp < 0x250 && cp != 0xD7 && cp != 0xF7);
}

bool is_open(unsigned cp) { return cp == '(' || cp == '[' || cp == 0xFF08 || cp == 0x3010 || cp == 0xFF3B; }
bool is_close(unsigned cp) { return cp == ')' || cp == ']' || cp == 0xFF09 || cp == 0x3011 || cp == 0xFF3D; }

int edit_distance(const std::string& a, const std::string& b) {
    std::vector<int> prev(b.size() + 1), cur(b.size() + 1);
    for (size_t j = 0; j <= b.size(); ++j) prev[j] = static_cast<int>(j);
    for (size_t i = 1; i <= a.size(); ++i) {
        cur[0] = static_cast<int>(i);
        for (size_t j = 1; j <= b.size(); ++j) {
            cur[j] = std::min({prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)});
        }
        std::swap(prev, cur);
    }
    return prev[b.size()];
}

double unit_weight(const Unit& q, const Unit& f) {
    if (q.text == f.text) return 1.0;
    bool qpy = q.py[0] != 0, fpy = f.py[0] != 0;
    if (qpy && fpy) {
        for (int a = 0; a < 2; ++a)
            for (int b = 0; b < 2; ++b)
                if (q.py[a] && q.py[a] == f.py[b]) return 0.9;
        for (int a = 0; a < 2; ++a)
            for (int b = 0; b < 2; ++b)
                if (!q.fz[a].empty() && q.fz[a] == f.fz[b]) return 0.75;
        return 0.0;
    }
    if (!qpy && !fpy && q.text.size() >= 4 && f.text.size() >= 4 && edit_distance(q.text, f.text) <= 1) return 0.8;
    return 0.0;
}

struct Match {
    double cov = 0;            // weighted LCS / field length, scaled by contiguity
    std::vector<char> mask;    // query units used by the match
};

// Max-weight common subsequence between query and field.
Match match_field(const std::vector<Unit>& q, const std::vector<Unit>& f) {
    Match m;
    m.mask.assign(q.size(), 0);
    if (q.empty() || f.empty()) return m;
    size_t n = q.size(), k = f.size();
    std::vector<double> dp((n + 1) * (k + 1), 0.0);
    std::vector<double> w(n * k);
    auto at = [&](size_t i, size_t j) -> double& { return dp[i * (k + 1) + j]; };
    for (size_t i = 1; i <= n; ++i) {
        for (size_t j = 1; j <= k; ++j) {
            double wij = w[(i - 1) * k + (j - 1)] = unit_weight(q[i - 1], f[j - 1]);
            double best = std::max(at(i - 1, j), at(i, j - 1));
            if (wij > 0) best = std::max(best, at(i - 1, j - 1) + wij);
            at(i, j) = best;
        }
    }
    double total = at(n, k);
    if (total <= 0) return m;
    size_t i = n, j = k, count = 0, lo = n, hi = 0;
    while (i > 0 && j > 0) {
        double wij = w[(i - 1) * k + (j - 1)];
        if (wij > 0 && at(i, j) == at(i - 1, j - 1) + wij) {
            m.mask[i - 1] = 1;
            ++count;
            lo = std::min(lo, i - 1);
            hi = std::max(hi, i - 1);
            --i;
            --j;
        } else if (at(i, j) == at(i - 1, j)) {
            --i;
        } else {
            --j;
        }
    }
    double contiguity = count ? static_cast<double>(count) / static_cast<double>(hi - lo + 1) : 0;
    // One shared character with a longer field is noise (陈奕迅 vs 爱情转移 via 奕/移).
    if (count < 2 && k >= 2) return Match{0, std::vector<char>(q.size(), 0)};
    m.cov = total / static_cast<double>(k) * contiguity;
    return m;
}

}  // namespace

std::vector<Unit> tokenize(const std::string& text, bool drop_brackets) {
    std::vector<Unit> out;
    std::string word;
    int depth = 0;
    auto flush = [&]() {
        if (!word.empty()) {
            Unit u;
            u.text = word;
            u.py[0] = u.py[1] = 0;
            out.push_back(u);
            word.clear();
        }
    };
    size_t i = 0;
    while (i < text.size()) {
        unsigned cp = next_cp(text, i);
        if (cp >= 0xFF01 && cp <= 0xFF5E && !is_open(cp) && !is_close(cp)) cp -= 0xFEE0;  // full-width ASCII
        if (drop_brackets && is_open(cp)) {
            flush();
            ++depth;
            continue;
        }
        if (drop_brackets && is_close(cp)) {
            flush();
            if (depth > 0) --depth;
            continue;
        }
        if (depth > 0) continue;
        if (is_word_char(cp)) {
            if (cp < 0x80) cp = static_cast<unsigned>(std::tolower(static_cast<int>(cp)));
            append_utf8(word, cp);
            continue;
        }
        flush();
        if (!is_cjk(cp)) continue;
        Unit u;
        append_utf8(u.text, cp);
        u.py[0] = u.py[1] = 0;
        if (cp >= kPinyinLo && cp <= kPinyinHi) {
            u.py[0] = kReading0[cp - kPinyinLo];
            u.py[1] = kReading1[cp - kPinyinLo];
            for (int r = 0; r < 2; ++r)
                if (u.py[r]) u.fz[r] = fuzzy_syllable(kSyllables[u.py[r]]);
        }
        out.push_back(u);
    }
    flush();
    // A title made only of bracketed text ("(Intro)") would otherwise vanish.
    if (out.empty() && drop_brackets) return tokenize(text, false);
    return out;
}

std::string to_pinyin(const std::string& text) {
    std::string out;
    for (const Unit& u : tokenize(text)) {
        if (!out.empty()) out += ' ';
        out += u.py[0] ? kSyllables[u.py[0]] : u.text;
    }
    return out;
}

void FuzzyIndex::add(const std::string& title, const std::string& artist, const std::string& album, json payload) {
    Item it;
    it.title = tokenize(title, true);
    it.album = tokenize(album, true);
    // Split artists on common separators.
    std::string cur;
    auto push = [&]() {
        std::vector<Unit> u = tokenize(cur);
        if (!u.empty()) it.artists.push_back(u);
        cur.clear();
    };
    size_t i = 0;
    while (i < artist.size()) {
        size_t start = i;
        unsigned cp = next_cp(artist, i);
        if (cp == '/' || cp == ',' || cp == '&' || cp == ';' || cp == 0x3001 || cp == 0xFF0C || cp == 0xFF0F) {
            push();
        } else {
            cur.append(artist, start, i - start);
        }
    }
    push();
    it.payload = std::move(payload);
    items_.push_back(std::move(it));
}

std::vector<FuzzyHit> FuzzyIndex::search(const std::string& query, size_t limit, double min_score) const {
    std::vector<FuzzyHit> hits;
    std::vector<Unit> q = tokenize(query);
    if (q.empty()) return hits;
    const double n = static_cast<double>(q.size());
    for (size_t idx = 0; idx < items_.size(); ++idx) {
        const Item& it = items_[idx];
        std::vector<char> used(q.size(), 0);
        auto merge = [&](const Match& m) {
            if (m.cov < 0.5) return;  // ignore incidental single-character overlaps
            for (size_t i = 0; i < used.size(); ++i) used[i] |= m.mask[i];
        };
        Match t = match_field(q, it.title);
        merge(t);
        Match best_artist;
        for (const auto& a : it.artists) {
            Match m = match_field(q, a);
            if (m.cov > best_artist.cov) best_artist = m;
        }
        merge(best_artist);
        Match al = match_field(q, it.album);
        merge(al);
        double qcov = static_cast<double>(std::count(used.begin(), used.end(), 1)) / n;

        FuzzyHit h;
        h.index = idx;
        h.title = std::min(1.0, t.cov);
        h.artist = std::min(1.0, best_artist.cov);
        h.album = std::min(1.0, al.cov);
        h.query = qcov;
        h.score = 0.5 * h.title + 0.25 * h.artist + 0.1 * h.album + 0.15 * qcov;
        if (h.score >= min_score) hits.push_back(h);
    }
    std::stable_sort(hits.begin(), hits.end(),
                     [](const FuzzyHit& a, const FuzzyHit& b) { return a.score > b.score; });
    if (hits.size() > limit) hits.resize(limit);
    return hits;
}

}  // namespace mico
