#include <kano_toml.hpp>
#include <toml.hpp>
#include <sstream>
#include <stdexcept>

namespace kano::config {
namespace {
constexpr std::size_t kMaximumBytes=16*1024*1024;
[[noreturn]] void Refuse(){throw std::runtime_error("Native TOML operation refused");}
toml::value Parse(std::string_view InBytes){
    if(InBytes.size()>kMaximumBytes || InBytes.find('\0')!=std::string_view::npos) Refuse();
    std::istringstream stream{std::string(InBytes)};
    return toml::parse(stream,"native-input");
}
}
bool IsValidToml(std::string_view InBytes){
    try{(void)Parse(InBytes); return true;}catch(...){return false;}
}
std::string RewriteTomlTable(const std::string& InBytes,const std::vector<std::string>& InTablePath,
                            const std::map<std::string,std::string>& InStrings,
                            const std::map<std::string,std::vector<std::string>>& InStringArrays){
    try{
        auto document=Parse(InBytes); auto* table=&document;
        for(const auto& name:InTablePath){
            if(name.empty() || !table->is_table()) Refuse();
            if(!table->contains(name)) (*table)[name]=toml::table{};
            table=&table->at(name);
        }
        if(!table->is_table()) Refuse();
        for(const auto& [name,value]:InStrings){
            if(name.empty() || InStringArrays.count(name) || (table->contains(name) && !table->at(name).is_string())) Refuse();
            (*table)[name]=value;
        }
        for(const auto& [name,values]:InStringArrays){
            if(name.empty()) Refuse();
            if(table->contains(name)){
                if(!table->at(name).is_array()) Refuse();
                for(const auto& value:table->at(name).as_array()) if(!value.is_string()) Refuse();
            }
            (*table)[name]=values;
        }
        return toml::format(document);
    }catch(...){Refuse();}
}
}
