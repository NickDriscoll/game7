package main

import "core:fmt"
import vgd "desktop_vulkan_wrapper"

main :: proc() {
    feature_set := vgd.Graphics_FeatureSet {}
    vgd.vulkan_init(feature_set)
}