package main

import "core:log"
import "core:prof/spall"

Profiler :: struct {
    spall_ctx: spall.Context,
    spall_buffer: spall.Buffer,
    do_tracing: bool
}

init_profiler :: proc(trace_file: string, allocator := context.allocator) -> Profiler {
    profiler: Profiler

    spall_ok := false
    profiler.spall_ctx, spall_ok = spall.context_create(trace_file)
    if !spall_ok {
        log.error("Error creating spall context")
    }
    buffer_backing := make([]u8, spall.BUFFER_DEFAULT_SIZE, allocator = allocator)
    profiler.spall_buffer = spall.buffer_create(buffer_backing, 0)

    return profiler
}

quit_profiler :: proc(profiler: ^Profiler) {
    if profiler.spall_ctx.fd != 0 {
        spall.buffer_destroy(&profiler.spall_ctx, &profiler.spall_buffer)
        spall.context_destroy(&profiler.spall_ctx)
        profiler^ = {}
    }
}

@(deferred_in=_scoped_end)
scoped_event :: proc(profiler: ^Profiler, label: string = #caller_expression) {
    if profiler.spall_ctx.fd != 0 {
        spall._buffer_begin(&profiler.spall_ctx, &profiler.spall_buffer, label)
    }
}

@(private)
_scoped_end :: proc(profiler: ^Profiler, _: string) {
    if profiler.spall_ctx.fd != 0 {
        spall._buffer_end(&profiler.spall_ctx, &profiler.spall_buffer)
    }
}
