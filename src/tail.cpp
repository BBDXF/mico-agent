#include "tail.h"

#include <sys/stat.h>

namespace mico {

static const size_t kMaxLine = 1 << 20;

Tailer::~Tailer() { close_file(); }

void Tailer::close_file() {
    if (f_) fclose(f_);
    f_ = nullptr;
    pos_ = 0;
    pending_.clear();
}

void Tailer::poll(const std::function<void(const std::string&)>& emit) {
    struct stat st;
    bool exists = stat(path_.c_str(), &st) == 0;

    auto drain = [&]() {
        char buf[16384];
        fseek(f_, pos_, SEEK_SET);
        size_t n;
        while ((n = fread(buf, 1, sizeof buf, f_)) > 0) {
            pos_ += static_cast<long>(n);
            pending_.append(buf, n);
            size_t nl;
            while ((nl = pending_.find('\n')) != std::string::npos) {
                std::string line = pending_.substr(0, nl);
                pending_.erase(0, nl + 1);
                if (!line.empty() && line.back() == '\r') line.pop_back();
                if (!line.empty()) emit(line);
            }
            if (pending_.size() > kMaxLine) pending_.clear();
        }
        clearerr(f_);
    };

    if (f_ && (!exists || st.st_ino != ino_ || st.st_dev != dev_)) {
        drain();  // finish the old file before switching
        close_file();
    }
    if (!f_ && exists) {
        f_ = fopen(path_.c_str(), "rb");
        if (!f_) return;
        ino_ = st.st_ino;
        dev_ = st.st_dev;
        pos_ = (first_ && !from_start_) ? static_cast<long>(st.st_size) : 0;
    }
    first_ = false;
    if (!f_) return;
    if (static_cast<long>(st.st_size) < pos_) {  // truncated in place
        pos_ = 0;
        pending_.clear();
    }
    drain();
}

}  // namespace mico
