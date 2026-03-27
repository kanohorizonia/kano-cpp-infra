add_library(kano_infra_self
    private/self_impl.cpp
)
target_include_directories(kano_infra_self PUBLIC
    "$<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/public>"
    "$<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}>"
)
add_library(KanoInfra::self ALIAS kano_infra_self)
