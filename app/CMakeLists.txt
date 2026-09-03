cmake_minimum_required(VERSION 3.16)

# Version source of truth: git tags when available, falling back to
# app/version.txt for builds without .git.
set(OPENCOUCH_VERSION "")
set(OPENCOUCH_RELEASE_DATE "")
find_package(Git QUIET)
if(GIT_FOUND AND EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/.git")
    execute_process(
        COMMAND "${GIT_EXECUTABLE}" describe --tags --match "v*" --abbrev=0
        WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
        OUTPUT_VARIABLE OPENCOUCH_GIT_TAG
        OUTPUT_STRIP_TRAILING_WHITESPACE
        ERROR_QUIET
    )
    if(OPENCOUCH_GIT_TAG)
        string(REGEX REPLACE "^v" "" OPENCOUCH_VERSION "${OPENCOUCH_GIT_TAG}")
        execute_process(
            COMMAND "${GIT_EXECUTABLE}" log -1 --format=%cs "${OPENCOUCH_GIT_TAG}"
            WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
            OUTPUT_VARIABLE OPENCOUCH_RELEASE_DATE
            OUTPUT_STRIP_TRAILING_WHITESPACE
            ERROR_QUIET
        )
    endif()
endif()
if(NOT OPENCOUCH_VERSION)
    file(STRINGS "${CMAKE_CURRENT_SOURCE_DIR}/version.txt" OPENCOUCH_VERSION_LINES)
    foreach(_line IN LISTS OPENCOUCH_VERSION_LINES)
        if(_line MATCHES "^VERSION=(.+)$")
            set(OPENCOUCH_VERSION "${CMAKE_MATCH_1}")
        elseif(_line MATCHES "^RELEASE_DATE=(.+)$")
            set(OPENCOUCH_RELEASE_DATE "${CMAKE_MATCH_1}")
        endif()
    endforeach()
endif()
if(NOT OPENCOUCH_VERSION OR NOT OPENCOUCH_RELEASE_DATE)
    message(FATAL_ERROR "Could not determine version: set a git tag (vX.Y.Z) or app/version.txt")
endif()

project(opencouch VERSION "${OPENCOUCH_VERSION}" LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

if(EXISTS "${CMAKE_SOURCE_DIR}/packaging")
    set(OPENCOUCH_PACKAGING_DIR "${CMAKE_SOURCE_DIR}/packaging")
else()
    set(OPENCOUCH_PACKAGING_DIR "${CMAKE_SOURCE_DIR}/../packaging")
endif()

configure_file(
    "${CMAKE_CURRENT_SOURCE_DIR}/src/appversion.h.in"
    "${CMAKE_CURRENT_BINARY_DIR}/generated/appversion.h"
    @ONLY
)

configure_file(
    "${OPENCOUCH_PACKAGING_DIR}/io.github.gustavobelo.opencouch.metainfo.xml"
    "${CMAKE_CURRENT_BINARY_DIR}/generated/io.github.gustavobelo.opencouch.metainfo.xml"
    @ONLY
)

find_package(ECM REQUIRED NO_MODULE)
set(CMAKE_MODULE_PATH ${ECM_MODULE_PATH})

find_package(Qt6 REQUIRED COMPONENTS Core Gui Widgets LinguistTools Qml Quick QuickControls2 DBus)
find_package(KF6Kirigami REQUIRED)

qt_add_executable(opencouch
    src/main.cpp
    src/applicationicon.cpp
    src/applicationicon.h
    src/backend.cpp
    src/backend.h
    src/configstore.cpp
    src/configstore.h
    src/engineclient.cpp
    src/engineclient.h
    src/appinfomodel.cpp
    src/appinfomodel.h
    src/appcleanupmodel.cpp
    src/appcleanupmodel.h
)

qt_add_qml_module(opencouch
    URI io.github.gustavobelo.opencouch
    VERSION 1.0
    QML_FILES
        qml/main.qml
        qml/SetupPage.qml
        qml/DashboardPage.qml
        qml/OnboardingSheet.qml
        qml/ChooseAppDialog.qml
        qml/RunningAppsDialog.qml
        qml/AppRowDelegate.qml
    RESOURCES
)

qt_add_resources(OPENCOUCH_ICON_RESOURCES applicationicon.qrc)
target_sources(opencouch PRIVATE ${OPENCOUCH_ICON_RESOURCES})

qt_add_translations(opencouch
    RESOURCE_PREFIX "/i18n"
    LRELEASE_OPTIONS -idbased
    TS_FILES
        translations/opencouch_en.ts
        translations/opencouch_pt_BR.ts
        translations/opencouch_en_GB.ts
        translations/opencouch_de_DE.ts
        translations/opencouch_es_ES.ts
        translations/opencouch_fr_FR.ts
        translations/opencouch_zh_CN.ts
)

target_link_libraries(opencouch PRIVATE
    Qt6::Core
    Qt6::Gui
    Qt6::Widgets
    Qt6::Qml
    Qt6::Quick
    Qt6::QuickControls2
    Qt6::DBus
)

target_include_directories(opencouch PRIVATE
    "${CMAKE_CURRENT_BINARY_DIR}/generated"
)

include(GNUInstallDirs)

install(TARGETS opencouch DESTINATION ${CMAKE_INSTALL_BINDIR})
install(FILES ${OPENCOUCH_PACKAGING_DIR}/io.github.gustavobelo.opencouch.desktop
        DESTINATION ${CMAKE_INSTALL_DATADIR}/applications)
install(FILES ${CMAKE_CURRENT_BINARY_DIR}/generated/io.github.gustavobelo.opencouch.metainfo.xml
        DESTINATION ${CMAKE_INSTALL_DATADIR}/metainfo)
install(FILES ${OPENCOUCH_PACKAGING_DIR}/icons/io.github.gustavobelo.opencouch.svg
        DESTINATION ${CMAKE_INSTALL_DATADIR}/icons/hicolor/scalable/apps)

# The engine is a separate Go binary rather than part of this target: it runs as
# the login session itself, long before and long after the app, and the app only
# ever drives it over QProcess.
if(EXISTS "${CMAKE_SOURCE_DIR}/engine")
    set(OPENCOUCH_ENGINE_DIR "${CMAKE_SOURCE_DIR}/engine")
else()
    set(OPENCOUCH_ENGINE_DIR "${CMAKE_SOURCE_DIR}/../engine")
endif()
set(OPENCOUCH_ENGINE_BINARY "${CMAKE_CURRENT_BINARY_DIR}/open-couch-engine")

find_program(GO_EXECUTABLE go REQUIRED)

# Always out of date on purpose: Go's own build cache decides what to rebuild,
# and listing every source here would go stale the first time one is added.
add_custom_target(engine ALL
    COMMAND "${CMAKE_COMMAND}" -E env GOFLAGS=-mod=mod
            "${GO_EXECUTABLE}" build -trimpath
            -ldflags "-s -w -X main.version=${OPENCOUCH_VERSION}"
            -o "${OPENCOUCH_ENGINE_BINARY}"
            ./cmd/open-couch-engine
    WORKING_DIRECTORY "${OPENCOUCH_ENGINE_DIR}"
    COMMENT "Building open-couch-engine ${OPENCOUCH_VERSION}"
    VERBATIM
)

option(INSTALL_ENGINE_BUNDLE "Bundle the engine for AppImage distribution" OFF)
if(INSTALL_ENGINE_BUNDLE)
    install(PROGRAMS "${OPENCOUCH_ENGINE_BINARY}"
        DESTINATION "${CMAKE_INSTALL_DATADIR}/open-couch"
    )
endif()

# Defines BUILD_TESTING and calls enable_testing(). Without it add_test() below
# is accepted and silently registers nothing.
include(CTest)

if(BUILD_TESTING)
    add_test(NAME engine
        COMMAND "${GO_EXECUTABLE}" test ./...
    )
    set_tests_properties(engine PROPERTIES
        WORKING_DIRECTORY "${OPENCOUCH_ENGINE_DIR}"
    )
endif()