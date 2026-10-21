#pragma once
#include <cstddef>
#include <functional>
#include <stdexcept>
#include <string>

namespace kano::http {
enum class EndpointPolicy { LoopbackHttp, PrivateControl };
enum class Failure { InvalidRequest, Unavailable, Overflow, Cancelled, Deadline };
class Error : public std::runtime_error {
public:
    explicit Error(Failure InReason, long InStatus = 0) : std::runtime_error("Bounded HTTP request failed"), Reason(InReason), Status(InStatus) {}
    Failure Reason;
    long Status; // Received HTTP status, even when its bounded body transfer failed.
};
// No DNS except localhost -> 127.0.0.1; RFC1918/ULA requires verified TLS.
std::string ValidateEndpoint(const std::string& InUrl, EndpointPolicy InPolicy);
struct Request {
    std::string Endpoint, Method = "GET", Path = "/", Body, Bearer;
    std::string Accept = "application/json";
    EndpointPolicy Policy = EndpointPolicy::LoopbackHttp;
    std::size_t ResponseBytes = 4 * 1024 * 1024;
    int TimeoutMs = 5000;
    std::function<bool()> Cancelled = [] { return false; };
};
struct Response { long Status = 0; std::string Bytes, ContentType; };
// One transfer, no retry/redirect/proxy/netrc. Cancellation affects this connection only.
Response Perform(const Request& InRequest);
}
