add_library(kano_infra_build_info
    private/build_info_impl.cpp
)
target_include_directories(kano_infra_build_info PUBLIC
    "$<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/public>"
    "$<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}>"
)
add_library(KanoInfra::build_info ALIAS kano_infra_build_info)
