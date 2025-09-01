package main

import "core:log"
import "core:prof/spall"

Profiler :: struct {
    spall_ctx: spall.Context,
    spall_buffer: spall.Buffer
}

init_profiler :: proc(trace_file: string, allocator := context.allocator) -> Profiler {
    profiler: Profiler
    
    when ODIN_DEBUG {
        spall_ok := false
        profiler.spall_ctx, spall_ok = spall.context_create(trace_file)
        if !spall_ok {
            log.error("Error creating spall context")
        }
        buffer_backing := make([]u8, spall.BUFFER_DEFAULT_SIZE, allocator = allocator)
        profiler.spall_buffer = spall.buffer_create(buffer_backing, 0)
    }

    return profiler
}

quit_profiler :: proc(profiler: ^Profiler) {
    when ODIN_DEBUG {
        spall.buffer_destroy(&profiler.spall_ctx, &profiler.spall_buffer)
        spall.context_destroy(&profiler.spall_ctx)
    }
}

@(deferred_in=_scoped_end)
scoped_event :: proc(profiler: ^Profiler, label: string) {
    when ODIN_DEBUG {
        spall._buffer_begin(&profiler.spall_ctx, &profiler.spall_buffer, label)
    }
}

@(private)
_scoped_end :: proc(profiler: ^Profiler, _: string) {
    when ODIN_DEBUG {
        spall._buffer_end(&profiler.spall_ctx, &profiler.spall_buffer)
    }
}
