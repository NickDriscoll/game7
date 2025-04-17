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
STATIC_BUFFER_SIZE :: 2048

audio_system_tick : sdl2.AudioCallback : proc "c" (userdata: rawptr, stream: [^]u8, samples_size: c.int) {
    // Unpack userdata
    audio_system := cast(^AudioSystem)userdata
    context = audio_system.ctxt

    out_sample_count := samples_size / size_of(f32)
    out_samples_buf := cast([^]f32)stream
    


    play_file := len(audio_system.music_files) > 0
    assert(STATIC_BUFFER_SIZE >= samples_size)
    buffer: [STATIC_BUFFER_SIZE]f32
    if play_file {
        has_ended := vorbis.get_samples_float_interleaved(
            audio_system.music_files[0],
            1,
            &buffer[0],
            out_sample_count
        ) == 0
        if has_ended {
            //vorbis.seek_start(audio_system.music_files[0])
        }
    }
    



    for i in 0..<out_sample_count {
        // Mix samples into this variable
        sample: f32

        // Generate pure sine wave tone
        if audio_system.play_tone {
            sample += math.sin_f32(audio_system.sine_time)
            audio_system.sine_time += 2.0 * math.PI * (audio_system.note_freq / f32(audio_system.spec.freq))
            for audio_system.sine_time > 2.0 * math.PI {
                audio_system.sine_time -= 2.0 * math.PI
            }
        }
        
        if play_file {
            sample += buffer[i]
        }

        //sample /= 2
        
        out_samples_buf[i] = audio_system.volume * sample
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
            callback = audio_system_tick,
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
    if err != nil {
        log.errorf("Error opening vorbis file: %v", err)
    }
    append(&audio_system.music_files, v)
    return len(audio_system.music_files) - 1
}

close_music_file :: proc(audio_system: ^AudioSystem, idx: int) {
    unordered_remove(&audio_system.music_files, idx)
}

audio_gui :: proc(audio_system: ^AudioSystem, open: ^bool) {
    if imgui.Begin("Audio panel", open) {
        imgui.SliderFloat("Master volume", &audio_system.volume, 0.0, 1.0)

        imgui.SliderFloat("Tone frequency", &audio_system.note_freq, 20.0, 2400.0)
        imgui.Checkbox("Play tone", &audio_system.play_tone)

        for file in audio_system.music_files {
            //vorbis.stream_length_in_seconds()
        }
        
    }
    imgui.End()
}