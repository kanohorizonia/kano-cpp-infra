#include <kano_unattended.hpp>
#include <kano_task_scheduler.hpp>
#include <kano_infra_process/public/kano_process_session.hpp>
#include <kano_infra_process/public/kano_process_listener.hpp>
#include <kano_infra_platform/public/kano_local_path.hpp>
#include <cstdio>
#ifdef KANO_INSTALLED_HTTP
#include <kano_http.hpp>
#endif

int main(int argc, char** argv) {
    kano::infra::ConfigureUnattendedExecution();
    if (!kano::process::MatchLoopbackListeners(1234, {}).verified) return 7;
    if (kano::process::MatchLoopbackListeners(1234, {{42, "*:1234"}}).verified) return 8;
#ifdef KANO_INSTALLED_HTTP
    if (kano::http::ValidateEndpoint("http://localhost:1234/", kano::http::EndpointPolicy::LoopbackHttp) != "http://127.0.0.1:1234") return 6;
#endif
    std::uint64_t parent = 0;
    if (kano::process::QueryParent({}, parent)) return 1;
    if (kano::platform::LocalPath(std::filesystem::current_path()).empty()) return 2;
    Json::Value request; request["operation"] = "identity";
#ifdef _WIN32
    if (argc != 2) return 3;
    if (!kano::process::QueryParent(kano::process::CurrentIdentity(), parent) || !parent) return 4;
    const auto identity = kano::scheduler::Invoke(argv[1], request, 5000);
    if (!identity["integrity_rid"].isUInt() || !identity["user"].isString()) return 5;
#else
    (void)argc; (void)argv;
    try { kano::scheduler::Invoke("missing-scheduler-helper", request, 100); return 3; }
    catch (const std::exception&) {}
#endif
    std::puts("Installed unattended, scheduler, process and local-path interfaces passed.");
    return 0;
}
