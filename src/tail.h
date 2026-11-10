#pragma once

#include <sys/types.h>

#include <cstdio>
#include <functional>
#include <string>

namespace mico {

// Follows a growing text file by polling. Survives the file not existing yet,
// being truncated in place, and being replaced (new inode).
class Tailer {
public:
    explicit Tailer(std::string path, bool from_start = false)
        : path_(std::move(path)), from_start_(from_start) {}
    ~Tailer();

    // Reads whatever is new and calls emit for each complete line.
    // Call periodically; never blocks.
    void poll(const std::function<void(const std::string&)>& emit);

private:
    void close_file();

    std::string path_;
    bool from_start_;
    bool first_ = true;
    FILE* f_ = nullptr;
    ino_t ino_ = 0;
    dev_t dev_ = 0;
    long pos_ = 0;
    std::string pending_;
};

}  // namespace mico
