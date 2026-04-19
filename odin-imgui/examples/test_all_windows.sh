#!/bin/bash
# TODO: glf2_opengl3 opens in background
odin run glfw_opengl3
odin run glfw_wgpu
# cd js_webgl && ./build.sh (doesn't compile on my machine?)
# cd ..
cd js_wgpu && ./build.sh
cd ..
odin run null
odin run sdl2_directx11
odin run sdl2_opengl3
# odin run sdl2_sdlrenderer2 (odin version too old)

