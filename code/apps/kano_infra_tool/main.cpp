#include <algorithm>
#include <cctype>
#include <cstdint>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <map>
#include <cstdio>
#include <regex>
#include <sstream>
#include <string>
#include <string_view>
#include <vector>

#ifdef _WIN32
#include <crtdbg.h>
#include <windows.h>
#endif

#include <json/json.h>

#include "kano_process.h"

namespace fs = std::filesystem;

namespace {

void ConfigureNoninteractiveErrorHandling() {
#ifdef _WIN32
    SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX | SEM_NOOPENFILEERRORBOX);
    SetThreadErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX | SEM_NOOPENFILEERRORBOX, nullptr);

    SetUnhandledExceptionFilter([](EXCEPTION_POINTERS*) -> LONG {
        std::fputs("Fatal native exception.\n", stderr);
        std::fflush(stderr);
        return EXCEPTION_EXECUTE_HANDLER;
    });

    _set_error_mode(_OUT_TO_STDERR);
    _set_invalid_parameter_handler(
        [](const wchar_t*, const wchar_t*, const wchar_t*, unsigned int, uintptr_t) {});
    _set_thread_local_invalid_parameter_handler(
        [](const wchar_t*, const wchar_t*, const wchar_t*, unsigned int, uintptr_t) {});
    _set_abort_behavior(0, _WRITE_ABORT_MSG | _CALL_REPORTFAULT);

    _CrtSetReportMode(_CRT_WARN, _CRTDBG_MODE_FILE);
    _CrtSetReportFile(_CRT_WARN, _CRTDBG_FILE_STDERR);
    _CrtSetReportMode(_CRT_ERROR, _CRTDBG_MODE_FILE);
    _CrtSetReportFile(_CRT_ERROR, _CRTDBG_FILE_STDERR);
    _CrtSetReportMode(_CRT_ASSERT, _CRTDBG_MODE_FILE);
    _CrtSetReportFile(_CRT_ASSERT, _CRTDBG_FILE_STDERR);
#endif
}

struct TestSuite {
    std::string Name = "unnamed";
    int Tests = 0;
    int Failures = 0;
    int Errors = 0;
    int Skipped = 0;
    double Time = 0.0;
};

struct TestCase {
    std::string SuiteName;
    std::string Name = "unnamed";
    std::string Time = "0";
    bool bFailure = false;
    bool bError = false;
    bool bSkipped = false;
};

std::string ReadText(const fs::path& Path) {
    std::ifstream In(Path, std::ios::binary);
    if (!In) {
        throw std::runtime_error("failed to read file: " + Path.string());
    }
    std::ostringstream Buffer;
    Buffer << In.rdbuf();
    return Buffer.str();
}

void WriteText(const fs::path& Path, const std::string& Text) {
    fs::create_directories(Path.parent_path());
    std::ofstream Out(Path, std::ios::binary);
    if (!Out) {
        throw std::runtime_error("failed to write file: " + Path.string());
    }
    Out << Text;
}

std::string EscapeXml(const std::string& Value) {
    std::string Out;
    Out.reserve(Value.size());
    for (char Ch : Value) {
        switch (Ch) {
        case '&': Out += "&amp;"; break;
        case '<': Out += "&lt;"; break;
        case '>': Out += "&gt;"; break;
        case '"': Out += "&quot;"; break;
        case '\'': Out += "&apos;"; break;
        default: Out += Ch; break;
        }
    }
    return Out;
}

std::string EscapeHtml(const std::string& Value) {
    return EscapeXml(Value);
}

std::string EscapeJson(const std::string& Value) {
    Json::Value Node(Value);
    Json::StreamWriterBuilder Builder;
    Builder["indentation"] = "";
    return Json::writeString(Builder, Node);
}

std::string NormalizePathText(const std::string& In) {
    std::string Out = In;
    std::replace(Out.begin(), Out.end(), '\\', '/');
    return Out;
}

std::string SlurpAttribute(const std::string& Tag, const std::string& Name) {
    const std::regex Pattern(Name + R"(\s*=\s*(['"])(.*?)\1)", std::regex::icase);
    std::smatch Match;
    if (std::regex_search(Tag, Match, Pattern)) {
        std::string Value = Match[2].str();
        Value = std::regex_replace(Value, std::regex("&quot;"), "\"");
        Value = std::regex_replace(Value, std::regex("&apos;"), "'");
        Value = std::regex_replace(Value, std::regex("&lt;"), "<");
        Value = std::regex_replace(Value, std::regex("&gt;"), ">");
        Value = std::regex_replace(Value, std::regex("&amp;"), "&");
        return Value;
    }
    return {};
}

int ToInt(const std::string& Value, int DefaultValue = 0) {
    if (Value.empty()) {
        return DefaultValue;
    }
    try {
        return static_cast<int>(std::stod(Value));
    } catch (...) {
        return DefaultValue;
    }
}

double ToDouble(const std::string& Value, double DefaultValue = 0.0) {
    if (Value.empty()) {
        return DefaultValue;
    }
    try {
        return std::stod(Value);
    } catch (...) {
        return DefaultValue;
    }
}

std::vector<TestSuite> ParseSuites(const std::string& Xml) {
    std::vector<TestSuite> Suites;
    const std::regex Pattern(R"(<testsuite\b([^>]*)>)", std::regex::icase);
    for (std::sregex_iterator It(Xml.begin(), Xml.end(), Pattern), End; It != End; ++It) {
        const std::string Tag = (*It)[1].str();
        TestSuite Suite;
        Suite.Name = SlurpAttribute(Tag, "name");
        if (Suite.Name.empty()) {
            Suite.Name = "unnamed";
        }
        Suite.Tests = ToInt(SlurpAttribute(Tag, "tests"));
        Suite.Failures = ToInt(SlurpAttribute(Tag, "failures"));
        Suite.Errors = ToInt(SlurpAttribute(Tag, "errors"));
        Suite.Skipped = ToInt(SlurpAttribute(Tag, "skipped"));
        Suite.Time = ToDouble(SlurpAttribute(Tag, "time"));
        Suites.push_back(Suite);
    }
    return Suites;
}

std::vector<TestCase> ParseCases(const std::string& Xml) {
    std::vector<TestCase> Cases;
    const std::regex SuitePattern(R"(<testsuite\b([^>]*)>([\s\S]*?)</testsuite>)", std::regex::icase);
    const std::regex CasePattern(R"(<testcase\b([^>]*)(?:/>|>([\s\S]*?)</testcase>))", std::regex::icase);
    for (std::sregex_iterator SuiteIt(Xml.begin(), Xml.end(), SuitePattern), SuiteEnd; SuiteIt != SuiteEnd; ++SuiteIt) {
        const std::string SuiteTag = (*SuiteIt)[1].str();
        const std::string SuiteBody = (*SuiteIt)[2].str();
        std::string SuiteName = SlurpAttribute(SuiteTag, "name");
        if (SuiteName.empty()) {
            SuiteName = "unnamed";
        }
        for (std::sregex_iterator CaseIt(SuiteBody.begin(), SuiteBody.end(), CasePattern), CaseEnd; CaseIt != CaseEnd; ++CaseIt) {
            const std::string CaseTag = (*CaseIt)[1].str();
            const std::string CaseBody = CaseIt->size() > 2 ? (*CaseIt)[2].str() : std::string();
            TestCase Case;
            Case.SuiteName = SuiteName;
            Case.Name = SlurpAttribute(CaseTag, "name");
            if (Case.Name.empty()) {
                Case.Name = "unnamed";
            }
            Case.Time = SlurpAttribute(CaseTag, "time");
            if (Case.Time.empty()) {
                Case.Time = "0";
            }
            Case.bFailure = CaseBody.find("<failure") != std::string::npos;
            Case.bError = CaseBody.find("<error") != std::string::npos;
            Case.bSkipped = CaseBody.find("<skipped") != std::string::npos;
            Cases.push_back(Case);
        }
    }
    if (!Cases.empty()) {
        return Cases;
    }
    const std::regex TopCasePattern(R"(<testcase\b([^>]*)(?:/>|>([\s\S]*?)</testcase>))", std::regex::icase);
    for (std::sregex_iterator It(Xml.begin(), Xml.end(), TopCasePattern), End; It != End; ++It) {
        const std::string CaseTag = (*It)[1].str();
        const std::string CaseBody = It->size() > 2 ? (*It)[2].str() : std::string();
        TestCase Case;
        Case.SuiteName = "unnamed";
        Case.Name = SlurpAttribute(CaseTag, "name");
        if (Case.Name.empty()) {
            Case.Name = "unnamed";
        }
        Case.Time = SlurpAttribute(CaseTag, "time");
        if (Case.Time.empty()) {
            Case.Time = "0";
        }
        Case.bFailure = CaseBody.find("<failure") != std::string::npos;
        Case.bError = CaseBody.find("<error") != std::string::npos;
        Case.bSkipped = CaseBody.find("<skipped") != std::string::npos;
        Cases.push_back(Case);
    }
    return Cases;
}

int CoberturaLinesValid(const fs::path& XmlPath) {
    try {
        const std::string Xml = ReadText(XmlPath);
        std::smatch Match;
        if (std::regex_search(Xml, Match, std::regex(R"(<coverage\b([^>]*)>)", std::regex::icase))) {
            return ToInt(SlurpAttribute(Match[1].str(), "lines-valid"));
        }
    } catch (...) {
    }
    return 0;
}

int CoberturaLinesCovered(const fs::path& XmlPath) {
    try {
        const std::string Xml = ReadText(XmlPath);
        std::smatch Match;
        if (std::regex_search(Xml, Match, std::regex(R"(<coverage\b([^>]*)>)", std::regex::icase))) {
            return ToInt(SlurpAttribute(Match[1].str(), "lines-covered"));
        }
    } catch (...) {
    }
    return 0;
}

std::string CoberturaLineRate(const fs::path& XmlPath) {
    try {
        const std::string Xml = ReadText(XmlPath);
        std::smatch Match;
        if (std::regex_search(Xml, Match, std::regex(R"(<coverage\b([^>]*)>)", std::regex::icase))) {
            return SlurpAttribute(Match[1].str(), "line-rate");
        }
    } catch (...) {
    }
    return "0";
}

int CoberturaPackageCount(const fs::path& XmlPath) {
    try {
        const std::string Xml = ReadText(XmlPath);
        const std::regex PackagePattern(R"(<package\b)", std::regex::icase);
        return static_cast<int>(std::distance(
            std::sregex_iterator(Xml.begin(), Xml.end(), PackagePattern),
            std::sregex_iterator()));
    } catch (...) {
    }
    return 0;
}

Json::Value ParseJsonFile(const fs::path& Path) {
    Json::CharReaderBuilder Builder;
    Json::Value Root;
    std::string Errors;
    std::istringstream In(ReadText(Path));
    if (!Json::parseFromStream(Builder, In, &Root, &Errors)) {
        throw std::runtime_error("failed to parse json " + Path.string() + ": " + Errors);
    }
    return Root;
}

Json::Value ParseJsonTextOrObject(const std::string& Text) {
    if (Text.empty()) {
        return Json::Value(Json::objectValue);
    }
    Json::CharReaderBuilder Builder;
    Json::Value Root;
    std::string Errors;
    std::istringstream In(Text);
    if (!Json::parseFromStream(Builder, In, &Root, &Errors) || !Root.isObject()) {
        throw std::runtime_error("failed to parse JSON object: " + Errors);
    }
    return Root;
}

std::string WriteJsonString(const Json::Value& Value) {
    Json::StreamWriterBuilder Builder;
    Builder["indentation"] = "  ";
    return Json::writeString(Builder, Value);
}

std::string WriteJsonCompact(const Json::Value& Value) {
    Json::StreamWriterBuilder Builder;
    Builder["indentation"] = "";
    return Json::writeString(Builder, Value);
}

std::string GetEnvString(const char* Name) {
    if (const char* Value = std::getenv(Name)) {
        return Value;
    }
    return {};
}

void SetEnvString(const std::string& Name, const std::string& Value) {
#ifdef _WIN32
    _putenv_s(Name.c_str(), Value.c_str());
#else
    setenv(Name.c_str(), Value.c_str(), 1);
#endif
}

void UnsetEnvString(const std::string& Name) {
#ifdef _WIN32
    _putenv_s(Name.c_str(), "");
#else
    unsetenv(Name.c_str());
#endif
}

struct EnvRestore {
    std::map<std::string, std::string> Previous;
    std::vector<std::string> Missing;

    void Set(const std::string& Name, const std::string& Value) {
        if (Previous.find(Name) == Previous.end() && std::find(Missing.begin(), Missing.end(), Name) == Missing.end()) {
            if (const char* Existing = std::getenv(Name.c_str())) {
                Previous[Name] = Existing;
            } else {
                Missing.push_back(Name);
            }
        }
        SetEnvString(Name, Value);
    }

    ~EnvRestore() {
        for (const auto& Item : Previous) {
            SetEnvString(Item.first, Item.second);
        }
        for (const auto& Name : Missing) {
            UnsetEnvString(Name);
        }
    }
};

std::string Lower(std::string Value) {
    std::transform(Value.begin(), Value.end(), Value.begin(), [](unsigned char Ch) { return static_cast<char>(std::tolower(Ch)); });
    return Value;
}

std::vector<std::string> SplitCsv(const std::string& Value) {
    std::vector<std::string> Out;
    std::stringstream Stream(Value);
    std::string Item;
    while (std::getline(Stream, Item, ',')) {
        Item.erase(Item.begin(), std::find_if(Item.begin(), Item.end(), [](unsigned char Ch) { return !std::isspace(Ch); }));
        Item.erase(std::find_if(Item.rbegin(), Item.rend(), [](unsigned char Ch) { return !std::isspace(Ch); }).base(), Item.end());
        if (!Item.empty()) {
            Out.push_back(Item);
        }
    }
    return Out;
}

Json::Value CsvJsonArray(const std::string& Value) {
    Json::Value Out(Json::arrayValue);
    for (const std::string& Item : SplitCsv(Value)) {
        Out.append(Item);
    }
    return Out;
}

std::vector<std::string> ExtractTags(const std::string& Name) {
    std::vector<std::string> Tags;
    const std::regex Pattern(R"(\[([^\]]+)\])");
    for (std::sregex_iterator It(Name.begin(), Name.end(), Pattern), End; It != End; ++It) {
        std::string Tag = (*It)[1].str();
        Tag.erase(Tag.begin(), std::find_if(Tag.begin(), Tag.end(), [](unsigned char Ch) { return !std::isspace(Ch); }));
        Tag.erase(std::find_if(Tag.rbegin(), Tag.rend(), [](unsigned char Ch) { return !std::isspace(Ch); }).base(), Tag.end());
        if (!Tag.empty()) {
            Tags.push_back(Tag);
        }
    }
    return Tags;
}

std::string ExtractPrefixedTag(const std::vector<std::string>& Tags, const std::string& Prefix, const std::string& DefaultValue) {
    for (const std::string& Tag : Tags) {
        if (Tag.rfind(Prefix, 0) == 0) {
            std::string Value = Tag.substr(Prefix.size());
            Value.erase(Value.begin(), std::find_if(Value.begin(), Value.end(), [](unsigned char Ch) { return !std::isspace(Ch); }));
            Value.erase(std::find_if(Value.rbegin(), Value.rend(), [](unsigned char Ch) { return !std::isspace(Ch); }).base(), Value.end());
            return Value;
        }
    }
    return DefaultValue;
}

std::string StripTagSuffix(const std::string& Name) {
    std::string Out = std::regex_replace(Name, std::regex(R"(\s*\[[^\]]+\]\s*)"), " ");
    Out.erase(Out.begin(), std::find_if(Out.begin(), Out.end(), [](unsigned char Ch) { return !std::isspace(Ch); }));
    Out.erase(std::find_if(Out.rbegin(), Out.rend(), [](unsigned char Ch) { return !std::isspace(Ch); }).base(), Out.end());
    return Out;
}

std::string GetString(const Json::Value& Node, const std::string& Key, const std::string& DefaultValue = "") {
    return Node.isMember(Key) && Node[Key].isString() ? Node[Key].asString() : DefaultValue;
}

std::string GetStringEither(const Json::Value& Node, const Json::Value& Defaults, const std::string& Key, const std::string& DefaultValue = "") {
    std::string Value = GetString(Node, Key, "");
    if (!Value.empty()) {
        return Value;
    }
    return GetString(Defaults, Key, DefaultValue);
}

std::vector<fs::path> SortedFilesWithExtension(const fs::path& Dir, const std::string& Ext) {
    std::vector<fs::path> Files;
    if (!fs::is_directory(Dir)) {
        return Files;
    }
    for (const auto& Entry : fs::directory_iterator(Dir)) {
        if (Entry.is_regular_file() && Entry.path().extension() == Ext) {
            Files.push_back(Entry.path());
        }
    }
    std::sort(Files.begin(), Files.end());
    return Files;
}

std::vector<fs::path> SortedCoberturaFiles(const fs::path& Dir) {
    std::vector<fs::path> Files;
    if (!fs::is_directory(Dir)) {
        return Files;
    }
    for (const auto& Entry : fs::directory_iterator(Dir)) {
        if (!Entry.is_regular_file()) {
            continue;
        }
        const std::string Name = Entry.path().filename().string();
        if (Name.size() >= 14 && Name.rfind(".cobertura.xml") == Name.size() - 14) {
            Files.push_back(Entry.path());
        }
    }
    std::sort(Files.begin(), Files.end());
    return Files;
}

int CommandGenerateBddMetadata(const std::vector<std::string>& Args) {
    if (Args.size() != 3) {
        std::cerr << "usage: generate-bdd-metadata <tests.xml> <bdd-dir> <test-binary-name>\n";
        return 2;
    }
    const fs::path XmlPath = Args[0];
    const fs::path OutDir = Args[1];
    const std::string BinaryName = Args[2];
    if (!fs::is_regular_file(XmlPath)) {
        std::cerr << "tests.xml not found: " << XmlPath.string() << "\n";
        return 1;
    }
    fs::create_directories(OutDir);
    for (const TestCase& Case : ParseCases(ReadText(XmlPath))) {
        const std::vector<std::string> Tags = ExtractTags(Case.Name);
        const std::string ScenarioId = ExtractPrefixedTag(Tags, "scenario:", "");
        if (ScenarioId.empty()) {
            continue;
        }
        const std::string Feature = ExtractPrefixedTag(Tags, "feature:", "unknown");
        const std::string ScenarioTitle = StripTagSuffix(Case.Name);
        const bool bFeatured = std::find(Tags.begin(), Tags.end(), "featured") != Tags.end();
        const fs::path OutPath = OutDir / (ScenarioId + ".json");
        if (fs::exists(OutPath)) {
            continue;
        }
        Json::Value Root(Json::objectValue);
        Root["style"] = "bdd";
        Root["layer"] = "functional";
        Root["feature"] = Feature;
        Root["scenarioId"] = ScenarioId;
        Root["scenarioTitle"] = ScenarioTitle;
        Root["featured"] = bFeatured;
        Root["docVisibility"] = bFeatured ? "public" : "internal";
        Root["automationStatus"] = "automated";
        Root["diagramType"] = "flowchart";
        Root["sourceTestName"] = ScenarioTitle;
        Root["sourceTestBinary"] = BinaryName;
        Root["tags"] = Json::Value(Json::arrayValue);
        for (const std::string& Tag : Tags) {
            Root["tags"].append(Tag);
        }
        Root["steps"] = Json::Value(Json::arrayValue);
        Root["steps"].append("Given scenario " + ScenarioId + " preconditions");
        Root["steps"].append("When " + ScenarioTitle + " executes");
        Root["steps"].append("Then expected outcome is observed");
        Root["actors"] = Json::Value(Json::arrayValue);
        Root["actors"].append("user");
        Root["actors"].append("kano-git");
        Root["traces"] = Json::Value(Json::arrayValue);
        Root["relatedArtifacts"] = Json::Value(Json::arrayValue);
        Root["environment"] = Json::Value(Json::objectValue);
        Root["lane"] = "";
        Root["project"] = "kano-git-master-skill";
        Root["domain"] = Feature;
        WriteText(OutPath, WriteJsonString(Root) + "\n");
    }
    return 0;
}

int CommandRenderJunitReport(const std::vector<std::string>& Args) {
    if (Args.size() != 3) {
        std::cerr << "usage: render-junit-report <junit-xml> <output-dir> <title>\n";
        return 2;
    }
    const fs::path JunitXml = Args[0];
    const fs::path OutputDir = Args[1];
    const std::string Title = Args[2];
    fs::create_directories(OutputDir);

    std::vector<TestSuite> Suites;
    if (fs::is_regular_file(JunitXml)) {
        Suites = ParseSuites(ReadText(JunitXml));
    }

    int TotalTests = 0;
    int TotalFailures = 0;
    int TotalErrors = 0;
    int TotalSkipped = 0;
    double TotalTime = 0.0;
    for (const TestSuite& Suite : Suites) {
        TotalTests += Suite.Tests;
        TotalFailures += Suite.Failures;
        TotalErrors += Suite.Errors;
        TotalSkipped += Suite.Skipped;
        TotalTime += Suite.Time;
    }
    const int PassedTotal = std::max(TotalTests - TotalFailures - TotalErrors - TotalSkipped, 0);
    std::string Status = "Passed";
    if (TotalFailures || TotalErrors) {
        Status = "Failed";
    } else if (TotalSkipped) {
        Status = "Warnings";
    }

    Json::Value Summary(Json::objectValue);
    Summary["title"] = Title;
    Summary["summary"] = Status + ": " + std::to_string(PassedTotal) + "/" + std::to_string(TotalTests) + " passed";
    Summary["stats"] = Json::Value(Json::arrayValue);
    const auto AddStat = [&](const std::string& Label, const std::string& Value) {
        Json::Value Row(Json::arrayValue);
        Row.append(Label);
        Row.append(Value);
        Summary["stats"].append(Row);
    };
    AddStat("Total tests", std::to_string(TotalTests));
    AddStat("Passed", std::to_string(PassedTotal));
    AddStat("Failures", std::to_string(TotalFailures));
    AddStat("Errors", std::to_string(TotalErrors));
    AddStat("Skipped", std::to_string(TotalSkipped));
    {
        std::ostringstream S;
        S.setf(std::ios::fixed);
        S.precision(3);
        S << TotalTime;
        AddStat("Duration (s)", S.str());
    }
    WriteText(OutputDir / "summary.json", WriteJsonString(Summary));

    std::ostringstream Rows;
    Rows.setf(std::ios::fixed);
    Rows.precision(3);
    if (Suites.empty()) {
        Rows << "<tr><td colspan=\"7\">No JUnit suites found.</td></tr>";
    } else {
        for (const TestSuite& Suite : Suites) {
            const int Passed = std::max(Suite.Tests - Suite.Failures - Suite.Errors - Suite.Skipped, 0);
            Rows << "<tr><td>" << EscapeHtml(Suite.Name) << "</td><td>" << Suite.Tests << "</td><td>" << Passed << "</td>"
                 << "<td>" << Suite.Failures << "</td><td>" << Suite.Errors << "</td><td>" << Suite.Skipped << "</td>"
                 << "<td>" << Suite.Time << "</td></tr>";
        }
    }

    std::ostringstream Page;
    Page << "<!doctype html>\n<html lang=\"en\">\n<head>\n  <meta charset=\"utf-8\">\n"
         << "  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n"
         << "  <title>" << EscapeHtml(Title) << "</title>\n"
         << "  <style>\n"
         << "    :root { color-scheme: dark; --bg: #0b1020; --panel: #121a31; --text: #edf2ff; --muted: #9fb0d8; --accent: #6a8cff; --border: #2a3557; }\n"
         << "    body { margin: 0; font-family: Inter, Segoe UI, Arial, sans-serif; background: var(--bg); color: var(--text); }\n"
         << "    main { max-width: 1100px; margin: 0 auto; padding: 32px 20px 48px; }\n"
         << "    .summary { display: grid; grid-template-columns: repeat(auto-fit, minmax(140px, 1fr)); gap: 12px; margin: 20px 0 28px; }\n"
         << "    .card, table { background: var(--panel); border: 1px solid var(--border); border-radius: 12px; }\n"
         << "    .card { padding: 14px 16px; }\n"
         << "    .label { color: var(--muted); font-size: 12px; text-transform: uppercase; letter-spacing: .08em; }\n"
         << "    .value { font-size: 24px; font-weight: 700; margin-top: 8px; }\n"
         << "    table { width: 100%; border-collapse: collapse; overflow: hidden; }\n"
         << "    th, td { padding: 10px 12px; border-bottom: 1px solid var(--border); text-align: left; }\n"
         << "    th { color: var(--muted); font-size: 12px; text-transform: uppercase; letter-spacing: .08em; }\n"
         << "    tr:last-child td { border-bottom: 0; }\n"
         << "    .footer { margin-top: 18px; color: var(--muted); font-size: 13px; }\n"
         << "    a { color: var(--accent); }\n"
         << "  </style>\n</head>\n<body>\n  <main>\n"
         << "    <h1>" << EscapeHtml(Title) << "</h1>\n"
         << "    <p>" << EscapeHtml(Summary["summary"].asString()) << "</p>\n"
         << "    <div class=\"summary\">\n";
    for (const auto& Stat : Summary["stats"]) {
        Page << "      <div class=\"card\"><div class=\"label\">" << EscapeHtml(Stat[0].asString())
             << "</div><div class=\"value\">" << EscapeHtml(Stat[1].asString()) << "</div></div>\n";
    }
    Page << "    </div>\n"
         << "    <table>\n"
         << "      <thead><tr><th>Suite</th><th>Tests</th><th>Passed</th><th>Failures</th><th>Errors</th><th>Skipped</th><th>Duration (s)</th></tr></thead>\n"
         << "      <tbody>" << Rows.str() << "</tbody>\n"
         << "    </table>\n"
         << "    <p class=\"footer\">Source XML: <code>" << EscapeHtml(JunitXml.filename().string()) << "</code></p>\n"
         << "  </main>\n</body>\n</html>\n";
    WriteText(OutputDir / "index.html", Page.str());
    return 0;
}

int CommandMergeJunitDir(const std::vector<std::string>& Args) {
    if (Args.size() != 2) {
        std::cerr << "usage: merge-junit-dir <input-dir> <output-xml>\n";
        return 2;
    }
    const fs::path InputDir = Args[0];
    const fs::path OutputXml = Args[1];
    std::ostringstream Out;
    Out << "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<testsuites>\n";
    for (const fs::path& Xml : SortedFilesWithExtension(InputDir, ".xml")) {
        const std::string Text = ReadText(Xml);
        const std::regex SuitePattern(R"(<testsuite\b[^>]*(?:/>|>[\s\S]*?</testsuite>))", std::regex::icase);
        for (std::sregex_iterator It(Text.begin(), Text.end(), SuitePattern), End; It != End; ++It) {
            Out << It->str() << "\n";
        }
    }
    Out << "</testsuites>\n";
    WriteText(OutputXml, Out.str());
    return 0;
}

int CommandGatherSummaryJunit(const std::vector<std::string>& Args) {
    if (Args.size() != 3) {
        std::cerr << "usage: gather-summary-junit <reports-root> <input-dir> <output-xml>\n";
        return 2;
    }
    const fs::path ReportsRoot = Args[0];
    const fs::path InputDir = Args[1];
    const fs::path OutputXml = Args[2];
    int RawSuites = 0;
    int RawTests = 0;
    int RawFailures = 0;
    int RawErrors = 0;
    int RawSkipped = 0;
    int RawFiles = 0;
    for (const fs::path& Xml : SortedFilesWithExtension(InputDir, ".xml")) {
        std::vector<TestSuite> Suites;
        try {
            Suites = ParseSuites(ReadText(Xml));
        } catch (...) {
            continue;
        }
        RawFiles += 1;
        for (const TestSuite& Suite : Suites) {
            RawSuites += 1;
            RawTests += Suite.Tests;
            RawFailures += Suite.Failures;
            RawErrors += Suite.Errors;
            RawSkipped += Suite.Skipped;
        }
    }
    std::ostringstream Xml;
    Xml << "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<testsuites>\n"
        << "  <testsuite name=\"linux_coverage_gather\" tests=\"1\" failures=\"0\" errors=\"0\" skipped=\"0\" time=\"0\">\n"
        << "    <testcase classname=\"linux_coverage_gather\" name=\"coverage-gather-succeeded\" time=\"0\"/>\n"
        << "    <system-out>"
        << EscapeXml("pgo-gather completed successfully. rawFiles=" + std::to_string(RawFiles) +
                     " rawSuites=" + std::to_string(RawSuites) +
                     " rawTests=" + std::to_string(RawTests) +
                     " rawFailures=" + std::to_string(RawFailures) +
                     " rawErrors=" + std::to_string(RawErrors) +
                     " rawSkipped=" + std::to_string(RawSkipped) +
                     " rawReports=" + (ReportsRoot / "junit").string())
        << "</system-out>\n"
        << "  </testsuite>\n</testsuites>\n";
    WriteText(OutputXml, Xml.str());
    return 0;
}

int CommandCtestFromJunitDir(const std::vector<std::string>& Args) {
    if (Args.size() != 2) {
        std::cerr << "usage: ctest-from-junit-dir <input-dir> <output-xml>\n";
        return 2;
    }
    const fs::path InputDir = Args[0];
    const fs::path OutputXml = Args[1];
    std::ostringstream Out;
    Out << "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<Site><Testing>\n";
    for (const fs::path& XmlPath : SortedFilesWithExtension(InputDir, ".xml")) {
        std::vector<TestSuite> Suites;
        std::vector<TestCase> Cases;
        try {
            const std::string Text = ReadText(XmlPath);
            Suites = ParseSuites(Text);
            Cases = ParseCases(Text);
        } catch (...) {
            continue;
        }
        std::map<std::string, std::vector<TestCase>> CasesBySuite;
        for (const TestCase& Case : Cases) {
            CasesBySuite[Case.SuiteName].push_back(Case);
        }
        for (const TestSuite& Suite : Suites) {
            const std::vector<TestCase>& SuiteCases = CasesBySuite[Suite.Name];
            if (SuiteCases.empty()) {
                const std::string Status = (Suite.Failures || Suite.Errors) ? "failed" : (Suite.Skipped ? "notrun" : "passed");
                Out << "<Test Status=\"" << Status << "\"><Name>" << EscapeXml(Suite.Name) << "</Name><FullName>" << EscapeXml(Suite.Name)
                    << "</FullName><CompletionStatus>" << Status << "</CompletionStatus><ExecutionTime>" << Suite.Time
                    << "</ExecutionTime><Results><NamedMeasurement name=\"Warnings\"><Value>0</Value></NamedMeasurement>"
                    << "<NamedMeasurement name=\"Errors\"><Value>" << (Suite.Errors + Suite.Failures) << "</Value></NamedMeasurement>"
                    << "</Results></Test>\n";
                continue;
            }
            int Emitted = 0;
            int EmittedFailed = 0;
            int EmittedSkipped = 0;
            for (const TestCase& Case : SuiteCases) {
                const bool bFailed = Case.bFailure || Case.bError;
                const std::string Status = bFailed ? "failed" : (Case.bSkipped ? "notrun" : "passed");
                Out << "<Test Status=\"" << Status << "\"><Name>" << EscapeXml(Case.Name) << "</Name><FullName>"
                    << EscapeXml(Suite.Name + "::" + Case.Name) << "</FullName><CompletionStatus>" << Status
                    << "</CompletionStatus><ExecutionTime>" << EscapeXml(Case.Time)
                    << "</ExecutionTime><Results><NamedMeasurement name=\"Warnings\"><Value>0</Value></NamedMeasurement>"
                    << "<NamedMeasurement name=\"Errors\"><Value>" << (bFailed ? "1" : "0") << "</Value></NamedMeasurement>"
                    << "</Results></Test>\n";
                Emitted += 1;
                if (bFailed) {
                    EmittedFailed += 1;
                }
                if (Case.bSkipped) {
                    EmittedSkipped += 1;
                }
            }
            const int Missing = std::max(0, Suite.Tests - Emitted);
            const int RemainingFailed = std::max(0, (Suite.Failures + Suite.Errors) - EmittedFailed);
            const int RemainingSkipped = std::max(0, Suite.Skipped - EmittedSkipped);
            for (int Index = 0; Index < Missing; ++Index) {
                const bool bFailed = Index < RemainingFailed;
                const bool bSkipped = !bFailed && Index < RemainingFailed + RemainingSkipped;
                const std::string Status = bFailed ? "failed" : (bSkipped ? "notrun" : "passed");
                const std::string Name = Suite.Name + "::synthetic-" + std::to_string(Index + 1);
                Out << "<Test Status=\"" << Status << "\"><Name>" << EscapeXml(Name) << "</Name><FullName>" << EscapeXml(Name)
                    << "</FullName><CompletionStatus>" << Status << "</CompletionStatus><ExecutionTime>0</ExecutionTime>"
                    << "<Results><NamedMeasurement name=\"Warnings\"><Value>0</Value></NamedMeasurement>"
                    << "<NamedMeasurement name=\"Errors\"><Value>" << (bFailed ? "1" : "0") << "</Value></NamedMeasurement>"
                    << "</Results></Test>\n";
            }
        }
    }
    Out << "</Testing></Site>\n";
    WriteText(OutputXml, Out.str());
    return 0;
}

int CommandJunitHtmlFallback(const std::vector<std::string>& Args) {
    if (Args.size() != 2) {
        std::cerr << "usage: junit-html-fallback <reports-dir> <html-root>\n";
        return 2;
    }
    const fs::path ReportsDir = Args[0];
    const fs::path HtmlRoot = Args[1];
    fs::create_directories(HtmlRoot);
    std::ostringstream Rows;
    for (const fs::path& XmlPath : SortedFilesWithExtension(ReportsDir, ".xml")) {
        int Tests = 0, Failures = 0, Errors = 0, Skipped = 0;
        std::string Name = XmlPath.stem().string();
        try {
            const std::vector<TestSuite> Suites = ParseSuites(ReadText(XmlPath));
            if (!Suites.empty()) {
                Name = Suites.front().Name;
                for (const TestSuite& Suite : Suites) {
                    Tests += Suite.Tests;
                    Failures += Suite.Failures;
                    Errors += Suite.Errors;
                    Skipped += Suite.Skipped;
                }
            }
        } catch (...) {
            Failures = 1;
        }
        const int Passed = std::max(0, Tests - Failures - Errors - Skipped);
        const double Rate = Tests > 0 ? (static_cast<double>(Passed) / static_cast<double>(Tests) * 100.0) : 0.0;
        const fs::path Leaf = HtmlRoot / XmlPath.stem();
        fs::create_directories(Leaf);
        std::ostringstream LeafPage;
        LeafPage.setf(std::ios::fixed);
        LeafPage.precision(2);
        LeafPage << "<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\"><title>" << EscapeHtml(Name) << "</title></head>\n"
                 << "<body><h1>" << EscapeHtml(Name) << "</h1>\n<p>tests=" << Tests << " passed=" << Passed
                 << " failures=" << Failures << " errors=" << Errors << " skipped=" << Skipped << " pass_rate=" << Rate
                 << "%</p>\n<p><a href=\"../../junit/" << EscapeHtml(XmlPath.filename().string())
                 << "\">Open JUnit XML</a></p>\n</body></html>\n";
        WriteText(Leaf / "index.html", LeafPage.str());
        Rows.setf(std::ios::fixed);
        Rows.precision(2);
        Rows << "<tr><td><a href=\"" << EscapeHtml(XmlPath.stem().string()) << "/index.html\">" << EscapeHtml(Name)
             << "</a></td><td>" << Tests << "</td><td>" << Passed << "</td><td>" << Failures << "</td><td>"
             << Errors << "</td><td>" << Skipped << "</td><td>" << Rate << "%</td></tr>";
    }
    std::ostringstream Index;
    Index << "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><title>PGO Gather Test Report</title></head>"
          << "<body><h1>PGO Gather Test Report</h1><table border=\"1\" cellpadding=\"6\" cellspacing=\"0\">"
          << "<thead><tr><th>Suite</th><th>Tests</th><th>Passed</th><th>Failures</th><th>Errors</th><th>Skipped</th><th>Pass rate</th></tr></thead>"
          << "<tbody>" << Rows.str() << "</tbody></table></body></html>";
    WriteText(HtmlRoot / "index.html", Index.str());
    return 0;
}

int CommandReportsHomepage(const std::vector<std::string>& Args) {
    if (Args.size() != 7) {
        std::cerr << "usage: reports-homepage <reports-root> <html-dir> <coverage-html-dir> <reports-dir> <logs-dir> <coverage-tool> <quick-mode>\n";
        return 2;
    }
    const fs::path ReportsRoot = Args[0];
    const fs::path HtmlDir = Args[1];
    const fs::path CoverageHtmlDir = Args[2];
    const fs::path ReportsDir = Args[3];
    const fs::path LogsDir = Args[4];
    const std::string CoverageTool = Args[5];
    const bool bQuickMode = Args[6] == "1";
    fs::create_directories(ReportsRoot);
    const auto RelLink = [&](const fs::path& Target) {
        std::error_code Ec;
        fs::path Rel = fs::relative(Target, ReportsRoot, Ec);
        return NormalizePathText((Ec ? Target : Rel).string());
    };
    const fs::path TestIndex = HtmlDir / "index.html";
    const fs::path CoverageIndex = CoverageHtmlDir / "index.html";
    const size_t JunitCount = SortedFilesWithExtension(ReportsDir, ".xml").size();
    const size_t LogCount = SortedFilesWithExtension(LogsDir, ".log").size();
    std::ostringstream Rows;
    if (fs::is_regular_file(TestIndex)) {
        Rows << "<tr><td>Test HTML</td><td>ready</td><td><a href=\"" << EscapeHtml(RelLink(TestIndex)) << "\">open</a></td></tr>\n";
    } else {
        Rows << "<tr><td>Test HTML</td><td>missing</td><td>-</td></tr>\n";
    }
    if (fs::is_regular_file(CoverageIndex)) {
        Rows << "<tr><td>Coverage HTML</td><td>ready</td><td><a href=\"" << EscapeHtml(RelLink(CoverageIndex)) << "\">open</a></td></tr>\n";
    } else {
        Rows << "<tr><td>Coverage HTML</td><td>missing</td><td>-</td></tr>\n";
    }
    Rows << "<tr><td>JUnit XML</td><td>" << JunitCount << " file(s)</td><td><a href=\"" << EscapeHtml(RelLink(ReportsDir)) << "\">open folder</a></td></tr>\n";
    Rows << "<tr><td>Logs</td><td>" << LogCount << " file(s)</td><td><a href=\"" << EscapeHtml(RelLink(LogsDir)) << "\">open folder</a></td></tr>\n";

    std::ostringstream Doc;
    Doc << "<!doctype html>\n<html lang=\"en\">\n<head>\n  <meta charset=\"utf-8\" />\n"
        << "  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\" />\n"
        << "  <title>PGO Gather Report Index</title>\n"
        << "  <style>\n    body { font-family: Segoe UI, sans-serif; margin: 2rem; line-height: 1.45; }\n"
        << "    table { border-collapse: collapse; width: 100%; max-width: 960px; }\n"
        << "    th, td { border: 1px solid #d0d7de; padding: 0.55rem 0.7rem; text-align: left; }\n"
        << "    th { background: #f6f8fa; }\n    .meta { color: #57606a; margin-bottom: 1rem; }\n"
        << "  </style>\n</head>\n<body>\n  <h1>PGO Gather Report Index</h1>\n"
        << "  <p class=\"meta\">Generated by native kano-cpp-infra-tool | mode: " << (bQuickMode ? "quick" : "full")
        << " | coverage tool: " << EscapeHtml(CoverageTool) << "</p>\n"
        << "  <table>\n    <thead><tr><th>Report</th><th>Status</th><th>Link</th></tr></thead>\n    <tbody>\n      "
        << Rows.str() << "    </tbody>\n  </table>\n</body>\n</html>\n";
    WriteText(ReportsRoot / "index.html", Doc.str());
    return 0;
}

int CommandDumpCoberturaSummary(const std::vector<std::string>& Args) {
    if (Args.size() != 2) {
        std::cerr << "usage: dump-cobertura-summary <raw-dir> <out-file>\n";
        return 2;
    }
    const fs::path RawDir = Args[0];
    const fs::path OutFile = Args[1];
    std::ostringstream Lines;
    Lines << "raw_dir=" << RawDir.string() << "\n";
    for (const fs::path& Xml : SortedCoberturaFiles(RawDir)) {
        Lines << Xml.filename().string()
              << "\tlines-valid=" << CoberturaLinesValid(Xml)
              << "\tlines-covered=" << CoberturaLinesCovered(Xml)
              << "\tline-rate=" << CoberturaLineRate(Xml)
              << "\tpackages=" << CoberturaPackageCount(Xml)
              << "\n";
    }
    WriteText(OutFile, Lines.str());
    return 0;
}

int CommandCountNonemptyCobertura(const std::vector<std::string>& Args) {
    if (Args.size() != 1) {
        std::cerr << "usage: count-nonempty-cobertura <raw-dir>\n";
        return 2;
    }
    int Count = 0;
    for (const fs::path& Xml : SortedCoberturaFiles(Args[0])) {
        if (CoberturaLinesValid(Xml) > 0) {
            Count += 1;
        }
    }
    std::cout << Count << "\n";
    return 0;
}

int CommandCoberturaHasLines(const std::vector<std::string>& Args) {
    if (Args.size() != 1) {
        std::cerr << "usage: cobertura-has-lines <xml>\n";
        return 2;
    }
    return CoberturaLinesValid(Args[0]) > 0 ? 0 : 1;
}

int CommandCoberturaLinesValid(const std::vector<std::string>& Args) {
    if (Args.size() != 1) {
        std::cerr << "usage: cobertura-lines-valid <xml>\n";
        return 2;
    }
    std::cout << CoberturaLinesValid(Args[0]) << "\n";
    return 0;
}

int CommandBestCobertura(const std::vector<std::string>& Args) {
    if (Args.empty()) {
        return 1;
    }
    fs::path Best;
    int BestLines = -1;
    for (const std::string& Arg : Args) {
        const int Lines = CoberturaLinesValid(Arg);
        if (Lines > BestLines) {
            BestLines = Lines;
            Best = Arg;
        }
    }
    if (Best.empty()) {
        return 1;
    }
    std::cout << Best.string() << "\n";
    return 0;
}

int CommandLlvmJsonToCobertura(const std::vector<std::string>& Args) {
    if (Args.size() != 3) {
        std::cerr << "usage: llvm-json-to-cobertura <llvm-export.json> <repo-root> <out.xml>\n";
        return 2;
    }
    const fs::path JsonPath = Args[0];
    const fs::path RepoRoot = fs::absolute(Args[1]);
    const fs::path OutXml = Args[2];
    const Json::Value Payload = ParseJsonFile(JsonPath);

    struct FileHits {
        std::string RelPath;
        std::map<int, int> Hits;
    };
    std::map<std::string, std::vector<FileHits>> Packages;
    int TotalValid = 0;
    int TotalCovered = 0;

    for (const Json::Value& Data : Payload["data"]) {
        for (const Json::Value& FileEntry : Data["files"]) {
            const std::string Filename = NormalizePathText(FileEntry["filename"].asString());
            if (Filename.empty()) {
                continue;
            }
            std::map<int, int> Hits;
            for (const Json::Value& Segment : FileEntry["segments"]) {
                if (!Segment.isArray() || Segment.size() < 5) {
                    continue;
                }
                const int LineNo = Segment[0].asInt();
                const int Count = Segment[2].asInt();
                const bool bHasCount = Segment[3].asBool();
                const bool bIsGap = Segment[4].asBool();
                if (LineNo <= 0 || !bHasCount || bIsGap) {
                    continue;
                }
                auto It = Hits.find(LineNo);
                if (It == Hits.end() || Count > It->second) {
                    Hits[LineNo] = Count;
                }
            }

            fs::path RelPath = Filename;
            std::error_code Ec;
            const fs::path Absolute = fs::absolute(Filename, Ec);
            if (!Ec) {
                fs::path MaybeRel = fs::relative(Absolute, RepoRoot, Ec);
                const std::string MaybeRelText = NormalizePathText(MaybeRel.string());
                if (!Ec && !MaybeRel.empty() && MaybeRelText.find("..") != 0) {
                    RelPath = MaybeRel;
                }
            }
            const std::string Rel = NormalizePathText(RelPath.string());
            const std::string PackageName = Rel.find('/') == std::string::npos ? "." : Rel.substr(0, Rel.find_last_of('/'));
            Packages[PackageName].push_back(FileHits{Rel, Hits});
        }
    }

    std::ostringstream Xml;
    Xml << "<coverage line-rate=\"0\" branch-rate=\"0\" lines-covered=\"0\" lines-valid=\"0\" branches-covered=\"0\" branches-valid=\"0\" complexity=\"0\" version=\"llvm-json-to-cobertura\">\n";
    Xml << "  <sources><source>" << EscapeXml(NormalizePathText(RepoRoot.string())) << "</source></sources>\n";
    Xml << "  <packages>\n";
    for (const auto& Package : Packages) {
        int PackageValid = 0;
        int PackageCovered = 0;
        std::ostringstream Classes;
        for (const FileHits& File : Package.second) {
            const int LinesValid = static_cast<int>(File.Hits.size());
            const int LinesCovered = static_cast<int>(std::count_if(File.Hits.begin(), File.Hits.end(), [](const auto& Item) { return Item.second > 0; }));
            PackageValid += LinesValid;
            PackageCovered += LinesCovered;
            Classes << "      <class name=\"" << EscapeXml(fs::path(File.RelPath).filename().string()) << "\" filename=\"" << EscapeXml(File.RelPath)
                    << "\" line-rate=\"" << (LinesValid ? static_cast<double>(LinesCovered) / LinesValid : 0.0)
                    << "\" branch-rate=\"0\" complexity=\"0\" lines-covered=\"" << LinesCovered << "\" lines-valid=\"" << LinesValid << "\">\n"
                    << "        <lines>\n";
            for (const auto& Hit : File.Hits) {
                Classes << "          <line number=\"" << Hit.first << "\" hits=\"" << Hit.second << "\" branch=\"false\"/>\n";
            }
            Classes << "        </lines>\n      </class>\n";
        }
        TotalValid += PackageValid;
        TotalCovered += PackageCovered;
        Xml << "    <package name=\"" << EscapeXml(Package.first) << "\" line-rate=\"" << (PackageValid ? static_cast<double>(PackageCovered) / PackageValid : 0.0)
            << "\" branch-rate=\"0\" complexity=\"0\" lines-covered=\"" << PackageCovered << "\" lines-valid=\"" << PackageValid << "\">\n"
            << "      <classes>\n" << Classes.str() << "      </classes>\n    </package>\n";
    }
    Xml << "  </packages>\n</coverage>\n";
    std::string XmlText = Xml.str();
    XmlText = std::regex_replace(XmlText, std::regex(R"(lines-covered="0" lines-valid="0")"), "lines-covered=\"" + std::to_string(TotalCovered) + "\" lines-valid=\"" + std::to_string(TotalValid) + "\"");
    XmlText = std::regex_replace(XmlText, std::regex(R"(line-rate="0")"), "line-rate=\"" + std::to_string(TotalValid ? static_cast<double>(TotalCovered) / TotalValid : 0.0) + "\"", std::regex_constants::format_first_only);
    WriteText(OutXml, XmlText);
    return 0;
}

int CommandCmakePresetExists(const std::vector<std::string>& Args) {
    if (Args.size() != 2) {
        std::cerr << "usage: cmake-preset-exists <CMakePresets.json> <preset>\n";
        return 2;
    }
    const Json::Value Root = ParseJsonFile(Args[0]);
    const std::string Name = Args[1];
    for (const std::string Section : {"configurePresets", "buildPresets"}) {
        for (const Json::Value& Preset : Root[Section]) {
            if (Preset.isMember("name") && Preset["name"].asString() == Name) {
                return 0;
            }
        }
    }
    return 1;
}

int CommandCacheArgsWithPgoMode(const std::vector<std::string>& Args) {
    if (Args.size() != 1) {
        std::cerr << "usage: cache-args-with-pgo-mode <mode>\n";
        return 2;
    }
    Json::Value Root = ParseJsonTextOrObject(GetEnvString("KANO_CPP_INFRA_CMAKE_CACHE_ARGS_JSON"));
    Root["KANO_CPP_INFRA_PGO_MODE"] = Args[0];
    if (Args[0] == "use" && !Root.isMember("KOG_BUILD_TESTS")) {
        Root["KOG_BUILD_TESTS"] = "OFF";
    }
    std::cout << WriteJsonCompact(Root) << "\n";
    return 0;
}

int CommandCacheArgsToCmake(const std::vector<std::string>& Args) {
    std::string Raw = Args.empty() ? GetEnvString("INF_CMAKE_CACHE_ARGS_JSON") : Args[0];
    if (Raw.empty()) {
        return 0;
    }
    const Json::Value Root = ParseJsonTextOrObject(Raw);
    for (const std::string& Key : Root.getMemberNames()) {
        const Json::Value& Value = Root[Key];
        if (Value.isString()) {
            std::cout << "-D" << Key << "=" << Value.asString() << "\n";
        } else if (Value.isBool()) {
            std::cout << "-D" << Key << "=" << (Value.asBool() ? "ON" : "OFF") << "\n";
        } else {
            std::cout << "-D" << Key << "=" << Value.asString() << "\n";
        }
    }
    return 0;
}

int CommandProfileRunManifest(const std::vector<std::string>& Args) {
    std::map<std::string, std::string> Options;
    bool bMicrosoftServerMode = false;
    for (size_t Index = 0; Index < Args.size(); ++Index) {
        const std::string& Arg = Args[Index];
        if (Arg == "--microsoft-server-mode") {
            bMicrosoftServerMode = true;
            continue;
        }
        if (Arg.rfind("--", 0) == 0 && Index + 1 < Args.size()) {
            Options[Arg] = Args[++Index];
            continue;
        }
        std::cerr << "unknown profile-run-manifest argument: " << Arg << "\n";
        return 2;
    }
    const std::string Out = Options["--out"];
    if (Out.empty()) {
        std::cerr << "profile-run-manifest requires --out\n";
        return 2;
    }
    std::string Compiler = Lower(Options["--compiler"].empty() ? (GetEnvString("KANO_CXX_COMPILER").empty() ? "msvc" : GetEnvString("KANO_CXX_COMPILER")) : Options["--compiler"]);
    std::string CoverageProvider = Lower(Options["--coverage-provider"].empty() ? (GetEnvString("KANO_CXX_COVERAGE_PROVIDER").empty() ? "none" : GetEnvString("KANO_CXX_COVERAGE_PROVIDER")) : Options["--coverage-provider"]);
    std::string PgoProvider = Lower(Options["--pgo-provider"].empty() ? (GetEnvString("KANO_CXX_PGO_PROVIDER").empty() ? "none" : GetEnvString("KANO_CXX_PGO_PROVIDER")) : Options["--pgo-provider"]);
    std::string Mode = Lower(Options["--profile-run-mode"].empty() ? (GetEnvString("KANO_CXX_PROFILE_RUN_MODE").empty() ? "pgo-rebuild" : GetEnvString("KANO_CXX_PROFILE_RUN_MODE")) : Options["--profile-run-mode"]);

    bool bUnifiedExecution = false;
    bool bUnifiedProfileData = false;
    bool bSplitLanes = true;
    std::string CoverageSubject = "normal-test-binary";
    std::string CollectorScope = "none";
    Json::Value Notes(Json::arrayValue);

    if (Mode == "pgo-gather-with-coverage") {
        bSplitLanes = false;
        if (Compiler == "msvc" && CoverageProvider == "opencppcoverage" && PgoProvider == "msvc-pgo") {
            bUnifiedExecution = true;
            CoverageSubject = "pgo-instrumented-training-binary";
            CollectorScope = "process-wrapper";
            Notes.append("MSVC training run wrapped by OpenCppCoverage; coverage output remains separate from .pgd/.pgc data.");
        } else if (Compiler == "msvc" && CoverageProvider == "microsoft-codecoverage" && PgoProvider == "msvc-pgo") {
            std::cerr << "MSVC unified PGO+coverage execution is only supported with OpenCppCoverage. Microsoft.CodeCoverage.Console coverage output is not MSVC PGO training data.\n";
            return 2;
        } else if (Compiler == "clang" && CoverageProvider == "llvm-cov" && PgoProvider == "llvm-profdata") {
            bUnifiedExecution = true;
            bUnifiedProfileData = true;
            CoverageSubject = "llvm-instrumented-binary";
            CollectorScope = "process-wrapper";
            Notes.append("LLVM source-based instrumentation provides shared profile data for coverage and PGO.");
        } else {
            std::cerr << "Unsupported unified profile combination: compiler=" << Compiler << ", coverageProvider=" << CoverageProvider << ", pgoProvider=" << PgoProvider << "\n";
            return 2;
        }
    } else if (Mode == "coverage-all") {
        if (CoverageProvider == "microsoft-codecoverage") {
            CoverageSubject = "instrumented-coverage-binary";
            CollectorScope = bMicrosoftServerMode ? "local-session-server" : "process-wrapper";
            if (bMicrosoftServerMode) {
                Notes.append("Microsoft.CodeCoverage.Console server-mode is local/session detached collection, not remote telemetry.");
            }
        } else if (CoverageProvider == "llvm-cov") {
            CoverageSubject = "llvm-instrumented-binary";
            CollectorScope = "process-wrapper";
        } else if (CoverageProvider == "opencppcoverage") {
            CoverageSubject = "normal-test-binary";
            CollectorScope = "process-wrapper";
        }
    } else if (Mode == "pgo-gather" || Mode == "pgo-rebuild") {
        Notes.append("PGO lane only; coverage reports are not treated as training data.");
    } else {
        std::cerr << "Unsupported profile run mode: " << Mode << "\n";
        return 2;
    }
    if (CoverageProvider == "microsoft-codecoverage" && bMicrosoftServerMode && Mode != "coverage-all") {
        Notes.append("microsoftServerMode requested outside coverage-all; collectorScope remains mode-derived.");
    }

    Json::Value Root(Json::objectValue);
    Root["schemaVersion"] = "1.0";
    Root["profileRunMode"] = Mode;
    Root["compiler"] = Compiler;
    Root["coverageProvider"] = CoverageProvider;
    Root["pgoProvider"] = PgoProvider;
    Root["unifiedExecution"] = bUnifiedExecution;
    Root["unifiedProfileData"] = bUnifiedProfileData;
    Root["splitLanes"] = bSplitLanes;
    Root["coverageSubject"] = CoverageSubject;
    Root["collectorScope"] = CollectorScope;
    Root["remoteTelemetry"] = false;
    Root["realUserProfile"] = false;
    Root["pgoDataPaths"] = CsvJsonArray(Options["--pgo-data-paths"]);
    Root["coverageReportPaths"] = CsvJsonArray(Options["--coverage-report-paths"]);
    Root["trainingCommand"] = Options["--training-command"];
    Root["coverageCommand"] = Options["--coverage-command"];
    Root["notes"] = Notes;
    WriteText(Out, WriteJsonString(Root) + "\n");
    return 0;
}

std::string HostOs() {
#ifdef _WIN32
    return "windows";
#elif defined(__APPLE__)
    return "macos";
#else
    return "linux";
#endif
}

std::string HostArch() {
#if defined(_M_ARM64) || defined(__aarch64__) || defined(__arm64__)
    return "arm64";
#else
    return "x64";
#endif
}

int CommandRunProfileMatrix(const std::vector<std::string>& Args) {
    if (Args.size() != 4) {
        std::cerr << "usage: run-profile-matrix <matrix.json> <tmp-root> <repo-root> <cpp-root>\n";
        return 2;
    }
    const fs::path MatrixPath = Args[0];
    const fs::path TmpRoot = Args[1];
    const fs::path RepoRoot = Args[2];
    const fs::path CppRoot = Args[3];
    const Json::Value Matrix = ParseJsonFile(MatrixPath);
    const Json::Value Defaults = Matrix["defaults"];
    const std::string MatrixName = GetString(Matrix, "name", MatrixPath.stem().string());
    const std::string ReportSlug = GetString(Matrix, "reportSlug", MatrixName);
    const fs::path MatrixRoot = TmpRoot / MatrixName;
    fs::create_directories(MatrixRoot);

    Json::Value Results(Json::arrayValue);
    for (const Json::Value& Case : Matrix["cases"]) {
        const std::string CaseId = Case["id"].asString();
        const fs::path CaseRoot = MatrixRoot / CaseId;
        fs::create_directories(CaseRoot);

        std::string Launcher = GetStringEither(Case, Defaults, "launcher", "auto");
        std::string Modules = Lower(GetStringEither(Case, Defaults, "modules", "off"));
        std::string Unity = Lower(GetStringEither(Case, Defaults, "unity", "off"));
        std::string PgoMode = Lower(GetStringEither(Case, Defaults, "pgo", "off"));
        std::string Workflow = Lower(GetStringEither(Case, Defaults, "workflow", "baseline"));

        Json::Value CacheArgs(Json::objectValue);
        CacheArgs["INF_ENABLE_MODULES"] = Modules == "on" ? "ON" : "OFF";
        CacheArgs["INF_ENABLE_UNITY_BUILD"] = Unity == "off" ? "OFF" : "ON";
        if (Unity == "full" || Unity == "changed") {
            CacheArgs["INF_UNITY_BUILD_MODE"] = Unity;
        }
        if (Lower(GetStringEither(Case, Defaults, "coverage", "off")) == "on") {
            CacheArgs["INF_ENABLE_COVERAGE"] = "ON";
        }
        if (PgoMode == "collect") {
            CacheArgs["INF_PGO_MODE"] = "collect";
        } else if (PgoMode == "use") {
            CacheArgs["INF_PGO_MODE"] = "use";
        }

        EnvRestore Env;
        Env.Set("INF_CPP_ROOT", CppRoot.string());
        Env.Set("INF_PROFILE_CASE_ID", CaseId);
        Env.Set("INF_PROFILE_MATRIX", MatrixName);
        Env.Set("INF_PROFILE_REPORT_SLUG", ReportSlug);
        if (!Launcher.empty()) {
            Env.Set("INF_COMPILER_LAUNCHER", Launcher);
        }
        Env.Set("INF_CMAKE_CACHE_ARGS_JSON", WriteJsonCompact(CacheArgs));

        const fs::path OutputCsv = CaseRoot / "baseline.csv";
        Json::Value Artifacts(Json::objectValue);
        Artifacts["caseRoot"] = CaseRoot.string();
        Json::Value Result(Json::objectValue);
        Result["id"] = CaseId;
        Result["hostOs"] = HostOs();
        Result["hostArch"] = HostArch();
        Result["launcher"] = Launcher;
        Result["unity"] = Unity;
        Result["modules"] = Modules;
        Result["pgo"] = PgoMode;
        Result["workflow"] = Workflow;
        Result["cacheArgs"] = CacheArgs;
        Result["status"] = "pending";
        Result["artifacts"] = Artifacts;

        const std::string BaselineScript = GetEnvString("INF_BASELINE_SCRIPT").empty()
            ? (CppRoot / "shared/infra/scripts/common/measure_iteration_baseline.sh").string()
            : GetEnvString("INF_BASELINE_SCRIPT");
        const std::string PgoScript = GetEnvString("INF_PGO_REBUILD_SCRIPT").empty()
            ? (CppRoot / "shared/infra/scripts/workflows/pgo-rebuild.sh").string()
            : GetEnvString("INF_PGO_REBUILD_SCRIPT");
        std::vector<std::string> CommandArgs;
        if (Workflow == "pgo") {
            CommandArgs = {PgoScript};
        } else {
            CommandArgs = {
                BaselineScript,
                "--configure-preset", GetStringEither(Case, Defaults, "configurePreset"),
                "--build-preset", GetStringEither(Case, Defaults, "buildPreset"),
                "--build-dir", GetStringEither(Case, Defaults, "buildDir"),
                "--config", GetStringEither(Case, Defaults, "config", "Release"),
                "--output", OutputCsv.string(),
            };
        }
        std::vector<std::string> ProcessArgs;
#ifdef _WIN32
        ProcessArgs.push_back("bash");
#endif
        ProcessArgs.insert(ProcessArgs.end(), CommandArgs.begin(), CommandArgs.end());
        std::vector<const char*> Argv;
        for (const std::string& Arg : ProcessArgs) {
            Argv.push_back(Arg.c_str());
        }
        KanoProcessOptions Options{};
        const std::string RepoRootString = RepoRoot.string();
        Options.executable = "bash";
        Options.working_dir = RepoRootString.c_str();
        Options.argv = Argv.data();
        Options.argv_count = Argv.size();
        Options.mode = KANO_PROCESS_MODE_CAPTURE;
        KanoProcessResult ProcResult{};
        const bool bRan = kano_process_run_ex(&Options, &ProcResult);
        const int ExitCode = bRan ? ProcResult.exit_code : 127;
        WriteText(CaseRoot / "stdout.log", ProcResult.stdout_data ? ProcResult.stdout_data : "");
        WriteText(CaseRoot / "stderr.log", ProcResult.stderr_data ? ProcResult.stderr_data : (bRan ? "" : "failed to spawn process\n"));
        kano_process_free_result(&ProcResult);

        Result["exitCode"] = ExitCode;
        Result["status"] = ExitCode == 0 ? "passed" : "failed";
        if (fs::is_regular_file(OutputCsv)) {
            Artifacts["baselineCsv"] = OutputCsv.string();
            Result["artifacts"] = Artifacts;
        }
        WriteText(CaseRoot / "result.json", WriteJsonString(Result) + "\n");
        Results.append(Result);
    }

    Json::Value Summary(Json::objectValue);
    Summary["name"] = MatrixName;
    Summary["reportSlug"] = ReportSlug;
    Summary["hostOs"] = HostOs();
    Summary["hostArch"] = HostArch();
    Summary["cases"] = Results;
    const fs::path ProfilePath = MatrixRoot / "profile.json";
    WriteText(ProfilePath, WriteJsonString(Summary) + "\n");
    std::cout << ProfilePath.string() << "\n";
    return 0;
}

int CommandRenderProfileReport(const std::vector<std::string>& Args) {
    if (Args.size() != 3) {
        std::cerr << "usage: render-profile-report <matrix.json> <tmp-root> <report-root>\n";
        return 2;
    }
    const fs::path MatrixPath = Args[0];
    const fs::path TmpRoot = Args[1];
    const fs::path ReportRoot = Args[2];
    const std::string MatrixName = MatrixPath.stem().string();
    const fs::path ProfileSource = TmpRoot / MatrixName / "profile.json";
    if (!fs::is_regular_file(ProfileSource)) {
        std::cerr << "profile artifact not found: " << ProfileSource.string() << "\n";
        return 1;
    }
    const Json::Value Profile = ParseJsonFile(ProfileSource);
    const std::string Slug = GetString(Profile, "reportSlug", MatrixName);
    const fs::path OutDir = ReportRoot / Slug;
    fs::create_directories(OutDir);
    WriteText(OutDir / "profile.json", WriteJsonString(Profile) + "\n");

    std::ostringstream Markdown;
    Markdown << "# Profiling Report - " << Slug << "\n\n";
    Markdown << "Host: `" << GetString(Profile, "hostOs") << "` / `" << GetString(Profile, "hostArch") << "`\n\n";
    std::ostringstream Rows;
    for (const Json::Value& Case : Profile["cases"]) {
        std::string Metrics;
        if (Case.isMember("baselineRows")) {
            for (const Json::Value& Row : Case["baselineRows"]) {
                if (!Metrics.empty()) {
                    Metrics += ", ";
                }
                Metrics += GetString(Row, "case") + "=" + GetString(Row, "elapsed_seconds") + "s";
            }
        }
        Markdown << "- **" << GetString(Case, "id") << "** - status=`" << GetString(Case, "status")
                 << "` launcher=`" << GetString(Case, "launcher") << "` unity=`" << GetString(Case, "unity")
                 << "` modules=`" << GetString(Case, "modules") << "` pgo=`" << GetString(Case, "pgo") << "`\n";
        if (!Metrics.empty()) {
            Markdown << "  - metrics: " << Metrics << "\n";
        }
        Rows << "<tr><td>" << EscapeHtml(GetString(Case, "id")) << "</td><td>" << EscapeHtml(GetString(Case, "status"))
             << "</td><td>" << EscapeHtml(GetString(Case, "launcher")) << "</td><td>" << EscapeHtml(GetString(Case, "unity"))
             << "</td><td>" << EscapeHtml(GetString(Case, "modules")) << "</td><td>" << EscapeHtml(GetString(Case, "pgo"))
             << "</td><td>" << EscapeHtml(Metrics) << "</td></tr>\n";
    }
    WriteText(OutDir / "summary.md", Markdown.str());
    std::ostringstream Html;
    Html << "<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n"
         << "<title>Profiling Report - " << EscapeHtml(Slug) << "</title>\n"
         << "<style>\nbody { font-family: Inter, Segoe UI, Arial, sans-serif; margin: 0; background: #0b1020; color: #edf2ff; }\n"
         << "main { max-width: 1200px; margin: 0 auto; padding: 24px; }\n"
         << "table { width: 100%; border-collapse: collapse; background: #121a31; border: 1px solid #2a3557; }\n"
         << "th, td { border-bottom: 1px solid #2a3557; padding: 10px 12px; text-align: left; vertical-align: top; }\n"
         << "th { color: #9fb0d8; font-size: 12px; text-transform: uppercase; }\ncode { color: #6a8cff; }\n"
         << "</style></head><body><main>\n<h1>Profiling Report - " << EscapeHtml(Slug) << "</h1>\n"
         << "<p>Host: <code>" << EscapeHtml(GetString(Profile, "hostOs")) << "</code> / <code>"
         << EscapeHtml(GetString(Profile, "hostArch")) << "</code></p>\n"
         << "<table><thead><tr><th>Case</th><th>Status</th><th>Launcher</th><th>Unity</th><th>Modules</th><th>PGO</th><th>Metrics</th></tr></thead><tbody>\n"
         << Rows.str() << "</tbody></table>\n</main></body></html>";
    WriteText(OutDir / "index.html", Html.str());
    std::cout << OutDir.string() << "\n";
    return 0;
}

int CommandRewriteExportManifests(const std::vector<std::string>& Args) {
    if (Args.size() != 3) {
        std::cerr << "usage: rewrite-export-manifests <staged-output-dir> <target-output-dir> <repo-tmp-dir>\n";
        return 2;
    }
    const fs::path StagedOutput = Args[0];
    const fs::path TargetOutput = Args[1];
    const fs::path RepoTmp = Args[2];
    if (!fs::is_directory(RepoTmp) || !fs::is_directory(StagedOutput)) {
        return 0;
    }
    std::vector<std::string> ManifestNames;
    for (const auto& Entry : fs::directory_iterator(StagedOutput)) {
        if (Entry.is_regular_file()) {
            const std::string Name = Entry.path().filename().string();
            if (Name.size() >= 21 && Name.rfind(".export-manifest.json") == Name.size() - 21) {
                ManifestNames.push_back(Name);
            }
        }
    }
    if (ManifestNames.empty()) {
        return 0;
    }
    for (const std::string& ManifestName : ManifestNames) {
        for (const fs::path ManifestPath : {TargetOutput / ManifestName, RepoTmp / ManifestName}) {
            if (!fs::is_regular_file(ManifestPath)) {
                continue;
            }
            Json::Value Data;
            try {
                Data = ParseJsonFile(ManifestPath);
            } catch (...) {
                continue;
            }
            const auto RewriteArchivePath = [&](const std::string& Source) {
                return NormalizePathText((TargetOutput / fs::path(Source).filename()).string());
            };
            if (Data.isMember("archiveFile") && Data["archiveFile"].isString()) {
                const std::string Rewritten = RewriteArchivePath(Data["archiveFile"].asString());
                Data["archiveFile"] = Rewritten;
                if (Data.isMember("path") && Data["path"].isString()) {
                    Data["path"] = Rewritten;
                }
            }
            if (Data.isMember("archives") && Data["archives"].isArray()) {
                for (Json::Value& Entry : Data["archives"]) {
                    const std::string Source = Entry.isMember("archiveFile") && Entry["archiveFile"].isString()
                        ? Entry["archiveFile"].asString()
                        : (Entry.isMember("path") && Entry["path"].isString() ? Entry["path"].asString() : "");
                    if (!Source.empty()) {
                        const std::string Rewritten = RewriteArchivePath(Source);
                        Entry["archiveFile"] = Rewritten;
                        Entry["path"] = Rewritten;
                    }
                }
            }
            WriteText(ManifestPath, WriteJsonString(Data) + "\n");
        }
    }
    return 0;
}

void PrintUsage() {
    std::cerr
        << "usage: kano-cpp-infra-tool <command> [args]\n"
        << "commands: generate-bdd-metadata, render-junit-report, merge-junit-dir,\n"
        << "          gather-summary-junit, ctest-from-junit-dir, junit-html-fallback,\n"
        << "          reports-homepage, dump-cobertura-summary, count-nonempty-cobertura,\n"
        << "          cobertura-has-lines, cobertura-lines-valid, best-cobertura,\n"
        << "          llvm-json-to-cobertura, cmake-preset-exists, cache-args-with-pgo-mode,\n"
        << "          cache-args-to-cmake, profile-run-manifest, run-profile-matrix,\n"
        << "          render-profile-report, rewrite-export-manifests\n";
}

} // namespace

int main(int argc, char** argv) {
    ConfigureNoninteractiveErrorHandling();

    if (argc < 2) {
        PrintUsage();
        return 2;
    }
    const std::string Command = argv[1];
    std::vector<std::string> Args;
    for (int Index = 2; Index < argc; ++Index) {
        Args.emplace_back(argv[Index]);
    }
    try {
        if (Command == "generate-bdd-metadata") return CommandGenerateBddMetadata(Args);
        if (Command == "render-junit-report") return CommandRenderJunitReport(Args);
        if (Command == "merge-junit-dir") return CommandMergeJunitDir(Args);
        if (Command == "gather-summary-junit") return CommandGatherSummaryJunit(Args);
        if (Command == "ctest-from-junit-dir") return CommandCtestFromJunitDir(Args);
        if (Command == "junit-html-fallback") return CommandJunitHtmlFallback(Args);
        if (Command == "reports-homepage") return CommandReportsHomepage(Args);
        if (Command == "dump-cobertura-summary") return CommandDumpCoberturaSummary(Args);
        if (Command == "count-nonempty-cobertura") return CommandCountNonemptyCobertura(Args);
        if (Command == "cobertura-has-lines") return CommandCoberturaHasLines(Args);
        if (Command == "cobertura-lines-valid") return CommandCoberturaLinesValid(Args);
        if (Command == "best-cobertura") return CommandBestCobertura(Args);
        if (Command == "llvm-json-to-cobertura") return CommandLlvmJsonToCobertura(Args);
        if (Command == "cmake-preset-exists") return CommandCmakePresetExists(Args);
        if (Command == "cache-args-with-pgo-mode") return CommandCacheArgsWithPgoMode(Args);
        if (Command == "cache-args-to-cmake") return CommandCacheArgsToCmake(Args);
        if (Command == "profile-run-manifest") return CommandProfileRunManifest(Args);
        if (Command == "run-profile-matrix") return CommandRunProfileMatrix(Args);
        if (Command == "render-profile-report") return CommandRenderProfileReport(Args);
        if (Command == "rewrite-export-manifests") return CommandRewriteExportManifests(Args);
        std::cerr << "unknown command: " << Command << "\n";
        PrintUsage();
        return 2;
    } catch (const std::exception& Ex) {
        std::cerr << "fatal: " << Ex.what() << "\n";
        return 1;
    }
}
