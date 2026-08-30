# Unit tests for the non-UI half of the app. They link opencouch_core, the same
# objects the application ships.

find_package(Qt6 REQUIRED COMPONENTS Test)

set(OPENCOUCH_TESTS
    tst_displaysettingsvalidator
    tst_engineclient
    tst_configstore
    tst_appcleanupmodel
)

foreach(_test IN LISTS OPENCOUCH_TESTS)
    qt_add_executable(${_test} ${_test}.cpp)
    target_link_libraries(${_test} PRIVATE opencouch_core Qt6::Test)
    target_compile_definitions(${_test} PRIVATE
        OPENCOUCH_TEST_FIXTURES="${CMAKE_CURRENT_SOURCE_DIR}/fixtures"
    )
    add_test(NAME ${_test} COMMAND ${_test})
    # Qt needs a platform plugin even for GUI-less tests once QtGui is linked.
    set_tests_properties(${_test} PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen")
endforeach()
