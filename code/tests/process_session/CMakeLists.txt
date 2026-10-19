cmake_minimum_required(VERSION 3.16)
if(CMAKE_SOURCE_DIR STREQUAL CMAKE_CURRENT_SOURCE_DIR)
    project(kano-process-session-contract LANGUAGES CXX)
    enable_testing()
    include("${CMAKE_CURRENT_LIST_DIR}/../../../scripts/cmake/KanoInfraUnattended.cmake")
endif()

add_library(kano_process_session_test_impl STATIC
    ../../systems/kano_infra_process/private/process_impl.cpp)
target_compile_definitions(kano_process_session_test_impl PRIVATE KANO_PROCESS_TESTING)
target_compile_features(kano_process_session_test_impl PUBLIC cxx_std_17)
target_include_directories(kano_process_session_test_impl PUBLIC
    "${CMAKE_CURRENT_LIST_DIR}/../../systems/kano_infra_process/public")
if(NOT WIN32)
    find_package(Threads REQUIRED)
    target_link_libraries(kano_process_session_test_impl PUBLIC Threads::Threads)
endif()
add_executable(kano_process_session_child process_session_child.cpp)
target_link_libraries(kano_process_session_child PRIVATE kano_process_session_test_impl KanoInfra::unattended)
add_executable(kano_process_session_tests process_session_tests.cpp)
target_compile_definitions(kano_process_session_tests PRIVATE KANO_PROCESS_TESTING
    "KANO_SESSION_CHILD_PATH=\"$<TARGET_FILE:kano_process_session_child>\"")
target_link_libraries(kano_process_session_tests PRIVATE kano_process_session_test_impl KanoInfra::unattended)
add_dependencies(kano_process_session_tests kano_process_session_child)
add_test(NAME infra.process_session COMMAND kano_process_session_tests)
set_tests_properties(infra.process_session PROPERTIES TIMEOUT 30
    ENVIRONMENT "KANO_UNATTENDED=1" LABELS "process;session;${KANO_PROCESS_SESSION_TEST_LABELS}")
