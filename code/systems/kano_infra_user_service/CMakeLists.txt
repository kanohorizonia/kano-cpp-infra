add_library(kano_infra_user_service private/user_service.cpp)
target_compile_features(kano_infra_user_service PUBLIC cxx_std_17)
target_include_directories(kano_infra_user_service PUBLIC
    "$<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/public>"
    "$<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}/kano_infra_user_service/public>")
target_link_libraries(kano_infra_user_service PUBLIC KanoInfra::process KanoInfra::platform)
add_library(KanoInfra::user_service ALIAS kano_infra_user_service)
