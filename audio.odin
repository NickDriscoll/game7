package main

import "core:c"
import "core:fmt"
import "core:log"
import "core:math"
import "core:mem"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "base:runtime"

import "vendor:sdl2"
import "vendor:stb/vorbis"

import imgui "odin-imgui"

STANDARD_CD_AUDIO :: 44100 //Hz
MIDDLE_C_HZ :: 278.4375
STATIC_BUFFER_SIZE :: 2048

// NOTE: This callback runs on an independent thread
// T
audio_system_tick : sdl2.AudioCallback : proc "c" (userdata: rawptr, stream: [^]u8, samples_size: c.int) {
    
    // Unpack userdata
    audio_system := cast(^AudioSystem)userdata
    
    source_count := 0
    
    // SLice for output samples to get mixed into
    out_samples: []f32
    {
        out_sample_count := samples_size / size_of(f32)
        out_samples_buf := cast([^]f32)stream
        out_samples = slice.from_ptr(out_samples_buf, int(out_sample_count))
    }

    // SDL's streamout buffer isn't initialized to zero
    // @TODO: This is something dumb. Stop it.
    mem.zero(&out_samples[0], len(out_samples) * size_of(f32))
    
    for &playback in audio_system.music_files {
        if playback.is_interacted || playback.is_paused do continue
        source_count += 1

        file_stream_buffer: [STATIC_BUFFER_SIZE]f32
        has_ended := vorbis.get_samples_float_interleaved(
            playback.file,
            1,
            &file_stream_buffer[0],
            c.int(len(out_samples))
        ) == 0
        playback.calculated_read_head += i32(len(out_samples))
        if has_ended {
            playback.calculated_read_head = 0
            vorbis.seek(playback.file, c.uint(playback.calculated_read_head))
        }
        for i in 0..<len(out_samples) {
            out_samples[i] += playback.volume * file_stream_buffer[i]
        }
    }
    



    for i in 0..<len(out_samples) {
        // Generate pure sine wave tone
        if audio_system.play_tone {
            out_samples[i] += audio_system.tone_volume * math.sin_f32(audio_system.sine_time)

            // Advance position on sine wave by 
            audio_system.sine_time += 2.0 * math.PI * (audio_system.tone_freq / f32(audio_system.spec.freq))
            for audio_system.sine_time > 2.0 * math.PI {
                // Clamping to [0, 2*pi] in a continuous way
                audio_system.sine_time -= 2.0 * math.PI
            }
            source_count += 1
        }

        // Apply master volume
        out_samples[i] *= audio_system.volume
    }
}

FilePlayback :: struct {
    file: ^vorbis.vorbis,
    is_interacted: bool,
    is_paused: bool,
    calculated_read_head: i32,
    volume: f32         // 1.0 == 100%
}

AudioSystem :: struct {
    device_id: sdl2.AudioDeviceID,
    spec: sdl2.AudioSpec,
    out_channels: u8,
    volume: f32,            // Between 0.0 and 1.0
    
    sine_time: f32,
    play_tone: bool,
    tone_freq: f32,
    tone_volume: f32,

    music_files: [dynamic]FilePlayback,

    //local_mixing_buffer: [dynamic]f32,
}

init_audio_system :: proc(audio_system: ^AudioSystem, allocator := context.allocator) {
    audio_system.out_channels = 1
    audio_system.tone_freq = MIDDLE_C_HZ
    audio_system.volume = 0.5
    audio_system.tone_volume = 0.1

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
    audio_new_scene(audio_system, allocator)
}

audio_new_scene :: proc(audio_system: ^AudioSystem, allocator := context.allocator) {
    audio_system.music_files = make([dynamic]FilePlayback, 0, 16, allocator)
}

destroy_audio_system :: proc(audio_system: ^AudioSystem) {
    sdl2.CloseAudioDevice(audio_system.device_id)
}

toggle_device_playback :: proc(audio_system: ^AudioSystem, playing: bool) {
    sdl2.PauseAudioDevice(audio_system.device_id, sdl2.bool(!playing))
}

open_music_file :: proc(audio_system: ^AudioSystem, path: cstring) -> (uint, bool) {
    playback: FilePlayback
    playback.volume = 1.0

    glb_filename := filepath.base(string(path))
    
    err: vorbis.Error
    alloc_buffer: vorbis.vorbis_alloc
    
    playback.file = vorbis.open_filename(path, &err, nil)
    if err != nil {
        log.errorf("Error opening vorbis file: %v", err)
        return 0, false
    }

    info := vorbis.get_info(playback.file)
    if info.sample_rate != c.uint(audio_system.spec.freq) {
        log.warnf("Audio file sample rate (%v Hz) doesn't match audio spec (%v Hz)", info.sample_rate, audio_system.spec.freq)
    }

    append(&audio_system.music_files, playback)
    return len(audio_system.music_files) - 1, true
}

close_music_file :: proc(audio_system: ^AudioSystem, idx: uint) {
    unordered_remove(&audio_system.music_files, idx)
}

audio_gui :: proc(game_state: ^GameState, audio_system: ^AudioSystem, input_system: InputSystem, open: ^bool) {
    if imgui.Begin("Audio panel", open) {
        builder: strings.Builder
        strings.builder_init(&builder, context.temp_allocator)

        imgui.SliderFloat("Master volume", &audio_system.volume, 0.0, 1.0)
        imgui.Separator()

        imgui.SliderFloat("Tone frequency", &audio_system.tone_freq, 20.0, 2400.0)
        imgui.Checkbox("Play tone", &audio_system.play_tone)
        imgui.Separator()

        @static selected_item : c.int = 0
        items := make([dynamic]cstring, 0, 16, context.temp_allocator)
        if gui_dropdown_files("data/audio", &items, &selected_item, "Choose bgm") {
            close_music_file(audio_system, game_state.bgm_id)
            fmt.sbprintf(&builder, "data/audio/%v", items[selected_item])
            c, _ := strings.to_cstring(&builder)
            game_state.bgm_id, _ = open_music_file(audio_system, c)
        }

        for &file, i in audio_system.music_files {
            imgui.PushIDInt(c.int(i))
            imgui.Text("Audio file #%i", i)
            imgui.SliderFloat("Volume", &file.volume, 0.0, 3.0)
            file.is_interacted = imgui.SliderInt("Scrub samples", &file.calculated_read_head, 0, i32(vorbis.stream_length_in_samples(file.file)))
            file.is_interacted &= !input_system.mouse_clicked
            imgui.Checkbox("Paused", &file.is_paused)
            if file.is_interacted {
                vorbis.seek(file.file, c.uint(file.calculated_read_head))
            }
            imgui.Separator()
            imgui.PopID()
        }
        
    }
    imgui.End()
}