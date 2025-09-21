package main

import "core:prof/spall"
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

// NOTE: This callback runs on an independent thread managed by SDL2
audio_system_callback : sdl2.AudioCallback : proc "c" (userdata: rawptr, stream: [^]u8, samples_size: c.int) {
    // Unpack userdata
    audio_system := cast(^AudioSystem)userdata

    // SLice for output samples to get mixed into
    out_samples: []f32
    {
        out_sample_count := samples_size / size_of(f32)
        out_samples_buf := cast([^]f32)stream
        out_samples = slice.from_ptr(out_samples_buf, int(out_sample_count))
    }
    source_count := 0

    mix_buffer: [STATIC_BUFFER_SIZE]f32

    for &playback in audio_system.music_files {
        if playback.is_paused {
            continue
        }
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
            mix_buffer[i] += audio_system.music_volume * file_stream_buffer[i]
        }
    }

    for i in 0..<len(audio_system.playing_sound_effects) {
        playback := &audio_system.playing_sound_effects[i]
        effect := &audio_system.sound_effects[playback.idx]
        count := min(i32(len(out_samples)), i32(len(effect.samples)) - playback.read_head)
        for i in 0..<count {
            mix_buffer[i] += audio_system.sfx_volume * effect.samples[playback.read_head + i32(i)]
        }
        playback.read_head += count
    }



    for i in 0..<len(out_samples) {
        // Generate pure sine wave tone
        if audio_system.play_tone {
            mix_buffer[i] += audio_system.tone_volume * math.sin_f32(audio_system.sine_time)

            // Advance position on sine wave by 
            audio_system.sine_time += 2.0 * math.PI * (audio_system.tone_freq / f32(audio_system.spec.freq))
            for audio_system.sine_time > 2.0 * math.PI {
                // Clamping to [0, 2*pi] in a continuous way
                audio_system.sine_time -= 2.0 * math.PI
            }
            source_count += 1
        }

        // Apply master volume
        mix_buffer[i] *= audio_system.master_volume
    }

    mem.copy(&out_samples[0], &mix_buffer[0], size_of(f32) * len(out_samples))
}

FilePlayback :: struct {
    file: ^vorbis.vorbis,
    name: string,
    is_paused: bool,
    calculated_read_head: i32,
}

SoundEffect :: struct {
    samples: [dynamic]f32,
    name: string,
}

SoundEffectPlayback :: struct {
    idx: uint,
    read_head: i32,
}

AudioSystem :: struct {
    device_id: sdl2.AudioDeviceID,
    spec: sdl2.AudioSpec,
    out_channels: u8,
    master_volume: f32,            // Between 0.0 and 1.0
    
    sine_time: f32,
    play_tone: bool,
    tone_freq: f32,
    tone_volume: f32,

    music_files: [dynamic]FilePlayback,
    music_volume: f32,      // 1.0 == 100%

    sound_effects: [dynamic]SoundEffect,
    playing_sound_effects: [dynamic]SoundEffectPlayback,
    sfx_volume: f32,
}

init_audio_system :: proc(
    audio_system: ^AudioSystem,
    user_config: UserConfiguration,
    global_allocator: runtime.Allocator,
    scene_allocator := context.allocator
) {
    scoped_event(&profiler, "Init audio system")
    audio_system.out_channels = 1
    audio_system.tone_freq = MIDDLE_C_HZ
    audio_system.tone_volume = 0.1

    {
        audio_system.master_volume = 0.5
        v, ok := user_config.floats[.MasterVolume]
        if ok {
            audio_system.master_volume = f32(v)
        }
    }
    {
        audio_system.music_volume = 0.5
        v, ok := user_config.floats[.MusicVolume]
        if ok {
            audio_system.music_volume = f32(v)
        }
    }
    {
        audio_system.sfx_volume = 0.5
        v, ok := user_config.floats[.SFXVolume]
        if ok {
            audio_system.sfx_volume = f32(v)
        }
    }

    audio_system.sound_effects = make([dynamic]SoundEffect, 0, 16, global_allocator)

    // Init audio system
    {
        desired_samples : u16 = 512
        desired_audiospec := sdl2.AudioSpec {
            freq = STANDARD_CD_AUDIO,
            format = sdl2.AUDIO_F32,
            samples = desired_samples,
            channels = audio_system.out_channels,
            callback = audio_system_callback,
            userdata = audio_system
        }
        audio_system.device_id = sdl2.OpenAudioDevice(nil, false, &desired_audiospec, &audio_system.spec, nil)
    }
    audio_new_scene(audio_system, scene_allocator)
}

audio_new_scene :: proc(audio_system: ^AudioSystem, allocator := context.allocator) {
    audio_system.music_files = make([dynamic]FilePlayback, 0, 16, allocator)
    audio_system.playing_sound_effects = make([dynamic]SoundEffectPlayback, 0, 16, allocator)
}

destroy_audio_system :: proc(audio_system: ^AudioSystem) {
    sdl2.CloseAudioDevice(audio_system.device_id)
}

toggle_device_playback :: proc(audio_system: ^AudioSystem, playing: bool) {
    sdl2.PauseAudioDevice(audio_system.device_id, sdl2.bool(!playing))
}

load_sound_effect :: proc(audio_system: ^AudioSystem, path: cstring, global_allocator: runtime.Allocator) -> (uint, bool) {
    scoped_event(&profiler, "load_sound_effect")
    err: vorbis.Error
    file := vorbis.open_filename(path, &err, nil)
    if err != nil {
        log.errorf("Error loading sound effect: %v", err)
        return 0, false
    }

    file_info := vorbis.get_info(file)

    // Assumption is that sound effects will be mono
    assert(file_info.channels == 1, "Sound effects must be mono.")

    if file_info.sample_rate != c.uint(audio_system.spec.freq) {
        log.warnf("Audio file sample rate (%v Hz) doesn't match audio spec (%v Hz)", file_info.sample_rate, audio_system.spec.freq)
    }

    sound_effect := SoundEffect {
        samples = make([dynamic]f32, global_allocator),
        name = filepath.stem(strings.clone_from_cstring(path, global_allocator))
    }
    temp_sample_buffer: [44100]f32 
    sample_head : i32 = 0
    samples_read := vorbis.get_samples_float_interleaved(file, 1, &temp_sample_buffer[0], max(c.int))
    for samples_read > 0 {
        resize(&sound_effect.samples, sample_head + samples_read)
        mem.copy_non_overlapping(raw_data(sound_effect.samples), &temp_sample_buffer, int(samples_read * size_of(f32)))
        sample_head += samples_read
        samples_read = vorbis.get_samples_float_interleaved(file, 1, &temp_sample_buffer[0], max(c.int))
    }
    append(&audio_system.sound_effects, sound_effect)
    idx : uint = len(audio_system.sound_effects) - 1

    return idx, true
}

play_sound_effect :: proc(audio_system: ^AudioSystem, i: uint) {
    scoped_event(&profiler, "play_sound_effect")
    append(&audio_system.playing_sound_effects, SoundEffectPlayback {
        idx = i,
        read_head = 0
    })
}

open_music_file :: proc(audio_system: ^AudioSystem, path: cstring) -> (uint, bool) {
    playback: FilePlayback
    playback.name = filepath.stem(strings.clone_from_cstring(path))
    
    err: vorbis.Error
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
    if len(audio_system.music_files) > int(idx) {
        unordered_remove(&audio_system.music_files, idx)
    }
}

audio_tick :: proc(audio_system: ^AudioSystem) {
    scoped_event(&profiler, "Per-frame audio tick")
    sdl2.LockAudioDevice(audio_system.device_id)
    defer sdl2.UnlockAudioDevice(audio_system.device_id)

    i := 0
    for i < len(audio_system.playing_sound_effects) {
        playback := &audio_system.playing_sound_effects[i]
        effect := audio_system.sound_effects[playback.idx]
        if playback.read_head == i32(len(effect.samples)) {
            unordered_remove(&audio_system.playing_sound_effects, i)
            i -= 1
        }
        i += 1
    }
}

audio_gui :: proc(
    game_state: ^GameState,
    audio_system: ^AudioSystem,
    user_config: ^UserConfiguration,
    open: ^bool
) {
    if imgui.Begin("Audio panel", open) {
        scoped_event(&profiler, "Audio GUI")
        builder: strings.Builder
        strings.builder_init(&builder, context.temp_allocator)

        if imgui.SliderFloat("Master volume", &audio_system.master_volume, 0.0, 1.0) {
            user_config.floats[.MasterVolume] = f64(audio_system.master_volume)
        }
        if imgui.SliderFloat("Music volume", &audio_system.music_volume, 0.0, 5.0) {
            user_config.floats[.MusicVolume] = f64(audio_system.music_volume)
        }
        if imgui.SliderFloat("SFX volume", &audio_system.sfx_volume, 0.0, 5.0) {
            user_config.floats[.SFXVolume] = f64(audio_system.sfx_volume)
        }
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
            strings.builder_reset(&builder)
        }

        for &file, i in audio_system.music_files {
            imgui.PushIDInt(c.int(i))
            imgui.Text("Audio file #%i", i)
            interacted := imgui.SliderInt("Scrub samples", &file.calculated_read_head, 0, i32(vorbis.stream_length_in_samples(file.file)))
            imgui.Checkbox("Paused", &file.is_paused)
            if interacted {
                vorbis.seek(file.file, c.uint(file.calculated_read_head))
            }
            imgui.Separator()
            imgui.PopID()
        }

        imgui.Text("Sound effects:")
        for fx, i in audio_system.sound_effects {
            imgui.PushIDInt(c.int(i))
            gui_print_value(&builder, "Name", fx.name)
            if imgui.Button("Play") {
                play_sound_effect(audio_system, uint(i))
            }

            imgui.PopID()
        }
        
    }
    imgui.End()
}