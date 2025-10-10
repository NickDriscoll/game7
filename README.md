# game7
3D platformer in Odin with a custom engine.
---
## Work completed so far
- Basic Vulkan renderer
    - Opinionated custom Vulkan wrapper
    - Barebones unlit shading
    - Static and skinned models loaded from glTF (.glb) files
    - Ray-traced hard shadows via VK_KHR_ray_query
    - Skeletal animation with the skinning-in-compute technique

![alt text](complex_anim_999999.gif "Simple 3D walking animation")
- Handrolled collision detection and game physics
- Basic level saving/loading
- Custom audio engine
    - Sine wave test output
    - .ogg file playback
- Bugs

## Build requirements

Download the following and put them in your PATH
- [Odin (ver. dev-2025-09)](https://github.com/odin-lang/Odin/releases/tag/dev-2025-09)
- [Slang (ver. 2025.18.2)](https://github.com/shader-slang/slang/releases/tag/v2025.18.2)

Clone the repo and init submodules
```
git clone git@github.com:NickDriscoll/game7.git
git submodule update --init --recursive
```

### Build on Windows
```
.\windows_build.bat debug
```

### Build on Linux
```
./linux_build.sh debug
```
