#include <kano_toml.hpp>
#include <toml.hpp>
#include <catch2/catch_test_macros.hpp>
#include <catch2/catch_session.hpp>
#include <kano_unattended.hpp>
#include <sstream>

int main(int InCount,char** InArguments){
    kano::infra::ConfigureUnattendedExecution();
    return Catch::Session().run(InCount,InArguments);
}

TEST_CASE("Full TOML rejects duplicates malformed values and embedded null"){
    for(const auto* source:{"x=1\nx=2\n","x=unknown\n","[a]\nx=1\n[a]\ny=2\n","x=[1,\n","x=\"bad\\q\"\n"})
        CHECK_FALSE(kano::config::IsValidToml(source));
    CHECK_FALSE(kano::config::IsValidToml(std::string("x=1\0y=2",9)));
}
TEST_CASE("Full TOML table edits preserve multiline nested arrays dates and unrelated auth"){
    const std::string input=R"(title="""line one
line two"""
date=2026-10-22
items=[{name="first",enabled=true},{name="second",enabled=false}]
[auth]
mode="password"
unrelated="keep me"
[other.deep]
value=9
)";
    REQUIRE(kano::config::IsValidToml(input));
    const auto output=kano::config::RewriteTomlTable(input,{"auth"},{{"mode","trusted_header"},{"header","Remote-User"}},{{"trusted_sources",{"192.0.2.10"}}});
    std::istringstream beforeStream(input),afterStream(output);
    auto before=toml::parse(beforeStream),after=toml::parse(afterStream);
    CHECK(toml::find<std::string>(after,"auth","mode")=="trusted_header");
    CHECK(toml::find<std::vector<std::string>>(after,"auth","trusted_sources")==std::vector<std::string>{"192.0.2.10"});
    for(const auto* key:{"mode","header","trusted_sources"}){before["auth"].as_table().erase(key);after["auth"].as_table().erase(key);}
    CHECK(before==after);
    CHECK_THROWS(kano::config::RewriteTomlTable("auth=3\n",{"auth"},{{"mode","x"}},{}));
    CHECK_THROWS(kano::config::RewriteTomlTable("[auth]\nmode=3\n",{"auth"},{{"mode","x"}},{}));
    CHECK_THROWS(kano::config::RewriteTomlTable("[auth]\ntrusted_sources=[1]\n",{"auth"},{},{{"trusted_sources",{"x"}}}));
}
