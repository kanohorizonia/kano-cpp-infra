cmake_minimum_required(VERSION 3.16)

if(NOT TARGET KanoInfra::unattended)
    include("${CMAKE_CURRENT_LIST_DIR}/../../../scripts/cmake/KanoInfraUnattended.cmake")
endif()
foreach(_module platform process user_service)
    if(NOT TARGET KanoInfra::${_module})
        add_subdirectory("${CMAKE_CURRENT_LIST_DIR}/../../systems/kano_infra_${_module}"
            "${CMAKE_CURRENT_BINARY_DIR}/dependencies/${_module}")
    endif()
endforeach()

if(NOT TARGET Catch2::Catch2)
    find_package(Catch2 3.5.2 CONFIG QUIET)
endif()
if(NOT TARGET Catch2::Catch2)
    include(FetchContent)
    FetchContent_Declare(kano_infra_test_catch2
        GIT_REPOSITORY https://github.com/catchorg/Catch2.git
        GIT_TAG v3.5.2
        GIT_SHALLOW TRUE)
    FetchContent_MakeAvailable(kano_infra_test_catch2)
endif()

add_executable(kano_user_service_child user_service_child.cpp)
target_compile_features(kano_user_service_child PRIVATE cxx_std_17)
target_link_libraries(kano_user_service_child PRIVATE
    KanoInfra::platform KanoInfra::process KanoInfra::unattended)

add_executable(kano_user_service_tests user_service_tests.cpp)
target_compile_features(kano_user_service_tests PRIVATE cxx_std_17)
target_compile_definitions(kano_user_service_tests PRIVATE
    "KANO_USER_SERVICE_CHILD_PATH=\"$<TARGET_FILE:kano_user_service_child>\"")
target_link_libraries(kano_user_service_tests PRIVATE Catch2::Catch2
    KanoInfra::user_service KanoInfra::platform KanoInfra::process KanoInfra::unattended)
add_dependencies(kano_user_service_tests kano_user_service_child)
add_test(NAME infra.user_service COMMAND kano_user_service_tests)
set_tests_properties(infra.user_service PROPERTIES TIMEOUT 60
    ENVIRONMENT "KANO_UNATTENDED=1" LABELS "user_service;process")
