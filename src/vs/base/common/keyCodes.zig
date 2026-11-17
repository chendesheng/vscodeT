// Port of `src/vs/base/common/keyCodes.ts`.
//
// Terminal adaptation: the upstream module-global string maps are derived from
// the mapping table at comptime, and lookups scan that table instead of using
// object hash maps (the table has 229 entries and keybinding parsing is not a
// hot path). `KeyCodeUtils.toString`/`toUserSettings*` return an empty string
// where upstream would return `undefined`, and `EVENT_KEY_CODE_MAP` entries that
// upstream leaves unset are `.Unknown`.
const std = @import("std");

/// Virtual key codes. The value does not hold any inherent meaning.
pub const KeyCode = enum(i16) {
    DependsOnKbLayout = -1,
    Unknown = 0,
    Backspace = 1,
    Tab = 2,
    Enter = 3,
    Shift = 4,
    Ctrl = 5,
    Alt = 6,
    PauseBreak = 7,
    CapsLock = 8,
    Escape = 9,
    Space = 10,
    PageUp = 11,
    PageDown = 12,
    End = 13,
    Home = 14,
    LeftArrow = 15,
    UpArrow = 16,
    RightArrow = 17,
    DownArrow = 18,
    Insert = 19,
    Delete = 20,
    Digit0 = 21,
    Digit1 = 22,
    Digit2 = 23,
    Digit3 = 24,
    Digit4 = 25,
    Digit5 = 26,
    Digit6 = 27,
    Digit7 = 28,
    Digit8 = 29,
    Digit9 = 30,
    KeyA = 31,
    KeyB = 32,
    KeyC = 33,
    KeyD = 34,
    KeyE = 35,
    KeyF = 36,
    KeyG = 37,
    KeyH = 38,
    KeyI = 39,
    KeyJ = 40,
    KeyK = 41,
    KeyL = 42,
    KeyM = 43,
    KeyN = 44,
    KeyO = 45,
    KeyP = 46,
    KeyQ = 47,
    KeyR = 48,
    KeyS = 49,
    KeyT = 50,
    KeyU = 51,
    KeyV = 52,
    KeyW = 53,
    KeyX = 54,
    KeyY = 55,
    KeyZ = 56,
    Meta = 57,
    ContextMenu = 58,
    F1 = 59,
    F2 = 60,
    F3 = 61,
    F4 = 62,
    F5 = 63,
    F6 = 64,
    F7 = 65,
    F8 = 66,
    F9 = 67,
    F10 = 68,
    F11 = 69,
    F12 = 70,
    F13 = 71,
    F14 = 72,
    F15 = 73,
    F16 = 74,
    F17 = 75,
    F18 = 76,
    F19 = 77,
    F20 = 78,
    F21 = 79,
    F22 = 80,
    F23 = 81,
    F24 = 82,
    NumLock = 83,
    ScrollLock = 84,
    Semicolon = 85,
    Equal = 86,
    Comma = 87,
    Minus = 88,
    Period = 89,
    Slash = 90,
    Backquote = 91,
    BracketLeft = 92,
    Backslash = 93,
    BracketRight = 94,
    Quote = 95,
    OEM_8 = 96,
    IntlBackslash = 97,
    Numpad0 = 98,
    Numpad1 = 99,
    Numpad2 = 100,
    Numpad3 = 101,
    Numpad4 = 102,
    Numpad5 = 103,
    Numpad6 = 104,
    Numpad7 = 105,
    Numpad8 = 106,
    Numpad9 = 107,
    NumpadMultiply = 108,
    NumpadAdd = 109,
    NUMPAD_SEPARATOR = 110,
    NumpadSubtract = 111,
    NumpadDecimal = 112,
    NumpadDivide = 113,
    KEY_IN_COMPOSITION = 114,
    ABNT_C1 = 115,
    ABNT_C2 = 116,
    AudioVolumeMute = 117,
    AudioVolumeUp = 118,
    AudioVolumeDown = 119,
    BrowserSearch = 120,
    BrowserHome = 121,
    BrowserBack = 122,
    BrowserForward = 123,
    MediaTrackNext = 124,
    MediaTrackPrevious = 125,
    MediaStop = 126,
    MediaPlayPause = 127,
    LaunchMediaPlayer = 128,
    LaunchMail = 129,
    LaunchApp2 = 130,
    Clear = 131,
    MAX_VALUE = 132,
};

/// `keyboardEvent.code`.
pub const ScanCode = enum(i16) {
    DependsOnKbLayout = -1,
    None = 0,
    Hyper = 1,
    Super = 2,
    Fn = 3,
    FnLock = 4,
    Suspend = 5,
    Resume = 6,
    Turbo = 7,
    Sleep = 8,
    WakeUp = 9,
    KeyA = 10,
    KeyB = 11,
    KeyC = 12,
    KeyD = 13,
    KeyE = 14,
    KeyF = 15,
    KeyG = 16,
    KeyH = 17,
    KeyI = 18,
    KeyJ = 19,
    KeyK = 20,
    KeyL = 21,
    KeyM = 22,
    KeyN = 23,
    KeyO = 24,
    KeyP = 25,
    KeyQ = 26,
    KeyR = 27,
    KeyS = 28,
    KeyT = 29,
    KeyU = 30,
    KeyV = 31,
    KeyW = 32,
    KeyX = 33,
    KeyY = 34,
    KeyZ = 35,
    Digit1 = 36,
    Digit2 = 37,
    Digit3 = 38,
    Digit4 = 39,
    Digit5 = 40,
    Digit6 = 41,
    Digit7 = 42,
    Digit8 = 43,
    Digit9 = 44,
    Digit0 = 45,
    Enter = 46,
    Escape = 47,
    Backspace = 48,
    Tab = 49,
    Space = 50,
    Minus = 51,
    Equal = 52,
    BracketLeft = 53,
    BracketRight = 54,
    Backslash = 55,
    IntlHash = 56,
    Semicolon = 57,
    Quote = 58,
    Backquote = 59,
    Comma = 60,
    Period = 61,
    Slash = 62,
    CapsLock = 63,
    F1 = 64,
    F2 = 65,
    F3 = 66,
    F4 = 67,
    F5 = 68,
    F6 = 69,
    F7 = 70,
    F8 = 71,
    F9 = 72,
    F10 = 73,
    F11 = 74,
    F12 = 75,
    PrintScreen = 76,
    ScrollLock = 77,
    Pause = 78,
    Insert = 79,
    Home = 80,
    PageUp = 81,
    Delete = 82,
    End = 83,
    PageDown = 84,
    ArrowRight = 85,
    ArrowLeft = 86,
    ArrowDown = 87,
    ArrowUp = 88,
    NumLock = 89,
    NumpadDivide = 90,
    NumpadMultiply = 91,
    NumpadSubtract = 92,
    NumpadAdd = 93,
    NumpadEnter = 94,
    Numpad1 = 95,
    Numpad2 = 96,
    Numpad3 = 97,
    Numpad4 = 98,
    Numpad5 = 99,
    Numpad6 = 100,
    Numpad7 = 101,
    Numpad8 = 102,
    Numpad9 = 103,
    Numpad0 = 104,
    NumpadDecimal = 105,
    IntlBackslash = 106,
    ContextMenu = 107,
    Power = 108,
    NumpadEqual = 109,
    F13 = 110,
    F14 = 111,
    F15 = 112,
    F16 = 113,
    F17 = 114,
    F18 = 115,
    F19 = 116,
    F20 = 117,
    F21 = 118,
    F22 = 119,
    F23 = 120,
    F24 = 121,
    Open = 122,
    Help = 123,
    Select = 124,
    Again = 125,
    Undo = 126,
    Cut = 127,
    Copy = 128,
    Paste = 129,
    Find = 130,
    AudioVolumeMute = 131,
    AudioVolumeUp = 132,
    AudioVolumeDown = 133,
    NumpadComma = 134,
    IntlRo = 135,
    KanaMode = 136,
    IntlYen = 137,
    Convert = 138,
    NonConvert = 139,
    Lang1 = 140,
    Lang2 = 141,
    Lang3 = 142,
    Lang4 = 143,
    Lang5 = 144,
    Abort = 145,
    Props = 146,
    NumpadParenLeft = 147,
    NumpadParenRight = 148,
    NumpadBackspace = 149,
    NumpadMemoryStore = 150,
    NumpadMemoryRecall = 151,
    NumpadMemoryClear = 152,
    NumpadMemoryAdd = 153,
    NumpadMemorySubtract = 154,
    NumpadClear = 155,
    NumpadClearEntry = 156,
    ControlLeft = 157,
    ShiftLeft = 158,
    AltLeft = 159,
    MetaLeft = 160,
    ControlRight = 161,
    ShiftRight = 162,
    AltRight = 163,
    MetaRight = 164,
    BrightnessUp = 165,
    BrightnessDown = 166,
    MediaPlay = 167,
    MediaRecord = 168,
    MediaFastForward = 169,
    MediaRewind = 170,
    MediaTrackNext = 171,
    MediaTrackPrevious = 172,
    MediaStop = 173,
    Eject = 174,
    MediaPlayPause = 175,
    MediaSelect = 176,
    LaunchMail = 177,
    LaunchApp2 = 178,
    LaunchApp1 = 179,
    SelectTask = 180,
    LaunchScreenSaver = 181,
    BrowserSearch = 182,
    BrowserHome = 183,
    BrowserBack = 184,
    BrowserForward = 185,
    BrowserStop = 186,
    BrowserRefresh = 187,
    BrowserFavorites = 188,
    ZoomToggle = 189,
    MailReply = 190,
    MailForward = 191,
    MailSend = 192,
    MAX_VALUE = 193,
};

const scan_code_count = @backingInt(ScanCode.MAX_VALUE) + 1;
const key_code_count = @backingInt(KeyCode.MAX_VALUE) + 1;

/// One row of the upstream `mappings` table.
const MappingEntry = struct {
    immutable: bool,
    scan_code: ScanCode,
    scan_code_str: []const u8,
    key_code: KeyCode,
    key_code_str: []const u8,
    event_key_code: u16,
    vkey: []const u8,
    us_user_settings_label: []const u8,
    general_user_settings_label: []const u8,
};

/// Immutable/native mapping rows from upstream (same order).
const mappings = [_]MappingEntry{
    .{ .immutable = true, .scan_code = .None, .scan_code_str = "None", .key_code = .Unknown, .key_code_str = "unknown", .event_key_code = 0, .vkey = "VK_UNKNOWN", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .Hyper, .scan_code_str = "Hyper", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .Super, .scan_code_str = "Super", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .Fn, .scan_code_str = "Fn", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .FnLock, .scan_code_str = "FnLock", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .Suspend, .scan_code_str = "Suspend", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .Resume, .scan_code_str = "Resume", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .Turbo, .scan_code_str = "Turbo", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .Sleep, .scan_code_str = "Sleep", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "VK_SLEEP", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .WakeUp, .scan_code_str = "WakeUp", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = false, .scan_code = .KeyA, .scan_code_str = "KeyA", .key_code = .KeyA, .key_code_str = "A", .event_key_code = 65, .vkey = "VK_A", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = false, .scan_code = .KeyB, .scan_code_str = "KeyB", .key_code = .KeyB, .key_code_str = "B", .event_key_code = 66, .vkey = "VK_B", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = false, .scan_code = .KeyC, .scan_code_str = "KeyC", .key_code = .KeyC, .key_code_str = "C", .event_key_code = 67, .vkey = "VK_C", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = false, .scan_code = .KeyD, .scan_code_str = "KeyD", .key_code = .KeyD, .key_code_str = "D", .event_key_code = 68, .vkey = "VK_D", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = false, .scan_code = .KeyE, .scan_code_str = "KeyE", .key_code = .KeyE, .key_code_str = "E", .event_key_code = 69, .vkey = "VK_E", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = false, .scan_code = .KeyF, .scan_code_str = "KeyF", .key_code = .KeyF, .key_code_str = "F", .event_key_code = 70, .vkey = "VK_F", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = false, .scan_code = .KeyG, .scan_code_str = "KeyG", .key_code = .KeyG, .key_code_str = "G", .event_key_code = 71, .vkey = "VK_G", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = false, .scan_code = .KeyH, .scan_code_str = "KeyH", .key_code = .KeyH, .key_code_str = "H", .event_key_code = 72, .vkey = "VK_H", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = false, .scan_code = .KeyI, .scan_code_str = "KeyI", .key_code = .KeyI, .key_code_str = "I", .event_key_code = 73, .vkey = "VK_I", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = false, .scan_code = .KeyJ, .scan_code_str = "KeyJ", .key_code = .KeyJ, .key_code_str = "J", .event_key_code = 74, .vkey = "VK_J", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = false, .scan_code = .KeyK, .scan_code_str = "KeyK", .key_code = .KeyK, .key_code_str = "K", .event_key_code = 75, .vkey = "VK_K", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = false, .scan_code = .KeyL, .scan_code_str = "KeyL", .key_code = .KeyL, .key_code_str = "L", .event_key_code = 76, .vkey = "VK_L", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = false, .scan_code = .KeyM, .scan_code_str = "KeyM", .key_code = .KeyM, .key_code_str = "M", .event_key_code = 77, .vkey = "VK_M", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = false, .scan_code = .KeyN, .scan_code_str = "KeyN", .key_code = .KeyN, .key_code_str = "N", .event_key_code = 78, .vkey = "VK_N", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = false, .scan_code = .KeyO, .scan_code_str = "KeyO", .key_code = .KeyO, .key_code_str = "O", .event_key_code = 79, .vkey = "VK_O", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = false, .scan_code = .KeyP, .scan_code_str = "KeyP", .key_code = .KeyP, .key_code_str = "P", .event_key_code = 80, .vkey = "VK_P", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = false, .scan_code = .KeyQ, .scan_code_str = "KeyQ", .key_code = .KeyQ, .key_code_str = "Q", .event_key_code = 81, .vkey = "VK_Q", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = false, .scan_code = .KeyR, .scan_code_str = "KeyR", .key_code = .KeyR, .key_code_str = "R", .event_key_code = 82, .vkey = "VK_R", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = false, .scan_code = .KeyS, .scan_code_str = "KeyS", .key_code = .KeyS, .key_code_str = "S", .event_key_code = 83, .vkey = "VK_S", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = false, .scan_code = .KeyT, .scan_code_str = "KeyT", .key_code = .KeyT, .key_code_str = "T", .event_key_code = 84, .vkey = "VK_T", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = false, .scan_code = .KeyU, .scan_code_str = "KeyU", .key_code = .KeyU, .key_code_str = "U", .event_key_code = 85, .vkey = "VK_U", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = false, .scan_code = .KeyV, .scan_code_str = "KeyV", .key_code = .KeyV, .key_code_str = "V", .event_key_code = 86, .vkey = "VK_V", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = false, .scan_code = .KeyW, .scan_code_str = "KeyW", .key_code = .KeyW, .key_code_str = "W", .event_key_code = 87, .vkey = "VK_W", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = false, .scan_code = .KeyX, .scan_code_str = "KeyX", .key_code = .KeyX, .key_code_str = "X", .event_key_code = 88, .vkey = "VK_X", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = false, .scan_code = .KeyY, .scan_code_str = "KeyY", .key_code = .KeyY, .key_code_str = "Y", .event_key_code = 89, .vkey = "VK_Y", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = false, .scan_code = .KeyZ, .scan_code_str = "KeyZ", .key_code = .KeyZ, .key_code_str = "Z", .event_key_code = 90, .vkey = "VK_Z", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = false, .scan_code = .Digit1, .scan_code_str = "Digit1", .key_code = .Digit1, .key_code_str = "1", .event_key_code = 49, .vkey = "VK_1", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = false, .scan_code = .Digit2, .scan_code_str = "Digit2", .key_code = .Digit2, .key_code_str = "2", .event_key_code = 50, .vkey = "VK_2", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = false, .scan_code = .Digit3, .scan_code_str = "Digit3", .key_code = .Digit3, .key_code_str = "3", .event_key_code = 51, .vkey = "VK_3", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = false, .scan_code = .Digit4, .scan_code_str = "Digit4", .key_code = .Digit4, .key_code_str = "4", .event_key_code = 52, .vkey = "VK_4", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = false, .scan_code = .Digit5, .scan_code_str = "Digit5", .key_code = .Digit5, .key_code_str = "5", .event_key_code = 53, .vkey = "VK_5", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = false, .scan_code = .Digit6, .scan_code_str = "Digit6", .key_code = .Digit6, .key_code_str = "6", .event_key_code = 54, .vkey = "VK_6", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = false, .scan_code = .Digit7, .scan_code_str = "Digit7", .key_code = .Digit7, .key_code_str = "7", .event_key_code = 55, .vkey = "VK_7", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = false, .scan_code = .Digit8, .scan_code_str = "Digit8", .key_code = .Digit8, .key_code_str = "8", .event_key_code = 56, .vkey = "VK_8", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = false, .scan_code = .Digit9, .scan_code_str = "Digit9", .key_code = .Digit9, .key_code_str = "9", .event_key_code = 57, .vkey = "VK_9", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = false, .scan_code = .Digit0, .scan_code_str = "Digit0", .key_code = .Digit0, .key_code_str = "0", .event_key_code = 48, .vkey = "VK_0", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .Enter, .scan_code_str = "Enter", .key_code = .Enter, .key_code_str = "Enter", .event_key_code = 13, .vkey = "VK_RETURN", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .Escape, .scan_code_str = "Escape", .key_code = .Escape, .key_code_str = "Escape", .event_key_code = 27, .vkey = "VK_ESCAPE", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .Backspace, .scan_code_str = "Backspace", .key_code = .Backspace, .key_code_str = "Backspace", .event_key_code = 8, .vkey = "VK_BACK", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .Tab, .scan_code_str = "Tab", .key_code = .Tab, .key_code_str = "Tab", .event_key_code = 9, .vkey = "VK_TAB", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .Space, .scan_code_str = "Space", .key_code = .Space, .key_code_str = "Space", .event_key_code = 32, .vkey = "VK_SPACE", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = false, .scan_code = .Minus, .scan_code_str = "Minus", .key_code = .Minus, .key_code_str = "-", .event_key_code = 189, .vkey = "VK_OEM_MINUS", .us_user_settings_label = "-", .general_user_settings_label = "OEM_MINUS" },
    .{ .immutable = false, .scan_code = .Equal, .scan_code_str = "Equal", .key_code = .Equal, .key_code_str = "=", .event_key_code = 187, .vkey = "VK_OEM_PLUS", .us_user_settings_label = "=", .general_user_settings_label = "OEM_PLUS" },
    .{ .immutable = false, .scan_code = .BracketLeft, .scan_code_str = "BracketLeft", .key_code = .BracketLeft, .key_code_str = "[", .event_key_code = 219, .vkey = "VK_OEM_4", .us_user_settings_label = "[", .general_user_settings_label = "OEM_4" },
    .{ .immutable = false, .scan_code = .BracketRight, .scan_code_str = "BracketRight", .key_code = .BracketRight, .key_code_str = "]", .event_key_code = 221, .vkey = "VK_OEM_6", .us_user_settings_label = "]", .general_user_settings_label = "OEM_6" },
    .{ .immutable = false, .scan_code = .Backslash, .scan_code_str = "Backslash", .key_code = .Backslash, .key_code_str = "\\", .event_key_code = 220, .vkey = "VK_OEM_5", .us_user_settings_label = "\\", .general_user_settings_label = "OEM_5" },
    .{ .immutable = false, .scan_code = .IntlHash, .scan_code_str = "IntlHash", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = false, .scan_code = .Semicolon, .scan_code_str = "Semicolon", .key_code = .Semicolon, .key_code_str = ";", .event_key_code = 186, .vkey = "VK_OEM_1", .us_user_settings_label = ";", .general_user_settings_label = "OEM_1" },
    .{ .immutable = false, .scan_code = .Quote, .scan_code_str = "Quote", .key_code = .Quote, .key_code_str = "'", .event_key_code = 222, .vkey = "VK_OEM_7", .us_user_settings_label = "'", .general_user_settings_label = "OEM_7" },
    .{ .immutable = false, .scan_code = .Backquote, .scan_code_str = "Backquote", .key_code = .Backquote, .key_code_str = "`", .event_key_code = 192, .vkey = "VK_OEM_3", .us_user_settings_label = "`", .general_user_settings_label = "OEM_3" },
    .{ .immutable = false, .scan_code = .Comma, .scan_code_str = "Comma", .key_code = .Comma, .key_code_str = ",", .event_key_code = 188, .vkey = "VK_OEM_COMMA", .us_user_settings_label = ",", .general_user_settings_label = "OEM_COMMA" },
    .{ .immutable = false, .scan_code = .Period, .scan_code_str = "Period", .key_code = .Period, .key_code_str = ".", .event_key_code = 190, .vkey = "VK_OEM_PERIOD", .us_user_settings_label = ".", .general_user_settings_label = "OEM_PERIOD" },
    .{ .immutable = false, .scan_code = .Slash, .scan_code_str = "Slash", .key_code = .Slash, .key_code_str = "/", .event_key_code = 191, .vkey = "VK_OEM_2", .us_user_settings_label = "/", .general_user_settings_label = "OEM_2" },
    .{ .immutable = true, .scan_code = .CapsLock, .scan_code_str = "CapsLock", .key_code = .CapsLock, .key_code_str = "CapsLock", .event_key_code = 20, .vkey = "VK_CAPITAL", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .F1, .scan_code_str = "F1", .key_code = .F1, .key_code_str = "F1", .event_key_code = 112, .vkey = "VK_F1", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .F2, .scan_code_str = "F2", .key_code = .F2, .key_code_str = "F2", .event_key_code = 113, .vkey = "VK_F2", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .F3, .scan_code_str = "F3", .key_code = .F3, .key_code_str = "F3", .event_key_code = 114, .vkey = "VK_F3", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .F4, .scan_code_str = "F4", .key_code = .F4, .key_code_str = "F4", .event_key_code = 115, .vkey = "VK_F4", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .F5, .scan_code_str = "F5", .key_code = .F5, .key_code_str = "F5", .event_key_code = 116, .vkey = "VK_F5", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .F6, .scan_code_str = "F6", .key_code = .F6, .key_code_str = "F6", .event_key_code = 117, .vkey = "VK_F6", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .F7, .scan_code_str = "F7", .key_code = .F7, .key_code_str = "F7", .event_key_code = 118, .vkey = "VK_F7", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .F8, .scan_code_str = "F8", .key_code = .F8, .key_code_str = "F8", .event_key_code = 119, .vkey = "VK_F8", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .F9, .scan_code_str = "F9", .key_code = .F9, .key_code_str = "F9", .event_key_code = 120, .vkey = "VK_F9", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .F10, .scan_code_str = "F10", .key_code = .F10, .key_code_str = "F10", .event_key_code = 121, .vkey = "VK_F10", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .F11, .scan_code_str = "F11", .key_code = .F11, .key_code_str = "F11", .event_key_code = 122, .vkey = "VK_F11", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .F12, .scan_code_str = "F12", .key_code = .F12, .key_code_str = "F12", .event_key_code = 123, .vkey = "VK_F12", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .PrintScreen, .scan_code_str = "PrintScreen", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .ScrollLock, .scan_code_str = "ScrollLock", .key_code = .ScrollLock, .key_code_str = "ScrollLock", .event_key_code = 145, .vkey = "VK_SCROLL", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .Pause, .scan_code_str = "Pause", .key_code = .PauseBreak, .key_code_str = "PauseBreak", .event_key_code = 19, .vkey = "VK_PAUSE", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .Insert, .scan_code_str = "Insert", .key_code = .Insert, .key_code_str = "Insert", .event_key_code = 45, .vkey = "VK_INSERT", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .Home, .scan_code_str = "Home", .key_code = .Home, .key_code_str = "Home", .event_key_code = 36, .vkey = "VK_HOME", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .PageUp, .scan_code_str = "PageUp", .key_code = .PageUp, .key_code_str = "PageUp", .event_key_code = 33, .vkey = "VK_PRIOR", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .Delete, .scan_code_str = "Delete", .key_code = .Delete, .key_code_str = "Del", .event_key_code = 46, .vkey = "VK_DELETE", .us_user_settings_label = "Delete", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .End, .scan_code_str = "End", .key_code = .End, .key_code_str = "End", .event_key_code = 35, .vkey = "VK_END", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .PageDown, .scan_code_str = "PageDown", .key_code = .PageDown, .key_code_str = "PageDown", .event_key_code = 34, .vkey = "VK_NEXT", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .ArrowRight, .scan_code_str = "ArrowRight", .key_code = .RightArrow, .key_code_str = "RightArrow", .event_key_code = 39, .vkey = "VK_RIGHT", .us_user_settings_label = "Right", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .ArrowLeft, .scan_code_str = "ArrowLeft", .key_code = .LeftArrow, .key_code_str = "LeftArrow", .event_key_code = 37, .vkey = "VK_LEFT", .us_user_settings_label = "Left", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .ArrowDown, .scan_code_str = "ArrowDown", .key_code = .DownArrow, .key_code_str = "DownArrow", .event_key_code = 40, .vkey = "VK_DOWN", .us_user_settings_label = "Down", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .ArrowUp, .scan_code_str = "ArrowUp", .key_code = .UpArrow, .key_code_str = "UpArrow", .event_key_code = 38, .vkey = "VK_UP", .us_user_settings_label = "Up", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .NumLock, .scan_code_str = "NumLock", .key_code = .NumLock, .key_code_str = "NumLock", .event_key_code = 144, .vkey = "VK_NUMLOCK", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .NumpadDivide, .scan_code_str = "NumpadDivide", .key_code = .NumpadDivide, .key_code_str = "NumPad_Divide", .event_key_code = 111, .vkey = "VK_DIVIDE", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .NumpadMultiply, .scan_code_str = "NumpadMultiply", .key_code = .NumpadMultiply, .key_code_str = "NumPad_Multiply", .event_key_code = 106, .vkey = "VK_MULTIPLY", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .NumpadSubtract, .scan_code_str = "NumpadSubtract", .key_code = .NumpadSubtract, .key_code_str = "NumPad_Subtract", .event_key_code = 109, .vkey = "VK_SUBTRACT", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .NumpadAdd, .scan_code_str = "NumpadAdd", .key_code = .NumpadAdd, .key_code_str = "NumPad_Add", .event_key_code = 107, .vkey = "VK_ADD", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .NumpadEnter, .scan_code_str = "NumpadEnter", .key_code = .Enter, .key_code_str = "", .event_key_code = 0, .vkey = "", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .Numpad1, .scan_code_str = "Numpad1", .key_code = .Numpad1, .key_code_str = "NumPad1", .event_key_code = 97, .vkey = "VK_NUMPAD1", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .Numpad2, .scan_code_str = "Numpad2", .key_code = .Numpad2, .key_code_str = "NumPad2", .event_key_code = 98, .vkey = "VK_NUMPAD2", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .Numpad3, .scan_code_str = "Numpad3", .key_code = .Numpad3, .key_code_str = "NumPad3", .event_key_code = 99, .vkey = "VK_NUMPAD3", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .Numpad4, .scan_code_str = "Numpad4", .key_code = .Numpad4, .key_code_str = "NumPad4", .event_key_code = 100, .vkey = "VK_NUMPAD4", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .Numpad5, .scan_code_str = "Numpad5", .key_code = .Numpad5, .key_code_str = "NumPad5", .event_key_code = 101, .vkey = "VK_NUMPAD5", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .Numpad6, .scan_code_str = "Numpad6", .key_code = .Numpad6, .key_code_str = "NumPad6", .event_key_code = 102, .vkey = "VK_NUMPAD6", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .Numpad7, .scan_code_str = "Numpad7", .key_code = .Numpad7, .key_code_str = "NumPad7", .event_key_code = 103, .vkey = "VK_NUMPAD7", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .Numpad8, .scan_code_str = "Numpad8", .key_code = .Numpad8, .key_code_str = "NumPad8", .event_key_code = 104, .vkey = "VK_NUMPAD8", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .Numpad9, .scan_code_str = "Numpad9", .key_code = .Numpad9, .key_code_str = "NumPad9", .event_key_code = 105, .vkey = "VK_NUMPAD9", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .Numpad0, .scan_code_str = "Numpad0", .key_code = .Numpad0, .key_code_str = "NumPad0", .event_key_code = 96, .vkey = "VK_NUMPAD0", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .NumpadDecimal, .scan_code_str = "NumpadDecimal", .key_code = .NumpadDecimal, .key_code_str = "NumPad_Decimal", .event_key_code = 110, .vkey = "VK_DECIMAL", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = false, .scan_code = .IntlBackslash, .scan_code_str = "IntlBackslash", .key_code = .IntlBackslash, .key_code_str = "OEM_102", .event_key_code = 226, .vkey = "VK_OEM_102", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .ContextMenu, .scan_code_str = "ContextMenu", .key_code = .ContextMenu, .key_code_str = "ContextMenu", .event_key_code = 93, .vkey = "", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .Power, .scan_code_str = "Power", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .NumpadEqual, .scan_code_str = "NumpadEqual", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .F13, .scan_code_str = "F13", .key_code = .F13, .key_code_str = "F13", .event_key_code = 124, .vkey = "VK_F13", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .F14, .scan_code_str = "F14", .key_code = .F14, .key_code_str = "F14", .event_key_code = 125, .vkey = "VK_F14", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .F15, .scan_code_str = "F15", .key_code = .F15, .key_code_str = "F15", .event_key_code = 126, .vkey = "VK_F15", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .F16, .scan_code_str = "F16", .key_code = .F16, .key_code_str = "F16", .event_key_code = 127, .vkey = "VK_F16", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .F17, .scan_code_str = "F17", .key_code = .F17, .key_code_str = "F17", .event_key_code = 128, .vkey = "VK_F17", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .F18, .scan_code_str = "F18", .key_code = .F18, .key_code_str = "F18", .event_key_code = 129, .vkey = "VK_F18", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .F19, .scan_code_str = "F19", .key_code = .F19, .key_code_str = "F19", .event_key_code = 130, .vkey = "VK_F19", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .F20, .scan_code_str = "F20", .key_code = .F20, .key_code_str = "F20", .event_key_code = 131, .vkey = "VK_F20", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .F21, .scan_code_str = "F21", .key_code = .F21, .key_code_str = "F21", .event_key_code = 132, .vkey = "VK_F21", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .F22, .scan_code_str = "F22", .key_code = .F22, .key_code_str = "F22", .event_key_code = 133, .vkey = "VK_F22", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .F23, .scan_code_str = "F23", .key_code = .F23, .key_code_str = "F23", .event_key_code = 134, .vkey = "VK_F23", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .F24, .scan_code_str = "F24", .key_code = .F24, .key_code_str = "F24", .event_key_code = 135, .vkey = "VK_F24", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .Open, .scan_code_str = "Open", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .Help, .scan_code_str = "Help", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .Select, .scan_code_str = "Select", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .Again, .scan_code_str = "Again", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .Undo, .scan_code_str = "Undo", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .Cut, .scan_code_str = "Cut", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .Copy, .scan_code_str = "Copy", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .Paste, .scan_code_str = "Paste", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .Find, .scan_code_str = "Find", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .AudioVolumeMute, .scan_code_str = "AudioVolumeMute", .key_code = .AudioVolumeMute, .key_code_str = "AudioVolumeMute", .event_key_code = 173, .vkey = "VK_VOLUME_MUTE", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .AudioVolumeUp, .scan_code_str = "AudioVolumeUp", .key_code = .AudioVolumeUp, .key_code_str = "AudioVolumeUp", .event_key_code = 175, .vkey = "VK_VOLUME_UP", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .AudioVolumeDown, .scan_code_str = "AudioVolumeDown", .key_code = .AudioVolumeDown, .key_code_str = "AudioVolumeDown", .event_key_code = 174, .vkey = "VK_VOLUME_DOWN", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .NumpadComma, .scan_code_str = "NumpadComma", .key_code = .NUMPAD_SEPARATOR, .key_code_str = "NumPad_Separator", .event_key_code = 108, .vkey = "VK_SEPARATOR", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = false, .scan_code = .IntlRo, .scan_code_str = "IntlRo", .key_code = .ABNT_C1, .key_code_str = "ABNT_C1", .event_key_code = 193, .vkey = "VK_ABNT_C1", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .KanaMode, .scan_code_str = "KanaMode", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = false, .scan_code = .IntlYen, .scan_code_str = "IntlYen", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .Convert, .scan_code_str = "Convert", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .NonConvert, .scan_code_str = "NonConvert", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .Lang1, .scan_code_str = "Lang1", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .Lang2, .scan_code_str = "Lang2", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .Lang3, .scan_code_str = "Lang3", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .Lang4, .scan_code_str = "Lang4", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .Lang5, .scan_code_str = "Lang5", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .Abort, .scan_code_str = "Abort", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .Props, .scan_code_str = "Props", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .NumpadParenLeft, .scan_code_str = "NumpadParenLeft", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .NumpadParenRight, .scan_code_str = "NumpadParenRight", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .NumpadBackspace, .scan_code_str = "NumpadBackspace", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .NumpadMemoryStore, .scan_code_str = "NumpadMemoryStore", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .NumpadMemoryRecall, .scan_code_str = "NumpadMemoryRecall", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .NumpadMemoryClear, .scan_code_str = "NumpadMemoryClear", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .NumpadMemoryAdd, .scan_code_str = "NumpadMemoryAdd", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .NumpadMemorySubtract, .scan_code_str = "NumpadMemorySubtract", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .NumpadClear, .scan_code_str = "NumpadClear", .key_code = .Clear, .key_code_str = "Clear", .event_key_code = 12, .vkey = "VK_CLEAR", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .NumpadClearEntry, .scan_code_str = "NumpadClearEntry", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .None, .scan_code_str = "", .key_code = .Ctrl, .key_code_str = "Ctrl", .event_key_code = 17, .vkey = "VK_CONTROL", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .None, .scan_code_str = "", .key_code = .Shift, .key_code_str = "Shift", .event_key_code = 16, .vkey = "VK_SHIFT", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .None, .scan_code_str = "", .key_code = .Alt, .key_code_str = "Alt", .event_key_code = 18, .vkey = "VK_MENU", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .None, .scan_code_str = "", .key_code = .Meta, .key_code_str = "Meta", .event_key_code = 91, .vkey = "VK_COMMAND", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .ControlLeft, .scan_code_str = "ControlLeft", .key_code = .Ctrl, .key_code_str = "", .event_key_code = 0, .vkey = "VK_LCONTROL", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .ShiftLeft, .scan_code_str = "ShiftLeft", .key_code = .Shift, .key_code_str = "", .event_key_code = 0, .vkey = "VK_LSHIFT", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .AltLeft, .scan_code_str = "AltLeft", .key_code = .Alt, .key_code_str = "", .event_key_code = 0, .vkey = "VK_LMENU", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .MetaLeft, .scan_code_str = "MetaLeft", .key_code = .Meta, .key_code_str = "", .event_key_code = 0, .vkey = "VK_LWIN", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .ControlRight, .scan_code_str = "ControlRight", .key_code = .Ctrl, .key_code_str = "", .event_key_code = 0, .vkey = "VK_RCONTROL", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .ShiftRight, .scan_code_str = "ShiftRight", .key_code = .Shift, .key_code_str = "", .event_key_code = 0, .vkey = "VK_RSHIFT", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .AltRight, .scan_code_str = "AltRight", .key_code = .Alt, .key_code_str = "", .event_key_code = 0, .vkey = "VK_RMENU", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .MetaRight, .scan_code_str = "MetaRight", .key_code = .Meta, .key_code_str = "", .event_key_code = 0, .vkey = "VK_RWIN", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .BrightnessUp, .scan_code_str = "BrightnessUp", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .BrightnessDown, .scan_code_str = "BrightnessDown", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .MediaPlay, .scan_code_str = "MediaPlay", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .MediaRecord, .scan_code_str = "MediaRecord", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .MediaFastForward, .scan_code_str = "MediaFastForward", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .MediaRewind, .scan_code_str = "MediaRewind", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .MediaTrackNext, .scan_code_str = "MediaTrackNext", .key_code = .MediaTrackNext, .key_code_str = "MediaTrackNext", .event_key_code = 176, .vkey = "VK_MEDIA_NEXT_TRACK", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .MediaTrackPrevious, .scan_code_str = "MediaTrackPrevious", .key_code = .MediaTrackPrevious, .key_code_str = "MediaTrackPrevious", .event_key_code = 177, .vkey = "VK_MEDIA_PREV_TRACK", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .MediaStop, .scan_code_str = "MediaStop", .key_code = .MediaStop, .key_code_str = "MediaStop", .event_key_code = 178, .vkey = "VK_MEDIA_STOP", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .Eject, .scan_code_str = "Eject", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .MediaPlayPause, .scan_code_str = "MediaPlayPause", .key_code = .MediaPlayPause, .key_code_str = "MediaPlayPause", .event_key_code = 179, .vkey = "VK_MEDIA_PLAY_PAUSE", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .MediaSelect, .scan_code_str = "MediaSelect", .key_code = .LaunchMediaPlayer, .key_code_str = "LaunchMediaPlayer", .event_key_code = 181, .vkey = "VK_MEDIA_LAUNCH_MEDIA_SELECT", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .LaunchMail, .scan_code_str = "LaunchMail", .key_code = .LaunchMail, .key_code_str = "LaunchMail", .event_key_code = 180, .vkey = "VK_MEDIA_LAUNCH_MAIL", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .LaunchApp2, .scan_code_str = "LaunchApp2", .key_code = .LaunchApp2, .key_code_str = "LaunchApp2", .event_key_code = 183, .vkey = "VK_MEDIA_LAUNCH_APP2", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .LaunchApp1, .scan_code_str = "LaunchApp1", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "VK_MEDIA_LAUNCH_APP1", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .SelectTask, .scan_code_str = "SelectTask", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .LaunchScreenSaver, .scan_code_str = "LaunchScreenSaver", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .BrowserSearch, .scan_code_str = "BrowserSearch", .key_code = .BrowserSearch, .key_code_str = "BrowserSearch", .event_key_code = 170, .vkey = "VK_BROWSER_SEARCH", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .BrowserHome, .scan_code_str = "BrowserHome", .key_code = .BrowserHome, .key_code_str = "BrowserHome", .event_key_code = 172, .vkey = "VK_BROWSER_HOME", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .BrowserBack, .scan_code_str = "BrowserBack", .key_code = .BrowserBack, .key_code_str = "BrowserBack", .event_key_code = 166, .vkey = "VK_BROWSER_BACK", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .BrowserForward, .scan_code_str = "BrowserForward", .key_code = .BrowserForward, .key_code_str = "BrowserForward", .event_key_code = 167, .vkey = "VK_BROWSER_FORWARD", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .BrowserStop, .scan_code_str = "BrowserStop", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "VK_BROWSER_STOP", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .BrowserRefresh, .scan_code_str = "BrowserRefresh", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "VK_BROWSER_REFRESH", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .BrowserFavorites, .scan_code_str = "BrowserFavorites", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "VK_BROWSER_FAVORITES", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .ZoomToggle, .scan_code_str = "ZoomToggle", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .MailReply, .scan_code_str = "MailReply", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .MailForward, .scan_code_str = "MailForward", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .MailSend, .scan_code_str = "MailSend", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .None, .scan_code_str = "", .key_code = .KEY_IN_COMPOSITION, .key_code_str = "KeyInComposition", .event_key_code = 229, .vkey = "", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .None, .scan_code_str = "", .key_code = .ABNT_C2, .key_code_str = "ABNT_C2", .event_key_code = 194, .vkey = "VK_ABNT_C2", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .None, .scan_code_str = "", .key_code = .OEM_8, .key_code_str = "OEM_8", .event_key_code = 223, .vkey = "VK_OEM_8", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .None, .scan_code_str = "", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "VK_KANA", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .None, .scan_code_str = "", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "VK_HANGUL", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .None, .scan_code_str = "", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "VK_JUNJA", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .None, .scan_code_str = "", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "VK_FINAL", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .None, .scan_code_str = "", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "VK_HANJA", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .None, .scan_code_str = "", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "VK_KANJI", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .None, .scan_code_str = "", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "VK_CONVERT", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .None, .scan_code_str = "", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "VK_NONCONVERT", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .None, .scan_code_str = "", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "VK_ACCEPT", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .None, .scan_code_str = "", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "VK_MODECHANGE", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .None, .scan_code_str = "", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "VK_SELECT", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .None, .scan_code_str = "", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "VK_PRINT", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .None, .scan_code_str = "", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "VK_EXECUTE", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .None, .scan_code_str = "", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "VK_SNAPSHOT", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .None, .scan_code_str = "", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "VK_HELP", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .None, .scan_code_str = "", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "VK_APPS", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .None, .scan_code_str = "", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "VK_PROCESSKEY", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .None, .scan_code_str = "", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "VK_PACKET", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .None, .scan_code_str = "", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "VK_DBE_SBCSCHAR", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .None, .scan_code_str = "", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "VK_DBE_DBCSCHAR", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .None, .scan_code_str = "", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "VK_ATTN", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .None, .scan_code_str = "", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "VK_CRSEL", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .None, .scan_code_str = "", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "VK_EXSEL", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .None, .scan_code_str = "", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "VK_EREOF", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .None, .scan_code_str = "", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "VK_PLAY", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .None, .scan_code_str = "", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "VK_ZOOM", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .None, .scan_code_str = "", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "VK_NONAME", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .None, .scan_code_str = "", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "VK_PA1", .us_user_settings_label = "", .general_user_settings_label = "" },
    .{ .immutable = true, .scan_code = .None, .scan_code_str = "", .key_code = .Unknown, .key_code_str = "", .event_key_code = 0, .vkey = "VK_OEM_CLEAR", .us_user_settings_label = "", .general_user_settings_label = "" },
};

/// -1 (`DependsOnKbLayout`) if a ScanCode => KeyCode mapping depends on the
/// keyboard layout. Only the first row of each scan code contributes.
pub const IMMUTABLE_CODE_TO_KEY_CODE: [scan_code_count]KeyCode = buildImmutableCodeToKeyCode();

/// -1 if a KeyCode => ScanCode mapping depends on the keyboard layout.
pub const IMMUTABLE_KEY_CODE_TO_CODE: [key_code_count]ScanCode = buildImmutableKeyCodeToCode();

/// `event.keyCode` => KeyCode.
pub const EVENT_KEY_CODE_MAP: [230]KeyCode = buildEventKeyCodeMap();

fn buildImmutableCodeToKeyCode() [scan_code_count]KeyCode {
    var result: [scan_code_count]KeyCode = @splat(.DependsOnKbLayout);
    var seen: [scan_code_count]bool = @splat(false);
    for (mappings) |mapping| {
        const scan_code = @backingInt(mapping.scan_code);
        if (seen[scan_code]) continue;
        seen[scan_code] = true;
        if (mapping.immutable) result[scan_code] = mapping.key_code;
    }
    return result;
}

fn buildImmutableKeyCodeToCode() [key_code_count]ScanCode {
    var result: [key_code_count]ScanCode = @splat(.DependsOnKbLayout);
    var seen: [scan_code_count]bool = @splat(false);
    for (mappings) |mapping| {
        const scan_code = @backingInt(mapping.scan_code);
        if (seen[scan_code]) continue;
        seen[scan_code] = true;
        if (!mapping.immutable) continue;
        if (mapping.key_code == .Unknown or mapping.key_code == .Enter or isModifierKey(mapping.key_code)) continue;
        result[@backingInt(mapping.key_code)] = mapping.scan_code;
    }
    // Manually added upstream due to the exclusion above (NumpadEnter
    // duplicates Enter).
    result[@backingInt(KeyCode.Enter)] = .Enter;
    return result;
}

fn buildEventKeyCodeMap() [230]KeyCode {
    var result: [230]KeyCode = @splat(.Unknown);
    for (mappings) |mapping| {
        if (mapping.event_key_code != 0) {
            result[mapping.event_key_code] = mapping.key_code;
        }
    }
    return result;
}

pub const ScanCodeUtils = struct {
    /// Case-insensitive scan-code string lookup.
    pub fn lowerCaseToEnum(scan_code: []const u8) ScanCode {
        for (mappings) |mapping| {
            if (mapping.scan_code_str.len > 0 and std.ascii.eqlIgnoreCase(mapping.scan_code_str, scan_code)) {
                return mapping.scan_code;
            }
        }
        return .None;
    }

    pub fn toEnum(scan_code: []const u8) ScanCode {
        for (mappings) |mapping| {
            if (mapping.scan_code_str.len > 0 and std.mem.eql(u8, mapping.scan_code_str, scan_code)) {
                return mapping.scan_code;
            }
        }
        return .None;
    }

    pub fn toString(scan_code: ScanCode) []const u8 {
        for (mappings) |mapping| {
            if (mapping.scan_code == scan_code) {
                return if (mapping.scan_code_str.len > 0) mapping.scan_code_str else "None";
            }
        }
        return "None";
    }
};

/// `SCAN_CODE_STR_TO_EVENT_KEY_CODE` (the last row wins, as upstream).
pub fn scanCodeStrToEventKeyCode(scan_code: []const u8) ?u16 {
    var result: ?u16 = null;
    for (mappings) |mapping| {
        if (mapping.scan_code_str.len > 0 and std.mem.eql(u8, mapping.scan_code_str, scan_code)) {
            result = mapping.event_key_code;
        }
    }
    return result;
}

/// `NATIVE_WINDOWS_KEY_CODE_TO_KEY_CODE[vkey]`.
pub fn nativeWindowsKeyCodeToKeyCode(vkey: []const u8) ?KeyCode {
    var result: ?KeyCode = null;
    for (mappings) |mapping| {
        if (mapping.vkey.len > 0 and std.mem.eql(u8, mapping.vkey, vkey)) {
            result = mapping.key_code;
        }
    }
    return result;
}

fn firstMappingForKeyCode(key_code: KeyCode) ?MappingEntry {
    for (mappings) |mapping| {
        if (mapping.key_code == key_code) return mapping;
    }
    return null;
}

fn isFirstForKeyCode(index: usize) bool {
    const key_code = mappings[index].key_code;
    for (mappings[0..index]) |mapping| {
        if (mapping.key_code == key_code) return false;
    }
    return true;
}

pub const KeyCodeUtils = struct {
    pub fn toString(key_code: KeyCode) []const u8 {
        const mapping = firstMappingForKeyCode(key_code) orelse return "";
        return mapping.key_code_str;
    }

    pub fn fromString(key: []const u8) KeyCode {
        for (mappings, 0..) |mapping, index| {
            if (!isFirstForKeyCode(index)) continue;
            if (std.ascii.eqlIgnoreCase(mapping.key_code_str, key)) {
                return mapping.key_code;
            }
        }
        return .Unknown;
    }

    pub fn toUserSettingsUS(key_code: KeyCode) []const u8 {
        const mapping = firstMappingForKeyCode(key_code) orelse return "";
        if (mapping.us_user_settings_label.len > 0) return mapping.us_user_settings_label;
        return mapping.key_code_str;
    }

    pub fn toUserSettingsGeneral(key_code: KeyCode) []const u8 {
        const mapping = firstMappingForKeyCode(key_code) orelse return "";
        if (mapping.general_user_settings_label.len > 0) return mapping.general_user_settings_label;
        if (mapping.us_user_settings_label.len > 0) return mapping.us_user_settings_label;
        return mapping.key_code_str;
    }

    pub fn fromUserSettings(key: []const u8) KeyCode {
        for (mappings, 0..) |mapping, index| {
            if (!isFirstForKeyCode(index)) continue;
            const label = if (mapping.us_user_settings_label.len > 0) mapping.us_user_settings_label else mapping.key_code_str;
            if (std.ascii.eqlIgnoreCase(label, key)) return mapping.key_code;
        }
        for (mappings, 0..) |mapping, index| {
            if (!isFirstForKeyCode(index)) continue;
            const label = if (mapping.general_user_settings_label.len > 0)
                mapping.general_user_settings_label
            else if (mapping.us_user_settings_label.len > 0)
                mapping.us_user_settings_label
            else
                mapping.key_code_str;
            if (std.ascii.eqlIgnoreCase(label, key)) return mapping.key_code;
        }
        return .Unknown;
    }

    pub fn toElectronAccelerator(key_code: KeyCode) ?[]const u8 {
        if (@backingInt(key_code) >= @backingInt(KeyCode.Numpad0) and @backingInt(key_code) <= @backingInt(KeyCode.NumpadDivide)) {
            // Electron renders numpad keys as regular keys; upstream falls back
            // to custom rendering.
            return null;
        }
        return switch (key_code) {
            .UpArrow => "Up",
            .DownArrow => "Down",
            .LeftArrow => "Left",
            .RightArrow => "Right",
            .Delete => "Delete",
            else => KeyCodeUtils.toString(key_code),
        };
    }
};

/// Upstream `KeyMod`.
pub const KeyMod = struct {
    pub const CtrlCmd: u32 = 1 << 11;
    pub const Shift: u32 = 1 << 10;
    pub const Alt: u32 = 1 << 9;
    pub const WinCtrl: u32 = 1 << 8;
};

/// Upstream `KeyChord(firstPart, secondPart)`.
pub fn KeyChord(first_part: u32, second_part: u32) u32 {
    const chord_part: u32 = ((second_part & 0x0000FFFF) << 16);
    return (first_part | chord_part);
}

pub fn isModifierKey(key_code: KeyCode) bool {
    return key_code == .Ctrl or key_code == .Shift or key_code == .Alt or key_code == .Meta;
}
