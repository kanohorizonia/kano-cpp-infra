include_guard(GLOBAL)

# Lightweight startup target: no JsonCpp, process library, or executable build.
if(NOT TARGET KanoInfra::unattended)
    get_filename_component(_kano_unattended_root "${CMAKE_CURRENT_LIST_DIR}/../.." ABSOLUTE)
    if(EXISTS "${_kano_unattended_root}/code/systems/kano_infra_unattended/CMakeLists.txt")
        include(GNUInstallDirs)
        add_subdirectory("${_kano_unattended_root}/code/systems/kano_infra_unattended"
                         "${CMAKE_CURRENT_BINARY_DIR}/kano-infra-unattended")
    else()
        message(FATAL_ERROR "KanoInfra::unattended is missing from the installed package")
    endif()
endif()

function(_kano_infra_positive_timeout value context)
    # Literal decimal values are portable across all configurations. Reject
    # unevaluated generator expressions and non-finite spellings, rather than
    # claiming they provide a deadline.
    if(NOT "${value}" MATCHES "^[0-9]+(\\.[0-9]+)?$" OR NOT value GREATER 0 OR value GREATER 2147483647)
        message(FATAL_ERROR "${context}: TIMEOUT must be a finite positive decimal <= 2147483647; got '${value}'")
    endif()
endfunction()

# For runtime-discovered tests, pass this list to catch_discover_tests(PROPERTIES
# ${properties}). Directory traversal cannot see tests generated after configure.
function(kano_infra_test_properties output timeout_seconds)
    _kano_infra_positive_timeout("${timeout_seconds}" "Discovered test registration")
    set(${output} TIMEOUT "${timeout_seconds}" ENVIRONMENT "KANO_UNATTENDED=1" PARENT_SCOPE)
endfunction()

function(_kano_infra_finalize_directory directory timeout_seconds)
    get_property(_tests DIRECTORY "${directory}" PROPERTY TESTS)
    foreach(_test IN LISTS _tests)
        if(CMAKE_VERSION VERSION_LESS 3.28)
            get_property(_has_timeout TEST "${_test}" PROPERTY TIMEOUT SET)
            get_property(_timeout TEST "${_test}" PROPERTY TIMEOUT)
        else()
            get_property(_has_timeout TEST "${_test}" DIRECTORY "${directory}" PROPERTY TIMEOUT SET)
            get_property(_timeout TEST "${_test}" DIRECTORY "${directory}" PROPERTY TIMEOUT)
        endif()
        if(_has_timeout)
            _kano_infra_positive_timeout("${_timeout}" "Test '${_test}'")
        elseif(CMAKE_VERSION VERSION_LESS 3.28)
            set_property(TEST "${_test}" PROPERTY TIMEOUT "${timeout_seconds}")
        else()
            set_property(TEST "${_test}" DIRECTORY "${directory}" PROPERTY TIMEOUT "${timeout_seconds}")
        endif()
    endforeach()
    get_property(_children DIRECTORY "${directory}" PROPERTY SUBDIRECTORIES)
    if(_children AND CMAKE_VERSION VERSION_LESS 3.28)
        message(FATAL_ERROR "Tree timeout finalization requires CMake 3.28; call kano_infra_finalize_local_test_timeouts in each test directory")
    endif()
    foreach(_child IN LISTS _children)
        _kano_infra_finalize_directory("${_child}" "${timeout_seconds}")
    endforeach()
endfunction()

# Invoke after all add_subdirectory/add_test calls. Missing deadlines receive the
# chosen default; explicit zero/negative/empty/non-finite values are fatal errors.
function(kano_infra_finalize_test_timeouts timeout_seconds)
    _kano_infra_positive_timeout("${timeout_seconds}" "Default test registration")
    _kano_infra_finalize_directory("${CMAKE_CURRENT_SOURCE_DIR}" "${timeout_seconds}")
endfunction()

function(kano_infra_finalize_local_test_timeouts timeout_seconds)
    _kano_infra_positive_timeout("${timeout_seconds}" "Default local test registration")
    get_property(_tests DIRECTORY PROPERTY TESTS)
    foreach(_test IN LISTS _tests)
        get_property(_has_timeout TEST "${_test}" PROPERTY TIMEOUT SET)
        if(_has_timeout)
            get_property(_timeout TEST "${_test}" PROPERTY TIMEOUT)
            _kano_infra_positive_timeout("${_timeout}" "Test '${_test}'")
        else()
            set_property(TEST "${_test}" PROPERTY TIMEOUT "${timeout_seconds}")
        endif()
    endforeach()
endfunction()
