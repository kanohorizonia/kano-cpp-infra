#include <kano_unattended.hpp>
#include <kano_task_scheduler.hpp>
#include <kano_infra_process/public/kano_process_session.hpp>
#include <kano_infra_process/public/kano_process_listener.hpp>
#include <kano_infra_platform/public/kano_local_path.hpp>
#include <cstdio>
#include <stdexcept>
#include <string>
#ifdef KANO_INSTALLED_HTTP
#include <kano_http.hpp>
#endif

namespace {
int Fail(int code, const char* message) {
    std::fprintf(stderr, "Installed interface check failed: %s\n", message);
    return code;
}

#ifdef _WIN32
void Require(bool condition, const std::string& message) {
    if (!condition) throw std::runtime_error(message);
}

std::string XmlText(const std::string& value) {
    std::string result;
    for (const char character : value) {
        switch (character) {
        case '&': result += "&amp;"; break;
        case '<': result += "&lt;"; break;
        case '>': result += "&gt;"; break;
        case '\"': result += "&quot;"; break;
        case '\'': result += "&apos;"; break;
        default: result += character; break;
        }
    }
    return result;
}

void CheckProjectionVersions(const std::filesystem::path& helper, const std::string& user,
                             const std::string& executable) {
    for (const bool unifiedEngine : {false, true}) {
        const std::string scenario = std::string("project unified_engine=") + (unifiedEngine ? "true" : "false");
        Json::Value request;
        request["operation"] = "project";
        request["name"] = "\\KanoInstalledProjectionCheck";
        // Project imports this disabled definition into memory; it never registers or runs it.
        // Omit an encoding declaration: the helper supplies a UTF-16 BSTR.
        request["xml"] =
            "<?xml version=\"1.0\"?>"
            "<Task version=\"1.3\" xmlns=\"http://schemas.microsoft.com/windows/2004/02/mit/task\">"
            "<RegistrationInfo><Description>Installed scheduler projection check</Description></RegistrationInfo>"
            "<Triggers><LogonTrigger><Enabled>false</Enabled><UserId>" + XmlText(user) +
            "</UserId></LogonTrigger></Triggers>"
            "<Principals><Principal id=\"CurrentUser\"><UserId>" + XmlText(user) +
            "</UserId><LogonType>InteractiveToken</LogonType><RunLevel>LeastPrivilege</RunLevel></Principal></Principals>"
            "<Settings><Enabled>false</Enabled><UseUnifiedSchedulingEngine>" +
            (unifiedEngine ? "true" : "false") +
            "</UseUnifiedSchedulingEngine></Settings>"
            "<Actions Context=\"CurrentUser\"><Exec><Command>" + XmlText(executable) +
            "</Command></Exec></Actions></Task>";

        const auto defaultResult = kano::scheduler::Invoke(helper, request, 5000);
        const auto& legacy = defaultResult["projection"];
        Require(legacy.isObject(), scenario + ": default projection is not an object");
        Require(defaultResult["enabled"].isBool() && !defaultResult["enabled"].asBool(),
                scenario + ": default projection did not preserve the disabled task");
        Require(!legacy.isMember("unified_engine"), scenario + ": default projection exposed unified_engine");
        Require(legacy["user"].isString() && legacy["user"].asString() == user,
                scenario + ": projected principal differs from the current user SID");
        Require(legacy["actions"].isArray() && legacy["actions"].size() == 1,
                scenario + ": projected action count differs from the XML");
        Require(legacy["actions"][0]["path"].isString() && legacy["actions"][0]["path"].asString() == executable,
                scenario + ": projected executable differs from the XML");
        Require(legacy["triggers"].isArray() && legacy["triggers"].size() == 1,
                scenario + ": projected trigger count differs from the XML");
        Require(legacy["triggers"][0]["type"].isInt() && legacy["triggers"][0]["type"].asInt() == 9,
                scenario + ": projected trigger is not a logon trigger");
        Require(legacy["triggers"][0]["user"].isString() && legacy["triggers"][0]["user"].asString() == user,
                scenario + ": projected logon trigger differs from the current user SID");
        Require(legacy["triggers"][0]["enabled"].isBool() && !legacy["triggers"][0]["enabled"].asBool(),
                scenario + ": projected logon trigger is enabled");

        request["projection_version"] = 1;
        const auto version1 = kano::scheduler::Invoke(helper, request, 5000);
        Require(version1["projection"].isObject(), scenario + ": version 1 projection is not an object");
        Require(version1["enabled"].isBool() && !version1["enabled"].asBool(),
                scenario + ": version 1 projection did not preserve the disabled task");
        Require(!version1["projection"].isMember("unified_engine"), scenario + ": version 1 exposed unified_engine");
        Require(version1["projection"] == legacy, scenario + ": explicit version 1 differs from the default");

        request["projection_version"] = 2;
        const auto version2 = kano::scheduler::Invoke(helper, request, 5000);
        Require(version2["projection"].isObject(), scenario + ": version 2 projection is not an object");
        Require(version2["enabled"].isBool() && !version2["enabled"].asBool(),
                scenario + ": version 2 projection did not preserve the disabled task");
        Require(version2["projection"]["unified_engine"].isBool(), scenario + ": version 2 unified_engine is not a boolean");
        Require(version2["projection"]["unified_engine"].asBool() == unifiedEngine,
                scenario + ": version 2 unified_engine differs from the XML");
        auto normalized = version2["projection"];
        normalized.removeMember("unified_engine");
        Require(normalized == legacy, scenario + ": version 2 changed legacy projection fields");
    }

    const Json::Value invalidVersions[]{Json::Value(0), Json::Value(3), Json::Value(-1),
        Json::Value(true), Json::Value("2"), Json::Value(2.0), Json::Value(Json::nullValue)};
    const char* invalidNames[]{"zero", "unsupported integer", "negative integer", "boolean", "string", "double", "null"};
    for (std::size_t index = 0; index < sizeof(invalidVersions) / sizeof(invalidVersions[0]); ++index) {
        Json::Value request;
        request["operation"] = "identity";
        request["projection_version"] = invalidVersions[index];
        const std::string scenario = std::string("invalid projection_version ") + invalidNames[index];
        try {
            kano::scheduler::Invoke(helper, request, 5000);
        } catch (const std::exception& error) {
            Require(std::string(error.what()).find("projection_version") != std::string::npos,
                    scenario + ": unexpected helper error: " + error.what());
            continue;
        }
        Require(false, scenario + ": helper accepted an invalid version");
    }
    std::puts("Scheduler projection checks passed: 6 XML projections and 7 invalid versions.");
}
#endif
}

int main(int argc, char** argv) {
    kano::infra::ConfigureUnattendedExecution();
    if (!kano::process::MatchLoopbackListeners(1234, {}).verified) return Fail(7, "empty loopback listener set was not verified");
    if (kano::process::MatchLoopbackListeners(1234, {{42, "*:1234"}}).verified) return Fail(8, "wildcard listener was accepted as loopback");
#ifdef KANO_INSTALLED_HTTP
    if (kano::http::ValidateEndpoint("http://localhost:1234/", kano::http::EndpointPolicy::LoopbackHttp) != "http://127.0.0.1:1234") return Fail(6, "loopback HTTP endpoint was not normalized");
#endif
    std::uint64_t parent = 0;
    if (kano::process::QueryParent({}, parent)) return Fail(1, "empty process identity unexpectedly has a parent");
    if (kano::platform::LocalPath(std::filesystem::current_path()).empty()) return Fail(2, "current directory resolved to an empty local path");
    Json::Value request; request["operation"] = "identity";
#ifdef _WIN32
    if (argc != 2) return Fail(3, "expected the installed scheduler helper path");
    if (!kano::process::QueryParent(kano::process::CurrentIdentity(), parent) || !parent) return Fail(4, "current process parent is unavailable");
    try {
        const auto identity = kano::scheduler::Invoke(argv[1], request, 5000);
        if (!identity["integrity_rid"].isUInt() || !identity["user"].isString()) return Fail(5, "scheduler identity response is incomplete");
        CheckProjectionVersions(argv[1], identity["user"].asString(), argv[0]);
    } catch (const std::exception& error) {
        return Fail(9, error.what());
    }
#else
    (void)argc; (void)argv;
    try { kano::scheduler::Invoke("missing-scheduler-helper", request, 100); return Fail(3, "missing scheduler helper unexpectedly succeeded"); }
    catch (const std::exception&) {}
#endif
    std::puts("Installed unattended, scheduler, process and local-path interfaces passed.");
    return 0;
}
