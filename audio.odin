package main

import "vendor:sdl2"

AudioSystem :: struct {

}

init_audio_system :: proc() -> AudioSystem {
    audio_system: AudioSystem

    // Init audio system
    audio_device_id: sdl2.AudioDeviceID
    {
        desired_audiospec := sdl2.AudioSpec {
            freq = 44100,
            format = sdl2.AUDIO_F32,
            channels = 1,
            
        }
        returned_audiospec: sdl2.AudioSpec
        audio_device_id = sdl2.OpenAudioDevice(nil, false, &desired_audiospec, &returned_audiospec, false)
    
    }
    defer sdl2.CloseAudioDevice(audio_device_id)

    return audio_system
}
