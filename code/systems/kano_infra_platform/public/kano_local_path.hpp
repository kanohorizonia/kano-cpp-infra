#pragma once
#include <filesystem>
#include <stdexcept>
#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#endif
namespace kano::platform {
inline std::string PathUtf8(const std::filesystem::path& path) { const auto bytes = path.u8string(); return {bytes.begin(), bytes.end()}; }
// Validate existing ancestors as well as the leaf; missing final components are
// allowed for exclusive installation. This is not a race-proof filesystem sandbox.
inline std::filesystem::path LocalPath(const std::filesystem::path& input) {
    namespace fs = std::filesystem;
    if (!input.is_absolute() || input.empty()) throw std::invalid_argument("An absolute local path is required.");
    if (input.native().find(fs::path::value_type{}) != fs::path::string_type::npos) throw std::invalid_argument("Embedded path terminators are unsupported.");
#ifdef _WIN32
    if (input.native().rfind(L"\\\\", 0) == 0 || input.native().rfind(L"//", 0) == 0) throw std::invalid_argument("Network/device paths are unsupported.");
#endif
    auto path = input.lexically_normal();
    path.make_preferred();
    for (auto current = path; !current.empty(); current = current.parent_path()) {
#ifdef _WIN32
        const auto attrs = GetFileAttributesW(current.c_str());
        if (attrs != INVALID_FILE_ATTRIBUTES && (attrs & FILE_ATTRIBUTE_REPARSE_POINT)) throw std::invalid_argument("Reparse ancestry is unsupported.");
        if (attrs == INVALID_FILE_ATTRIBUTES && GetLastError() != ERROR_FILE_NOT_FOUND && GetLastError() != ERROR_PATH_NOT_FOUND) throw std::invalid_argument("Path ancestry is unavailable.");
#else
        std::error_code error; const auto status = fs::symlink_status(current, error);
        if (error && error != std::errc::no_such_file_or_directory) throw std::invalid_argument("Path ancestry is unavailable.");
        if (fs::is_symlink(status)) throw std::invalid_argument("Symlink ancestry is unsupported.");
#endif
        if (current == current.parent_path()) break;
    }
    return path;
}
}
