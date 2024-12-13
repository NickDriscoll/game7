package main

import "core:os"

create_write_file :: proc(filename: string) -> (os.Handle, os.Error) {
    h: os.Handle

    err: os.Errno
    when ODIN_OS == .Windows {
        h, err = os.open(
            filename,
            os.O_WRONLY | os.O_CREATE
        )
    }
    when ODIN_OS == .Linux {
        h, err = os.open(
            filename,
            os.O_WRONLY | os.O_CREATE,
            os.S_IRUSR | os.S_IWUSR
        )
    }

    return h, err
}