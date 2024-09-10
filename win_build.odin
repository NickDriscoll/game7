package main

import "core:fmt"
import "core:os"
//import "core:c/libc"
import "core:os/os2"

VERTEX_SHADERS : []string : {
    "shaders/test.slang"
}

FRAGMENT_SHADERS : []string : {
    "shaders/test.slang"
}



main :: proc() {
    fmt.println("balls")

    slang_desc := os2.Process_Desc {
        command = {
            "slangc",
            "-stage",
            "fragment",
            "-entry",
            "fragment_main",
            "-o",
            "./data/shaders/test.frag.spv",
            "./shaders/test.slang"
        }
    }
    process, error := os2.process_start(slang_desc)

    fmt.println("Waiting for slangc...")
    state, error2 := os2.process_wait(process)
    
}