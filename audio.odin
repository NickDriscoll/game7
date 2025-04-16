package main

import "core:c"
import "core:log"
import "core:math"
import "base:runtime"

import "vendor:sdl2"
import "vendor:stb/vorbis"

import imgui "odin-imgui"

STANDARD_CD_AUDIO :: 44100 //Hz
MIDDLE_C_HZ :: 278.4375

audio_callback : sdl2.AudioCallback : proc "c" (userdata: rawptr, stream: [^]u8, len: c.int) {
    // Unpack userdata
    audio_system := cast(^AudioSystem)userdata
    context = audio_system.ctxt

    samples_to_generate := len / size_of(f32)
    f32_stream := cast([^]f32)stream
    

    for i in 0..<samples_to_generate {
        // Mix samples into this variable
        sample: f32

        // Generate pure sine wave tone
        if audio_system.play_tone {
            sample += math.sin_f32(audio_system.sine_time)
            audio_system.sine_time += 2.0 * math.PI / (f32(audio_system.spec.freq) / audio_system.note_freq)
            for audio_system.sine_time > 2.0 * math.PI {
                audio_system.sine_time -= 2.0 * math.PI
            }
        }

        f32_stream[i] = audio_system.volume * sample
    }
}

AudioSystem :: struct {
    device_id: sdl2.AudioDeviceID,
    spec: sdl2.AudioSpec,
    out_channels: u8,
    volume: f32,            // Between 0.0 and 1.0
    
    sine_time: f32,
    play_tone: bool,
    note_freq: f32,

    music_files: [dynamic]^vorbis.vorbis,

    ctxt: runtime.Context       // Copy of context for the callback proc
}

init_audio_system :: proc(audio_system: ^AudioSystem, allocator := context.allocator) {
    audio_system.out_channels = 1
    audio_system.note_freq = MIDDLE_C_HZ
    audio_system.volume = 0.1
    audio_system.ctxt = context
    audio_system.music_files = make([dynamic]^vorbis.vorbis, 0, 16, allocator)

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
    sdl2.PauseAudioDevice(audio_system.device_id, false)
}

destroy_audio_system :: proc(audio_system: ^AudioSystem) {
    sdl2.CloseAudioDevice(audio_system.device_id)
}

open_music_file :: proc(audio_system: ^AudioSystem, path: cstring) -> int {
    err: vorbis.Error
    alloc_buffer: vorbis.vorbis_alloc
    v := vorbis.open_filename(path, &err, &alloc_buffer)
    append(&audio_system.music_files, v)
    return len(audio_system.music_files) - 1
}

close_music_file :: proc(audio_system: ^AudioSystem, idx: int) {
    unordered_remove(&audio_system.music_files, idx)
}

audio_gui :: proc(audio_system: ^AudioSystem, open: ^bool) {
    if imgui.Begin("Audio panel", open) {
        imgui.SliderFloat("Note volume", &audio_system.volume, 0.0, 1.0)
        imgui.SliderFloat("Note frequency", &audio_system.note_freq, 20.0, 3200.0)

        imgui.Checkbox("Play tone", &audio_system.play_tone)
    }
    imgui.End()
}