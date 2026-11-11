// mico-agent: on-speaker AI agent for Xiaomi XiaoAi speakers.
//
//   mico-agent [-s main.lua]               follow instruction.log, call on_input(text, dialog_id)
//   mico-agent [-s main.lua] --once TEXT   call on_input(TEXT) once and exit (testing)
//   -c config.json                         config file (else $MICO_CONFIG, ./config.json, /data/mico-agent/config.json)
// In follow mode the web UI / stream proxy listens on config.web.listen.

#include <signal.h>
#include <unistd.h>

#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <string>

#include "http.h"
#include "httpd.h"
#include "instruction.h"
#include "logger.h"
#include "mdns.h"
#include "runtime.h"
#include "tail.h"

static volatile sig_atomic_t g_stop = 0;
static void on_signal(int) { g_stop = 1; }

static double rt_now_ms() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6;
}

// Reads the mdns config section; returns false when disabled.
static bool mdns_config(mico::Runtime& rt, mico::MdnsInfo& info) {
    const char* env = std::getenv("MICO_MDNS");
    if (env && (!std::strcmp(env, "0") || !std::strcmp(env, "false"))) return false;
    if (rt.config_number("mdns.enabled", 1) == 0) return false;
    info.host = rt.config_string("mdns.hostname", "mico");
    for (auto& c : info.host) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    if (!mico::mdns_valid_host(info.host)) info.host = "mico";
    info.instance = rt.config_string("mdns.instance", "");
    if (info.instance.empty()) info.instance = "mico-agent";
    info.port = rt.web_port;
    info.version = MICO_VERSION;
    return true;
}

static void mdns_sync(mico::Runtime& rt, mico::MdnsResponder& md, bool& failed) {
    mico::MdnsInfo want;
    bool on = mdns_config(rt, want);
    if (!on) {
        if (md.running()) {
            md.stop();
            mico::logf("mdns: disabled");
        }
        failed = false;
    } else if (!md.running()) {
        if (!failed) {  // don't retry a failed bind every second; toggling mdns.enabled resets this
            std::string err;
            if (md.start(want, err)) {
                md.poll(rt_now_ms());
                std::string ips;
                for (const auto& ip : md.ips()) ips += (ips.empty() ? "" : ", ") + ip;
                std::string svc = want.port ? " (http :" + std::to_string(want.port) + ")" : "";
                mico::logf("mdns: %s.local -> %s%s", want.host.c_str(), ips.empty() ? "(no address yet)" : ips.c_str(),
                           svc.c_str());
            } else {
                mico::logf("mdns: %s", err.c_str());
                failed = true;
            }
        }
    } else {
        const mico::MdnsInfo& cur = md.info();
        if (cur.host != want.host || cur.instance != want.instance || cur.port != want.port) {
            md.update(want);
            mico::logf("mdns: now %s.local", want.host.c_str());
        }
    }
    rt.mdns_enabled = md.running();
    rt.mdns_name = (on ? want.host : md.info().host) + ".local";
    rt.mdns_ips = md.ips();
}

static void usage() {
    std::fprintf(stderr, "usage: mico-agent [-s script.lua] [-c config.json] [--once TEXT]\n");
}

int main(int argc, char** argv) {
    std::string script = "scripts/main.lua";
    std::string once, config_path;
    bool has_once = false;
    for (int i = 1; i < argc; ++i) {
        if (!std::strcmp(argv[i], "-s") && i + 1 < argc) {
            script = argv[++i];
        } else if (!std::strcmp(argv[i], "-c") && i + 1 < argc) {
            config_path = argv[++i];
        } else if (!std::strcmp(argv[i], "--once") && i + 1 < argc) {
            once = argv[++i];
            has_once = true;
        } else {
            usage();
            return 2;
        }
    }

    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);
    signal(SIGPIPE, SIG_IGN);
    mico::http_global_init();

    int rc = 0;
    {
        mico::Runtime rt;
        rt.config_path = config_path;
        std::string err;
        if (!rt.load_script(script, err)) {
            mico::logf("load %s: %s", script.c_str(), err.c_str());
            mico::http_global_cleanup();
            return 1;
        }

        if (has_once) {
            if (!rt.call_hook("on_input", {once, "once"}, err)) {
                mico::logf("on_input: %s", err.c_str());
                rc = 1;
            }
        } else {
            std::string log_path = rt.config_string("instruction_log", "/tmp/mico_aivs_lab/instruction.log");
            bool from_start = rt.config_number("from_start", 0) != 0;
            mico::logf("following %s", log_path.c_str());
            mico::Tailer tail(log_path, from_start);
            mico::HttpServer web;
            std::string listen = rt.config_string("web.listen", "");
            if (!listen.empty()) {
                std::string lerr;
                if (web.listen(listen, lerr)) {
                    rt.web_port = web.port();
                    mico::logf("web: listening on %s (port %d)", listen.c_str(), web.port());
                } else {
                    mico::logf("web: %s", lerr.c_str());
                }
            }
            auto handler = [&rt](const mico::WebRequest& req) { return rt.handle_http(req); };
            mico::MdnsResponder mdns;
            bool mdns_failed = false;
            mdns_sync(rt, mdns, mdns_failed);
            std::string last_dialog;
            double last_tick = -1e18;  // first tick right after startup (web is already up)
            while (!g_stop) {
                double now = rt_now_ms();
                if (now - last_tick >= 1000) {
                    last_tick = now;
                    mdns_sync(rt, mdns, mdns_failed);
                    std::string terr;
                    if (!rt.call_hook("on_tick", {}, terr) && terr.rfind("no global function", 0) != 0) {
                        mico::logf("on_tick: %s", terr.c_str());
                    }
                }
                tail.poll([&](const std::string& line) {
                    mico::Recognition rec;
                    if (!mico::parse_recognition(line, rec) || !rec.final) return;
                    // The final result may be logged more than once per dialog.
                    if (!rec.dialog_id.empty() && rec.dialog_id == last_dialog) return;
                    last_dialog = rec.dialog_id;
                    std::string herr;
                    if (!rt.call_hook("on_input", {rec.text, rec.dialog_id}, herr)) {
                        mico::logf("on_input: %s", herr.c_str());
                    }
                });
                // Re-read each iteration so a saved poll_ms applies live.
                double poll_ms = rt.config_number("poll_ms", 50);
                if (!(poll_ms >= 1 && poll_ms <= 1000)) poll_ms = 50;
                web.poll(static_cast<int>(poll_ms), handler);
                mdns.poll(rt_now_ms());
            }
        }
    }
    mico::http_global_cleanup();
    return rc;
}
