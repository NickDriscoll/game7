#pragma once

// @CONFIGURE:
// This file can be filled with config lines in the same way as imconfig.h!
// These will be used in compilation, and will be written into the bindings
// However this support is _VERY VERY_ early and will probably go kablooey!

// Note: as of v1.91.5, the d3d12 backend cannot be built without obsolete functions disabled,
// as they overload ImGui_ImplDX12_Init, which is extern "C".
#define IMGUI_DISABLE_OBSOLETE_FUNCTIONS
