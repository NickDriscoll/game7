package main

import "core:c"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg/hlsl"
import "core:strings"
import "core:time"

import "vendor:sdl2"

import imgui "odin-imgui"
import vk "vendor:vulkan"
import vkw "desktop_vulkan_wrapper"

USER_CONFIG_FILENAME :: "user.cfg"

TITLE_WITHOUT_IMGUI :: "KataWARi"
TITLE_WITH_IMGUI :: "KataWARi -- Press ESC to hide developer GUI"
DEFAULT_RESOLUTION :: hlsl.uint2 {1280, 720}

MAXIMUM_FRAME_DT :: 1.0 / 30.0

SECONDS_TO_NANOSECONDS :: 1_000_000_000
MILLISECONDS_TO_NANOSECONDS :: 1_000_000

IDENTITY_MATRIX3x3 :: hlsl.float3x3 {
    1.0, 0.0, 0.0,
    0.0, 1.0, 0.0,
    0.0, 0.0, 1.0
}
IDENTITY_MATRIX4x4 :: hlsl.float4x4 {
    1.0, 0.0, 0.0, 0.0,
    0.0, 1.0, 0.0, 0.0,
    0.0, 0.0, 1.0, 0.0,
    0.0, 0.0, 0.0, 1.0,
}

@thread_local profiler: Profiler

main :: proc() {
    // Initialize app state and subsystems
    app: App
    app_init_ok := app_startup(&app)
    if !app_init_ok {
        log.error("Failed to init app struct")
        return
    }
    defer app_shutdown(&app)
    scoped_event(&profiler, "Main proc")

    // context is per-scope, so set the allocators and logger here
    context.logger = app.logger
    context.allocator = app.per_scene_allocator
    context.temp_allocator = app.per_frame_allocator

    log.info("App initialization complete. Entering main loop")

    do_main_loop := true
    for do_main_loop {
        scoped_event(&profiler, "Main frame loop")

        // Time
        app.current_time = time.now()
        nanosecond_dt := time.diff(app.previous_time, app.current_time)
        last_frame_dt := f32(nanosecond_dt / 1000) / 1_000_000
        dt := min(last_frame_dt, MAXIMUM_FRAME_DT)
        scaled_dt := app.game_state.timescale * dt
        app.previous_time = app.current_time

        // @TODO: Wrap this value at some point?
        app.game_state.time += scaled_dt

        // Save user configuration every 100ms
        if app.user_config.autosave && time.diff(app.user_config.last_saved, app.current_time) >= 100_000_000 {
            scoped_event(&profiler, "Auto-save user config")
            tform := &app.game_state.transforms[app.game_state.viewport_camera_id]
            camera := &app.game_state.cameras[app.game_state.viewport_camera_id]
            following := app.game_state.viewport_camera_id in app.game_state.lookat_controllers
            if len(app.current_level) > 0 {
                app.user_config.strs[.StartLevel] = app.current_level
            } else {
                delete_key(&app.user_config.strs, ConfigKey.StartLevel)
            }
            update_user_cfg_camera(&app.user_config, tform.position, following, camera^)
            save_user_config(&app.user_config, USER_CONFIG_FILENAME)
            app.user_config.last_saved = app.current_time
        }

        // Load new level before any other per-frame work begins
        {
            level, ok := app.load_new_level.?
            if ok {
                builder: strings.Builder
                strings.builder_init(&builder, context.temp_allocator)
                fmt.sbprintf(&builder, "data/levels/%v", level)
                path := strings.to_string(builder)
                load_level_file(&app, path)
                app.load_new_level = nil
            }
        }

        io := imgui.GetIO()
        io.DeltaTime = last_frame_dt
        app.renderer.uniforms.time += scaled_dt

        new_frame(&app.renderer)

        output_verbs := poll_sdl2_events(&app.input_system)

        // Quit if user wants it
        do_main_loop = !output_verbs.bools[.Quit]

        if .PerfProfile in app.app_options && app.vgd.frame_count >= 144 * 5 {
            do_main_loop = false
        }

        // Tell Dear ImGUI about inputs
        {
            scoped_event(&profiler, "Tell Dear ImGUI about events")

            camera := &app.game_state.cameras[app.game_state.viewport_camera_id]

            if output_verbs.bools[.ToggleImgui] {
                app.gui.show_gui = !app.gui.show_gui
                app.user_config.flags[.ImguiEnabled] = app.gui.show_gui
                if app.gui.show_gui {
                    sdl2.SetWindowTitle(app.window.window, TITLE_WITH_IMGUI)
                } else {
                    sdl2.SetWindowTitle(app.window.window, TITLE_WITHOUT_IMGUI)
                }
            }

            mlook_coords, ok := output_verbs.int2s[.ToggleMouseLook]
            if ok && mlook_coords != {0, 0} {
                mlook := !(.MouseLook in camera.flags)
                // Do nothing if Dear ImGUI wants mouse input
                if !(mlook && io.WantCaptureMouse) {
                    sdl2.SetRelativeMouseMode(sdl2.bool(mlook))
                    if mlook {
                        app.saved_mouse_coords.x = i32(mlook_coords.x)
                        app.saved_mouse_coords.y = i32(mlook_coords.y)
                    } else {
                        sdl2.WarpMouseInWindow(app.window.window, app.saved_mouse_coords.x, app.saved_mouse_coords.y)
                    }
                    // The ~ is "symmetric difference" for bit_sets
                    // Basically like XOR
                    camera.flags ~= {.MouseLook}
                }
            }

            if .MouseLook not_in camera.flags {
                x, y: c.int
                sdl2.GetMouseState(&x, &y)
                imgui.IO_AddMousePosEvent(io, f32(x), f32(y))
            } else {
                sdl2.WarpMouseInWindow(app.window.window, app.saved_mouse_coords.x, app.saved_mouse_coords.y)
            }

        }
        
        // Begin new Dear ImGUI frame
        begin_gui(&app.gui)

        {
            docknode := imgui.DockBuilderGetCentralNode(app.gui.dockspace_id)
            app.renderer.viewport_dimensions.offset.x = cast(i32)docknode.Pos.x
            app.renderer.viewport_dimensions.offset.y = cast(i32)docknode.Pos.y
            app.renderer.viewport_dimensions.extent.width = cast(u32)docknode.Size.x
            app.renderer.viewport_dimensions.extent.height = cast(u32)docknode.Size.y

            camera := &app.game_state.cameras[app.game_state.viewport_camera_id]
            camera.aspect_ratio = docknode.Size.x / docknode.Size.y
        }

        // Update
        scene_editor(&app)

        if output_verbs.bools[.ImguiScaleDown] {
            imgui.GetStyle().FontScaleMain -= 0.2
        }
        if output_verbs.bools[.ImguiScaleUp] {
            imgui.GetStyle().FontScaleMain += 0.2
        }

        // Misc imgui window for testing
        @static minimum_frametime : c.int = 33
        if app.gui.show_gui && app.user_config.flags[.ShowDebugMenu] {
            if imgui.Begin("Hacking window", &app.user_config.flags[.ShowDebugMenu]) {
                scoped_event(&profiler, "Show debug menu")
                imgui.Text("Frame #%i", app.vgd.frame_count)
                imgui.Separator()

                {
                    tform := &app.game_state.transforms[app.game_state.player_id]
                    collision := &app.game_state.spherical_bodies[app.game_state.player_id]
                    player := &app.game_state.character_controllers[app.game_state.player_id]

                    sb: strings.Builder
                    strings.builder_init(&sb, context.temp_allocator)
                    defer strings.builder_destroy(&sb)

                    flag := .ShowPlayerHitSphere in app.game_state.debug_vis_flags
                    if imgui.Checkbox("Show player collision", &flag) {
                        app.game_state.debug_vis_flags ~= {.ShowPlayerHitSphere}
                        if flag {
                            app.game_state.debug_models[app.game_state.player_id] = DebugModelInstance {
                                handle = app.game_state.sphere_mesh,
                                scale = collision.radius,
                                color = {0.2, 0.0, 1.0, 0.5}
                            }
                        } else {
                            delete_key(&app.game_state.debug_models, app.game_state.player_id)
                        }
                    }
                    flag = .ShowCoinRadius in app.game_state.debug_vis_flags
                    if imgui.Checkbox("Show coin radius", &flag) {
                        app.game_state.debug_vis_flags ~= {.ShowCoinRadius}
                    }

                    gui_print_value(&sb, "Player position", tform.position)
                    gui_print_value(&sb, "Player velocity", collision.velocity)
                    gui_print_value(&sb, "Player acceleration", player.acceleration)
                    gui_print_value(&sb, "Player state", collision.state)

                    imgui.SliderFloat("Player move speed", &player.move_speed, 1.0, 50.0)
                    imgui.SliderFloat("Player sprint speed", &player.sprint_speed, 1.0, 50.0)
                    imgui.SliderFloat("Player deceleration speed", &player.deceleration_speed, 0.01, 2.0)
                    imgui.SliderFloat("Player jump speed", &player.jump_speed, 1.0, 50.0)
                    imgui.SliderFloat("Player anim speed", &player.anim_speed, 0.0, 2.0)
                    imgui.SliderFloat("Bullet travel time", &player.bullet_travel_time, 0.0, 1.0)
                    imgui.SliderFloat("Coin radius", &app.game_state.collectable_radius, 0.1, 1.0)
                    if imgui.Button("Reset player") {
                        output_verbs.bools[.PlayerReset] = true
                    }
                    imgui.SameLine()

                    moving_something := .MoveSelectedEntity in app.game_state.edit_flags
                    imgui.BeginDisabled(moving_something)
                    move_text : cstring = "Move player"
                    if moving_something && app.selected_entity.? == app.game_state.player_id {
                        move_text = "Moving player..."
                    }
                    if imgui.Button(move_text) {
                        app.selected_entity = app.game_state.player_id
                        app.game_state.edit_flags += {.MoveSelectedEntity}
                    }
                    imgui.EndDisabled()
                }

                imgui.SliderFloat("Distortion Strength", &app.renderer.uniforms.distortion_strength, 0.0, 1.0)
                imgui.SliderFloat("Timescale", &app.game_state.timescale, 0.0, 2.0)
                imgui.SameLine()
                if imgui.Button("Reset") {
                    app.game_state.timescale = 1.0
                }

                if imgui.Button("Re-encode this level file") {
                    _reencode_level_file(&app, app.current_level, app.per_frame_allocator)
                }

                if imgui.Button("Re-encode all level files") {
                    _reencode_level_files(&app, app.per_frame_allocator)
                }

                {
                    b := .LimitCPU in app.app_options
                    if imgui.Checkbox("Enable CPU Limiter", &b) {
                        app.app_options ~= {.LimitCPU}
                    }
                }
                imgui.SameLine()
                HelpMarker(
                    "Enabling this setting forces the main thread " +
                    "to sleep for (minimum_frametime - this_frames_duration) milliseconds " +
                    "at the end of the main loop, more-or-less capping the framerate."
                )
                imgui.SliderInt("Minimum frametime", &minimum_frametime, 2, 50)

                imgui.Separator()
            }
            imgui.End()
        }

        // React to main menu bar interaction
        @static show_load_modal := false
        @static show_save_modal := false
        do_fullscreen := false
        switch gui_main_menu_bar(&app) {
            case .Exit: do_main_loop = false
            case .NewLevel: {
                new_scene(&app, app.per_scene_allocator)
            }
            case .LoadLevel: { show_load_modal = true }
            case .SaveLevel: {
                sb: strings.Builder
                strings.builder_init(&sb, context.temp_allocator)
                path := fmt.sbprintf(&sb, "data/levels/%v.lvl", app.current_level)
                save_level_file(&app, path)
            }
            case .SaveLevelAs: { show_save_modal = true }
            case .ToggleAlwaysOnTop: { sdl2.SetWindowAlwaysOnTop(app.window.window, sdl2.bool(app.user_config.flags[.AlwaysOnTop])) }
            case .ToggleBorderlessFullscreen: { do_fullscreen = true }
            case .ToggleExclusiveFullscreen: {
                app.game_state.exclusive_fullscreen = !app.game_state.exclusive_fullscreen
                app.game_state.borderless_fullscreen = false
                xpos, ypos: c.int
                flags : sdl2.WindowFlags = nil
                app.window.resolution = DEFAULT_RESOLUTION
                if app.game_state.exclusive_fullscreen {
                    flags += {.FULLSCREEN}
                    app.window.resolution = app.window.display_resolution
                } else {
                    app.window.resolution = DEFAULT_RESOLUTION
                    xpos = c.int(app.user_config.ints[.WindowX])
                    ypos = c.int(app.user_config.ints[.WindowY])
                }
                io.DisplaySize.x = f32(app.window.resolution.x)
                io.DisplaySize.y = f32(app.window.resolution.y)

                sdl2.SetWindowSize(app.window.window, c.int(app.window.resolution.x), c.int(app.window.resolution.y))
                sdl2.SetWindowFullscreen(app.window.window, flags)
                sdl2.SetWindowResizable(app.window.window, !app.game_state.exclusive_fullscreen)

                app.vgd.resize_window = true
            }
            case .None: {}
        }

        if output_verbs.bools[.NewLevel] {
            new_scene(&app, app.per_scene_allocator)
        }

        if output_verbs.bools[.ShowLoadLevel] {
            show_load_modal = !show_load_modal
        }

        if output_verbs.bools[.FullscreenHotkey] {
            do_fullscreen = true
        }

        if do_fullscreen {
            app.game_state.borderless_fullscreen = !app.game_state.borderless_fullscreen
            app.game_state.exclusive_fullscreen = false
            xpos, ypos: c.int
            if app.game_state.borderless_fullscreen {
                app.window.resolution = app.window.display_resolution
            } else {
                app.window.resolution = {u32(app.user_config.ints[.WindowWidth]), u32(app.user_config.ints[.WindowHeight])}
                xpos = c.int(app.user_config.ints[.WindowX])
                ypos = c.int(app.user_config.ints[.WindowY])
            }
            io.DisplaySize.x = f32(app.window.resolution.x)
            io.DisplaySize.y = f32(app.window.resolution.y)

            sdl2.SetWindowBordered(app.window.window, !app.game_state.borderless_fullscreen)
            sdl2.SetWindowPosition(app.window.window, xpos, ypos)
            sdl2.SetWindowSize(app.window.window, c.int(app.window.resolution.x), c.int(app.window.resolution.y))
            sdl2.SetWindowResizable(app.window.window, !app.game_state.borderless_fullscreen)

            app.vgd.resize_window = true
        }

        if show_load_modal {
            popup_text : cstring = "Level select"
            imgui.OpenPopup(popup_text)

            center := imgui.GetMainViewport().Size / 2.0
            imgui.SetNextWindowPos(center, .Appearing, {0.5, 0.5})
            imgui.SetNextWindowSize(imgui.GetMainViewport().Size - 200.0)
            if imgui.BeginPopupModal(popup_text, &show_load_modal, {.NoMove,.NoResize}) {
                selected_item: c.int
                list_items := make([dynamic]cstring, 0, 16, context.temp_allocator)
                if gui_list_files("./data/levels/", &list_items, &selected_item, popup_text) {
                    // Load selected level
                    app.load_new_level = strings.clone(string(list_items[selected_item]), context.allocator)
                    show_load_modal = false
                    imgui.CloseCurrentPopup()
                }
                imgui.Separator()
                if imgui.Button("Back") {
                    show_load_modal = false
                    imgui.CloseCurrentPopup()
                }
                imgui.EndPopup()
            }
        }

        if show_save_modal {
            popup_text : cstring = "Save level"
            imgui.OpenPopup(popup_text)

            center := imgui.GetMainViewport().Size / 2.0
            imgui.SetNextWindowPos(center, .Appearing, {0.5, 0.5})
            imgui.SetNextWindowSize(imgui.GetMainViewport().Size - 200.0)
            if imgui.BeginPopupModal(popup_text, &show_save_modal, {.NoMove,.NoResize}) {
                level_savename: string
                builder: strings.Builder
                strings.builder_init(&builder, context.temp_allocator)

                selected_item: c.int
                list_items := make([dynamic]cstring, 0, 16, context.temp_allocator)
                if gui_list_files("./data/levels/", &list_items, &selected_item, popup_text) {
                    // Save selected level
                    level_savename = fmt.sbprintf(&builder, "data/levels/%v", list_items[selected_item])
                    show_save_modal = false
                    imgui.CloseCurrentPopup()
                }
                imgui.InputText("Level savename", cstring(&app.savename_buffer[0]), len(app.savename_buffer))
                if imgui.Button("Save") {
                    s := strings.string_from_null_terminated_ptr(&app.savename_buffer[0], len(app.savename_buffer))
                    level_savename = fmt.sbprintf(&builder, "data/levels/%v", s)
                    app.savename_buffer[0] = 0
                    show_save_modal = false
                    imgui.CloseCurrentPopup()
                }

                imgui.Separator()
                if imgui.Button("Back") {
                    show_save_modal = false
                    imgui.CloseCurrentPopup()
                }

                if len(level_savename) > 0 {
                    save_level_file(&app, level_savename)
                }

                imgui.EndPopup()
            }
        }

        if app.gui.show_gui && app.user_config.flags[.CameraConfig] {
            camera_gui(
                &app.game_state,
                app.game_state.viewport_camera_id,
                &app.input_system,
                &app.user_config,
                &app.user_config.flags[.CameraConfig]
            )
        }

        if app.gui.show_gui && app.user_config.flags[.WindowConfig] {
            app.vgd.resize_window |= window_config(app.gui, &app.window, app.user_config)
        }

        if app.gui.show_gui && app.user_config.flags[.GraphicsSettings] {
            graphics_gui(app.vgd, &app.renderer, &app.user_config.flags[.GraphicsSettings])
        }
        if app.gui.show_gui && app.user_config.flags[.AudioPanel] {
            audio_gui(&app.game_state, &app.audio_system, &app.user_config, &app.user_config.flags[.AudioPanel])
        }
        // Input remapping GUI
        if app.gui.show_gui && app.user_config.flags[.InputConfig] {
            input_gui(&app.input_system, &app.user_config.flags[.InputConfig])
        }
        // Imgui Demo
        if app.gui.show_gui && app.user_config.flags[.ShowImguiDemo] {
            imgui.ShowDemoWindow(&app.user_config.flags[.ShowImguiDemo])
        }

        // Memory viewer
        when ODIN_DEBUG {
            if app.gui.show_gui && app.user_config.flags[.ShowAllocatorStats] {
                if imgui.Begin("Allocator stats", &app.user_config.flags[.ShowAllocatorStats]) {
                    imgui.Text("Global allocator stats")
                    imgui.Text("Total global memory allocated: %i", app.global_track.current_memory_allocated)
                    imgui.Text("Peak global memory allocated: %i", app.global_track.peak_memory_allocated)
                    imgui.Separator()
                    imgui.Text("Per-scene allocator stats")
                    imgui.Text("Total per-scene memory allocated: %i", app.scene_track.current_memory_allocated)
                    imgui.Text("Peak per-scene memory allocated: %i", app.scene_track.peak_memory_allocated)
                    imgui.Separator()
                }
                imgui.End()
            }
        }

        // Move entity
        if .MoveSelectedEntity in app.game_state.edit_flags && !io.WantCaptureMouse {
            scoped_event(&profiler, "Move entity")

            id, ok := app.selected_entity.?
            assert(ok)

            tform := &app.game_state.transforms[id]
            collision_pt, _, hit := do_mouse_raycast(
                app.game_state,
                app.renderer,
                app.input_system,
            )
            if hit {
                old_tform := tform^
                tform.position = collision_pt
                event := MovedEntityEvent {
                    id = id,
                    old_tform = old_tform
                }
                append(&app.game_state.moved_collision, event)
            }


            if .MouseClicked in app.input_system.state_flags {
                app.game_state.edit_flags -= {.MoveSelectedEntity}
            }
        }

        game_tick(&app.game_state, &app.vgd, &app.renderer, output_verbs, &app.audio_system, scaled_dt)

        // Camera update
        {
            scoped_event(&profiler, "Camera update")

            tform := &app.game_state.transforms[app.game_state.viewport_camera_id]
            camera := &app.game_state.cameras[app.game_state.viewport_camera_id]
            lookat_controller, is_lookat := &app.game_state.lookat_controllers[app.game_state.viewport_camera_id]
            current_view_from_world: hlsl.float4x4
            if is_lookat {
                lookat_camera_update(&app.game_state, output_verbs, app.game_state.viewport_camera_id, dt)
                current_view_from_world = lookat_view_from_world(tform^, lookat_controller.current_focal_point)
            } else {
                freecam_update(&app.game_state, output_verbs, app.game_state.viewport_camera_id, dt)
                current_view_from_world = freecam_view_from_world(tform^, camera^)
            }

            projection_from_view := camera_projection_from_view(camera^)
            app.renderer.uniforms.clip_from_world =
                projection_from_view *
                current_view_from_world
            renderer.uniforms.world_from_clip = hlsl.inverse(renderer.uniforms.clip_from_world)
            renderer.uniforms.view_from_world = current_view_from_world
            renderer.uniforms.world_from_view = hlsl.inverse(current_view_from_world)
            renderer.uniforms.clip_from_view = projection_from_view;
            renderer.uniforms.view_from_clip = hlsl.inverse(projection_from_view)

            vfw := hlsl.float3x3(current_view_from_world)
            vfw4 := hlsl.float4x4(vfw)
            app.renderer.uniforms.clip_from_skybox = projection_from_view * vfw4;

            app.renderer.uniforms.view_position.xyz = tform.position
            app.renderer.uniforms.view_position.a = 1.0
        }

        // Draw static models
        {
            scoped_event(&profiler, "Draw static models")
            for id, model in app.game_state.static_models {
                tform := &app.game_state.transforms[id]

                mat := get_transform_matrix(tform^)
                mat[3][0] += model.pos_offset.x
                mat[3][1] += model.pos_offset.y
                mat[3][2] += model.pos_offset.z
                draw := StaticDraw {
                    world_from_model = mat,
                    flags = model.flags
                }
                draw_ps1_static_mesh(&app.vgd, &app.renderer, model.handle, draw)

                if .Glowing in model.flags {
                    // Light source
                    l := default_point_light()
                    l.world_position = tform.position
                    l.color = {0.0, 1.0, 0.0}
                    l.intensity = light_flicker(app.game_state.rng_seed, app.game_state.time)
                    do_point_light(&app.renderer, l)
                }
            }
        }

        {
            scoped_event(&profiler, "Draw skinned models")
            // Draw skinned models
            for id, model in app.game_state.skinned_models {
                tform := &app.game_state.transforms[id]

                mat := get_transform_matrix(tform^)
                mat[3][0] += model.pos_offset.x
                mat[3][1] += model.pos_offset.y
                mat[3][2] += model.pos_offset.z
                draw := SkinnedDraw {
                    world_from_model = mat,
                    anim_idx = model.anim_idx,
                    anim_t = model.anim_t,
                    //flags = model.flags
                }
                draw_ps1_skinned_mesh(&app.vgd, &app.renderer, model.handle, &draw)

                if .Glowing in model.flags {
                    // Light source
                    l := default_point_light()
                    l.world_position = tform.position
                    l.color = {0.0, 1.0, 0.0}
                    l.intensity = light_flicker(app.game_state.rng_seed, app.game_state.time)
                    do_point_light(&app.renderer, l)
                }
            }
        }

        {
            scoped_event(&profiler, "Draw debug models")
            // Draw debug models
            for id, model in app.game_state.debug_models {
                tform := &app.game_state.transforms[id]

                mat := get_transform_matrix(tform^, model.scale)
                mat[3][0] += model.pos_offset.x
                mat[3][1] += model.pos_offset.y
                mat[3][2] += model.pos_offset.z
                draw := DebugDraw {
                    world_from_model = mat,
                    color = model.color
                }
                draw_debug_mesh(&app.vgd, &app.renderer, app.game_state.sphere_mesh, &draw)
            }
        }

        // Window update
        {
            scoped_event(&profiler, "Window update")
            new_size, ok := output_verbs.int2s[.ResizeWindow]
            if ok {
                app.window.resolution.x = u32(new_size.x)
                app.window.resolution.y = u32(new_size.y)
                app.vgd.resize_window = true
            }

            new_pos, ok2 := output_verbs.int2s[.MoveWindow]
            if ok2 {
                app.user_config.ints[.WindowX] = i64(new_pos.x)
                app.user_config.ints[.WindowY] = i64(new_pos.y)
            }
        }

        audio_tick(&app.audio_system)

        @static window_minimized := false
        {
            value, ok := output_verbs.bools[.MinimizeWindow]
            if ok {
                window_minimized = value
                if !value {
                    app.vgd.resize_window = true
                }
            }
        }

        {
            imgui.SliderFloat("Fog intensity", &renderer.uniforms.fog_fudge, 100.0, 5000.0)
            
        }

        // Render
        cancel_frame := window_minimized
        graphics: if !cancel_frame {
            scoped_event(&profiler, "Everything from remaking the window to presenting the swapchain")
            full_swapchain_remake :: proc(gd: ^vkw.VulkanGraphicsDevice, renderer: ^Renderer, user_config: ^UserConfiguration, window: Window) {
                scoped_event(&profiler, "full_swapchain_remake")
                io := imgui.GetIO()

                info := vkw.SwapchainInfo {
                    dimensions = {
                        uint(window.resolution.x),
                        uint(window.resolution.y)
                    },
                    present_mode = window.present_mode
                }
                if !vkw.resize_window(gd, info) {
                    log.error("Failed to resize window")
                }
                resize_framebuffers(gd, renderer, window.resolution)
                is_fullscreen := user_config.flags[.BorderlessFullscreen] || user_config.flags[.ExclusiveFullscreen]
                if !is_fullscreen {
                    user_config.ints[.WindowWidth] = i64(window.resolution.x)
                    user_config.ints[.WindowHeight] = i64(window.resolution.y)
                }
                io.DisplaySize.x = f32(window.resolution.x)
                io.DisplaySize.y = f32(window.resolution.y)
            }

            // Resize swapchain if necessary
            if app.vgd.resize_window {
                full_swapchain_remake(&app.vgd, &app.renderer, &app.user_config, app.window)
                app.vgd.resize_window = false
            }

            // Pre-command-buffer-recording work for imgui
            setup_imgui_textures(&app.vgd, &app.gui)

            // Sync point where we wait if there are already 2 frames in the gfx queue
            {
                scoped_event(&profiler, "CPU wait on GPU")
                vkw.wait_frames_in_flight(&app.vgd)
            }

            // Acquire swapchain image and try to handle result
            swapchain_image_idx, acquire_result := vkw.acquire_swapchain_image(&app.vgd, &app.renderer.gfx_sync)
            #partial switch acquire_result {
                case .SUCCESS: {}
                case .SUBOPTIMAL_KHR, .ERROR_OUT_OF_DATE_KHR: {
                    app.vgd.resize_window = true
                    cancel_frame = true
                    break graphics
                }
                case: {
                    log.errorf("Swapchain image acquire failed: %v", acquire_result)
                    cancel_frame = true
                    break graphics
                }
            }

            gfx_cb_idx := vkw.begin_gfx_command_buffer(&app.vgd)

            // Define execution and memory dependencies surrounding swapchain image acquire
            vkw.swapchain_acquire_dependencies(&app.vgd, &app.renderer.gfx_sync, swapchain_image_idx)

            framebuffer := swapchain_framebuffer(&app.vgd, swapchain_image_idx, app.window.resolution)

            // Main render call
            render_scene(
                &app.vgd,
                gfx_cb_idx,
                &app.renderer,
                &framebuffer
            )

            // Draw Dear Imgui
            framebuffer.color_load_op = .LOAD
            render_imgui(&app.vgd, gfx_cb_idx, &app.gui, &framebuffer)

            // Submit gfx command buffer and present swapchain image
            {
                scoped_event(&profiler, "Submit to gfx queue and present")
                present_res := vkw.submit_gfx_and_present(&app.vgd, gfx_cb_idx, &app.renderer.gfx_sync, &swapchain_image_idx)
                if present_res == .SUBOPTIMAL_KHR || present_res == .ERROR_OUT_OF_DATE_KHR {
                    app.vgd.resize_window = true
                }
            }
            
        }

        if cancel_frame {
            gui_cancel_frame(&app.gui)
        }

        // End-of-frame cleanup
        {
            scoped_event(&profiler, "End-of-frame cleanup")

            // CLear temp allocator for next frame
            free_all(app.per_frame_allocator)

            // Clear sync info for next frame
            vkw.clear_sync_info(&app.renderer.gfx_sync)
            vkw.clear_sync_info(&app.renderer.compute_sync)
        }

        // CPU limiter
        if .LimitCPU in app.app_options {
            scoped_event(&profiler, "CPU Limiter")
            min_time := time.time_add(
                app.current_time,
                time.Duration(MILLISECONDS_TO_NANOSECONDS * minimum_frametime)
            )
            sleep_duration := max(0.0, time.diff(time.now(), min_time))
            time.sleep(sleep_duration)
        }
    }

    vkw.device_wait_idle(&app.vgd)
    log.info("Returning from main()")
}
