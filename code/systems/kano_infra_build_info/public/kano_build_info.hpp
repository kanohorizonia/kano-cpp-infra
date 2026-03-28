#pragma once

#include "kano_build_info.h"

#include <string>
#include <string_view>

namespace kano::infra::build_info {

struct Snapshot {
    std::string version{"unknown"};
    std::string vcs{"unknown"};
    std::string branch{"unknown"};
    std::string revision{"unknown"};
    std::string revisionHashShort{"unknown"};
    std::string revisionHash{"unknown"};
    std::string dirty{"unknown"};
    std::string host{"unknown"};
    std::string ci{"false"};
    std::string context{"local-manual"};
    std::string pipeline{"unknown"};
    std::string toolchain{"unknown"};
    std::string generator{"unknown"};
    std::string preset{"unknown-preset"};
    std::string configuration{"unknown"};
    std::string platform{"unknown"};
};

struct Fallbacks {
    std::string_view version{"unknown"};
    std::string_view vcs{"unknown"};
    std::string_view branch{"unknown"};
    std::string_view revision{"unknown"};
    std::string_view revisionHashShort{"unknown"};
    std::string_view revisionHash{"unknown"};
    std::string_view dirty{"unknown"};
    std::string_view host{"unknown"};
    std::string_view ci{"false"};
    std::string_view context{"local-manual"};
    std::string_view pipeline{"unknown"};
    std::string_view toolchain{"unknown"};
    std::string_view generator{"unknown"};
    std::string_view preset{"unknown-preset"};
    std::string_view configuration{"unknown"};
    std::string_view platform{"unknown"};
};

inline auto copy_or_fallback(const char* value, std::string_view fallback) -> std::string {
    if (value != nullptr && value[0] != '\0') {
        return value;
    }
    return std::string(fallback);
}

inline auto discover_snapshot(const Fallbacks& fallbacks = {}) -> Snapshot {
    KanoBuildInfo info = kano_build_info_discover();
    Snapshot out{
        .version = copy_or_fallback(kano_build_info_get_version(info), fallbacks.version),
        .vcs = copy_or_fallback(kano_build_info_get_vcs_status(info), fallbacks.vcs),
        .branch = copy_or_fallback(kano_build_info_get_vcs_branch(info), fallbacks.branch),
        .revision = copy_or_fallback(kano_build_info_get_vcs_revision(info), fallbacks.revision),
        .revisionHashShort = std::string(fallbacks.revisionHashShort),
        .revisionHash = std::string(fallbacks.revisionHash),
        .dirty = copy_or_fallback(kano_build_info_get_vcs_status(info), fallbacks.dirty),
        .host = std::string(fallbacks.host),
        .ci = std::string(fallbacks.ci),
        .context = std::string(fallbacks.context),
        .pipeline = std::string(fallbacks.pipeline),
        .toolchain = copy_or_fallback(kano_build_info_get_compiler(info), fallbacks.toolchain),
        .generator = std::string(fallbacks.generator),
        .preset = std::string(fallbacks.preset),
        .configuration = copy_or_fallback(kano_build_info_get_build_type(info), fallbacks.configuration),
        .platform = std::string(fallbacks.platform),
    };
    kano_build_info_free(info);
    return out;
}

inline auto summarize(const Snapshot& snapshot) -> std::string {
    std::string out;
    out.reserve(256);
    out += "version=";
    out += snapshot.version;
    out += " vcs=";
    out += snapshot.vcs;
    out += " branch=";
    out += snapshot.branch;
    out += " rev=";
    out += snapshot.revision;
    out += " hash_short=";
    out += snapshot.revisionHashShort;
    out += " hash=";
    out += snapshot.revisionHash;
    out += " dirty=";
    out += snapshot.dirty;
    out += " host=";
    out += snapshot.host;
    out += " platform=";
    out += snapshot.platform;
    out += " toolchain=";
    out += snapshot.toolchain;
    out += " generator=";
    out += snapshot.generator;
    out += " preset=";
    out += snapshot.preset;
    out += " config=";
    out += snapshot.configuration;
    out += " ci=";
    out += snapshot.ci;
    out += " context=";
    out += snapshot.context;
    out += " pipeline=";
    out += snapshot.pipeline;
    return out;
}

} // namespace kano::infra::build_info
