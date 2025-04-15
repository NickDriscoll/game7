package main

import "core:c"
import "core:log"
import "core:math"
import "base:runtime"
import "vendor:sdl2"

STANDARD_CD_AUDIO :: 44100 //Hz

audio_callback :: proc "c" (userdata: rawptr, stream: [^]u8, len: c.int) {
    // Unpack userdata
    audio_system := cast(^AudioSystem)userdata

    MIDDLE_C_HZ :: 278.4375

    samples_to_generate := len / size_of(f32)
    f32_stream := cast([^]f32)stream
    for i in 0..<samples_to_generate {
        sample := math.sin(MIDDLE_C_HZ * audio_system.time)

        f32_stream[i] = sample
        audio_system.time += 1.0 / f32(audio_system.spec.freq)
    }
}

AudioSystem :: struct {
    device_id: sdl2.AudioDeviceID,
    spec: sdl2.AudioSpec,
    time: f32,
    out_channels: u8,
}

init_audio_system :: proc(audio_system: ^AudioSystem) {
    audio_system.out_channels = 1

    // Init audio system
    {
        desired_samples : u16 = 512
        desired_audiospec := sdl2.AudioSpec {
            freq = STANDARD_CD_AUDIO,
            format = sdl2.AUDIO_F32,
            samples = desired_samples,
            channels = audio_system.out_channels,
            callback = audio_callback,
            userdata = audio_system
        }
        audio_system.device_id = sdl2.OpenAudioDevice(nil, false, &desired_audiospec, &audio_system.spec, false)
    }
    //sdl2.PauseAudioDevice(audio_system.device_id, false)
}

destroy_audio_system :: proc(audio_system: ^AudioSystem) {
    sdl2.CloseAudioDevice(audio_system.device_id)
}