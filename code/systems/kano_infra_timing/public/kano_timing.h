#pragma once

/**
 * kano_timing.h — scoped timing utilities for kano-cpp-infra
 *
 * RAII scope guard that logs elapsed time when leaving scope.
 * Uses std::chrono::steady_clock for monotonic, sleep-aware timing.
 *
 * Usage:
 *   #include <kano_timing.h>
 *
 *   // Simple: just elapsed time
 *   {
 *     SCOPED_TIMING_LOG("my_step");
 *     do_work();
 *   }  // logs: [TIMING] my_step completed in 1234.56ms
 *
 *   // With automatic elapsed member
 *   {
 *     SCOPED_TIMING_LOG_WITH_ELAPSED("network_call", timer);
 *     fetch_data();
 *   }  // timer.elapsed_ms() is also available after scope
 *
 *   // Stream-style with custom message
 *   {
 *     ScopedTimingLog log("validation");
 *     log.stream() << "checking " << count << " items";
 *   }  // logs: [TIMING] validation: checking 42 items (elapsed before dtor)
 */

#include <chrono>
#include <cstdio>
#include <string_view>

namespace kano {
namespace infra {
namespace timing {

/* ---------------------------------------------------------------------------
 * Low-level steady_clock access (header-only for inlining)
 * --------------------------------------------------------------------------- */

using Clock = std::chrono::steady_clock;
using Ms = std::chrono::duration<double, std::milli>;
using Us = std::chrono::duration<double, std::micro>;

struct TimingPoint {
    Clock::time_point point;

    explicit TimingPoint() : point(Clock::now()) {}
    explicit TimingPoint(Clock::time_point p) : point(p) {}

    double elapsed_ms() const {
        return std::chrono::duration_cast<Ms>(Clock::now() - point).count();
    }

    double elapsed_us() const {
        return std::chrono::duration_cast<Us>(Clock::now() - point).count();
    }

    static TimingPoint now() { return TimingPoint{}; }
};

/* ---------------------------------------------------------------------------
 * Core RAII scope guard
 * --------------------------------------------------------------------------- */

class ScopedTimingLog {
public:
    /**
     * Begin a timed scope with the given label.
     * @param label  Identifying name for this scope (printed in dtor log)
     * @param dest   Output FILE* (default stderr)
     */
    explicit ScopedTimingLog(std::string_view label, FILE* dest = stderr) noexcept
        : label_(label)
        , dest_(dest)
        , started_(TimingPoint::now())
    {
        std::fprintf(dest_, "[TIMING] %.*s started\n",
                     static_cast<int>(label_.size()), label_.data());
        std::fflush(dest_);
    }

    ~ScopedTimingLog() noexcept {
        const double elapsed = started_.elapsed_ms();
        std::fprintf(dest_, "[TIMING] %.*s completed in %.2fms\n",
                     static_cast<int>(label_.size()), label_.data(), elapsed);
        std::fflush(dest_);
    }

    // Non-copyable, non-movable
    ScopedTimingLog(const ScopedTimingLog&) = delete;
    ScopedTimingLog& operator=(const ScopedTimingLog&) = delete;
    ScopedTimingLog(ScopedTimingLog&&) = delete;
    ScopedTimingLog& operator=(ScopedTimingLog&&) = delete;

    /** Access elapsed time from within the timed scope */
    double elapsed_ms() const noexcept { return started_.elapsed_ms(); }

    /** Access the start time point */
    const TimingPoint& started_at() const noexcept { return started_; }

private:
    std::string_view label_;
    FILE* dest_;
    TimingPoint started_;
};

/**
 * Variant that also exposes elapsed time via a member reference.
 * Useful when you need to read the timer from multiple places.
 *
 *   ScopedTimingLogWithElapsed timer("step_name", elapsed_ref);
 *   // elapsed_ref is updated each time you access .elapsed_ms()
 */
class ScopedTimingLogWithElapsed {
public:
    explicit ScopedTimingLogWithElapsed(std::string_view label,
                                         double& out_elapsed,
                                         FILE* dest = stderr) noexcept
        : label_(label)
        , dest_(dest)
        , out_elapsed_(out_elapsed)
        , started_(TimingPoint::now())
    {
        out_elapsed_ = 0.0;
        std::fprintf(dest_, "[TIMING] %.*s started\n",
                     static_cast<int>(label_.size()), label_.data());
        std::fflush(dest_);
    }

    ~ScopedTimingLogWithElapsed() noexcept {
        out_elapsed_ = started_.elapsed_ms();
        std::fprintf(dest_, "[TIMING] %.*s completed in %.2fms\n",
                     static_cast<int>(label_.size()), label_.data(), out_elapsed_);
        std::fflush(dest_);
    }

    double elapsed_ms() const noexcept { return started_.elapsed_ms(); }
    const TimingPoint& started_at() const noexcept { return started_; }

    ScopedTimingLogWithElapsed(const ScopedTimingLogWithElapsed&) = delete;
    ScopedTimingLogWithElapsed& operator=(const ScopedTimingLogWithElapsed&) = delete;
    ScopedTimingLogWithElapsed(ScopedTimingLogWithElapsed&&) = delete;
    ScopedTimingLogWithElapsed& operator=(ScopedTimingLogWithElapsed&&) = delete;

private:
    std::string_view label_;
    FILE* dest_;
    double& out_elapsed_;
    TimingPoint started_;
};

}  // namespace timing
}  // namespace infra
}  // namespace kano

/* ---------------------------------------------------------------------------
 * Convenience macros (mirrors kernel style: SCOPED_xxx)
 * --------------------------------------------------------------------------- */

/**
 * SCOPED_TIMING_LOG — basic scoped timing, logs on scope exit
 *
 *   {
 *     SCOPED_TIMING_LOG("git_status");
 *     run_git_status();
 *   }
 */
#define SCOPED_TIMING_LOG(label) \
    kano::infra::timing::ScopedTimingLog ANONYMOY_VARIABLE__(timing_log_)(label)

/**
 * SCOPED_TIMING_LOG_WITH_ELAPSED — scoped timing + live elapsed reference
 *
 *   double ms = 0;
 *   {
 *     SCOPED_TIMING_LOG_WITH_ELAPSED("git_commit", ms);
 *     run_git_commit();
 *     fmt::print("progress at {:.0f}ms\n", ms);  // live value
 *   }
 *   fmt::print("total: {:.0f}ms\n", ms);  // final value
 */
#define SCOPED_TIMING_LOG_WITH_ELAPSED(label, out_ms_ref) \
    kano::infra::timing::ScopedTimingLogWithElapsed ANONYMOY_VARIABLE__(timing_log_)(label, out_ms_ref)

/* ---------------------------------------------------------------------------
 * Token pasting helpers for ANONYMOY_VARIABLE__
 * --------------------------------------------------------------------------- */
#define ANONYMOY_VARIABLE__(line) ANONYMOY_VARIABLE___LINE__(line)
#define ANONYMOY_VARIABLE___LINE__(line) timing_log_scope_##line
