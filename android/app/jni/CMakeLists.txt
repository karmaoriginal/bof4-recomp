cmake_minimum_required(VERSION 3.22.1)
project(bof4_sdl2 C)

# Path to SDL2 source tree (populated by android/build.sh or passed via -DSDL2_DIR=...)
if(NOT DEFINED SDL2_DIR)
    set(SDL2_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../sdl2")
endif()

if(NOT EXISTS "${SDL2_DIR}/CMakeLists.txt")
    message(FATAL_ERROR "SDL2 source not found at ${SDL2_DIR}. Run android/build.sh or pass -DSDL2_DIR=/path/to/SDL2")
endif()

# Optimized SDL2 configuration for Android game port:
# - Shared libSDL2.so (required by SDLActivity + Odin libbof4.so)
# - Video, OpenGL ES, Vulkan, Audio (AAudio/OpenSLES), GameController, Joystick, HIDAPI, Haptic ON
# - Sensor-as-joystick OFF at runtime via hints; keep SDL_SENSOR disabled to cut battery overhead
set(SDL_SHARED ON CACHE BOOL "" FORCE)
set(SDL_STATIC OFF CACHE BOOL "" FORCE)
set(SDL_TEST OFF CACHE BOOL "" FORCE)
set(SDL_TESTS OFF CACHE BOOL "" FORCE)
set(SDL_SENSOR OFF CACHE BOOL "" FORCE)
set(SDL_POWER OFF CACHE BOOL "" FORCE)
set(SDL_HIDAPI ON CACHE BOOL "" FORCE)
set(SDL_HIDAPI_JOYSTICK ON CACHE BOOL "" FORCE)
set(SDL_VULKAN ON CACHE BOOL "" FORCE)
set(SDL_OPENGLES ON CACHE BOOL "" FORCE)

add_subdirectory("${SDL2_DIR}" "${CMAKE_CURRENT_BINARY_DIR}/sdl2-build" EXCLUDE_FROM_ALL)
