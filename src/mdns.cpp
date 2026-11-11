#include "mdns.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <cstdlib>
#include <cstring>

#include "logger.h"

namespace mico {

namespace {

const uint16_t T_A = 1, T_PTR = 12, T_TXT = 16, T_SRV = 33, T_ANY = 255;
const uint32_t TTL = 120;
const char* MCAST = "224.0.0.251";

typedef std::vector<std::string> Name;

bool ieq(const std::string& a, const std::string& b) {
    if (a.size() != b.size()) return false;
    for (size_t i = 0; i < a.size(); ++i) {
        unsigned char x = a[i], y = b[i];
        if (x >= 'A' && x <= 'Z') x += 32;
        if (y >= 'A' && y <= 'Z') y += 32;
        if (x != y) return false;
    }
    return true;
}

bool name_eq(const Name& a, const Name& b) {
    if (a.size() != b.size()) return false;
    for (size_t i = 0; i < a.size(); ++i)
        if (!ieq(a[i], b[i])) return false;
    return true;
}

void put16(std::string& o, uint16_t v) {
    o += static_cast<char>(v >> 8);
    o += static_cast<char>(v & 0xff);
}
void put32(std::string& o, uint32_t v) {
    put16(o, static_cast<uint16_t>(v >> 16));
    put16(o, static_cast<uint16_t>(v & 0xffff));
}
void put_name(std::string& o, const Name& n) {
    for (const auto& l : n) {
        o += static_cast<char>(l.size());
        o += l;
    }
    o += '\0';
}

struct Names {
    Name host, svc, inst, sd;
};

std::string trunc_label(const std::string& s) {
    if (s.size() <= 63) return s;
    size_t n = 63;
    while (n > 0 && (static_cast<unsigned char>(s[n]) & 0xc0) == 0x80) --n;  // keep UTF-8 whole
    return s.substr(0, n);
}

Names make_names(const MdnsInfo& info) {
    Names n;
    n.host = {info.host, "local"};
    n.svc = {"_http", "_tcp", "local"};
    n.inst = {trunc_label(info.instance.empty() ? info.host : info.instance), "_http", "_tcp", "local"};
    n.sd = {"_services", "_dns-sd", "_udp", "local"};
    return n;
}

// Record builder; skips duplicates (type + name).
struct Builder {
    const MdnsInfo& info;
    const Names& names;
    uint32_t ip, ttl;
    bool flush;
    std::vector<std::pair<uint16_t, const Name*>> seen;
    std::string body;
    int count = 0;

    bool has(uint16_t t, const Name* n) const {
        for (const auto& s : seen)
            if (s.first == t && s.second == n) return true;
        return false;
    }
    void rr(uint16_t type, const Name& name, bool unique, const std::string& rdata) {
        put_name(body, name);
        put16(body, type);
        put16(body, static_cast<uint16_t>(1 | (unique && flush ? 0x8000 : 0)));
        put32(body, ttl);
        put16(body, static_cast<uint16_t>(rdata.size()));
        body += rdata;
        ++count;
    }
    void add(uint16_t type, const Name* n) {
        if (has(type, n)) return;
        seen.push_back(std::make_pair(type, n));
        std::string rd;
        if (type == T_A) {
            rd.assign(reinterpret_cast<const char*>(&ip), 4);
            rr(T_A, *n, true, rd);
        } else if (type == T_PTR) {
            put_name(rd, n == &names.svc ? names.inst : names.svc);
            rr(T_PTR, *n, false, rd);
        } else if (type == T_SRV) {
            put16(rd, 0);
            put16(rd, 0);
            put16(rd, static_cast<uint16_t>(info.port));
            put_name(rd, names.host);
            rr(T_SRV, *n, true, rd);
        } else if (type == T_TXT) {
            std::string kv[2] = {"path=/", "version=" + info.version};
            for (const auto& s : kv) {
                std::string t = s.substr(0, 255);
                rd += static_cast<char>(t.size());
                rd += t;
            }
            rr(T_TXT, *n, true, rd);
        }
    }
};

std::string header(uint16_t id, int qd, int an, int ar) {
    std::string h;
    put16(h, id);
    put16(h, 0x8400);  // QR + AA
    put16(h, static_cast<uint16_t>(qd));
    put16(h, static_cast<uint16_t>(an));
    put16(h, 0);
    put16(h, static_cast<uint16_t>(ar));
    return h;
}

}  // namespace

bool mdns_valid_host(const std::string& s) {
    if (s.empty() || s.size() > 63) return false;
    for (char c : s)
        if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-')) return false;
    return true;
}

bool mdns_parse_name(const unsigned char* p, size_t n, size_t& off, std::vector<std::string>& labels) {
    labels.clear();
    size_t pos = off, total = 0;
    bool jumped = false;
    for (int hops = 0; hops < 64; ++hops) {
        if (pos >= n) return false;
        unsigned len = p[pos];
        if ((len & 0xc0) == 0xc0) {
            if (pos + 1 >= n) return false;
            size_t ptr = ((len & 0x3f) << 8) | p[pos + 1];
            if (!jumped) off = pos + 2;
            jumped = true;
            if (ptr >= pos) return false;  // only backward pointers (no loops)
            pos = ptr;
            continue;
        }
        if (len & 0xc0) return false;
        if (len == 0) {
            if (!jumped) off = pos + 1;
            return true;
        }
        if (pos + 1 + len > n || (total += len + 1) > 255) return false;
        labels.push_back(std::string(reinterpret_cast<const char*>(p + pos + 1), len));
        pos += 1 + len;
    }
    return false;
}

bool mdns_answer(const unsigned char* q, size_t n, const MdnsInfo& info, uint32_t ip, bool legacy,
                 std::string& out, bool* unicast) {
    if (n < 12) return false;
    uint16_t id = (q[0] << 8) | q[1], flags = (q[2] << 8) | q[3];
    if ((flags & 0x8000) || (flags & 0x7800)) return false;  // response or non-zero opcode
    int qd = (q[4] << 8) | q[5];
    Names names = make_names(info);
    Builder an{info, names, ip, TTL, !legacy, {}, {}, 0};
    std::vector<std::pair<uint16_t, const Name*>> extra;
    std::string questions;
    int nq = 0;
    bool all_qu = true;
    size_t off = 12;
    for (int i = 0; i < qd; ++i) {
        Name qn;
        if (!mdns_parse_name(q, n, off, qn) || off + 4 > n) break;
        uint16_t qt = (q[off] << 8) | q[off + 1], qc = (q[off + 2] << 8) | q[off + 3];
        off += 4;
        if ((qc & 0x7fff) != 1 && (qc & 0x7fff) != 255) continue;
        int before = an.count;
        bool any = qt == T_ANY;
        if (name_eq(qn, names.host) && (qt == T_A || any)) {
            an.add(T_A, &names.host);
        } else if (info.port > 0 && name_eq(qn, names.svc) && (qt == T_PTR || any)) {
            an.add(T_PTR, &names.svc);
            extra.push_back(std::make_pair(T_SRV, &names.inst));
            extra.push_back(std::make_pair(T_TXT, &names.inst));
            extra.push_back(std::make_pair(T_A, &names.host));
        } else if (info.port > 0 && name_eq(qn, names.inst)) {
            if (qt == T_SRV || any) an.add(T_SRV, &names.inst);
            if (qt == T_TXT || any) an.add(T_TXT, &names.inst);
            extra.push_back(std::make_pair(T_A, &names.host));
        } else if (info.port > 0 && name_eq(qn, names.sd) && (qt == T_PTR || any)) {
            an.add(T_PTR, &names.sd);
        }
        if (an.count == before) continue;
        if (!(qc & 0x8000)) all_qu = false;
        if (legacy) {
            put_name(questions, qn);
            put16(questions, qt);
            put16(questions, 1);
            ++nq;
        }
    }
    if (!an.count) return false;
    int answers = an.count;
    for (const auto& e : extra) an.add(e.first, e.second);
    out = header(legacy ? id : 0, nq, answers, an.count - answers) + questions + an.body;
    if (unicast) *unicast = all_qu;
    return true;
}

std::string mdns_announce(const MdnsInfo& info, uint32_t ip, uint32_t ttl) {
    Names names = make_names(info);
    Builder b{info, names, ip, ttl, true, {}, {}, 0};
    b.add(T_A, &names.host);
    if (info.port > 0) {
        b.add(T_PTR, &names.svc);
        b.add(T_SRV, &names.inst);
        b.add(T_TXT, &names.inst);
    }
    return header(0, 0, b.count, 0) + b.body;
}

// ---------------------------------------------------------------------------

bool MdnsResponder::start(const MdnsInfo& info, std::string& err) {
    stop();
    info_ = info;
    const char* ep = std::getenv("MICO_MDNS_PORT");
    port_ = ep && std::atoi(ep) > 0 ? std::atoi(ep) : 5353;
    fd_ = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd_ < 0) {
        err = std::string("socket: ") + std::strerror(errno);
        return false;
    }
    int one = 1;
    setsockopt(fd_, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
#ifdef SO_REUSEPORT
    setsockopt(fd_, SOL_SOCKET, SO_REUSEPORT, &one, sizeof one);
#endif
    fcntl(fd_, F_SETFL, fcntl(fd_, F_GETFL) | O_NONBLOCK);
    fcntl(fd_, F_SETFD, FD_CLOEXEC);
    sockaddr_in sa;
    std::memset(&sa, 0, sizeof sa);
    sa.sin_family = AF_INET;
    sa.sin_port = htons(static_cast<uint16_t>(port_));
    sa.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(fd_, reinterpret_cast<sockaddr*>(&sa), sizeof sa) != 0) {
        err = "bind :" + std::to_string(port_) + ": " + std::strerror(errno);
        close(fd_);
        fd_ = -1;
        return false;
    }
    unsigned char ttl = 255, loop = 1;
    setsockopt(fd_, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, sizeof ttl);
    setsockopt(fd_, IPPROTO_IP, IP_MULTICAST_LOOP, &loop, sizeof loop);
    joined_.clear();
    refresh_ifaces(true);
    if (ifaces_.empty()) {  // no address yet: join on the default interface
        ip_mreq mr;
        mr.imr_multiaddr.s_addr = inet_addr(MCAST);
        mr.imr_interface.s_addr = htonl(INADDR_ANY);
        setsockopt(fd_, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mr, sizeof mr);
    }
    announces_left_ = 2;
    next_announce_ = 0;
    next_check_ = 0;
    return true;
}

void MdnsResponder::stop() {
    if (fd_ < 0) return;
    announce(0);
    close(fd_);
    fd_ = -1;
    ifaces_.clear();
}

void MdnsResponder::update(const MdnsInfo& info) {
    if (fd_ < 0) {
        info_ = info;
        return;
    }
    announce(0);
    info_ = info;
    announces_left_ = 2;
    next_announce_ = 0;
}

std::vector<std::string> MdnsResponder::ips() const {
    std::vector<std::string> out;
    for (const auto& i : ifaces_) {
        in_addr a;
        a.s_addr = i.addr;
        out.push_back(inet_ntoa(a));
    }
    return out;
}

void MdnsResponder::refresh_ifaces(bool join) {
    std::vector<Iface> now;
    ifaddrs* ifa = nullptr;
    if (getifaddrs(&ifa) == 0) {
        for (ifaddrs* p = ifa; p; p = p->ifa_next) {
            if (!p->ifa_addr || p->ifa_addr->sa_family != AF_INET) continue;
            if ((p->ifa_flags & IFF_LOOPBACK) || !(p->ifa_flags & IFF_UP)) continue;
            Iface f;
            f.addr = reinterpret_cast<sockaddr_in*>(p->ifa_addr)->sin_addr.s_addr;
            f.mask = p->ifa_netmask ? reinterpret_cast<sockaddr_in*>(p->ifa_netmask)->sin_addr.s_addr : 0xffffffff;
            now.push_back(f);
        }
        freeifaddrs(ifa);
    }
    bool changed = now.size() != ifaces_.size();
    for (size_t i = 0; !changed && i < now.size(); ++i) changed = now[i].addr != ifaces_[i].addr;
    ifaces_ = now;
    if (!changed && !join) return;
    for (const auto& f : ifaces_) {
        bool have = false;
        for (uint32_t j : joined_) have = have || j == f.addr;
        if (have) continue;
        ip_mreq mr;
        mr.imr_multiaddr.s_addr = inet_addr(MCAST);
        mr.imr_interface.s_addr = f.addr;
        if (setsockopt(fd_, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mr, sizeof mr) == 0 || errno == EADDRINUSE)
            joined_.push_back(f.addr);
    }
    if (changed && !join) {
        std::vector<std::string> v = ips();
        std::string s;
        for (const auto& x : v) s += (s.empty() ? "" : ", ") + x;
        logf("mdns: addresses changed -> %s", s.empty() ? "(none)" : s.c_str());
        announces_left_ = 2;
        next_announce_ = 0;
    }
}

void MdnsResponder::send_to(const std::string& pkt, uint32_t ip, int port, uint32_t mcast_if) {
    if (mcast_if) {
        in_addr a;
        a.s_addr = mcast_if;
        setsockopt(fd_, IPPROTO_IP, IP_MULTICAST_IF, &a, sizeof a);
    }
    sockaddr_in sa;
    std::memset(&sa, 0, sizeof sa);
    sa.sin_family = AF_INET;
    sa.sin_port = htons(static_cast<uint16_t>(port));
    sa.sin_addr.s_addr = ip;
    sendto(fd_, pkt.data(), pkt.size(), 0, reinterpret_cast<sockaddr*>(&sa), sizeof sa);
}

void MdnsResponder::announce(uint32_t ttl) {
    for (const auto& f : ifaces_) send_to(mdns_announce(info_, f.addr, ttl), inet_addr(MCAST), port_, f.addr);
}

void MdnsResponder::poll(double now_ms) {
    if (fd_ < 0) return;
    if (now_ms >= next_check_) {
        next_check_ = now_ms + 30000;
        refresh_ifaces(false);
    }
    if (announces_left_ > 0 && now_ms >= next_announce_ && !ifaces_.empty()) {
        announce(TTL);
        --announces_left_;
        next_announce_ = now_ms + 1000;
    }
    unsigned char buf[1500];
    for (int i = 0; i < 32; ++i) {
        sockaddr_in src;
        socklen_t sl = sizeof src;
        ssize_t r = recvfrom(fd_, buf, sizeof buf, 0, reinterpret_cast<sockaddr*>(&src), &sl);
        if (r <= 0) break;
        uint32_t s = src.sin_addr.s_addr, ip = 0;
        for (const auto& f : ifaces_)
            if ((f.addr & f.mask) == (s & f.mask)) {
                ip = f.addr;
                break;
            }
        if (!ip && !ifaces_.empty()) ip = ifaces_[0].addr;
        if (!ip && (ntohl(s) >> 24) == 127) ip = s;
        if (!ip) continue;
        int sport = ntohs(src.sin_port);
        bool legacy = sport != port_, unicast = false;
        std::string out;
        if (!mdns_answer(buf, static_cast<size_t>(r), info_, ip, legacy, out, &unicast)) continue;
        if (legacy || unicast)
            send_to(out, s, sport, 0);
        else
            send_to(out, inet_addr(MCAST), port_, ip);
    }
}

}  // namespace mico
