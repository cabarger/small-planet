//!
//! rl_sp.zig
//!
//! Polymorphic Games
//! zig 0.11.0
//! Caleb Barger
//! 12/06/23
//! barg8397@vandals.uidaho.edu
//!
//! Raylib platform layer for small planet
//!

const builtin = @import("builtin");
const std = @import("std");
const third_party = @import("third_party");
const base = @import("base");
const build_options = @import("build_options");

const sp_platform = @import("sp_platform.zig");
const base_thread_context = base.base_thread_context;
const rl = third_party.rl;
const fs = std.fs;
const heap = std.heap;
const mem = std.mem;

const FixedBufferAllocator = heap.FixedBufferAllocator;

const debug_sound_enabled = false;

pub extern "c" fn dlerror() ?[*:0]const u8;

pub fn main() !void {
    rl.InitWindow(800, 600, "small-planet");
    rl.SetWindowState(rl.FLAG_WINDOW_RESIZABLE);
    rl.InitAudioDevice();

    var game_state: sp_platform.GameState = undefined;
    game_state.did_init = false;
    const platform_api = platformAPIInit();
    var game_input = mem.zeroes(sp_platform.GameInput);
    var tctx: base_thread_context.TCTX = undefined;
    base_thread_context.tctxInitAndEquip(&tctx);

    //- cabarger: Platform memory
    var platform_fba: FixedBufferAllocator = undefined;
    {
        var arena = base_thread_context.tctxGetScratch(null, 0) orelse unreachable;
        const ally = arena.allocator();
        var platform_mem = ally.alloc(u8, 1024) catch unreachable;
        platform_fba = FixedBufferAllocator.init(platform_mem);
    }

    //- cabarger: Game memory
    {
        var arena = base_thread_context.tctxGetScratch(null, 0) orelse unreachable;
        const ally = arena.allocator();
        var perm_mem = ally.alloc(u8, 1024 * 1024 * 5) catch unreachable;
        var scratch_mem = ally.alloc(u8, 1024 * 1024) catch unreachable;

        game_state.perm_fba = FixedBufferAllocator.init(perm_mem);
        game_state.scratch_fba = FixedBufferAllocator.init(scratch_mem);
    }

    //- cabarger: Music
    const track1 = rl.LoadMusicStream("assets/music/track_1.wav");
    if (build_options.enable_sound) {
        rl.PlayMusicStream(track1);
        rl.SetMusicVolume(track1, 1.0);
    }

    const rel_lib_path = "./zig-out/lib/";
    const active_game_code_path = try fs.path.join(
        platform_fba.allocator(),
        &[_][]const u8{
            rel_lib_path,
            if (builtin.os.tag == .windows) "active-game-code.dll" else "libactive-game-code.so",
        },
    );
    const game_code_path = try fs.path.join(
        platform_fba.allocator(),
        &[_][]const u8{
            rel_lib_path,
            if (builtin.os.tag == .windows) "game-code.dll" else "libgame-code.so",
        },
    );

    var game_code_file_ctime = (try fs.cwd().statFile(game_code_path)).ctime;
    const lib_dir = try fs.cwd().openDir(rel_lib_path, .{});
    try fs.cwd().copyFile(game_code_path, lib_dir, fs.path.basename(active_game_code_path), .{});

    var game_code_library: LibraryHandle = try loadLibrary(&platform_fba, active_game_code_path);
    var game_code_fn_ptr: LibraryFunction = try loadLibraryFunction(&platform_fba, game_code_library, "spUpdateAndRender");
    var spUpdateAndRender: sp_platform.sp_update_and_render_sig = @ptrCast(game_code_fn_ptr);

    while (!rl.WindowShouldClose()) {
        // Detect new game code lib and load it.
        const creation_time_now = (try std.fs.cwd().statFile(game_code_path)).ctime;
        if (creation_time_now != game_code_file_ctime) {
            unloadLibrary(game_code_library);
            try fs.cwd().copyFile(game_code_path, lib_dir, fs.path.basename(active_game_code_path), .{});
            game_code_library = try loadLibrary(&platform_fba, active_game_code_path);
            game_code_fn_ptr = try loadLibraryFunction(&platform_fba, game_code_library, "spUpdateAndRender");
            spUpdateAndRender = @ptrCast(game_code_fn_ptr);
            game_code_file_ctime = creation_time_now;
            game_state.did_reload = true; //- cabarger: Notify game code that it was reloaded.
        }

        //- cabarger: Mouse inputs
        game_input.last_mouse_input = game_input.mouse_input;
        game_input.mouse_input = mem.zeroes(sp_platform.GameInput.MouseInput);
        game_input.mouse_input.wheel_move = rl.GetMouseWheelMove();
        game_input.mouse_input.p = @bitCast(rl.GetMousePosition());
        game_input.mouse_input.left_click = rl.IsMouseButtonDown(rl.MOUSE_BUTTON_LEFT);
        game_input.mouse_input.right_click = rl.IsMouseButtonDown(rl.MOUSE_BUTTON_RIGHT);

        //- cabarger: Key inputs
        game_input.last_key_input = game_input.key_input;
        game_input.key_input = mem.zeroes(sp_platform.GameInput.KeyInput);
        for (0..@intFromEnum(sp_platform.GameInput.Key.count)) |sp_key_index| {
            if (rl.IsKeyDown(spToRLKey(@enumFromInt(sp_key_index))))
                game_input.key_input.keys_down.set(sp_key_index);
        }

        if (build_options.enable_sound)
            rl.UpdateMusicStream(track1);

        spUpdateAndRender(
            &platform_api,
            &game_state,
            &game_input,
            base_thread_context.tctxGetEquipped(),
        );
    }
    rl.CloseWindow();
}

const LibraryHandle = if (builtin.os.tag == .windows) std.os.windows.HMODULE else *anyopaque;
fn loadLibrary(scratch_fba: *FixedBufferAllocator, path: []const u8) !LibraryHandle {
    var result: LibraryHandle = undefined;
    const restore_end_index = scratch_fba.end_index;
    defer scratch_fba.end_index = restore_end_index;
    switch (builtin.os.tag) {
        .windows => {
            const lpstr_game_code_path =
                try scratch_fba.allocator().alloc(u16, path.len + 1);
            for (path, 0..) |byte, byte_index|
                lpstr_game_code_path[byte_index] = byte;
            lpstr_game_code_path[path.len] = 0;

            result = try std.os.windows.LoadLibraryW(@ptrCast(lpstr_game_code_path.ptr));
        },
        else => {
            const pathz = try scratch_fba.allocator().dupeZ(u8, path);
            var result2 = std.c.dlopen(pathz, 0x1);
            if (result2 == null) {
                std.debug.print("{s}\n", .{dlerror().?});
                unreachable;
            }
            result = result2.?;
        },
    }
    return result;
}

fn unloadLibrary(library_handle: LibraryHandle) void {
    switch (builtin.os.tag) {
        .windows => std.os.windows.FreeLibrary(library_handle),
        else => _ = std.c.dlclose(library_handle),
    }
}

const LibraryFunction = if (builtin.os.tag == .windows) std.os.windows.FARPROC else *anyopaque;
fn loadLibraryFunction(
    scratch_fba: *FixedBufferAllocator,
    library_handle: LibraryHandle,
    function_name: []const u8,
) !LibraryFunction {
    const restore_end_index = scratch_fba.end_index;
    defer scratch_fba.end_index = restore_end_index;
    var result: LibraryFunction = undefined;
    switch (builtin.os.tag) {
        .windows => {
            result = std.os.windows.kernel32.GetProcAddress(library_handle, function_name.ptr) orelse unreachable;
        },
        else => {
            const function_namez = scratch_fba.allocator().dupeZ(u8, function_name) catch unreachable;
            result = std.c.dlsym(library_handle, function_namez) orelse unreachable;
        },
    }
    return result;
}

inline fn spToRLKey(sp_key: sp_platform.GameInput.Key) c_int {
    return switch (sp_key) {
        .r => rl.KEY_R,
        .h => rl.KEY_H,
        .e => rl.KEY_E,
        .m => rl.KEY_M,
        .t => rl.KEY_T,
        .f1 => rl.KEY_F1,
        .f2 => rl.KEY_F2,
        .f3 => rl.KEY_F3,
        .f4 => rl.KEY_F4,
        .left_shift => rl.KEY_LEFT_SHIFT,
        .enter => rl.KEY_ENTER,
        .space => rl.KEY_SPACE,
        .kp_6 => rl.KEY_KP_6,
        .kp_4 => rl.KEY_KP_4,
        .up => rl.KEY_UP,
        .down => rl.KEY_DOWN,
        .left => rl.KEY_LEFT,
        .right => rl.KEY_RIGHT,
        .count => unreachable,
    };
}

fn platformAPIInit() sp_platform.PlatformAPI {
    return sp_platform.PlatformAPI{
        .loadTexture = loadTexture,
        .getFontDefault = getFontDefault,
        .getScreenWidth = getScreenWidth,
        .getScreenHeight = getScreenHeight,
        .matrixInvert = matrixInvert,
        .drawTexturePro = drawTexturePro,
        .getTime = getTime,
        .beginDrawing = beginDrawing,
        .clearBackground = clearBackground,
        .drawLineEx = drawLineEx,
        .drawTextCodepoint = drawTextCodepoint,
        .drawTextEx = drawTextEx,
        .drawRectangleRec = drawRectangleRec,
        .drawRectangleLinesEx = drawRectangleLinesEx,
        .endDrawing = endDrawing,
        .measureText = measureText,
        .getFPS = getFPS,
        .loadFont = loadFont,
        .checkCollisionPointRec = checkCollisionPointRec,
    };
}

fn loadTexture(path: [:0]const u8) rl.Texture {
    return rl.LoadTexture(path);
}

fn getFontDefault() rl.Font {
    return rl.GetFontDefault();
}

fn getScreenWidth() c_int {
    return rl.GetScreenWidth();
}

fn getScreenHeight() c_int {
    return rl.GetScreenHeight();
}

fn matrixInvert(matrix: rl.Matrix) rl.Matrix {
    return rl.MatrixInvert(matrix);
}

fn drawTexturePro(texture: rl.Texture, source: rl.Rectangle, dest: rl.Rectangle, origin: rl.Vector2, rotation: f32, tint: rl.Color) void {
    return rl.DrawTexturePro(texture, source, dest, origin, rotation, tint);
}

fn getTime() f64 {
    return rl.GetTime();
}

fn beginDrawing() void {
    rl.BeginDrawing();
}

fn clearBackground(color: rl.Color) void {
    rl.ClearBackground(color);
}

fn drawLineEx(start: rl.Vector2, end: rl.Vector2, thick: f32, tint: rl.Color) void {
    return rl.DrawLineEx(start, end, thick, tint);
}

fn drawTextCodepoint(font: rl.Font, code_point: c_int, p: rl.Vector2, size: f32, color: rl.Color) void {
    rl.DrawTextCodepoint(font, code_point, p, size, color);
}

fn drawTextEx(font: rl.Font, text: [*:0]const u8, p: rl.Vector2, size: f32, spacing: f32, color: rl.Color) void {
    rl.DrawTextEx(font, text, p, size, spacing, color);
}

fn drawRectangleRec(rec: rl.Rectangle, color: rl.Color) void {
    rl.DrawRectangleRec(rec, color);
}

fn drawRectangleLinesEx(rec: rl.Rectangle, line_thick: f32, color: rl.Color) void {
    rl.DrawRectangleLinesEx(rec, line_thick, color);
}

fn checkCollisionPointRec(point: rl.Vector2, rec: rl.Rectangle) bool {
    return rl.CheckCollisionPointRec(point, rec);
}

fn endDrawing() void {
    rl.EndDrawing();
}

fn measureText(text: [*:0]const u8, glyph_size: c_int) c_int {
    return rl.MeasureText(text, glyph_size);
}

fn getFPS() c_int {
    return rl.GetFPS();
}

fn loadFont(font_path: [*:0]const u8) rl.Font {
    return rl.LoadFont(font_path);
}
