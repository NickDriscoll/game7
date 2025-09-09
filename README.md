# game7
3D platformer in Odin with a custom engine.
---
## Work completed so far
- Basic Vulkan renderer
    - Opinionated custom Vulkan wrapper
    - Barebones unlit shading
    - Static and skinned models loaded from glTF (.glb) files
    - Skeletal animation with the skinning-in-compute technique

![alt text](complex_anim_999999.gif "Simple 3D walking animation")
- Handrolled collision detection and game physics
- Basic level saving/loading
- Custom audio engine
    - Sine wave test output
    - .ogg file playback
- Bugs

## Build requirements

- [Odin (ver. dev-2025-09)](https://github.com/odin-lang/Odin/releases/tag/dev-2025-09)
- [Slang](https://github.com/shader-slang/slang/releases)

## Build

- powershell`.\windows_build.bat debug`
- bash`./linux_build.sh debug`