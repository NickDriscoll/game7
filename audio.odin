package main

import "core:c"
import "core:log"
import "core:math"
import "base:runtime"
import "vendor:sdl2"

import imgui "odin-imgui"

STANDARD_CD_AUDIO :: 44100 //Hz
MIDDLE_C_HZ :: 278.4375

audio_callback :: proc "c" (userdata: rawptr, stream: [^]u8, len: c.int) {
    // Unpack userdata
    audio_system := cast(^AudioSystem)userdata


    samples_to_generate := len / size_of(f32)
    f32_stream := cast([^]f32)stream
    for i in 0..<samples_to_generate {
        sample := audio_system.volume * math.sin_f32(audio_system.time)
        audio_system.time += 2.0 * math.PI / (f32(audio_system.spec.freq) / audio_system.note_freq)

        f32_stream[i] = sample
    }
}

AudioSystem :: struct {
    device_id: sdl2.AudioDeviceID,
    spec: sdl2.AudioSpec,
    time: f32,
    out_channels: u8,
    
    note_freq: f32,
    volume: f32
}

init_audio_system :: proc(audio_system: ^AudioSystem) {
    audio_system.out_channels = 1
    audio_system.note_freq = MIDDLE_C_HZ
    audio_system.volume = 0.1

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
        log.debugf("Audio spec received from SDL2:\n%#v", audio_system.spec)
    }
}

destroy_audio_system :: proc(audio_system: ^AudioSystem) {
    sdl2.CloseAudioDevice(audio_system.device_id)
}

audio_gui :: proc(audio_system: ^AudioSystem, open: ^bool) {
    if imgui.Begin("Audio panel", open) {
        imgui.SliderFloat("Note volume", &audio_system.volume, 0.0, 1.0)
        imgui.SliderFloat("Note frequency", &audio_system.note_freq, 20.0, 1600.0)
        if imgui.Button("Play/Pause") {
            @static playing := false
            playing = !playing
            sdl2.PauseAudioDevice(audio_system.device_id, !playing)
        }
    }
    imgui.End()
}