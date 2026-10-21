find_package(CURL 8 REQUIRED)
add_library(kano_infra_http private/http.cpp)
target_compile_features(kano_infra_http PUBLIC cxx_std_17)
target_include_directories(kano_infra_http PUBLIC
    "$<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/public>"
    "$<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}/kano_infra_http/public>")
target_link_libraries(kano_infra_http PUBLIC CURL::libcurl)
if(WIN32)
    target_link_libraries(kano_infra_http PRIVATE ws2_32)
endif()
set_target_properties(kano_infra_http PROPERTIES EXPORT_NAME http)
add_library(KanoInfra::http ALIAS kano_infra_http)
