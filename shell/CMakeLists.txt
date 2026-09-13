cmake_minimum_required(VERSION 3.21)
project(myshell VERSION 0.1 LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(Qt6 6.5 REQUIRED COMPONENTS Core Gui Network Qml Quick WaylandCompositor)
qt_standard_project_setup(REQUIRES 6.5)

qt_add_executable(myshell main.cpp launcher.cpp launcher.h settings.cpp settings.h agentusage.cpp agentusage.h themestore.cpp themestore.h keygrab.cpp keygrab.h tailscale.cpp tailscale.h secrets.cpp secrets.h weather.cpp weather.h barmodules.cpp barmodules.h http.cpp http.h)

set_source_files_properties(Theme.qml PROPERTIES QT_QML_SINGLETON_TYPE TRUE)

qt_add_qml_module(myshell
    URI MyShell
    VERSION 1.0
    QML_FILES
        Main.qml
        Desktop.qml
        MacWindow.qml
        Dock.qml
        MenuBar.qml
        AppIcon.qml
        GlassPanel.qml
        Theme.qml
        DisplayPanel.qml
        Spotlight.qml
        AgentPanel.qml
        TailscalePanel.qml
        SettingsPanel.qml
        FirstRun.qml
        Tiling.qml
        KeyHelp.qml
        DesktopWidgets.qml
    RESOURCES
        assets/wallpaper.png
        assets/icons/terminal.svg
        assets/icons/chatgpt.svg
        assets/icons/claude.svg
        assets/icons/claudecode.svg
        assets/icons/codex.svg
        assets/icons/firefox.svg
        assets/icons/chromium.svg
        assets/icons/remote.svg
)

target_link_libraries(myshell PRIVATE Qt6::Core Qt6::Gui Qt6::Network Qt6::Qml Qt6::Quick Qt6::WaylandCompositor)
install(TARGETS myshell RUNTIME DESTINATION bin)

# ---- vncview: the VNC viewer (needs libvncclient; skipped when the SDK sysroot lacks it) ----
find_package(PkgConfig QUIET)
if(PkgConfig_FOUND)
    pkg_check_modules(VNC IMPORTED_TARGET libvncclient)
endif()
if(VNC_FOUND)
    qt_add_executable(vncview vncview/main.cpp vncview/vncsession.cpp vncview/vncsession.h vncview/vncsurface.cpp vncview/vncsurface.h vncview/machines.cpp vncview/machines.h vncview/vnccert.cpp vncview/vnccert.h)
    target_include_directories(vncview PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/vncview)   # the generated type registration includes <vncsurface.h> etc.
    qt_add_qml_module(vncview URI VncView VERSION 1.0 QML_FILES vncview/Main.qml)
    target_link_libraries(vncview PRIVATE Qt6::Core Qt6::Gui Qt6::Network Qt6::Qml Qt6::Quick PkgConfig::VNC)
    # Buildroot builds in the source tree, where "vncview" is also the source directory: put the binary under bin/
    set_target_properties(vncview PROPERTIES RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)
    install(TARGETS vncview RUNTIME DESTINATION bin)
else()
    message(STATUS "libvncclient not found: vncview is not built")
endif()
