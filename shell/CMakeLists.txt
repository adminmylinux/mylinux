cmake_minimum_required(VERSION 3.21)
project(myshell VERSION 0.1 LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(Qt6 6.5 REQUIRED COMPONENTS Core Gui Network Qml Quick WaylandCompositor)
qt_standard_project_setup(REQUIRES 6.5)

qt_add_executable(myshell main.cpp launcher.cpp launcher.h settings.cpp settings.h agentusage.cpp agentusage.h themestore.cpp themestore.h keygrab.cpp keygrab.h)

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
        FirstRun.qml
        Tiling.qml
        KeyHelp.qml
    RESOURCES
        assets/wallpaper.png
        assets/icons/terminal.svg
        assets/icons/chatgpt.svg
        assets/icons/claude.svg
        assets/icons/claudecode.svg
        assets/icons/codex.svg
        assets/icons/firefox.svg
        assets/icons/chromium.svg
)

target_link_libraries(myshell PRIVATE Qt6::Core Qt6::Gui Qt6::Network Qt6::Qml Qt6::Quick Qt6::WaylandCompositor)
install(TARGETS myshell RUNTIME DESTINATION bin)
