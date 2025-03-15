package build

import "core:fmt"
import "core:log"
import "core:os"
import "core:os/os2"
import "core:strings"

// Shader naming convention:
// Compiling shader stage <stage> of a file "shaders/<name>.slang" will yield "data/shaders/<name>.<stage>.spv"
// i.e. Compiling frag shader of "test" would be "shaders/test.slang" -> "shaders/test.frag.spv"
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
    "compute_skinning"
}

when ODIN_DEBUG {
    //ODIN_COMMAND : []string : {"odin", "build", ".", "-debug", "-vet-shadowing", "-strict-style"}
    ODIN_COMMAND : []string : {
        "odin",
        "build",
        ".",
        "-debug",
        "-vet-shadowing",
    }
} else {
    //ODIN_COMMAND : []string : {"odin", "build", ".", "-vet-shadowing", "-strict-style"}
    ODIN_COMMAND : []string : {
        "odin",
        "build",
        ".",
        "-vet-shadowing"
    }
}

// @TODO: Automatically compile stb on Linux platforms

main :: proc() {
    // Parse command-line arguments
    log_level := log.Level.Info
    context.logger = log.create_console_logger(log_level)
    {
        argc := len(os.args)
        for arg, i in os.args {
            switch arg {
                case "--log-level", "-l": {
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

        slangc_command := os2.Process_Desc {
            command = {
                "slangc",
                "-stage",
                "vertex",
                "-g3",
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
        strings.builder_reset(&in_sb)
        strings.builder_reset(&out_sb)
    }

    log.info("building fragment shaders...")
    for path in FRAGMENT_SHADERS {
        out_path := fmt.sbprintf(&in_sb, "./data/shaders/%v.frag.spv", path)
        in_path := fmt.sbprintf(&out_sb, "./shaders/%v.slang", path)

        slangc_command := os2.Process_Desc {
            command = {
                "slangc",
                "-stage",
                "fragment",
                "-g3",
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
        strings.builder_reset(&in_sb)
        strings.builder_reset(&out_sb)
    }

    log.info("building compute shaders...")
    for path in COMPUTE_SHADERS {
        out_path := fmt.sbprintf(&in_sb, "./data/shaders/%v.comp.spv", path)
        in_path := fmt.sbprintf(&out_sb, "./shaders/%v.slang", path)

        slangc_command := os2.Process_Desc {
            command = {
                "slangc",
                "-stage",
                "compute",
                "-g3",
                "-O0",      // Some compute shaders have invalid SPIR-V when optimizations are on. See https://github.com/KhronosGroup/SPIRV-Tools/issues/5959
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
        strings.builder_reset(&in_sb)
        strings.builder_reset(&out_sb)
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

    // Start odin compilation
    log.info("starting odin compiler...")
    odin_process: os2.Process
    {
        odin_proc := os2.Process_Desc {
            command = ODIN_COMMAND
        }
        odin_process, _ = os2.process_start(odin_proc)
    }
    
    // wait for the odin compiler
    log.info("waiting on odin compiler...")
    {
        proc_state, _ := os2.process_wait(odin_process)
	    if proc_state.exit_code != 0 {
            log.errorf("main program failed to build.")
        }
    }

    
    log.info("Done!")
}
