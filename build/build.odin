package build

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"

// Shader naming convention:
// Compiling shader stage "<stage>" of a file "shaders/<name>.slang" will yield "data/shaders/<name>.<stage>.spv"
// i.e. Compiling frag shader of "test" would be "shaders/test.slang" -> "data/shaders/test.frag.spv"
// Stages are one of {vert, frag, comp}
// Shader entry point should be named "<stage>_main"

BUILT_COMPILER_VENDOR_LIBS_LOCKFILE :: ".built_odin_vendor_libs"

// List of all .slang files with a vertex shader entry point
VERTEX_SHADERS : []string : {
    "imgui",
    "ps1",
    "postprocessing",
    "skybox",
    "debug"
}
SHADER_EXTRAS : [][2]string : {
    { "HardwareRT", "_rt" }
}

// List of all .slang files with a fragment shader entry point
FRAGMENT_SHADERS : []string : {
    "imgui",
    "ps1",
    "postprocessing",
    "skybox",
    "debug"
}

// List of all .slang files with a compute shader entry point
COMPUTE_SHADERS : []string : {
    "compute_skinning"
}

when ODIN_DEBUG {
    ODIN_COMMAND : []string : {
        "odin",
        "build",
        ".",
        "-debug",
        "-vet-shadowing",
        //"-vet-unused-imports",
        "-disallow-do",
        "-define:INCLUDE_PROFILER=true",
    }
} else {
    ODIN_COMMAND : []string : {
        "odin",
        "build",
        ".",
        "-o:speed",
        "-lto:thin",
        "-vet-shadowing",
        //"-vet-unused-imports",
        "-disallow-do",
        "-disable-assert",
        "-no-bounds-check",
        "-define:INCLUDE_PROFILER=true",
    }
}

SlangProcess :: struct {
    process: os.Process,
    shader_name: string,
}

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
    log.infof("starting program build with ODIN_DEBUG==%v...", ODIN_DEBUG)

    when ODIN_OS == .Linux {
        if !os.exists(BUILT_COMPILER_VENDOR_LIBS_LOCKFILE) {
            log.info("Building odin vendor libraries...")
            d := os.Process_Desc {
                command = {
                    "make",
                    "-C",
                    ODIN_ROOT + "vendor/stb/src"
                }
            }
            d2 := os.Process_Desc {
                command = {
                    "make",
                    "-C",
                    ODIN_ROOT + "vendor/cgltf/src"
                }
            }
            process, e := os.process_start(d)
            process2, e2 := os.process_start(d2)
            if e != nil {
                log.errorf("Error compiling odin vendor libs: %v", e)
            }
            if e2 != nil {
                log.errorf("Error compiling odin vendor libs: %v", e2)
            }

            _, _ = os.process_wait(process)
            _, _ = os.process_wait(process2)

            _, err := os.create(BUILT_COMPILER_VENDOR_LIBS_LOCKFILE)
            if err != nil {
                log.errorf("Unable to create \"./" + 
                            BUILT_COMPILER_VENDOR_LIBS_LOCKFILE + 
                            "\": %v", err)
            }
        }
    }

    // String builders for formatting input and output path strings
    in_sb: strings.Builder
    out_sb: strings.Builder
    strings.builder_init(&in_sb)
    strings.builder_init(&out_sb)
    defer strings.builder_destroy(&in_sb)
    defer strings.builder_destroy(&out_sb)

    // stdout file path string builder
    file_sb: strings.Builder
    strings.builder_init(&file_sb)
    defer strings.builder_destroy(&file_sb)

    // Dynamic array for gathering process handles to wait on
    processes: [dynamic]SlangProcess
    defer delete(processes)

    // File handles for output stream files
    streamout_files: [dynamic]^os.File
    defer delete(streamout_files)

    // Need to create log directory if it doesn't exist
    os.make_directory_all("./build/logs")

    new_log_file :: proc(name: string) -> ^os.File {
        sb: strings.Builder
        strings.builder_init(&sb)
        defer strings.builder_destroy(&sb)
        path := fmt.sbprintf(&sb, "./build/logs/%v.log", name)

        f, err := os.create(path)
        if err != nil {
            log.warnf("Failed to create log file at \"%v\": %v", path, err)
        }

        return f;
    }

    // Need to create shader spir-v directory
    os.make_directory_all("./data/shaders")

    shader_types : []string = {"vertex", "fragment", "compute"}
    entry_points: []string = {"vertex_main", "fragment_main", "compute_main"}
    shader_lists : [][]string = {VERTEX_SHADERS, FRAGMENT_SHADERS, COMPUTE_SHADERS}

    for i in 0..<3 {
        list := shader_lists[i]
        type := shader_types[i]
        entry_point := entry_points[i]

        log.infof("building %v shaders...", type)
        for shader in list {
            out_path := fmt.sbprintf(&in_sb, "./data/shaders/%v.%v.spv", shader, type[0:4])
            in_path := fmt.sbprintf(&out_sb, "./shaders/%v.slang", shader)

            log_name := fmt.sbprintf(&file_sb, "%v.%v.stdout", shader, type[0:4])
            stdout_file := new_log_file(log_name)
            strings.builder_reset(&file_sb)
            logerr_name := fmt.sbprintf(&file_sb, "%v.%v.stderr", shader, type[0:4])
            stderr_file := new_log_file(logerr_name)
            strings.builder_reset(&file_sb)
            append(&streamout_files, stdout_file)
            append(&streamout_files, stderr_file)

            slangc_command := os.Process_Desc {
                command = {
                    "slangc",
                    "-stage",
                    type,
                    "-g3",
                    "-Wno-39001",   // Ignore aliased descriptor bindings warning
                    "-entry",
                    entry_point,
                    "-o",
                    out_path,
                    in_path
                },
		        stdout = stdout_file,
                stderr = stderr_file,
            }

            p, error := os.process_start(slangc_command)
            if error != nil {
                log.errorf("Error launching slangc: %#v", error)
                return
            }
            process := SlangProcess {
                process = p,
                shader_name = shader,
            }
            command_str := strings.join(slangc_command.command, " ")
            log.debugf("Launching:\n\"%v\"", command_str)
            append(&processes, process)
            strings.builder_reset(&in_sb)
            strings.builder_reset(&out_sb)

            for extra in SHADER_EXTRAS {
                out_path := fmt.sbprintf(&in_sb, "./data/shaders/%v%v.%v.spv", shader, extra[1], type[0:4])
                in_path := fmt.sbprintf(&out_sb, "./shaders/%v.slang", shader)

                out_name := fmt.sbprintf(&file_sb, "%v%v.%v.stdout", shader, extra[1], type[0:4])
                stdout_file := new_log_file(out_name)
                strings.builder_reset(&file_sb)
                err_name := fmt.sbprintf(&file_sb, "%v%v.%v.stderr", shader, extra[1], type[0:4])
                stderr_file := new_log_file(err_name)
                strings.builder_reset(&file_sb)
                append(&streamout_files, stdout_file)
                append(&streamout_files, stderr_file)

                slangc_command := os.Process_Desc {
                    command = {
                        "slangc",
                        "-stage",
                        type,
                        "-g3",
                        "-Wno-39001",   // Ignore aliased descriptor bindings warning
                        "-entry",
                        entry_point,
                        "-D",
                        extra[0],
                        "-o",
                        out_path,
                        in_path
                    },
		            stdout = stdout_file,
                    stderr = stderr_file,
                }

                p, error := os.process_start(slangc_command)
                if error != nil {
                    log.errorf("Error launching slangc: %#v", error)
                    return
                }
                process := SlangProcess {
                    process = p,
                    shader_name = shader,
                }
                command_str := strings.join(slangc_command.command, " ")
                log.debugf("Launching:\n\"%v\"", command_str)
                append(&processes, process)
                strings.builder_reset(&in_sb)
                strings.builder_reset(&out_sb)
            }
        }
    }

    // Wait on the shader compilers
    log.infof("waiting on shader compilation for %v shaders...", len(processes))
    for p in processes {
        proc_state, _ := os.process_wait(p.process)

        if proc_state.exit_code != 0 {
            log.errorf(
                "slangc process with id %v exited with return code %v. Please see \"./build/logs/%v.*\"",
                proc_state.pid,
                proc_state.exit_code,
                p.shader_name
            )
            return
        }
    }

    // Start odin compilation
    log.info("starting odin compiler...")
    odin_process: os.Process
    {
        stdout_file := new_log_file("main.stdout")
        stderr_file := new_log_file("main.stderr")
        append(&streamout_files, stdout_file)

        odin_proc := os.Process_Desc {
            command = ODIN_COMMAND,
            stdout = stdout_file,
	        stderr = stderr_file,
        }
        command_str := strings.join(odin_proc.command, " ")
        log.debugf("Launching:\n\"%v\"", command_str)
        odin_process, _ = os.process_start(odin_proc)
    }

    // wait for the odin compiler
    log.info("waiting on odin compiler...")
    {
        proc_state, _ := os.process_wait(odin_process)
	    if proc_state.exit_code != 0 {
            log.errorf("main program failed to build with exit code %v. Please see ./build/logs/main.stdout.log and main.stderr.log", proc_state.exit_code)
            return
        }
    }

    // Close the stdout files for the various subprocesses
    for file in streamout_files {
        os.close(file)
    }

    log.info("Program compilation succeeded!")
}
