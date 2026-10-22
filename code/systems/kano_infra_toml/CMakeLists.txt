include(FetchContent)
# Reuse the full parser already pinned by native consumer tests. The old
# single-header vendor entry is incomplete; no second parser is introduced.
FetchContent_Declare(toml11 GIT_REPOSITORY https://github.com/ToruNiina/toml11.git
    GIT_TAG v3.7.1 GIT_SHALLOW TRUE GIT_SUBMODULES "" SOURCE_SUBDIR toml)
FetchContent_MakeAvailable(toml11)
add_library(kano_infra_toml STATIC private/toml.cpp)
target_compile_features(kano_infra_toml PUBLIC cxx_std_17)
target_include_directories(kano_infra_toml PRIVATE "${toml11_SOURCE_DIR}")
target_include_directories(kano_infra_toml PUBLIC
    "$<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/public>"
    "$<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}/kano_infra_toml/public>")
add_library(KanoInfra::toml ALIAS kano_infra_toml)
