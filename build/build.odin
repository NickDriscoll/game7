package build

import "core:fmt"
import "core:log"
import "core:os"
import "core:os/os2"
import "core:strings"

// Shader naming convention:
// "shaders/<name>.<stage>.slang" will become "data/shaders/<name>.<stage>.spv"
// i.e. "shaders/test.vert.slang" -> "shaders/test.frag.spv"
// Stages are one of {vert, frag, comp}
// Shader entry point should be named "<stage>_main"

// List of all .slang files with a vertex shader entry point
VERTEX_SHADERS : []string : {
    "test"
}

// List of all .slang files with a fragment shader entry point
FRAGMENT_SHADERS : []string : {
    "test"
}

// List of all .slang files with a compute shader entry point
COMPUTE_SHADERS : []string : {

}

when ODIN_DEBUG {
    ODIN_COMMAND : []string : {"odin", "build", ".", "-debug"}
} else {
    ODIN_COMMAND : []string : {"odin", "build", "."}
}

main :: proc() {
    context.logger = log.create_console_logger(.Info)

    log.info("building program...")

    // String builders for formatting input and output path strings
    in_sb: strings.Builder
    out_sb: strings.Builder
    strings.builder_init(&in_sb)
    strings.builder_init(&out_sb)
    defer strings.builder_destroy(&in_sb)
    defer strings.builder_destroy(&out_sb)

    // Dynamic array for gathering process handles to wait on
    processes: [dynamic]os2.Process
    defer delete(processes)

    log.info("building vertex shaders...")
    for path in VERTEX_SHADERS {
        out_path := fmt.sbprintf(&in_sb, "./data/shaders/%v.vert.spv", path)
        in_path := fmt.sbprintf(&out_sb, "./shaders/%v.slang", path)
        strings.builder_reset(&in_sb)
        strings.builder_reset(&out_sb)

        slangc_command := os2.Process_Desc {
            command = {
                "slangc",
                "-stage",
                "vertex",
                "-entry",
                "vertex_main",
                "-o",
                out_path,
                in_path
            }
        }

        process, error := os2.process_start(slangc_command)
        if error != nil {
            fmt.printfln("%#v", error)
            return
        }
        append(&processes, process)
    }

    log.info("building fragment shaders...")
    for path in FRAGMENT_SHADERS {
        out_path := fmt.sbprintf(&in_sb, "./data/shaders/%v.frag.spv", path)
        in_path := fmt.sbprintf(&out_sb, "./shaders/%v.slang", path)
        strings.builder_reset(&in_sb)
        strings.builder_reset(&out_sb)

        slangc_command := os2.Process_Desc {
            command = {
                "slangc",
                "-stage",
                "fragment",
                "-entry",
                "fragment_main",
                "-o",
                out_path,
                in_path
            }
        }

        process, error := os2.process_start(slangc_command)
        if error != nil {
            fmt.printfln("%#v", error)
            return
        }
        append(&processes, process)
    }

    log.info("building compute shaders...")
    for path in COMPUTE_SHADERS {
        out_path := fmt.sbprintf(&in_sb, "./data/shaders/%v.comp.spv", path)
        in_path := fmt.sbprintf(&out_sb, "./shaders/%v.slang", path)
        strings.builder_reset(&in_sb)
        strings.builder_reset(&out_sb)

        slangc_command := os2.Process_Desc {
            command = {
                "slangc",
                "-stage",
                "compute",
                "-entry",
                "compute_main",
                "-o",
                out_path,
                in_path
            }
        }

        process, error := os2.process_start(slangc_command)
        if error != nil {
            fmt.printfln("%#v", error)
            return
        }
        append(&processes, process)
    }
    
    // Invoke the odin compiler
    {
        odin_proc := os2.Process_Desc {
            command = ODIN_COMMAND
        }
        process, error := os2.process_start(odin_proc)
        if error != nil {
            fmt.printfln("%#v", error)
            return
        }
        append(&processes, process)
    }

    // Wait on all the spawned processes
    log.info("waiting...")
    for p in processes {
        _, _ = os2.process_wait(p)
    }
    
    log.info("Done!")
}