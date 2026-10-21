#ifdef _WIN32
#define NOMINMAX
#include <winsock2.h>
#include <ws2tcpip.h>
#else
#include <arpa/inet.h>
#endif
#include <kano_http.hpp>
#include <curl/curl.h>
#include <algorithm>
#include <charconv>
#include <limits>
#include <memory>
#include <mutex>

namespace kano::http {
namespace {
void Check(bool InCondition) { if (!InCondition) throw Error(Failure::InvalidRequest); }
bool Controls(const std::string& InValue) {
    return std::any_of(InValue.begin(), InValue.end(), [](unsigned char c) { return c < 32 || c == 127; });
}
struct Transfer {
    const Request& Input;
    std::string Bytes;
    bool Overflow = false;
    bool Cancelled() const noexcept { try { return Input.Cancelled && Input.Cancelled(); } catch (...) { return true; } }
};
std::size_t Write(char* InBytes, std::size_t InSize, std::size_t InCount, void* InContext) noexcept {
    auto& transfer = *static_cast<Transfer*>(InContext);
    if (transfer.Cancelled()) return 0;
    if (InSize && InCount > std::numeric_limits<std::size_t>::max() / InSize) { transfer.Overflow = true; return 0; }
    const auto count = InSize * InCount;
    if (count > transfer.Input.ResponseBytes - transfer.Bytes.size()) { transfer.Overflow = true; return 0; }
    try { transfer.Bytes.append(InBytes, count); } catch (...) { transfer.Overflow = true; return 0; }
    return count;
}
int Progress(void* InContext, curl_off_t, curl_off_t, curl_off_t, curl_off_t) noexcept {
    return static_cast<Transfer*>(InContext)->Cancelled() ? 1 : 0;
}
}
std::string ValidateEndpoint(const std::string& InUrl, EndpointPolicy InPolicy) {
    Check(!InUrl.empty() && InUrl.size() <= 8192 && !Controls(InUrl) && InUrl.find_first_of("\\ ?#@") == std::string::npos);
    const auto separator = InUrl.find("://"); Check(separator != std::string::npos);
    const auto scheme = InUrl.substr(0, separator); Check(scheme == "http" || scheme == "https");
    auto authority = InUrl.substr(separator + 3);
    const auto slash = authority.find('/');
    if (slash != std::string::npos) { Check(slash == authority.size() - 1); authority.pop_back(); }
    Check(!authority.empty());
    std::string host, port;
    if (authority.front() == '[') {
        const auto end = authority.find(']'); Check(end != std::string::npos); host = authority.substr(1, end - 1);
        Check(end + 1 == authority.size() || authority[end + 1] == ':');
        if (end + 1 < authority.size()) { port = authority.substr(end + 2); Check(!port.empty()); }
    } else {
        const auto colon = authority.find(':'); host = authority.substr(0, colon);
        if (colon != std::string::npos) { port = authority.substr(colon + 1); Check(!port.empty()); }
    }
    if (!port.empty()) {
        unsigned number = 0; const auto parsed = std::from_chars(port.data(), port.data() + port.size(), number);
        Check(parsed.ec == std::errc{} && parsed.ptr == port.data() + port.size() && number > 0 && number <= 65535);
    }
    if (host == "localhost") host = "127.0.0.1";
    unsigned char address[16]{}; bool loopback = false, privateAddress = false; bool ipv6 = false;
    if (inet_pton(AF_INET, host.c_str(), address) == 1) {
        loopback = address[0] == 127;
        privateAddress = address[0] == 10 || (address[0] == 172 && address[1] >= 16 && address[1] <= 31) ||
            (address[0] == 192 && address[1] == 168);
    } else {
        Check(inet_pton(AF_INET6, host.c_str(), address) == 1); ipv6 = true;
        loopback = std::all_of(address, address + 15, [](unsigned char c) { return c == 0; }) && address[15] == 1;
        privateAddress = (address[0] & 0xfe) == 0xfc;
    }
    if (InPolicy == EndpointPolicy::LoopbackHttp) Check(scheme == "http" && loopback && !port.empty());
    else Check(loopback || (privateAddress && scheme == "https"));
    return scheme + "://" + (ipv6 ? "[" + host + "]" : host) + (port.empty() ? "" : ":" + port);
}
Response Perform(const Request& InRequest) {
    const auto base = ValidateEndpoint(InRequest.Endpoint, InRequest.Policy);
    Check((InRequest.Method == "GET" || InRequest.Method == "POST") && !InRequest.Path.empty() && InRequest.Path.front() == '/' &&
        InRequest.Path.compare(0, 2, "//") != 0 && !Controls(InRequest.Path) && InRequest.Path.find_first_of("\\# ") == std::string::npos &&
        (InRequest.Method == "POST" || InRequest.Body.empty()) && InRequest.Body.size() <= 4 * 1024 * 1024 &&
        InRequest.ResponseBytes > 0 && InRequest.ResponseBytes <= 64 * 1024 * 1024 && InRequest.TimeoutMs > 0 &&
        (InRequest.Accept == "application/json" || InRequest.Accept == "image/png") && InRequest.Bearer.size() <= 8192 && !Controls(InRequest.Bearer));
    Transfer transfer{InRequest, {}, false}; if (transfer.Cancelled()) throw Error(Failure::Cancelled);
    static std::once_flag once; static CURLcode initialized = CURLE_FAILED_INIT;
    std::call_once(once, [] { initialized = curl_global_init(CURL_GLOBAL_DEFAULT); });
    if (initialized != CURLE_OK) throw Error(Failure::Unavailable);
    std::unique_ptr<CURL, decltype(&curl_easy_cleanup)> easy(curl_easy_init(), curl_easy_cleanup);
    if (!easy) throw Error(Failure::Unavailable);
    auto Set = [&](CURLoption InOption, auto InValue) { if (curl_easy_setopt(easy.get(), InOption, InValue) != CURLE_OK) throw Error(Failure::Unavailable); };
    std::unique_ptr<curl_slist, decltype(&curl_slist_free_all)> headers(nullptr, curl_slist_free_all);
    auto Header = [&](const std::string& InValue) {
        auto* next = curl_slist_append(headers.get(), InValue.c_str()); if (!next) throw Error(Failure::Unavailable);
        headers.release(); headers.reset(next);
    };
    Header("Accept: " + InRequest.Accept); Header("Content-Type: application/json"); Header("Expect:");
    if (!InRequest.Bearer.empty()) Header("Authorization: Bearer " + InRequest.Bearer);
    const auto url = base + InRequest.Path;
    Set(CURLOPT_URL, url.c_str()); Set(CURLOPT_HTTPHEADER, headers.get()); Set(CURLOPT_NOSIGNAL, 1L);
    Set(CURLOPT_TIMEOUT_MS, static_cast<long>(InRequest.TimeoutMs)); Set(CURLOPT_CONNECTTIMEOUT_MS, static_cast<long>(InRequest.TimeoutMs));
    Set(CURLOPT_FOLLOWLOCATION, 0L); Set(CURLOPT_MAXREDIRS, 0L); Set(CURLOPT_PROTOCOLS_STR, "http,https");
    Set(CURLOPT_REDIR_PROTOCOLS_STR, "http,https"); Set(CURLOPT_DISALLOW_USERNAME_IN_URL, 1L);
    Set(CURLOPT_SSL_VERIFYPEER, 1L); Set(CURLOPT_SSL_VERIFYHOST, 2L);
    Set(CURLOPT_NETRC, static_cast<long>(CURL_NETRC_IGNORED)); Set(CURLOPT_PROXY, ""); Set(CURLOPT_NOPROXY, "*");
    Set(CURLOPT_HTTP_VERSION, static_cast<long>(CURL_HTTP_VERSION_1_1)); Set(CURLOPT_FRESH_CONNECT, 1L); Set(CURLOPT_FORBID_REUSE, 1L);
    Set(CURLOPT_WRITEFUNCTION, &Write); Set(CURLOPT_WRITEDATA, &transfer); Set(CURLOPT_NOPROGRESS, 0L);
    Set(CURLOPT_XFERINFOFUNCTION, &Progress); Set(CURLOPT_XFERINFODATA, &transfer); Set(CURLOPT_VERBOSE, 0L);
    if (InRequest.Method == "POST") { Set(CURLOPT_POST, 1L); Set(CURLOPT_POSTFIELDS, InRequest.Body.data()); Set(CURLOPT_POSTFIELDSIZE_LARGE, static_cast<curl_off_t>(InRequest.Body.size())); }
    else Set(CURLOPT_HTTPGET, 1L);
    const auto code = curl_easy_perform(easy.get());
    long status = 0;
    curl_easy_getinfo(easy.get(), CURLINFO_RESPONSE_CODE, &status);
    if (transfer.Cancelled()) throw Error(Failure::Cancelled, status);
    if (transfer.Overflow) throw Error(Failure::Overflow, status);
    if (code == CURLE_OPERATION_TIMEDOUT) throw Error(Failure::Deadline, status);
    if (code != CURLE_OK) throw Error(Failure::Unavailable, status);
    Response response; char* type = nullptr;
    if (curl_easy_getinfo(easy.get(), CURLINFO_RESPONSE_CODE, &response.Status) != CURLE_OK ||
        curl_easy_getinfo(easy.get(), CURLINFO_CONTENT_TYPE, &type) != CURLE_OK) throw Error(Failure::Unavailable);
    response.ContentType = type ? type : ""; response.Bytes = std::move(transfer.Bytes); return response;
}
}
