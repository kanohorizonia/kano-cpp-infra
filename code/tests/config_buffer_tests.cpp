#include <kano_config.h>
#include <kano_unattended.hpp>

#include <cstring>
#include <chrono>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>

namespace {
using Config = std::unique_ptr<KanoConfigImpl, decltype(&kano_config_free)>;

void Check(bool bCondition, const char* InMessage) {
    if (!bCondition) throw std::runtime_error(InMessage);
}

Config Parse(const std::string& InContent) {
    return Config(kano_config_load_buffer(InContent.data(), InContent.size()), &kano_config_free);
}

void CheckRejected(const std::string& InContent) {
    Check(!Parse(InContent), "Invalid or oversized buffer was accepted");
}
}

int main() {
    kano::infra::ConfigureUnattendedExecutionIfRequested();
    try {
        std::string original = "version = 1\n[runtime]\ninterpreter = 'detached/python'\n";
        const auto config = Parse(original);
        Check(static_cast<bool>(config), "Scalar buffer parsing failed");
        original.assign(original.size(), 'x');
        int version = 0;
        Check(kano_config_get_int(config.get(), "version", &version) && version == 1,
              "Parsed buffer must own its values independently of source bytes");
        Check(std::strcmp(kano_config_get(config.get(), "runtime.interpreter"), "detached/python") == 0,
              "Typed string accessor failed");
        Check(!kano_config_reload(config.get()), "Buffer-backed config must not reload a file");
        Check(!kano_config_load_buffer(nullptr, 0), "Null buffer must fail");
        CheckRejected(std::string("a = 1\0b = 2", 11));
        CheckRejected(std::string(4096, 'x'));
        CheckRejected("[" + std::string(256, 'x') + "]\na = 1\n");
        CheckRejected(std::string(1024, 'x') + " = 1\n");
        CheckRejected("[" + std::string(254, 's') + "]\n" + std::string(769, 'k') + " = 1\n");
        const auto literal = Parse("version = 1\r\n[local.services.\"synthetic\"]\r\nworker = 'worker.json'\r\n");
        Check(static_cast<bool>(literal), "Quoted sections and CRLF parsing failed");
        const auto path = std::filesystem::temp_directory_path() /
            ("kano-infra-config-" + std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()) + ".toml");
        { std::ofstream stream(path); stream << "version = 1\n"; }
        const Config fileConfig(kano_config_load(path.string().c_str()), &kano_config_free);
        std::filesystem::remove(path);
        Check(fileConfig && kano_config_get_int(fileConfig.get(), "version", &version) && version == 1,
              "Existing file-backed config API must remain usable");
        std::cout << "Shared immutable config buffer: PASS\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
