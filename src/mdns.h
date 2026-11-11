// Minimal built-in mDNS / DNS-SD responder (IPv4 only, RFC 6762/6763 subset).
// Answers A for <host>.local and advertises <instance>._http._tcp.local.
// Single nonblocking UDP socket, driven from the main loop via poll().
#pragma once

#include <stdint.h>

#include <string>
#include <vector>

namespace mico {

struct MdnsInfo {
    std::string host = "mico";      // label without ".local"
    std::string instance = "mico";  // DNS-SD service instance label (UTF-8)
    int port = 0;                   // HTTP port; 0 = only answer A
    std::string version;            // TXT version=
};

// True if name is a valid hostname label: [a-z0-9-], 1–63 chars.
bool mdns_valid_host(const std::string& name);

// Parses a (possibly compressed) DNS name at off; advances off past it.
// Labels are returned as-is (case preserved).
bool mdns_parse_name(const unsigned char* p, size_t n, size_t& off, std::vector<std::string>& labels);

// Builds a response to the query packet. ip is the IPv4 address (network order)
// to put in A records. legacy = querier's source port is not 5353 (echo ID and
// questions, no cache-flush bit). Sets *unicast when every answered question had
// the QU bit. Returns false when nothing matches (or packet is not a query).
bool mdns_answer(const unsigned char* q, size_t n, const MdnsInfo& info, uint32_t ip, bool legacy,
                 std::string& out, bool* unicast = nullptr);

// Unsolicited announcement (ttl 0 = goodbye).
std::string mdns_announce(const MdnsInfo& info, uint32_t ip, uint32_t ttl);

class MdnsResponder {
public:
    MdnsResponder() = default;
    ~MdnsResponder() { stop(); }
    MdnsResponder(const MdnsResponder&) = delete;
    MdnsResponder& operator=(const MdnsResponder&) = delete;

    // Binds 0.0.0.0:port (5353 unless $MICO_MDNS_PORT) and joins 224.0.0.251.
    bool start(const MdnsInfo& info, std::string& err);
    // Sends goodbye and closes the socket.
    void stop();
    // Changes the advertised info (goodbye for the old names, announce new ones).
    void update(const MdnsInfo& info);
    // Handles pending queries and timers; never blocks.
    void poll(double now_ms);

    bool running() const { return fd_ >= 0; }
    const MdnsInfo& info() const { return info_; }
    std::vector<std::string> ips() const;

private:
    void refresh_ifaces(bool join);
    void announce(uint32_t ttl);
    void send_to(const std::string& pkt, uint32_t ip, int port, uint32_t mcast_if);

    int fd_ = -1;
    int port_ = 5353;
    MdnsInfo info_;
    struct Iface {
        uint32_t addr, mask;  // network order
    };
    std::vector<Iface> ifaces_;
    std::vector<uint32_t> joined_;
    double next_check_ = 0, next_announce_ = 0;
    int announces_left_ = 0;
};

}  // namespace mico
