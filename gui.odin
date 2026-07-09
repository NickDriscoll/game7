package main

import "core:text/table"
import "core:c"
import "core:container/queue"
import "core:fmt"
import "core:math/linalg/hlsl"
import "core:log"
import "core:mem"
import "core:os"
import "core:reflect"
import "core:slice"
import "core:strings"
import "vendor:sdl2"
import vk "vendor:vulkan"
import imgui "odin-imgui"
import vkw "desktop_vulkan_wrapper"
import hm "desktop_vulkan_wrapper/handlemap"

MAX_IMGUI_VERTICES :: 256 * 1024
MAX_IMGUI_INDICES :: 64 * 1024

UserMenuItemCommon :: struct {
    _was_hovered: bool,
    _was_active: bool,
    label: string,
}

UserMenuButton :: struct {
    verb: VerbType,
}

UserMenuCheckbox :: struct {
    value: ^bool,
}

UserMenuFlagsCheckbox :: struct($T: typeid) {
    set: ^bit_set[T],
    flag: T,
}

UserMenuSlider :: struct {
    value: ^f32,
    min: f32,
    max: f32,
}

UserMenuWidget :: union {
    UserMenuButton,
    UserMenuCheckbox,
    //UserMenuFlagsCheckbox,
    UserMenuSlider
}

UserMenuItem :: struct {
    using c: UserMenuItemCommon,
    widget: UserMenuWidget,
}

UserMenu :: struct {
    items: []UserMenuItem,
    player_idx: int,
}

PAUSE_MENU_ITEMS : []UserMenuItem = {
    {
        label = "Resume",
        widget = UserMenuButton {
            verb = .PlayerPauseGame,
        },
    },
    {
        label = "Guide",
        widget = UserMenuButton {
            //verb = .PlayerPauseGame,
        },
    },
    {
        label = "Settings",
        widget = UserMenuButton {
            verb = .SettingsMenu,
        },
    },
    {
        label = "Quit",
        widget = UserMenuButton {
            verb = .Quit,
        },
    },
}
SETTINGS_MENU_ITEMS : []UserMenuItem = {
    {
        label = "Game",
        widget = UserMenuButton {
        },
    },
    {
        label = "Graphics",
        widget = UserMenuButton {
            verb = .GraphicsMenu
        },
    },
    {
        label = "Audio",
        widget = UserMenuButton {
            verb = .AudioMenu,
        },
    },
    {
        label = "System",
        widget = UserMenuButton {
        },
    },
    {
        label = "Back",
        widget = UserMenuButton {
            verb = .PopMenu,
        },
    },
}

ImguiPushConstants :: struct {
    font_idx: u32,
    sampler: vkw.Immutable_Sampler_Index,
    vertex_offset: u32,
    uniform_data: vk.DeviceAddress,
    vertex_data: vk.DeviceAddress,
}

ImguiUniforms :: struct {
    clip_from_screen: hlsl.float4x4,
}

ImguiState :: struct {
    ctxt: ^imgui.Context,
    vertex_buffer: vkw.Buffer_Handle,
    index_buffer: vkw.Buffer_Handle,
    uniform_buffer: vkw.Buffer_Handle,
    pipeline: vkw.Pipeline_Handle,
    show_gui: bool,

    dockspace_id: u32,
    dockspace_viewport: [4]f32,

    user_facing_font: ^imgui.Font,
    menu_stack: queue.Queue(UserMenu),
    menu_player_idx: int,               // Last player to use menus
}

imgui_init :: proc(gd: ^vkw.VulkanGraphicsDevice, user_config: UserConfiguration, resolution: hlsl.uint2, global_allocator := context.allocator) -> ImguiState {
    scoped_event(&profiler, "ImGUI init")
    imgui_state: ImguiState
    imgui_state.show_gui = user_config.flags[.ImguiEnabled]
    imgui_state.ctxt = imgui.CreateContext()

    queue.init(&imgui_state.menu_stack, allocator = global_allocator)

    io := imgui.GetIO()
    io.DisplaySize.x = f32(resolution.x)
    io.DisplaySize.y = f32(resolution.y)
    io.ConfigFlags += {.DockingEnable,.NavEnableGamepad}
    io.BackendFlags += {.RendererHasTextures,.HasGamepad}
    io.ConfigDpiScaleFonts = true

    platform_io := imgui.GetPlatformIO()
    platform_io.Platform_GetClipboardTextFn = get_clipboard_text
    platform_io.Platform_SetClipboardTextFn = set_clipboard_text

    // Create font atlas
    default_font := imgui.FontAtlas_AddFontDefaultVector(io.Fonts)
    imgui_state.user_facing_font = imgui.FontAtlas_AddFontFromFileTTF(io.Fonts, "data/fonts/carmina.ttf")
    style := imgui.GetStyle()
    style.FontSizeBase = 16

    {
        user_font_scale, ok := user_config.floats[.ImguiFontScaleMain]
        if ok {
            style.FontScaleMain = cast(f32)user_font_scale
        }
    } 

    // Allocate imgui vertex buffer
    buffer_info := vkw.Buffer_Info {
        size = vk.DeviceSize(gd.frames_in_flight) * MAX_IMGUI_VERTICES * size_of(imgui.DrawVert),
        usage = {.STORAGE_BUFFER,.TRANSFER_DST},
        alloc_flags = nil,
        required_flags = {.DEVICE_LOCAL},
        name = "ImGUI vertex buffer",
    }
    imgui_state.vertex_buffer = vkw.create_buffer(gd, &buffer_info)

    // Allocate imgui index buffer
    buffer_info = vkw.Buffer_Info {
        size = vk.DeviceSize(gd.frames_in_flight) * MAX_IMGUI_INDICES * size_of(imgui.DrawIdx),
        usage = {.INDEX_BUFFER,.TRANSFER_DST},
        alloc_flags = nil,
        required_flags = {.DEVICE_LOCAL},
        name = "ImGUI index buffer",
    }
    imgui_state.index_buffer = vkw.create_buffer(gd, &buffer_info)

    // Create uniform buffer
    {
        info := vkw.Buffer_Info {
            size = size_of(ImguiUniforms) * vk.DeviceSize(gd.frames_in_flight),
            usage = {.UNIFORM_BUFFER,.TRANSFER_DST},
            alloc_flags = {.Mapped},
            required_flags = {.DEVICE_LOCAL,.HOST_VISIBLE,.HOST_COHERENT},
            name = "ImGUI uniform buffer",
        }
        imgui_state.uniform_buffer = vkw.create_buffer(gd, &info)
    }

    // Create pipeline for drawing

    // Load shader bytecode
    // This will be embedded into the executable at compile-time
    vertex_spv :: #load("data/shaders/imgui.vert.spv", []u32)
    fragment_spv :: #load("data/shaders/imgui.frag.spv", []u32)

    raster_state := vkw.default_rasterization_state()
    raster_state.cull_mode = nil

    pipeline_info := vkw.GraphicsPipelineInfo {
        vertex_shader_bytecode = vertex_spv,
        fragment_shader_bytecode = fragment_spv,
        input_assembly_state = vkw.Input_Assembly_State {
            topology = .TRIANGLE_LIST,
            primitive_restart_enabled = false,
        },
        tessellation_state = {},
        rasterization_state = raster_state,
        multisample_state = vkw.Multisample_State {
            sample_count = {._1},
            do_sample_shading = false,
            min_sample_shading = 0.0,
            sample_mask = nil,
            do_alpha_to_coverage = false,
            do_alpha_to_one = false,
        },
        depthstencil_state = vkw.DepthStencil_State {
            flags = nil,
            do_depth_test = false,
            do_depth_write = false,
            depth_compare_op = .GREATER_OR_EQUAL,
            do_depth_bounds_test = false,
            do_stencil_test = false,
            // front = nil,
            // back = nil,
            min_depth_bounds = 0.0,
            max_depth_bounds = 1.0,
        },
        colorblend_state = vkw.default_colorblend_state(),
        renderpass_state = vkw.PipelineRenderpass_Info {
            color_attachment_formats = {vk.Format.B8G8R8A8_SRGB},
            depth_attachment_format = nil,
        },
        name = "Dear ImGUI pipeline"
    }

    handles := vkw.create_graphics_pipelines(gd, {pipeline_info})

    imgui_state.pipeline = handles[0]

    return imgui_state
}

begin_gui :: proc(state: ^ImguiState) {
    imgui.NewFrame()

    // Make viewport-sized dockspace
    {
        dock_window_flags := imgui.WindowFlags {
            .NoTitleBar,
            .NoMove,
            .NoResize,
            .NoBackground,
            .NoMouseInputs,
            .NoNavInputs
        }
        dockspace_viewport := imgui.GetWindowViewport()

        imgui.SetNextWindowPos(dockspace_viewport.WorkPos)
        imgui.SetNextWindowSize(dockspace_viewport.WorkSize)
        if imgui.Begin("Main dock window", flags = dock_window_flags) {
            state.dockspace_id = imgui.GetID("Main dockspace")
            flags := imgui.DockNodeFlags {
                .NoDockingOverCentralNode,
                .PassthruCentralNode,
            }
            imgui.DockSpaceOverViewport(state.dockspace_id, dockspace_viewport, flags = flags)
        }
        imgui.End()

        docknode := imgui.DockBuilderGetCentralNode(state.dockspace_id)
        state.dockspace_viewport[0] = docknode.Pos.x
        state.dockspace_viewport[1] = docknode.Pos.y
        state.dockspace_viewport[2] = docknode.Size.x
        state.dockspace_viewport[3] = docknode.Size.y
    }
}

MainMenuBarVerb :: enum {
    None,
    NewLevel,
    LoadLevel,
    SaveLevel,
    SaveLevelAs,
    Exit,
    ToggleAlwaysOnTop,
    ToggleBorderlessFullscreen,
    ToggleExclusiveFullscreen,
}

gui_main_menu_bar :: proc(
    app: ^App,
) -> MainMenuBarVerb {
    retval := MainMenuBarVerb.None
    if !app.gui.show_gui {
        return retval
    }

    io := imgui.GetIO()

    if imgui.BeginMainMenuBar() {
        if imgui.BeginMenu("File") {
            if imgui.MenuItem("New") {
                retval = .NewLevel
            }
            if imgui.MenuItem("Load") {
                retval = .LoadLevel
            }
            if imgui.MenuItem("Save") {
                retval = .SaveLevel
            }
            if imgui.MenuItem("Save As") {
                retval = .SaveLevelAs
            }
            if imgui.MenuItem("Save user config") {
                app.user_config.strs[.StartLevel] = app.current_level

                tform := &app.game_state.transforms[app.game_state.viewport_cameras[0]]
                camera := &app.game_state.cameras[app.game_state.viewport_cameras[0]]
                following := app.game_state.viewport_cameras[0] in app.game_state.lookat_controllers
                update_user_cfg_camera(&app.user_config, tform.position, following, camera^)

                save_user_config(&app.user_config, USER_CONFIG_FILENAME)
                log.info("Saved user config.")
            }
            if imgui.MenuItem("Exit") {
                retval = .Exit
            }

            imgui.EndMenu()
        }

        if imgui.BeginMenu("Edit") {
            if imgui.MenuItem("Scene", "idk", selected = bool(app.user_config.flags[.SceneEditor])) {
                app.user_config.flags[.SceneEditor] = !app.user_config.flags[.SceneEditor]
            }

            imgui.EndMenu()
        }

        if imgui.BeginMenu("Config") {
            config_autosave := app.user_config.flags[.ConfigAutosave]
            if imgui.MenuItem("Auto-save user config", selected = config_autosave) {
                app.user_config.flags[.ConfigAutosave] = !app.user_config.flags[.ConfigAutosave]
            }
            if imgui.MenuItem("Audio", selected = app.user_config.flags[.AudioPanel]) {
                app.user_config.flags[.AudioPanel] = !app.user_config.flags[.AudioPanel]
            }
            if imgui.MenuItem("Graphics", "erm", app.user_config.flags[.GraphicsSettings]) {
                app.user_config.flags[.GraphicsSettings] = !app.user_config.flags[.GraphicsSettings]
            }
            input_config := app.user_config.flags[.InputConfig]
            if imgui.MenuItem("Input", "porque?", input_config) {
                app.user_config.flags[.InputConfig] = !app.user_config.flags[.InputConfig]
            }
            camera_config := app.user_config.flags[.CameraConfig]
            if imgui.MenuItem("Camera", selected = camera_config) {
                app.user_config.flags[.CameraConfig] = !app.user_config.flags[.CameraConfig]
            }
            window_config := app.user_config.flags[.WindowConfig]
            if imgui.MenuItem("Window", selected = window_config) {
                app.user_config.flags[.WindowConfig] = !app.user_config.flags[.WindowConfig]
            }

            imgui.EndMenu()
        }

        if imgui.BeginMenu("Window") {
            if imgui.MenuItem("Always On Top", selected = bool(app.user_config.flags[.AlwaysOnTop])) {
                app.user_config.flags[.AlwaysOnTop] = !app.user_config.flags[.AlwaysOnTop]
                retval = .ToggleAlwaysOnTop
            }

            if imgui.MenuItem("Borderless Fullscreen", selected = app.game_state.borderless_fullscreen) {
                // Update config map
                app.user_config.flags[.BorderlessFullscreen] = !app.game_state.borderless_fullscreen
                retval = .ToggleBorderlessFullscreen
            }

            if imgui.MenuItem("Exclusive Fullscreen", selected = app.game_state.exclusive_fullscreen) {
                // Update config map
                app.user_config.flags[.ExclusiveFullscreen] = !app.game_state.exclusive_fullscreen
                retval = .ToggleExclusiveFullscreen
            }

            imgui.EndMenu()
        }

        if imgui.BeginMenu("Debug") {
            if imgui.MenuItem("Debug panel", selected = app.user_config.flags[.ShowDebugMenu]) {
                app.user_config.flags[.ShowDebugMenu] = !app.user_config.flags[.ShowDebugMenu]
            }
            when ODIN_DEBUG {
                if imgui.MenuItem("Allocator stats", selected = app.user_config.flags[.ShowAllocatorStats]) {
                    app.user_config.flags[.ShowAllocatorStats] = !app.user_config.flags[.ShowAllocatorStats]
                }
            }
            if imgui.MenuItem("Dear ImGUI demo", selected = app.user_config.flags[.ShowImguiDemo]) {
                app.user_config.flags[.ShowImguiDemo] = !app.user_config.flags[.ShowImguiDemo]
            }

            imgui.EndMenu()
        }

        imgui.EndMainMenuBar()
    }

    return retval
}

gui_centered_button :: proc(label: cstring, alignment: f32 = 0.5) -> bool {
    style := imgui.GetStyle()
    size := imgui.CalcTextSize(label).x + style.FramePadding * 2.0
    avail := imgui.GetContentRegionAvail().x
    offset := (avail - size) * alignment
    cursor_pos := imgui.GetCursorPos()
    pos := cursor_pos.x + offset
    imgui.SetCursorPos({pos.x, cursor_pos.y})

    return imgui.Button(label)
}

gui_do_menu_stack :: proc(app: ^App) -> VerbType {
    retval : VerbType = nil

    // Handle menu stack
    @static last_was_menu := false
    if queue.len(app.gui.menu_stack) > 0 {
        active_menu := queue.front_ptr(&app.gui.menu_stack)
        app.gui.menu_player_idx = active_menu.player_idx

        // Renderer and input state
        app.renderer.uniforms.fade_to_black = 0.4
        app.renderer.uniforms.flags += {.BlackAndWhite}
        app.input_system.button_mappings[active_menu.player_idx] = &app.game_state.menu_button_mappings[active_menu.player_idx]
        app.input_system.key_mappings[active_menu.player_idx] = &app.game_state.character_menu_key_mappings

        retval = gui_user_menu(app.gui, active_menu.items[:])
        last_was_menu = true
    } else if last_was_menu {
        app.renderer.uniforms.fade_to_black = 1.0
        app.renderer.uniforms.flags -= {.BlackAndWhite}
        app.input_system.button_mappings[app.gui.menu_player_idx] = &app.game_state.button_mappings[app.gui.menu_player_idx]
        app.input_system.key_mappings[app.gui.menu_player_idx] = &app.game_state.character_key_mappings
        app.game_state.paused = false
        last_was_menu = false
    }

    return retval
}

gui_user_menu :: proc(gui: ImguiState, items: []UserMenuItem) -> VerbType {
    imgui.PushFontFloat(gui.user_facing_font, 48.0)
    defer imgui.PopFont()

    retval : VerbType = nil

    imgui.SetNextWindowPos({
        gui.dockspace_viewport[2] / 2.0,
        gui.dockspace_viewport[3] / 2.0,
    }, .Always, {0.5, 0.5})

    imgui.SetNavCursorVisible(true)

    // First pass for layout
    items_size := [2]f32 {}
    total_items := 0
    for item in items {
        total_items += 1
        label := strings.unsafe_string_to_cstring(item.label)
        text_size := imgui.CalcTextSize(label)
        switch it in item.widget {
            case UserMenuButton: {
                items_size.x = max(items_size.x, text_size.x)
                items_size.y += text_size.y
            }
            case UserMenuCheckbox: {
                items_size.x = max(items_size.x, text_size.x + imgui.GetFrameHeight())
                items_size.y += text_size.y
            }
            case UserMenuSlider: {
                items_size.y += text_size.y
                items_size.x = max(imgui.GetContentRegionAvail().x + text_size.x, items_size.x)
            }
        }
    }
    // Add padding
    items_size.y += 10.0 * f32(total_items)

    imgui.SetNextWindowSize({items_size.x + 30.0, items_size.y})
    flags : imgui.WindowFlags = {.NoTitleBar,.NoResize,.NoScrollbar,.NoBackground}
    //flags : imgui.WindowFlags = {.NoTitleBar,.NoScrollbar}
    defer imgui.End()
    if imgui.Begin("Pause menu", nil, flags) {
        imgui.PushStyleColor(.Button, 0x00000000)
        imgui.PushStyleColor(.ButtonHovered, 0x00000000)
        imgui.PushStyleColor(.ButtonActive, 0x00000000)
        imgui.PushStyleColor(.NavCursor, 0xFFFFFFFF)
        imgui.PushStyleColor(.ScrollbarBg, 0x00000000)
        imgui.PushStyleColor(.FrameBg, 0xFF111111)
        defer imgui.PopStyleColor()
        defer imgui.PopStyleColor()
        defer imgui.PopStyleColor()
        defer imgui.PopStyleColor()
        defer imgui.PopStyleColor()
        defer imgui.PopStyleColor()


        new_cursor := imgui.GetCursorPos()
        new_cursor.y = imgui.GetCursorPos().y + imgui.GetContentRegionAvail().y / 2.0 - items_size.y / 2.0
        imgui.SetCursorPos(new_cursor)

        // Unselected, Hovered, Active
        text_colors := [?]u32 {0xFFFFFFFF, 0xFF007700, 0xFF00FF00}

        // Second pass for building UI
        for &item, i in items {
            colori := 0
            if item._was_hovered {colori = 1}
            if item._was_active {colori = 2}
            imgui.PushStyleColor(.Text, text_colors[colori])
            imgui.PushStyleColor(.SliderGrab, text_colors[colori])
            imgui.PushStyleColor(.SliderGrabActive, text_colors[colori])
            defer imgui.PopStyleColor()
            defer imgui.PopStyleColor()
            defer imgui.PopStyleColor()
            label := strings.unsafe_string_to_cstring(item.label)
            switch &it in item.widget {
                case UserMenuButton: {
                    if gui_centered_button(label) {
                        retval = it.verb
                    }
                }
                case UserMenuCheckbox: {
                    imgui.Checkbox(label, it.value)
                }
                case UserMenuSlider: {
                    imgui.SetNextItemWidth(imgui.GetContentRegionAvail().x * 0.5)
                    imgui.SliderFloat(label, it.value, it.min, it.max)
                }
            }
            item._was_hovered = imgui.IsItemHovered()
            item._was_active = imgui.IsItemActive()

            if i == 0 {
                imgui.SetItemDefaultFocus()
            }
        }
    }

    return retval
}

gui_print_value :: proc(builder: ^strings.Builder, label: string, value: $T) {
    fmt.sbprintf(builder, "%v: %v", label, value)
    imgui.Text(strings.to_cstring(builder))
    strings.builder_reset(builder)
}

gui_dropdown_files :: proc(path: string, list_items: ^[dynamic]cstring, selected_item: ^c.int, name: cstring, allocator := context.temp_allocator) -> bool {
    w: os.Walker
    os.walker_init_path(&w, path)
	defer os.walker_destroy(&w)

    for info in os.walker_walk(&w) {
        append(list_items, strings.clone_to_cstring(info.name, allocator))
    }

    ok := false
    if imgui.BeginCombo(name, list_items[selected_item^], {.HeightLarge}) {
        for item, i in list_items {
            if imgui.Selectable(item) {
                selected_item^ = i32(i)
                ok = true
            }
        }
        imgui.EndCombo()
    }
    return ok
}

gui_list_files :: proc(path: string, list_items: ^[dynamic]cstring, selected_item: ^c.int, name: cstring, allocator := context.temp_allocator) -> bool {
    w: os.Walker
    os.walker_init_path(&w, path)
	defer os.walker_destroy(&w)

    for info in os.walker_walk(&w) {
        append(list_items, strings.clone_to_cstring(info.name, allocator))
    }

    // Show listbox
    selected_item^ = 0
    return imgui.ListBox(name, selected_item, &list_items[0], c.int(len(list_items)), 15)
}

gui_dropdown_enum :: proc(label: cstring, current_value: ^$Enum, allocator := context.temp_allocator) -> bool {
    names := reflect.enum_field_names(Enum)
    items := make([dynamic]cstring, 0, len(names), allocator)
    selected: c.int
    for name, i in names {
        if int(current_value^) == i {
            selected = c.int(i)
        }
        cs := strings.clone_to_cstring(name, allocator)
        append(&items, cs)
    }

    interacted := false
    if imgui.BeginCombo(label, items[selected]) {
        for item, i in items {
            if imgui.Selectable(item) {
                current_value^ = Enum(i)
                interacted = true
            }
        }
        imgui.EndCombo()
    }
    return interacted
}

window_config :: proc(im: ImguiState, window: ^Window, user_config: UserConfiguration) -> bool {
    resize := false
    if imgui.Begin("Window", &user_config.flags[.WindowConfig]) {
        // Present mode switcher
        item: c.int = c.int(window.present_mode)
        modes : []cstring = {"Immediate","Mailbox","FIFO"}

        if imgui.BeginCombo("Present mode", modes[item]) {
            for mode, i in modes {
                if imgui.Selectable(mode) {
                    item = i32(i)
                    window.present_mode = vk.PresentModeKHR(item)
                    resize = true
                }
            }
            imgui.EndCombo()
        }
    }
    imgui.End()

    return resize
}

// Call this before beginning a vkw gfx command buffer
setup_imgui_textures :: proc(
    gd: ^vkw.VulkanGraphicsDevice,
    imgui_state: ^ImguiState,
    temp_allocator := context.temp_allocator
) {
    // This ends the current imgui frame until
    // the next call to imgui.NewFrame()
    {
        scoped_event(&profiler, "imgui.Render()")
        imgui.Render()
    }

    image_premultiply_alpha :: proc(bytes_slice: []byte, bytes_per_pixel: int) {
        for i := 0; i < len(bytes_slice); i += bytes_per_pixel {
            pixel := hlsl.float4 {
                f32(bytes_slice[i]) / 255.0,
                f32(bytes_slice[i + 1]) / 255.0,
                f32(bytes_slice[i + 2]) / 255.0,
                f32(bytes_slice[i + 3]) / 255.0,
            }
            new_pixel := pixel.rgb * pixel.a
            bytes_slice[i] = byte(new_pixel.r * 255.0)
            bytes_slice[i + 1] = byte(new_pixel.g * 255.0)
            bytes_slice[i + 2] = byte(new_pixel.b * 255.0)
        }
    }

    draw_data := imgui.GetDrawData()
    tex_count := draw_data.Textures.Size
    for i in 0..<tex_count {
        tex := (cast(^^imgui.TextureData)(uintptr(draw_data.Textures.Data) + uintptr(i * size_of(^imgui.TextureData))))^

        switch tex.Status {
            case .OK: {}
            case .Destroyed: {
            }
            case .WantCreate: {
                data := tex.Pixels
                width := tex.Width
                height := tex.Height

                format := vk.Format.R8G8B8A8_SRGB
                if tex.BytesPerPixel == 1 {
                    format = .R8_SRGB
                }

                info := vkw.Image_Create {
                    flags = nil,
                    image_type = .D2,
                    format = format,
                    extent = {
                        width = u32(width),
                        height = u32(height),
                        depth = 1,
                    },
                    has_mipmaps = false,
                    array_layers = 1,
                    samples = {._1},
                    tiling = .OPTIMAL,
                    usage = {.SAMPLED,.TRANSFER_DST},
                    alloc_flags = nil,
                    name = "Dear ImGUI font atlas",
                }
                font_bytes_slice := slice.from_ptr(data, int(width * height * tex.BytesPerPixel))

                // Premultiply alpha
                //image_premultiply_alpha(font_bytes_slice, int(tex.BytesPerPixel))

                tex_handle, ok := vkw.sync_create_image_with_data(gd, &info, font_bytes_slice)
                if !ok {
                    log.error("Failed to upload imgui font atlas data.")
                }

                imgui.TextureData_SetTexID(tex, hm.handle_to_u64(tex_handle))
                imgui.TextureData_SetStatus(tex, .OK)
            }
            case .WantUpdates: {
                update_rect := vk.Rect2D {
                    offset = {
                        x = i32(tex.UpdateRect.x),
                        y = i32(tex.UpdateRect.y),
                    },
                    extent = {
                        width = u32(tex.UpdateRect.w),
                        height = u32(tex.UpdateRect.h)
                    }
                }

                tex_handle := vkw.Image_Handle(hm.u64_to_handle(tex.TexID))
                tex_image, exok := vkw.get_image(gd, tex_handle)
                assert(exok)

                // tex.Pixels points to the whole image, so we need to manually
                // pick out the rows referred to by update_rect to copy to the image
                format_pixel_size := int(tex.BytesPerPixel)
                upload_pitch := int(update_rect.extent.width) * format_pixel_size
                subrect_pixels := make([dynamic]byte, upload_pitch * int(update_rect.extent.height), temp_allocator)
                for y in 0..<int(update_rect.extent.height) {
                    current_row := y + int(update_rect.offset.y)
                    in_ptr := cast(^byte)(uintptr(tex.Pixels) + uintptr(format_pixel_size * ((current_row * int(tex_image.extent.width)) + int(update_rect.offset.x))))
                    sp := &subrect_pixels[y * upload_pitch]
                    mem.copy_non_overlapping(sp, in_ptr, upload_pitch)
                }

                // Premultiply alpha
                //image_premultiply_alpha(subrect_pixels[:], format_pixel_size)

                vkw.sync_update_image_data(
                    gd,
                    vkw.Image_Handle(hm.u64_to_handle(tex.TexID)),
                    update_rect,
                    0,
                    0,
                    subrect_pixels[:]
                )

                imgui.TextureData_SetStatus(tex, .OK)
            }
            case .WantDestroy: {
                handle := hm.u64_to_handle(tex.TexID)
                vkw.delete_image(gd, vkw.Image_Handle(handle))

                //tex.UnusedFrames = i32(gd.frames_in_flight)
                imgui.TextureData_SetTexID(tex, 0)
                imgui.TextureData_SetStatus(tex, .Destroyed)
            }
        }
    }
}

// Once-per-frame call to update imgui vtx/idx/uniform buffers
// and record imgui draw commands into current frame's command buffer
render_imgui :: proc(
    gd: ^vkw.VulkanGraphicsDevice,
    gfx_cb_idx: vkw.CommandBuffer_Index,
    imgui_state: ^ImguiState,
    framebuffer: ^vkw.Framebuffer
) {
    scoped_event(&profiler, "render_imgui")
    in_flight_frame := gd.frame_count % u64(gd.frames_in_flight)

    // Update uniform buffer

    io := imgui.GetIO()
    uniforms: ImguiUniforms
    uniforms.clip_from_screen = {
        2.0 / cast(f32)framebuffer.resolution.x, 0.0, 0.0, -1.0,
        0.0, 2.0 / cast(f32)framebuffer.resolution.y, 0.0, -1.0,
        0.0, 0.0, 1.0, 0.0,
        0.0, 0.0, 0.0, 1.0,
    }
    u_slice := slice.from_ptr(&uniforms, 1)
    vkw.sync_write_buffer(gd, imgui_state.uniform_buffer, u_slice, u32(in_flight_frame))

    // Insert a barrier to sync ImGUI's color attachment write
    // With the previous color attachment write
    // The assumption here is that ImGUI rendering will be
    // at or near the end of the chain
    {
        swapchain_color_attachment, _ := vkw.get_image(gd, framebuffer.color_images[0])
        cb := gd.gfx_command_buffers[gfx_cb_idx]
        vkw.cmd_pipeline_barriers(gd, cb, {},
            {
                {
                    src_stage_mask = {.COLOR_ATTACHMENT_OUTPUT},
                    src_access_mask = {.COLOR_ATTACHMENT_WRITE},
                    dst_stage_mask = {.COLOR_ATTACHMENT_OUTPUT},
                    dst_access_mask = {.COLOR_ATTACHMENT_READ},
                    old_layout = .COLOR_ATTACHMENT_OPTIMAL, // No layout transition happens with this barrier
                    new_layout = .COLOR_ATTACHMENT_OPTIMAL,
                    src_queue_family = gd.gfx_queue_family,
                    dst_queue_family = gd.gfx_queue_family,
                    image = swapchain_color_attachment.image,
                    subresource_range = vk.ImageSubresourceRange {
                        aspectMask = {.COLOR},
                        baseMipLevel = 0,
                        levelCount = 1,
                        baseArrayLayer = 0,
                        layerCount = 1
                    }
                }
            }
        )
    }

    draw_data := imgui.GetDrawData()
    assert(draw_data.TotalVtxCount < MAX_IMGUI_VERTICES)
    assert(draw_data.TotalIdxCount < MAX_IMGUI_INDICES)

    // Temp buffers for collecting imgui vertices/indices from all cmd lists
    vertex_staging := make(
        [dynamic]imgui.DrawVert,
        0,
        draw_data.TotalVtxCount,
        allocator = context.temp_allocator,
    )
    index_staging := make(
        [dynamic]imgui.DrawIdx,
        0,
        draw_data.TotalIdxCount,
        allocator = context.temp_allocator,
    )

    vkw.cmd_set_viewport(gd, gfx_cb_idx, 0, {vkw.Viewport {
        x = 0.0,
        y = 0.0,
        width = f32(framebuffer.resolution.x),
        height = f32(framebuffer.resolution.y),
        minDepth = 0.0,
        maxDepth = 1.0
    }})

    rp := vkw.RenderPass {
        fb = framebuffer,
    }
    vkw.cmd_begin_render_pass(gd, gfx_cb_idx, rp)

    vkw.cmd_set_viewport(gd, gfx_cb_idx, 0, {
        {
            x = 0.0,
            y = 0.0,
            width = f32(framebuffer.resolution.x),
            height = f32(framebuffer.resolution.y),
            minDepth = 0.0,
            maxDepth = 1.0
        }
    })

    imgui_vertex_buffer, ok := vkw.get_buffer(gd, imgui_state.vertex_buffer)
    if !ok {
        log.error("Failed to get imgui vertex buffer")
    }

    if !vkw.cmd_bind_index_buffer(gd, gfx_cb_idx, imgui_state.index_buffer) {
        log.error("Failed to get imgui index buffer")  
    }
    vkw.cmd_bind_gfx_pipeline(gd, gfx_cb_idx, imgui_state.pipeline)

    uniform_buf, ok2 := vkw.get_buffer(gd, imgui_state.uniform_buffer)
    assert(ok2)

    // Compute a fixed vertex/index offset based on frame index
    // so that the CPU doesn't overwrite vertex data for a frame currently
    // being worked on
    global_vtx_offset : u32 = u32(in_flight_frame * MAX_IMGUI_VERTICES)
    global_idx_offset : u32 = u32(in_flight_frame * MAX_IMGUI_INDICES)
    local_vtx_offset : u32 = 0
    local_idx_offset : u32 = 0

    cmd_lists := slice.from_ptr(draw_data.CmdLists.Data, int(draw_data.CmdListsCount))
    for cmd_list in cmd_lists {
        // Push this cmd_list's vertex data to the staging buffer
        vtx_slice := slice.from_ptr(cmd_list.VtxBuffer.Data, int(cmd_list.VtxBuffer.Size))
        append(&vertex_staging, ..vtx_slice)

        // Now the index data
        idx_slice := slice.from_ptr(cmd_list.IdxBuffer.Data, int(cmd_list.IdxBuffer.Size))
        append(&index_staging, ..idx_slice)

        // Record commands into command buffer
        cmds := slice.from_ptr(cmd_list.CmdBuffer.Data, int(cmd_list.CmdBuffer.Size))
        for &cmd in cmds {
            // Have to clamp offsets to 0 as the x and y components
            // can be -1 for some freaking reason
            sc_offsetx := max(0, cmd.ClipRect.x)
            sc_offsety := max(0, cmd.ClipRect.y)
            vkw.cmd_set_scissor(gd, gfx_cb_idx, 0, {
                {
                    offset = {
                        x = i32(sc_offsetx),
                        y = i32(sc_offsety),
                    },
                    extent = {
                        width = u32(cmd.ClipRect.z - cmd.ClipRect.x),
                        height = u32(cmd.ClipRect.a - cmd.ClipRect.y),
                    },
                },
            })

            tex_handle := imgui.DrawCmd_GetTexID(&cmd)
            vkw.cmd_push_constants_gfx(gd, gfx_cb_idx, &ImguiPushConstants {
                font_idx = u32(tex_handle),
                sampler = .Point,
                vertex_offset = cmd.VtxOffset + global_vtx_offset + local_vtx_offset,
                uniform_data = uniform_buf.address + vk.DeviceAddress(in_flight_frame * size_of(ImguiUniforms)),
                vertex_data = imgui_vertex_buffer.address,
            })

            vkw.cmd_draw_indexed(
                gd,
                gfx_cb_idx,
                cmd.ElemCount,
                1,
                cmd.IdxOffset + global_idx_offset + local_idx_offset,
                0, // This parameter is unused when doing vertex pulling
                0
            )
        }

        // Update offsets within local vertex/index buffers
        local_vtx_offset += u32(cmd_list.VtxBuffer.Size)
        local_idx_offset += u32(cmd_list.IdxBuffer.Size)
    }

    // Upload vertex and index data to GPU buffers
    vkw.sync_write_buffer(gd, imgui_state.vertex_buffer, vertex_staging[:], global_vtx_offset)
    vkw.sync_write_buffer(gd, imgui_state.index_buffer, index_staging[:], global_idx_offset)

    vkw.cmd_end_render_pass(gd, gfx_cb_idx)
}

gui_cancel_frame :: proc(imgui_state: ^ImguiState) {
    imgui.EndFrame()
}

gui_cleanup :: proc(vgd: ^vkw.VulkanGraphicsDevice, is: ^ImguiState) {
    imgui.DestroyContext(is.ctxt)
}

// Utility funcs

// Translated from imgui_demo.cpp
HelpMarker :: proc(desc: cstring) {
    imgui.TextDisabled("(?)")
    if imgui.BeginItemTooltip() {
        imgui.PushTextWrapPos(imgui.GetFontSize() * 35.0)
        imgui.TextUnformatted(desc)
        imgui.PopTextWrapPos()
        imgui.EndTooltip()
    }
}

SDL2ToImGuiKey :: proc(keycode: sdl2.Scancode) -> imgui.Key {
    #partial switch (keycode)
    {
        case .TAB: return imgui.Key.Tab
        case .LEFT: return imgui.Key.LeftArrow
        case .RIGHT: return imgui.Key.RightArrow
        case .UP: return imgui.Key.UpArrow
        case .DOWN: return imgui.Key.DownArrow
        case .PAGEUP: return imgui.Key.PageUp
        case .PAGEDOWN: return imgui.Key.PageDown
        case .HOME: return imgui.Key.Home
        case .END: return imgui.Key.End
        case .INSERT: return imgui.Key.Insert
        case .DELETE: return imgui.Key.Delete
        case .BACKSPACE: return imgui.Key.Backspace
        case .SPACE: return imgui.Key.Space
        case .RETURN: return imgui.Key.Enter
        case .ESCAPE: return imgui.Key.Escape
        case .APOSTROPHE: return imgui.Key.Apostrophe
        case .COMMA: return imgui.Key.Comma
        case .MINUS: return imgui.Key.Minus
        case .PERIOD: return imgui.Key.Period
        case .SLASH: return imgui.Key.Slash
        case .SEMICOLON: return imgui.Key.Semicolon
        case .EQUALS: return imgui.Key.Equal
        case .LEFTBRACKET: return imgui.Key.LeftBracket
        case .BACKSLASH: return imgui.Key.Backslash
        case .RIGHTBRACKET: return imgui.Key.RightBracket
        case .GRAVE: return imgui.Key.GraveAccent
        case .CAPSLOCK: return imgui.Key.CapsLock
        case .SCROLLLOCK: return imgui.Key.ScrollLock
        case .NUMLOCKCLEAR: return imgui.Key.NumLock
        case .PRINTSCREEN: return imgui.Key.PrintScreen
        case .PAUSE: return imgui.Key.Pause
        case .KP_0: return imgui.Key.Keypad0
        case .KP_1: return imgui.Key.Keypad1
        case .KP_2: return imgui.Key.Keypad2
        case .KP_3: return imgui.Key.Keypad3
        case .KP_4: return imgui.Key.Keypad4
        case .KP_5: return imgui.Key.Keypad5
        case .KP_6: return imgui.Key.Keypad6
        case .KP_7: return imgui.Key.Keypad7
        case .KP_8: return imgui.Key.Keypad8
        case .KP_9: return imgui.Key.Keypad9
        case .KP_PERIOD: return imgui.Key.KeypadDecimal
        case .KP_DIVIDE: return imgui.Key.KeypadDivide
        case .KP_MULTIPLY: return imgui.Key.KeypadMultiply
        case .KP_MINUS: return imgui.Key.KeypadSubtract
        case .KP_PLUS: return imgui.Key.KeypadAdd
        case .KP_ENTER: return imgui.Key.KeypadEnter
        case .KP_EQUALS: return imgui.Key.KeypadEqual
        case .LCTRL: return imgui.Key.LeftCtrl
        case .LSHIFT: return imgui.Key.LeftShift
        case .LALT: return imgui.Key.LeftAlt
        case .LGUI: return imgui.Key.LeftSuper
        case .RCTRL: return imgui.Key.RightCtrl
        case .RSHIFT: return imgui.Key.RightShift
        case .RALT: return imgui.Key.RightAlt
        case .RGUI: return imgui.Key.RightSuper
        case .APPLICATION: return imgui.Key.Menu
        case .NUM0: return imgui.Key._0
        case .NUM1: return imgui.Key._1
        case .NUM2: return imgui.Key._2
        case .NUM3: return imgui.Key._3
        case .NUM4: return imgui.Key._4
        case .NUM5: return imgui.Key._5
        case .NUM6: return imgui.Key._6
        case .NUM7: return imgui.Key._7
        case .NUM8: return imgui.Key._8
        case .NUM9: return imgui.Key._9
        case .A: return imgui.Key.A
        case .B: return imgui.Key.B
        case .C: return imgui.Key.C
        case .D: return imgui.Key.D
        case .E: return imgui.Key.E
        case .F: return imgui.Key.F
        case .G: return imgui.Key.G
        case .H: return imgui.Key.H
        case .I: return imgui.Key.I
        case .J: return imgui.Key.J
        case .K: return imgui.Key.K
        case .L: return imgui.Key.L
        case .M: return imgui.Key.M
        case .N: return imgui.Key.N
        case .O: return imgui.Key.O
        case .P: return imgui.Key.P
        case .Q: return imgui.Key.Q
        case .R: return imgui.Key.R
        case .S: return imgui.Key.S
        case .T: return imgui.Key.T
        case .U: return imgui.Key.U
        case .V: return imgui.Key.V
        case .W: return imgui.Key.W
        case .X: return imgui.Key.X
        case .Y: return imgui.Key.Y
        case .Z: return imgui.Key.Z
        case .F1: return imgui.Key.F1
        case .F2: return imgui.Key.F2
        case .F3: return imgui.Key.F3
        case .F4: return imgui.Key.F4
        case .F5: return imgui.Key.F5
        case .F6: return imgui.Key.F6
        case .F7: return imgui.Key.F7
        case .F8: return imgui.Key.F8
        case .F9: return imgui.Key.F9
        case .F10: return imgui.Key.F10
        case .F11: return imgui.Key.F11
        case .F12: return imgui.Key.F12
        case .F13: return imgui.Key.F13
        case .F14: return imgui.Key.F14
        case .F15: return imgui.Key.F15
        case .F16: return imgui.Key.F16
        case .F17: return imgui.Key.F17
        case .F18: return imgui.Key.F18
        case .F19: return imgui.Key.F19
        case .F20: return imgui.Key.F20
        case .F21: return imgui.Key.F21
        case .F22: return imgui.Key.F22
        case .F23: return imgui.Key.F23
        case .F24: return imgui.Key.F24
        case .AC_BACK: return imgui.Key.AppBack
        case .AC_FORWARD: return imgui.Key.AppForward
        case: {assert(false, "Unhandled key.")}
    }
    return imgui.Key.None
}

SDL2ToImGuiGamepadButton :: proc(button: sdl2.GameControllerButton) -> imgui.Key {
    #partial switch button {
        case .A: return .GamepadFaceDown
        case .B: return .GamepadFaceRight
        case .X: return .GamepadFaceLeft
        case .Y: return .GamepadFaceUp
        case .DPAD_LEFT: return .GamepadDpadLeft
        case .DPAD_RIGHT: return .GamepadDpadRight
        case .DPAD_DOWN: return .GamepadDpadDown
        case .DPAD_UP: return .GamepadDpadUp
        case .LEFTSHOULDER: return .GamepadL1
        case .RIGHTSHOULDER: return .GamepadR1
        case .LEFTSTICK: return .GamepadL3
        case .RIGHTSTICK: return .GamepadR3
        case .BACK: return .GamepadBack
        case .START: return .GamepadStart
        case .TOUCHPAD, .GUIDE: return .None
    }
    log.errorf("Unsupported button %v", button)
    assert(false)
    return .None
}

SDL2ToImGuiMouseButton :: proc(button: u8) -> i32 {
    button := i32(button)
    switch button {
        case sdl2.BUTTON_MIDDLE: return sdl2.BUTTON_RIGHT - 1
        case sdl2.BUTTON_RIGHT: return sdl2.BUTTON_MIDDLE - 1
    }
    return button - 1
}