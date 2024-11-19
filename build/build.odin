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
    "test",
    "imgui",
    "ps1",
    "postprocessing"
}

// List of all .slang files with a fragment shader entry point
FRAGMENT_SHADERS : []string : {
    "test",
    "imgui",
    "ps1",
    "postprocessing"
}

// List of all .slang files with a compute shader entry point
COMPUTE_SHADERS : []string : {

}

when ODIN_DEBUG {
    ODIN_COMMAND : []string : {"odin", "build", ".", "-debug"}
} else {
    ODIN_COMMAND : []string : {"odin", "build", "."}
}

// @TODO: Automatically compile stb on Linux platforms

main :: proc() {
    // Parse command-line arguments
    log_level := log.Level.Info
    context.logger = log.create_console_logger(log_level)
    {
        argc := len(os.args)
        for arg, i in os.args {
            if arg == "--log-level" || arg == "-l" {
                if i + 1 < argc {
                    switch os.args[i + 1] {
                        case "DEBUG": log_level = .Debug
                        case "INFO": log_level = .Info
                        case "WARNING": log_level = .Warning
                        case "ERROR": log_level = .Error
                        case "FATAL": log_level = .Fatal
                        case: log.warnf(
                            "Unrecognized --log-level: %v. Using default (%v)",
                            os.args[i + 1],
                            log_level
                        )
                    }
                }
            }
        }
    }
    context.logger = log.create_console_logger(log_level)

    log.info("starting program build...")

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
            log.errorf("%#v", error)
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
            log.errorf("%#v", error)
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

    // Wait on the shader compilers
    log.info("waiting on slangc...")
    for p in processes {
        proc_state, _ := os2.process_wait(p)

        if proc_state.exit_code != 0 {
            log.errorf("slangc process with id %v exited with return code %v", proc_state.pid, proc_state.exit_code)
            return
        }
    }
    
    // Invoke the odin compiler
    log.info("building main program...")
    {
        odin_proc := os2.Process_Desc {
            command = ODIN_COMMAND
        }
        process, error := os2.process_start(odin_proc)
        if error != nil {
            fmt.printfln("%#v", error)
            return
        }
        proc_state, _ := os2.process_wait(process)
	
	if proc_state.exit_code != 0 {
            log.errorf("main program failed to build.")
        }
    }

    
    log.info("Done!")
}
