#define NOMINMAX
#include <windows.h>
#include <taskschd.h>
#include <sddl.h>
#include <wrl/client.h>
#include <kano_unattended.hpp>
#include <json/json.h>
#include <iostream>
#include <memory>
#include <set>
#include <stdexcept>
#include <string>

using Microsoft::WRL::ComPtr;
namespace {
struct Bstr {
    BSTR value = nullptr;
    explicit Bstr(const std::wstring& text) : value(SysAllocStringLen(text.data(), static_cast<UINT>(text.size()))) { if (!value) throw std::bad_alloc(); }
    Bstr() = default;
    ~Bstr() { SysFreeString(value); }
    Bstr(const Bstr&) = delete;
    operator BSTR() const { return value; }
};
const char* phase = "COM initialization";
void Check(HRESULT code, DWORD integrity = SECURITY_MANDATORY_MEDIUM_RID) { if (FAILED(code)) {
    std::string extra; ComPtr<IErrorInfo> info;
    if (GetErrorInfo(0, &info) == S_OK && info) { BSTR description = nullptr; if (SUCCEEDED(info->GetDescription(&description)) && description) {
        const int count = WideCharToMultiByte(CP_UTF8, 0, description, SysStringLen(description), nullptr, 0, nullptr, nullptr);
        extra.resize(count); WideCharToMultiByte(CP_UTF8, 0, description, SysStringLen(description), extra.data(), count, nullptr, nullptr); SysFreeString(description);
    } }
    if (integrity < SECURITY_MANDATORY_MEDIUM_RID)
        extra += " Low integrity (RID " + std::to_string(integrity) + "); check executable/build-output integrity labels and the authorized execution context. No automatic token or ACL changes are performed.";
    throw std::runtime_error(std::string(phase) + ": Task Scheduler HRESULT " + std::to_string(static_cast<unsigned long>(code)) + " " + extra);
} }
std::wstring Wide(const std::string& text) {
    const int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(), static_cast<int>(text.size()), nullptr, 0);
    if (!size && !text.empty()) throw std::runtime_error("Invalid UTF-8.");
    std::wstring result(size, 0); MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(), static_cast<int>(text.size()), result.data(), size); return result;
}
std::string Narrow(BSTR value) {
    if (!value) return {};
    const auto length = SysStringLen(value);
    const int size = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value, length, nullptr, 0, nullptr, nullptr);
    if (!size && length) throw std::runtime_error("Invalid UTF-16.");
    std::string result(size, 0); WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value, length, result.data(), size, nullptr, nullptr); return result;
}
template<class T, class Getter> std::string Text(T* object, Getter getter) { Bstr value; Check((object->*getter)(&value.value)); return Narrow(value); }
template<class T, class V> int Number(T* object, HRESULT (STDMETHODCALLTYPE T::*getter)(V*)) { V value{}; Check((object->*getter)(&value)); return static_cast<int>(value); }
template<class T, class Getter> bool Flag(T* object, Getter getter) { VARIANT_BOOL value = VARIANT_FALSE; Check((object->*getter)(&value)); return value != VARIANT_FALSE; }
std::string Sid() {
    HANDLE token = nullptr; if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) throw std::runtime_error("Token unavailable.");
    DWORD size = 0; GetTokenInformation(token, TokenUser, nullptr, 0, &size); std::string buffer(size, 0);
    const BOOL ok = GetTokenInformation(token, TokenUser, buffer.data(), size, &size); CloseHandle(token);
    LPWSTR sid = nullptr; if (!ok || !ConvertSidToStringSidW(reinterpret_cast<TOKEN_USER*>(buffer.data())->User.Sid, &sid)) throw std::runtime_error("SID unavailable.");
    Bstr copy(sid); LocalFree(sid); return Narrow(copy);
}
DWORD IntegrityRid() {
    HANDLE token = nullptr;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) throw std::runtime_error("Token integrity unavailable.");
    DWORD size = 0; GetTokenInformation(token, TokenIntegrityLevel, nullptr, 0, &size);
    std::string buffer(size, 0);
    const BOOL ok = GetTokenInformation(token, TokenIntegrityLevel, buffer.data(), size, &size); CloseHandle(token);
    if (!ok) throw std::runtime_error("Token integrity unavailable.");
    const auto sid = reinterpret_cast<TOKEN_MANDATORY_LABEL*>(buffer.data())->Label.Sid;
    const auto count = *GetSidSubAuthorityCount(sid);
    if (!count) throw std::runtime_error("Token integrity unavailable.");
    return *GetSidSubAuthority(sid, count - 1);
}
std::string PrincipalSid(const std::string& name) {
    if (name.empty() || name.rfind("S-1-", 0) == 0) return name;
    const auto account = Wide(name); DWORD sidBytes = 0, domainChars = 0; SID_NAME_USE use{};
    LookupAccountNameW(nullptr, account.c_str(), nullptr, &sidBytes, nullptr, &domainChars, &use);
    if (GetLastError() != ERROR_INSUFFICIENT_BUFFER) throw std::runtime_error("Principal SID resolution failed.");
    std::string sid(sidBytes, 0); std::wstring domain(domainChars, 0);
    if (!LookupAccountNameW(nullptr, account.c_str(), sid.data(), &sidBytes, domain.data(), &domainChars, &use)) throw std::runtime_error("Principal SID resolution failed.");
    LPWSTR raw = nullptr; if (!ConvertSidToStringSidW(sid.data(), &raw)) throw std::runtime_error("Principal SID conversion failed.");
    Bstr result(raw); LocalFree(raw); return Narrow(result);
}
Json::Value Projection(ITaskDefinition* definition) {
    Json::Value value;
    ComPtr<IRegistrationInfo> registration; Check(definition->get_RegistrationInfo(&registration));
    value["description"] = Text(registration.Get(), &IRegistrationInfo::get_Description);
    ComPtr<IPrincipal> principal; Check(definition->get_Principal(&principal));
    value["user"] = PrincipalSid(Text(principal.Get(), &IPrincipal::get_UserId));
    value["group"] = Text(principal.Get(), &IPrincipal::get_GroupId);
    TASK_LOGON_TYPE logon; Check(principal->get_LogonType(&logon)); value["logon"] = static_cast<int>(logon);
    TASK_RUNLEVEL_TYPE level; Check(principal->get_RunLevel(&level)); value["level"] = static_cast<int>(level);
    ComPtr<IActionCollection> actions; Check(definition->get_Actions(&actions)); long count = 0; Check(actions->get_Count(&count));
    value["actions"] = Json::Value(Json::arrayValue);
    for (long i = 1; i <= count; ++i) {
        ComPtr<IAction> action; Check(actions->get_Item(i, &action)); TASK_ACTION_TYPE type; Check(action->get_Type(&type));
        if (type != TASK_ACTION_EXEC) throw std::runtime_error("Unsupported task action.");
        ComPtr<IExecAction> exec; Check(action.As(&exec)); Json::Value row;
        row["path"] = Text(exec.Get(), &IExecAction::get_Path); row["arguments"] = Text(exec.Get(), &IExecAction::get_Arguments);
        row["cwd"] = Text(exec.Get(), &IExecAction::get_WorkingDirectory); value["actions"].append(row);
    }
    ComPtr<ITriggerCollection> triggers; Check(definition->get_Triggers(&triggers)); Check(triggers->get_Count(&count));
    value["triggers"] = Json::Value(Json::arrayValue);
    for (long i = 1; i <= count; ++i) {
        ComPtr<ITrigger> trigger; Check(triggers->get_Item(i, &trigger)); TASK_TRIGGER_TYPE2 type; Check(trigger->get_Type(&type));
        Json::Value row; row["type"] = static_cast<int>(type); row["enabled"] = Flag(trigger.Get(), &ITrigger::get_Enabled);
        row["start"] = Text(trigger.Get(), &ITrigger::get_StartBoundary); row["end"] = Text(trigger.Get(), &ITrigger::get_EndBoundary);
        row["execution_limit"] = Text(trigger.Get(), &ITrigger::get_ExecutionTimeLimit);
        ComPtr<IRepetitionPattern> repetition; Check(trigger->get_Repetition(&repetition));
        row["repeat_interval"] = Text(repetition.Get(), &IRepetitionPattern::get_Interval);
        row["repeat_duration"] = Text(repetition.Get(), &IRepetitionPattern::get_Duration);
        row["repeat_stop"] = Flag(repetition.Get(), &IRepetitionPattern::get_StopAtDurationEnd);
        if (type == TASK_TRIGGER_LOGON) { ComPtr<ILogonTrigger> logonTrigger; Check(trigger.As(&logonTrigger)); row["delay"] = Text(logonTrigger.Get(), &ILogonTrigger::get_Delay); row["user"] = PrincipalSid(Text(logonTrigger.Get(), &ILogonTrigger::get_UserId)); }
        else if (type == TASK_TRIGGER_BOOT) { ComPtr<IBootTrigger> boot; Check(trigger.As(&boot)); row["delay"] = Text(boot.Get(), &IBootTrigger::get_Delay); row["user"] = ""; }
        else throw std::runtime_error("Unsupported task trigger.");
        // Registration can omit an explicit zero delay that XML import retains.
        // Both describe the schema's default no-delay behavior.
        if (row["delay"].asString().empty()) row["delay"] = "PT0S";
        value["triggers"].append(row);
    }
    ComPtr<ITaskSettings> settings; Check(definition->get_Settings(&settings)); TASK_INSTANCES_POLICY instances;
    Check(settings->get_MultipleInstances(&instances)); value["instances"] = static_cast<int>(instances);
    value["restart_count"] = Number(settings.Get(), &ITaskSettings::get_RestartCount);
    value["restart_interval"] = Text(settings.Get(), &ITaskSettings::get_RestartInterval);
    value["execution_limit"] = Text(settings.Get(), &ITaskSettings::get_ExecutionTimeLimit);
    value["priority"] = Number(settings.Get(), &ITaskSettings::get_Priority);
    value["start_available"] = Flag(settings.Get(), &ITaskSettings::get_StartWhenAvailable);
    value["battery_start"] = Flag(settings.Get(), &ITaskSettings::get_DisallowStartIfOnBatteries);
    value["battery_stop"] = Flag(settings.Get(), &ITaskSettings::get_StopIfGoingOnBatteries);
    value["demand_start"] = Flag(settings.Get(), &ITaskSettings::get_AllowDemandStart);
    value["hard_stop"] = Flag(settings.Get(), &ITaskSettings::get_AllowHardTerminate);
    value["idle_only"] = Flag(settings.Get(), &ITaskSettings::get_RunOnlyIfIdle);
    value["network_only"] = Flag(settings.Get(), &ITaskSettings::get_RunOnlyIfNetworkAvailable);
    value["hidden"] = Flag(settings.Get(), &ITaskSettings::get_Hidden);
    // Enabled is mutable control state, intentionally separate from definition.
    return value;
}
Json::Value Execute(const Json::Value& request) {
    Json::Value result; result["ok"] = true; result["user"] = Sid();
    const auto integrity = IntegrityRid(); result["integrity_rid"] = Json::UInt(integrity);
    const auto operation = request["operation"].asString();
    const std::set<std::string> operations{"identity", "project", "read", "register", "enable", "disable", "start", "stop", "delete"};
    if (!operations.count(operation)) throw std::runtime_error("Unknown scheduler operation.");
    if (operation == "identity") return result;
    const auto name = request["name"].asString();
    if (name.size() < 2 || name.size() > 238 || name[0] != '\\' || name.find('\0') != std::string::npos || name.find_first_of("\r\n\"<>|") != std::string::npos) throw std::runtime_error("Invalid absolute task name.");
    phase = "COM activation"; ComPtr<ITaskService> service; Check(CoCreateInstance(CLSID_TaskScheduler, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&service)));
    phase = "scheduler connection"; VARIANT empty; VariantInit(&empty); Check(service->Connect(empty, empty, empty, empty));
    auto definition = [&] { phase = "new definition"; ComPtr<ITaskDefinition> d; Check(service->NewTask(0, &d)); phase = "XML import"; Check(d->put_XmlText(Bstr(Wide(request["xml"].asString())))); phase = "definition projection"; return d; };
    if (operation == "project") { auto d = definition(); result["projection"] = Projection(d.Get());
        ComPtr<ITaskSettings> settings; Check(d->get_Settings(&settings)); result["enabled"] = Flag(settings.Get(), &ITaskSettings::get_Enabled); return result; }
    phase = "root folder read"; ComPtr<ITaskFolder> folder; Bstr root(L"\\");
    Check(service->GetFolder(root.value, &folder), integrity);
    ComPtr<IRegisteredTask> task;
    phase = "exact task read"; const auto found = folder->GetTask(Bstr(Wide(name)), &task);
    if (found == HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND) || found == HRESULT_FROM_WIN32(ERROR_PATH_NOT_FOUND)) {
        result["found"] = false;
    } else { Check(found); result["found"] = true; }
    if (task) {
        ComPtr<ITaskDefinition> d; Check(task->get_Definition(&d)); result["projection"] = Projection(d.Get());
        TASK_STATE state; Check(task->get_State(&state)); result["state"] = static_cast<int>(state);
        result["enabled"] = Flag(task.Get(), &IRegisteredTask::get_Enabled);
        result["last_result"] = Number(task.Get(), &IRegisteredTask::get_LastTaskResult);
    }
    if (operation == "read") return result;
    if (operation == "register") {
        if (task) throw std::runtime_error("Task already exists; registration does not overwrite.");
        auto d = definition(); if (Projection(d.Get()) != request["expected"]) throw std::runtime_error("Task XML projection mismatch.");
        ComPtr<IPrincipal> principal; Check(d->get_Principal(&principal)); TASK_LOGON_TYPE logon; Check(principal->get_LogonType(&logon));
        // No credentials or elevation mechanism. S4U may be refused by the OS.
        Check(folder->RegisterTaskDefinition(Bstr(Wide(name)), d.Get(), TASK_CREATE, empty, empty, logon, empty, &task));
        return result;
    }
    if (!task || result["projection"] != request["expected"]) throw std::runtime_error("Task missing or foreign; refusing mutation.");
    if (operation == "enable" || operation == "disable") Check(task->put_Enabled(operation == "enable" ? VARIANT_TRUE : VARIANT_FALSE));
    else if (operation == "start") { ComPtr<IRunningTask> running; Check(task->Run(empty, &running)); }
    else if (operation == "stop") Check(task->Stop(0));
    else if (operation == "delete") { if (result["state"].asInt() == TASK_STATE_RUNNING || result["state"].asInt() == TASK_STATE_QUEUED) throw std::runtime_error("Stop task before deleting."); Check(folder->DeleteTask(Bstr(Wide(name)), 0)); }
    else throw std::runtime_error("Unknown scheduler operation.");
    return result;
}
}
int main() {
    kano::infra::ConfigureUnattendedExecution();
    const auto init = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    Json::Value result;
    try {
        Check(init);
        phase = "COM security";
        Check(CoInitializeSecurity(nullptr, -1, nullptr, nullptr, RPC_C_AUTHN_LEVEL_PKT_PRIVACY, RPC_C_IMP_LEVEL_IMPERSONATE, nullptr, EOAC_NONE, nullptr));
        std::string input; char block[4096];
        while (std::cin.read(block, sizeof(block)) || std::cin.gcount()) {
            if (input.size() + static_cast<std::size_t>(std::cin.gcount()) > 1024 * 1024) throw std::runtime_error("Request too large.");
            input.append(block, static_cast<std::size_t>(std::cin.gcount()));
        }
        Json::CharReaderBuilder reader; reader["rejectDupKeys"] = true; reader["failIfExtra"] = true; Json::Value request; std::string errors;
        auto parser = std::unique_ptr<Json::CharReader>(reader.newCharReader());
        if (!parser->parse(input.data(), input.data() + input.size(), &request, &errors) || !request.isObject()) throw std::runtime_error("Invalid JSON request.");
        result = Execute(request);
    } catch (const std::exception& error) { result["ok"] = false; result["error"] = error.what(); }
    if (SUCCEEDED(init)) CoUninitialize(); Json::StreamWriterBuilder writer; writer["indentation"] = "";
    std::cout << Json::writeString(writer, result) << '\n'; return 0;
}
