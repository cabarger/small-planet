//!
//! sp_platform.zig
//!
//! Polymorphic Games
//! zig 0.11.0
//! Caleb Barger
//! 01/10/24
//! barg8397@vandals.uidaho.edu
//!

const std = @import("std");
const third_party = @import("third_party");
const base = @import("base");

const base_thread_context = base.base_thread_context;
const rl = third_party.rl;
const bit_set = std.bit_set;
const math = std.math;
const fmt = std.fmt;
const mem = std.mem;
const fs = std.fs;
const rand = std.rand;

const FixedBufferAllocator = std.heap.FixedBufferAllocator;

pub const sp_update_and_render_sig = *fn (
    platform_api: *const PlatformAPI,
    game_state: *GameState,
    game_input: *GameInput,
    tctx: *base_thread_context.TCTX,
) void;

pub const GameInput = struct {
    pub const MouseInput = struct {
        wheel_move: f32,
        p: @Vector(2, f32),
        left_click: bool,
        right_click: bool,
    };

    pub const Key = enum(u8) {
        r = 0,
        h,
        e,
        m,
        t,

        f1,
        f2,
        f3,
        f4,

        left_shift,
        enter,
        space,

        kp_6,
        kp_4,

        up,
        down,
        right,
        left,

        count,
    };

    pub const KeyInput = struct {
        keys_down: bit_set.IntegerBitSet(@intFromEnum(Key.count)) =
            bit_set.IntegerBitSet(@intFromEnum(Key.count)).initEmpty(),

        pub inline fn isKeyDown(key_input: *const KeyInput, key: Key) bool {
            return key_input.keys_down.isSet(@intFromEnum(key));
        }
    };

    mouse_input: MouseInput,
    last_mouse_input: MouseInput,

    key_input: KeyInput,
    last_key_input: KeyInput,

    pub inline fn keyPressed(game_input: *const GameInput, key: GameInput.Key) bool {
        return (game_input.key_input.isKeyDown(key) and !game_input.last_key_input.isKeyDown(key));
    }

    pub inline fn keyHeld(game_input: *const GameInput, key: GameInput.Key) bool {
        return (game_input.key_input.isKeyDown(key) and game_input.last_key_input.isKeyDown(key));
    }

    // time: f64,
};

pub const PlatformAPI = struct {
    loadTexture: *const fn ([:0]const u8) rl.Texture,
    getFontDefault: *const fn () rl.Font,
    getScreenWidth: *const fn () c_int,
    getScreenHeight: *const fn () c_int,
    matrixInvert: *const fn (rl.Matrix) rl.Matrix,
    drawTexturePro: *const fn (rl.Texture, rl.Rectangle, rl.Rectangle, rl.Vector2, f32, rl.Color) void,
    getTime: *const fn () f64,
    beginDrawing: *const fn () void,
    clearBackground: *const fn (rl.Color) void,
    drawLineEx: *const fn (rl.Vector2, rl.Vector2, f32, rl.Color) void,
    drawTextCodepoint: *const fn (rl.Font, c_int, rl.Vector2, f32, rl.Color) void,
    drawTextEx: *const fn (rl.Font, [*:0]const u8, rl.Vector2, f32, f32, rl.Color) void,
    drawRectangleRec: *const fn (rl.Rectangle, rl.Color) void,
    drawRectangleLinesEx: *const fn (rl.Rectangle, line_thick: f32, rl.Color) void,
    endDrawing: *const fn () void,
    measureText: *const fn ([*:0]const u8, c_int) c_int,
    getFPS: *const fn () c_int,
    loadFont: *const fn ([*:0]const u8) rl.Font,
    checkCollisionPointRec: *const fn (point: rl.Vector2, rec: rl.Rectangle) bool,
};

// TODO(caleb): Function type for smallPlanetGameCode()
pub const GameState = struct {
    /// False prior to initial game code load otherwise true.
    did_init: bool,
    /// True when game code is recompiled.
    did_reload: bool,
    perm_fba: FixedBufferAllocator,
    scratch_fba: FixedBufferAllocator,

    // A word on offsets...
    // These are offsets to data residing in perm memory that platform layer
    // doesn't know about. (hents why they aren't stored here directly)

    entity_man_offset: usize,
    tile_p_components_offset: usize,
    target_tile_p_components_offset: usize,
    resource_kind_components_offset: usize,
    inventory_components_offset: usize,
    worker_state_components_offset: usize,
    tileset_offset: usize,
    world_offset: usize,

    // Types which are shared between platform and game code are placed here directly
    // as seen bellow.
    game_mode: u8,

    seed: u64,
    xoshiro_256: rand.Xoshiro256,
    sample_walk_map: []usize,

    game_time_minute: u8,
    game_time_hour: u8,
    game_time_day: u16,
    game_time_year: usize,

    tick_granularity: u8,

    debug_draw_distance_map: bool,
    debug_draw_grid_lines: bool,
    debug_draw_tile_height: bool,
    debug_draw_tile_hitboxes: bool,

    is_paused: bool,
    pause_start_time: f64,
    last_tick_time: f64,

    selected_tile_p: @Vector(2, i8),

    draw_3d: bool,
    scale_factor: f32,

    board_translation: @Vector(2, f32),
    draw_rot_state: u8,

    rl_font: rl.Font,
};
