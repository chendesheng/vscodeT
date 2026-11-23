//! Generated Oniguruma bindings for the WebAssembly build.
//!
//! Produced by `zig translate-c` (Zig 0.17.1) from `oniguruma.h` and checked in
//! only because the wasm build must not depend on a system libonig install or
//! pay the translator cost on every cold build. The declarations are
//! target-parametric (`c_long`, `usize`, pointers), so the same file is used
//! with the Oniguruma 6.9.10 submodule in `third_party/oniguruma/`.
//!
//! The native build keeps using `addTranslateC` in `build.zig`; regenerate this
//! file from that module if the header changes.

const __root = @This();
pub const __builtin = @import("std").zig.c_translation.builtins;
pub const __helpers = @import("std").zig.c_translation.helpers;
pub const OnigCodePoint = c_uint;
pub const OnigUChar = u8;
pub const OnigCtype = c_uint;
pub const OnigLen = c_uint;
pub const OnigCaseFoldType = c_uint;
pub extern var OnigDefaultCaseFoldFlag: OnigCaseFoldType;
pub const OnigCaseFoldCodeItem = extern struct {
    byte_len: c_int = 0,
    code_len: c_int = 0,
    code: [3]OnigCodePoint = @import("std").mem.zeroes([3]OnigCodePoint),
};
pub const OnigMetaCharTableType = extern struct {
    esc: OnigCodePoint = 0,
    anychar: OnigCodePoint = 0,
    anytime: OnigCodePoint = 0,
    zero_or_one_time: OnigCodePoint = 0,
    one_or_more_time: OnigCodePoint = 0,
    anychar_anytime: OnigCodePoint = 0,
};
pub const OnigApplyAllCaseFoldFunc = ?*const fn (from: OnigCodePoint, to: [*c]OnigCodePoint, to_len: c_int, arg: ?*anyopaque) callconv(.c) c_int;
pub const struct_OnigEncodingTypeST = extern struct {
    mbc_enc_len: ?*const fn (p: [*c]const OnigUChar) callconv(.c) c_int = null,
    name: [*c]const u8 = null,
    max_enc_len: c_int = 0,
    min_enc_len: c_int = 0,
    is_mbc_newline: ?*const fn (p: [*c]const OnigUChar, end: [*c]const OnigUChar) callconv(.c) c_int = null,
    mbc_to_code: ?*const fn (p: [*c]const OnigUChar, end: [*c]const OnigUChar) callconv(.c) OnigCodePoint = null,
    code_to_mbclen: ?*const fn (code: OnigCodePoint) callconv(.c) c_int = null,
    code_to_mbc: ?*const fn (code: OnigCodePoint, buf: [*c]OnigUChar) callconv(.c) c_int = null,
    mbc_case_fold: ?*const fn (flag: OnigCaseFoldType, pp: [*c][*c]const OnigUChar, end: [*c]const OnigUChar, to: [*c]OnigUChar) callconv(.c) c_int = null,
    apply_all_case_fold: ?*const fn (flag: OnigCaseFoldType, f: OnigApplyAllCaseFoldFunc, arg: ?*anyopaque) callconv(.c) c_int = null,
    get_case_fold_codes_by_str: ?*const fn (flag: OnigCaseFoldType, p: [*c]const OnigUChar, end: [*c]const OnigUChar, acs: [*c]OnigCaseFoldCodeItem) callconv(.c) c_int = null,
    property_name_to_ctype: ?*const fn (enc: [*c]struct_OnigEncodingTypeST, p: [*c]OnigUChar, end: [*c]OnigUChar) callconv(.c) c_int = null,
    is_code_ctype: ?*const fn (code: OnigCodePoint, ctype: OnigCtype) callconv(.c) c_int = null,
    get_ctype_code_range: ?*const fn (ctype: OnigCtype, sb_out: [*c]OnigCodePoint, ranges: [*c][*c]const OnigCodePoint) callconv(.c) c_int = null,
    left_adjust_char_head: ?*const fn (start: [*c]const OnigUChar, p: [*c]const OnigUChar) callconv(.c) [*c]OnigUChar = null,
    is_allowed_reverse_match: ?*const fn (p: [*c]const OnigUChar, end: [*c]const OnigUChar) callconv(.c) c_int = null,
    init: ?*const fn () callconv(.c) c_int = null,
    is_initialized: ?*const fn () callconv(.c) c_int = null,
    is_valid_mbc_string: ?*const fn (s: [*c]const OnigUChar, end: [*c]const OnigUChar) callconv(.c) c_int = null,
    flag: c_uint = 0,
    sb_range: OnigCodePoint = 0,
    index: c_int = 0,
    pub const onigenc_step_back = __root.onigenc_step_back;
    pub const onig_initialize_encoding = __root.onig_initialize_encoding;
    pub const onigenc_set_default_encoding = __root.onigenc_set_default_encoding;
    pub const onigenc_get_right_adjust_char_head_with_prev = __root.onigenc_get_right_adjust_char_head_with_prev;
    pub const onigenc_get_prev_char_head = __root.onigenc_get_prev_char_head;
    pub const onigenc_get_left_adjust_char_head = __root.onigenc_get_left_adjust_char_head;
    pub const onigenc_get_right_adjust_char_head = __root.onigenc_get_right_adjust_char_head;
    pub const onigenc_strlen = __root.onigenc_strlen;
    pub const onigenc_strlen_null = __root.onigenc_strlen_null;
    pub const onigenc_str_bytelen_null = __root.onigenc_str_bytelen_null;
    pub const onigenc_is_valid_mbc_string = __root.onigenc_is_valid_mbc_string;
    pub const onigenc_strdup = __root.onigenc_strdup;
    pub const onig_copy_encoding = __root.onig_copy_encoding;
    pub const onig_set_callout_of_name = __root.onig_set_callout_of_name;
    pub const back = __root.onigenc_step_back;
    pub const encoding = __root.onig_initialize_encoding;
    pub const prev = __root.onigenc_get_right_adjust_char_head_with_prev;
    pub const head = __root.onigenc_get_prev_char_head;
    pub const strlen = __root.onigenc_strlen;
    pub const @"null" = __root.onigenc_strlen_null;
    pub const string = __root.onigenc_is_valid_mbc_string;
    pub const strdup = __root.onigenc_strdup;
};
pub const OnigEncodingType = struct_OnigEncodingTypeST;
pub const OnigEncoding = [*c]OnigEncodingType;
pub extern var OnigEncodingASCII: OnigEncodingType;
pub extern var OnigEncodingISO_8859_1: OnigEncodingType;
pub extern var OnigEncodingISO_8859_2: OnigEncodingType;
pub extern var OnigEncodingISO_8859_3: OnigEncodingType;
pub extern var OnigEncodingISO_8859_4: OnigEncodingType;
pub extern var OnigEncodingISO_8859_5: OnigEncodingType;
pub extern var OnigEncodingISO_8859_6: OnigEncodingType;
pub extern var OnigEncodingISO_8859_7: OnigEncodingType;
pub extern var OnigEncodingISO_8859_8: OnigEncodingType;
pub extern var OnigEncodingISO_8859_9: OnigEncodingType;
pub extern var OnigEncodingISO_8859_10: OnigEncodingType;
pub extern var OnigEncodingISO_8859_11: OnigEncodingType;
pub extern var OnigEncodingISO_8859_13: OnigEncodingType;
pub extern var OnigEncodingISO_8859_14: OnigEncodingType;
pub extern var OnigEncodingISO_8859_15: OnigEncodingType;
pub extern var OnigEncodingISO_8859_16: OnigEncodingType;
pub extern var OnigEncodingUTF8: OnigEncodingType;
pub extern var OnigEncodingUTF16_BE: OnigEncodingType;
pub extern var OnigEncodingUTF16_LE: OnigEncodingType;
pub extern var OnigEncodingUTF32_BE: OnigEncodingType;
pub extern var OnigEncodingUTF32_LE: OnigEncodingType;
pub extern var OnigEncodingEUC_JP: OnigEncodingType;
pub extern var OnigEncodingEUC_TW: OnigEncodingType;
pub extern var OnigEncodingEUC_KR: OnigEncodingType;
pub extern var OnigEncodingEUC_CN: OnigEncodingType;
pub extern var OnigEncodingSJIS: OnigEncodingType;
pub extern var OnigEncodingKOI8: OnigEncodingType;
pub extern var OnigEncodingKOI8_R: OnigEncodingType;
pub extern var OnigEncodingCP1251: OnigEncodingType;
pub extern var OnigEncodingBIG5: OnigEncodingType;
pub extern var OnigEncodingGB18030: OnigEncodingType;
pub const ONIGENC_CTYPE_NEWLINE: c_int = 0;
pub const ONIGENC_CTYPE_ALPHA: c_int = 1;
pub const ONIGENC_CTYPE_BLANK: c_int = 2;
pub const ONIGENC_CTYPE_CNTRL: c_int = 3;
pub const ONIGENC_CTYPE_DIGIT: c_int = 4;
pub const ONIGENC_CTYPE_GRAPH: c_int = 5;
pub const ONIGENC_CTYPE_LOWER: c_int = 6;
pub const ONIGENC_CTYPE_PRINT: c_int = 7;
pub const ONIGENC_CTYPE_PUNCT: c_int = 8;
pub const ONIGENC_CTYPE_SPACE: c_int = 9;
pub const ONIGENC_CTYPE_UPPER: c_int = 10;
pub const ONIGENC_CTYPE_XDIGIT: c_int = 11;
pub const ONIGENC_CTYPE_WORD: c_int = 12;
pub const ONIGENC_CTYPE_ALNUM: c_int = 13;
pub const ONIGENC_CTYPE_ASCII: c_int = 14;
pub const OnigEncCtype = c_uint;
pub extern fn onigenc_step_back(enc: OnigEncoding, start: [*c]const OnigUChar, s: [*c]const OnigUChar, n: c_int) [*c]OnigUChar;
pub extern fn onigenc_init() c_int;
pub extern fn onig_initialize_encoding(enc: OnigEncoding) c_int;
pub extern fn onigenc_set_default_encoding(enc: OnigEncoding) c_int;
pub extern fn onigenc_get_default_encoding() OnigEncoding;
pub extern fn onigenc_set_default_caseconv_table(table: [*c]const OnigUChar) void;
pub extern fn onigenc_get_right_adjust_char_head_with_prev(enc: OnigEncoding, start: [*c]const OnigUChar, s: [*c]const OnigUChar, prev: [*c][*c]const OnigUChar) [*c]OnigUChar;
pub extern fn onigenc_get_prev_char_head(enc: OnigEncoding, start: [*c]const OnigUChar, s: [*c]const OnigUChar) [*c]OnigUChar;
pub extern fn onigenc_get_left_adjust_char_head(enc: OnigEncoding, start: [*c]const OnigUChar, s: [*c]const OnigUChar) [*c]OnigUChar;
pub extern fn onigenc_get_right_adjust_char_head(enc: OnigEncoding, start: [*c]const OnigUChar, s: [*c]const OnigUChar) [*c]OnigUChar;
pub extern fn onigenc_strlen(enc: OnigEncoding, p: [*c]const OnigUChar, end: [*c]const OnigUChar) c_int;
pub extern fn onigenc_strlen_null(enc: OnigEncoding, p: [*c]const OnigUChar) c_int;
pub extern fn onigenc_str_bytelen_null(enc: OnigEncoding, p: [*c]const OnigUChar) c_int;
pub extern fn onigenc_is_valid_mbc_string(enc: OnigEncoding, s: [*c]const OnigUChar, end: [*c]const OnigUChar) c_int;
pub extern fn onigenc_strdup(enc: OnigEncoding, s: [*c]const OnigUChar, end: [*c]const OnigUChar) [*c]OnigUChar;
pub const OnigOptionType = c_uint;
pub const OnigSyntaxType = extern struct {
    op: c_uint = 0,
    op2: c_uint = 0,
    behavior: c_uint = 0,
    options: OnigOptionType = 0,
    meta_char_table: OnigMetaCharTableType = @import("std").mem.zeroes(OnigMetaCharTableType),
    pub const onig_set_default_syntax = __root.onig_set_default_syntax;
    pub const onig_copy_syntax = __root.onig_copy_syntax;
    pub const onig_get_syntax_op = __root.onig_get_syntax_op;
    pub const onig_get_syntax_op2 = __root.onig_get_syntax_op2;
    pub const onig_get_syntax_behavior = __root.onig_get_syntax_behavior;
    pub const onig_get_syntax_options = __root.onig_get_syntax_options;
    pub const onig_set_syntax_op = __root.onig_set_syntax_op;
    pub const onig_set_syntax_op2 = __root.onig_set_syntax_op2;
    pub const onig_set_syntax_behavior = __root.onig_set_syntax_behavior;
    pub const onig_set_syntax_options = __root.onig_set_syntax_options;
    pub const onig_set_meta_char = __root.onig_set_meta_char;
    pub const syntax = __root.onig_set_default_syntax;
    pub const char = __root.onig_set_meta_char;
};
pub extern var OnigSyntaxASIS: OnigSyntaxType;
pub extern var OnigSyntaxPosixBasic: OnigSyntaxType;
pub extern var OnigSyntaxPosixExtended: OnigSyntaxType;
pub extern var OnigSyntaxEmacs: OnigSyntaxType;
pub extern var OnigSyntaxGrep: OnigSyntaxType;
pub extern var OnigSyntaxGnuRegex: OnigSyntaxType;
pub extern var OnigSyntaxJava: OnigSyntaxType;
pub extern var OnigSyntaxPerl: OnigSyntaxType;
pub extern var OnigSyntaxPerl_NG: OnigSyntaxType;
pub extern var OnigSyntaxRuby: OnigSyntaxType;
pub extern var OnigSyntaxPython: OnigSyntaxType;
pub extern var OnigSyntaxOniguruma: OnigSyntaxType;
pub extern var OnigDefaultSyntax: [*c]OnigSyntaxType;
pub const struct_OnigCaptureTreeNodeStruct = extern struct {
    group: c_int = 0,
    beg: c_int = 0,
    end: c_int = 0,
    allocated: c_int = 0,
    num_childs: c_int = 0,
    childs: [*c][*c]struct_OnigCaptureTreeNodeStruct = null,
};
pub const OnigCaptureTreeNode = struct_OnigCaptureTreeNodeStruct;
pub const struct_re_registers = extern struct {
    allocated: c_int = 0,
    num_regs: c_int = 0,
    beg: [*c]c_int = null,
    end: [*c]c_int = null,
    history_root: [*c]OnigCaptureTreeNode = null,
    pub const onig_region_init = __root.onig_region_init;
    pub const onig_region_free = __root.onig_region_free;
    pub const onig_region_copy = __root.onig_region_copy;
    pub const onig_region_clear = __root.onig_region_clear;
    pub const onig_region_resize = __root.onig_region_resize;
    pub const onig_region_set = __root.onig_region_set;
    pub const onig_get_capture_tree = __root.onig_get_capture_tree;
    pub const onig_capture_tree_traverse = __root.onig_capture_tree_traverse;
    pub const init = __root.onig_region_init;
    pub const free = __root.onig_region_free;
    pub const copy = __root.onig_region_copy;
    pub const clear = __root.onig_region_clear;
    pub const resize = __root.onig_region_resize;
    pub const set = __root.onig_region_set;
    pub const tree = __root.onig_get_capture_tree;
    pub const traverse = __root.onig_capture_tree_traverse;
};
pub const OnigRegion = struct_re_registers;
pub const OnigErrorInfo = extern struct {
    enc: OnigEncoding = null,
    par: [*c]OnigUChar = null,
    par_end: [*c]OnigUChar = null,
};
pub const OnigRepeatRange = extern struct {
    lower: c_int = 0,
    upper: c_int = 0,
};
pub const OnigWarnFunc = ?*const fn (s: [*c]const u8) callconv(.c) void;
pub extern fn onig_null_warn(s: [*c]const u8) void;
pub const struct_re_pattern_buffer = opaque {
    pub const onig_reg_init = __root.onig_reg_init;
    pub const onig_new_without_alloc = __root.onig_new_without_alloc;
    pub const onig_free = __root.onig_free;
    pub const onig_free_body = __root.onig_free_body;
    pub const onig_scan = __root.onig_scan;
    pub const onig_search = __root.onig_search;
    pub const onig_search_with_param = __root.onig_search_with_param;
    pub const onig_match = __root.onig_match;
    pub const onig_match_with_param = __root.onig_match_with_param;
    pub const onig_name_to_group_numbers = __root.onig_name_to_group_numbers;
    pub const onig_name_to_backref_number = __root.onig_name_to_backref_number;
    pub const onig_foreach_name = __root.onig_foreach_name;
    pub const onig_number_of_names = __root.onig_number_of_names;
    pub const onig_number_of_captures = __root.onig_number_of_captures;
    pub const onig_number_of_capture_histories = __root.onig_number_of_capture_histories;
    pub const onig_noname_group_capture_is_active = __root.onig_noname_group_capture_is_active;
    pub const onig_get_encoding = __root.onig_get_encoding;
    pub const onig_get_options = __root.onig_get_options;
    pub const onig_get_case_fold_flag = __root.onig_get_case_fold_flag;
    pub const onig_get_syntax = __root.onig_get_syntax;
    pub const onig_get_callout_num_by_tag = __root.onig_get_callout_num_by_tag;
    pub const onig_get_callout_data_by_tag = __root.onig_get_callout_data_by_tag;
    pub const onig_set_callout_data_by_tag = __root.onig_set_callout_data_by_tag;
    pub const onig_get_callout_data_by_tag_dont_clear_old = __root.onig_get_callout_data_by_tag_dont_clear_old;
    pub const onig_callout_tag_is_exist_at_callout_num = __root.onig_callout_tag_is_exist_at_callout_num;
    pub const onig_get_callout_tag_start = __root.onig_get_callout_tag_start;
    pub const onig_get_callout_tag_end = __root.onig_get_callout_tag_end;
    pub const onig_get_callout_data_dont_clear_old = __root.onig_get_callout_data_dont_clear_old;
    pub const onig_get_callout_data = __root.onig_get_callout_data;
    pub const onig_set_callout_data = __root.onig_set_callout_data;
    pub const init = __root.onig_reg_init;
    pub const alloc = __root.onig_new_without_alloc;
    pub const free = __root.onig_free;
    pub const body = __root.onig_free_body;
    pub const scan = __root.onig_scan;
    pub const search = __root.onig_search;
    pub const param = __root.onig_search_with_param;
    pub const match = __root.onig_match;
    pub const numbers = __root.onig_name_to_group_numbers;
    pub const number = __root.onig_name_to_backref_number;
    pub const name = __root.onig_foreach_name;
    pub const names = __root.onig_number_of_names;
    pub const captures = __root.onig_number_of_captures;
    pub const histories = __root.onig_number_of_capture_histories;
    pub const active = __root.onig_noname_group_capture_is_active;
    pub const encoding = __root.onig_get_encoding;
    pub const options = __root.onig_get_options;
    pub const flag = __root.onig_get_case_fold_flag;
    pub const syntax = __root.onig_get_syntax;
    pub const tag = __root.onig_get_callout_num_by_tag;
    pub const old = __root.onig_get_callout_data_by_tag_dont_clear_old;
    pub const num = __root.onig_callout_tag_is_exist_at_callout_num;
    pub const start = __root.onig_get_callout_tag_start;
    pub const end = __root.onig_get_callout_tag_end;
    pub const data = __root.onig_get_callout_data;
};
pub const OnigRegexType = struct_re_pattern_buffer;
pub const OnigRegex = ?*OnigRegexType;
pub const regex_t = OnigRegexType;
pub const struct_OnigRegSetStruct = opaque {
    pub const onig_regset_add = __root.onig_regset_add;
    pub const onig_regset_replace = __root.onig_regset_replace;
    pub const onig_regset_free = __root.onig_regset_free;
    pub const onig_regset_number_of_regex = __root.onig_regset_number_of_regex;
    pub const onig_regset_get_regex = __root.onig_regset_get_regex;
    pub const onig_regset_get_region = __root.onig_regset_get_region;
    pub const onig_regset_search = __root.onig_regset_search;
    pub const onig_regset_search_with_param = __root.onig_regset_search_with_param;
    pub const add = __root.onig_regset_add;
    pub const replace = __root.onig_regset_replace;
    pub const free = __root.onig_regset_free;
    pub const regex = __root.onig_regset_number_of_regex;
    pub const region = __root.onig_regset_get_region;
    pub const search = __root.onig_regset_search;
    pub const param = __root.onig_regset_search_with_param;
};
pub const OnigRegSet = struct_OnigRegSetStruct;
pub const ONIG_REGSET_POSITION_LEAD: c_int = 0;
pub const ONIG_REGSET_REGEX_LEAD: c_int = 1;
pub const ONIG_REGSET_PRIORITY_TO_REGEX_ORDER: c_int = 2;
pub const OnigRegSetLead = c_uint;
pub const OnigCompileInfo = extern struct {
    num_of_elements: c_int = 0,
    pattern_enc: OnigEncoding = null,
    target_enc: OnigEncoding = null,
    syntax: [*c]OnigSyntaxType = null,
    option: OnigOptionType = 0,
    case_fold_flag: OnigCaseFoldType = 0,
};
pub const OnigCallbackEachMatchFunc = ?*const fn (str: [*c]const OnigUChar, end: [*c]const OnigUChar, match_start: [*c]const OnigUChar, region: [*c]OnigRegion, user_data: ?*anyopaque) callconv(.c) c_int;
pub const ONIG_CALLOUT_IN_PROGRESS: c_int = 1;
pub const ONIG_CALLOUT_IN_RETRACTION: c_int = 2;
pub const OnigCalloutIn = c_uint;
pub const ONIG_CALLOUT_OF_CONTENTS: c_int = 0;
pub const ONIG_CALLOUT_OF_NAME: c_int = 1;
pub const OnigCalloutOf = c_uint;
pub const ONIG_CALLOUT_TYPE_SINGLE: c_int = 0;
pub const ONIG_CALLOUT_TYPE_START_CALL: c_int = 1;
pub const ONIG_CALLOUT_TYPE_BOTH_CALL: c_int = 2;
pub const ONIG_CALLOUT_TYPE_START_MARK_END_CALL: c_int = 3;
pub const OnigCalloutType = c_uint;
pub const struct_OnigCalloutArgsStruct = opaque {
    pub const onig_get_callout_num_by_callout_args = __root.onig_get_callout_num_by_callout_args;
    pub const onig_get_callout_in_by_callout_args = __root.onig_get_callout_in_by_callout_args;
    pub const onig_get_name_id_by_callout_args = __root.onig_get_name_id_by_callout_args;
    pub const onig_get_contents_by_callout_args = __root.onig_get_contents_by_callout_args;
    pub const onig_get_contents_end_by_callout_args = __root.onig_get_contents_end_by_callout_args;
    pub const onig_get_args_num_by_callout_args = __root.onig_get_args_num_by_callout_args;
    pub const onig_get_passed_args_num_by_callout_args = __root.onig_get_passed_args_num_by_callout_args;
    pub const onig_get_arg_by_callout_args = __root.onig_get_arg_by_callout_args;
    pub const onig_get_string_by_callout_args = __root.onig_get_string_by_callout_args;
    pub const onig_get_string_end_by_callout_args = __root.onig_get_string_end_by_callout_args;
    pub const onig_get_start_by_callout_args = __root.onig_get_start_by_callout_args;
    pub const onig_get_right_range_by_callout_args = __root.onig_get_right_range_by_callout_args;
    pub const onig_get_current_by_callout_args = __root.onig_get_current_by_callout_args;
    pub const onig_get_regex_by_callout_args = __root.onig_get_regex_by_callout_args;
    pub const onig_get_retry_counter_by_callout_args = __root.onig_get_retry_counter_by_callout_args;
    pub const onig_get_callout_data_by_callout_args_self_dont_clear_old = __root.onig_get_callout_data_by_callout_args_self_dont_clear_old;
    pub const onig_get_callout_data_by_callout_args = __root.onig_get_callout_data_by_callout_args;
    pub const onig_get_callout_data_by_callout_args_self = __root.onig_get_callout_data_by_callout_args_self;
    pub const onig_set_callout_data_by_callout_args = __root.onig_set_callout_data_by_callout_args;
    pub const onig_set_callout_data_by_callout_args_self = __root.onig_set_callout_data_by_callout_args_self;
    pub const onig_get_capture_range_in_callout = __root.onig_get_capture_range_in_callout;
    pub const onig_get_used_stack_size_in_callout = __root.onig_get_used_stack_size_in_callout;
    pub const onig_builtin_fail = __root.onig_builtin_fail;
    pub const onig_builtin_mismatch = __root.onig_builtin_mismatch;
    pub const onig_builtin_error = __root.onig_builtin_error;
    pub const onig_builtin_count = __root.onig_builtin_count;
    pub const onig_builtin_total_count = __root.onig_builtin_total_count;
    pub const onig_builtin_max = __root.onig_builtin_max;
    pub const onig_builtin_cmp = __root.onig_builtin_cmp;
    pub const args = __root.onig_get_callout_num_by_callout_args;
    pub const old = __root.onig_get_callout_data_by_callout_args_self_dont_clear_old;
    pub const self = __root.onig_get_callout_data_by_callout_args_self;
    pub const callout = __root.onig_get_capture_range_in_callout;
    pub const fail = __root.onig_builtin_fail;
    pub const mismatch = __root.onig_builtin_mismatch;
    pub const @"error" = __root.onig_builtin_error;
    pub const count = __root.onig_builtin_count;
    pub const max = __root.onig_builtin_max;
    pub const cmp = __root.onig_builtin_cmp;
};
pub const OnigCalloutArgs = struct_OnigCalloutArgsStruct;
pub const OnigCalloutFunc = ?*const fn (args: ?*OnigCalloutArgs, user_data: ?*anyopaque) callconv(.c) c_int;
pub const ONIG_CALLOUT_FAIL: c_int = 1;
pub const ONIG_CALLOUT_SUCCESS: c_int = 0;
pub const OnigCalloutResult = c_uint;
pub const ONIG_TYPE_VOID: c_int = 0;
pub const ONIG_TYPE_LONG: c_int = 1;
pub const ONIG_TYPE_CHAR: c_int = 2;
pub const ONIG_TYPE_STRING: c_int = 4;
pub const ONIG_TYPE_POINTER: c_int = 8;
pub const ONIG_TYPE_TAG: c_int = 16;
pub const OnigType = c_uint;
const struct_unnamed_1 = extern struct {
    start: [*c]OnigUChar = null,
    end: [*c]OnigUChar = null,
};
pub const OnigValue = extern union {
    l: c_long,
    c: OnigCodePoint,
    s: struct_unnamed_1,
    p: ?*anyopaque,
    tag: c_int,
};
pub const struct_OnigMatchParamStruct = opaque {
    pub const onig_free_match_param = __root.onig_free_match_param;
    pub const onig_free_match_param_content = __root.onig_free_match_param_content;
    pub const onig_initialize_match_param = __root.onig_initialize_match_param;
    pub const onig_set_match_stack_limit_size_of_match_param = __root.onig_set_match_stack_limit_size_of_match_param;
    pub const onig_set_retry_limit_in_match_of_match_param = __root.onig_set_retry_limit_in_match_of_match_param;
    pub const onig_set_retry_limit_in_search_of_match_param = __root.onig_set_retry_limit_in_search_of_match_param;
    pub const onig_set_progress_callout_of_match_param = __root.onig_set_progress_callout_of_match_param;
    pub const onig_set_retraction_callout_of_match_param = __root.onig_set_retraction_callout_of_match_param;
    pub const onig_set_callout_user_data_of_match_param = __root.onig_set_callout_user_data_of_match_param;
    pub const param = __root.onig_free_match_param;
    pub const content = __root.onig_free_match_param_content;
};
pub const OnigMatchParam = struct_OnigMatchParamStruct;
pub extern fn onig_initialize(encodings: [*c]OnigEncoding, number_of_encodings: c_int) c_int;
pub extern fn onig_init() c_int;
pub extern fn onig_error_code_to_str(s: [*c]OnigUChar, err_code: c_int, ...) c_int;
pub extern fn onig_is_error_code_needs_param(code: c_int) c_int;
pub extern fn onig_set_warn_func(f: OnigWarnFunc) void;
pub extern fn onig_set_verb_warn_func(f: OnigWarnFunc) void;
pub extern fn onig_new([*c]OnigRegex, pattern: [*c]const OnigUChar, pattern_end: [*c]const OnigUChar, option: OnigOptionType, enc: OnigEncoding, syntax: [*c]OnigSyntaxType, einfo: [*c]OnigErrorInfo) c_int;
pub extern fn onig_reg_init(reg: OnigRegex, option: OnigOptionType, case_fold_flag: OnigCaseFoldType, enc: OnigEncoding, syntax: [*c]OnigSyntaxType) c_int;
pub extern fn onig_new_without_alloc(OnigRegex, pattern: [*c]const OnigUChar, pattern_end: [*c]const OnigUChar, option: OnigOptionType, enc: OnigEncoding, syntax: [*c]OnigSyntaxType, einfo: [*c]OnigErrorInfo) c_int;
pub extern fn onig_new_deluxe(reg: [*c]OnigRegex, pattern: [*c]const OnigUChar, pattern_end: [*c]const OnigUChar, ci: [*c]OnigCompileInfo, einfo: [*c]OnigErrorInfo) c_int;
pub extern fn onig_free(OnigRegex) void;
pub extern fn onig_free_body(OnigRegex) void;
pub extern fn onig_scan(reg: OnigRegex, str: [*c]const OnigUChar, end: [*c]const OnigUChar, region: [*c]OnigRegion, option: OnigOptionType, scan_callback: ?*const fn (c_int, c_int, [*c]OnigRegion, ?*anyopaque) callconv(.c) c_int, callback_arg: ?*anyopaque) c_int;
pub extern fn onig_search(OnigRegex, str: [*c]const OnigUChar, end: [*c]const OnigUChar, start: [*c]const OnigUChar, range: [*c]const OnigUChar, region: [*c]OnigRegion, option: OnigOptionType) c_int;
pub extern fn onig_search_with_param(OnigRegex, str: [*c]const OnigUChar, end: [*c]const OnigUChar, start: [*c]const OnigUChar, range: [*c]const OnigUChar, region: [*c]OnigRegion, option: OnigOptionType, mp: ?*OnigMatchParam) c_int;
pub extern fn onig_match(OnigRegex, str: [*c]const OnigUChar, end: [*c]const OnigUChar, at: [*c]const OnigUChar, region: [*c]OnigRegion, option: OnigOptionType) c_int;
pub extern fn onig_match_with_param(OnigRegex, str: [*c]const OnigUChar, end: [*c]const OnigUChar, at: [*c]const OnigUChar, region: [*c]OnigRegion, option: OnigOptionType, mp: ?*OnigMatchParam) c_int;
pub extern fn onig_regset_new(rset: [*c]?*OnigRegSet, n: c_int, regs: [*c]OnigRegex) c_int;
pub extern fn onig_regset_add(set: ?*OnigRegSet, reg: OnigRegex) c_int;
pub extern fn onig_regset_replace(set: ?*OnigRegSet, at: c_int, reg: OnigRegex) c_int;
pub extern fn onig_regset_free(set: ?*OnigRegSet) void;
pub extern fn onig_regset_number_of_regex(set: ?*OnigRegSet) c_int;
pub extern fn onig_regset_get_regex(set: ?*OnigRegSet, at: c_int) OnigRegex;
pub extern fn onig_regset_get_region(set: ?*OnigRegSet, at: c_int) [*c]OnigRegion;
pub extern fn onig_regset_search(set: ?*OnigRegSet, str: [*c]const OnigUChar, end: [*c]const OnigUChar, start: [*c]const OnigUChar, range: [*c]const OnigUChar, lead: OnigRegSetLead, option: OnigOptionType, rmatch_pos: [*c]c_int) c_int;
pub extern fn onig_regset_search_with_param(set: ?*OnigRegSet, str: [*c]const OnigUChar, end: [*c]const OnigUChar, start: [*c]const OnigUChar, range: [*c]const OnigUChar, lead: OnigRegSetLead, option: OnigOptionType, mps: [*c]?*OnigMatchParam, rmatch_pos: [*c]c_int) c_int;
pub extern fn onig_region_new() [*c]OnigRegion;
pub extern fn onig_region_init(region: [*c]OnigRegion) void;
pub extern fn onig_region_free(region: [*c]OnigRegion, free_self: c_int) void;
pub extern fn onig_region_copy(to: [*c]OnigRegion, from: [*c]OnigRegion) void;
pub extern fn onig_region_clear(region: [*c]OnigRegion) void;
pub extern fn onig_region_resize(region: [*c]OnigRegion, n: c_int) c_int;
pub extern fn onig_region_set(region: [*c]OnigRegion, at: c_int, beg: c_int, end: c_int) c_int;
pub extern fn onig_name_to_group_numbers(reg: OnigRegex, name: [*c]const OnigUChar, name_end: [*c]const OnigUChar, nums: [*c][*c]c_int) c_int;
pub extern fn onig_name_to_backref_number(reg: OnigRegex, name: [*c]const OnigUChar, name_end: [*c]const OnigUChar, region: [*c]OnigRegion) c_int;
pub extern fn onig_foreach_name(reg: OnigRegex, func: ?*const fn ([*c]const OnigUChar, [*c]const OnigUChar, c_int, [*c]c_int, OnigRegex, ?*anyopaque) callconv(.c) c_int, arg: ?*anyopaque) c_int;
pub extern fn onig_number_of_names(reg: OnigRegex) c_int;
pub extern fn onig_number_of_captures(reg: OnigRegex) c_int;
pub extern fn onig_number_of_capture_histories(reg: OnigRegex) c_int;
pub extern fn onig_get_capture_tree(region: [*c]OnigRegion) [*c]OnigCaptureTreeNode;
pub extern fn onig_capture_tree_traverse(region: [*c]OnigRegion, at: c_int, callback_func: ?*const fn (c_int, c_int, c_int, c_int, c_int, ?*anyopaque) callconv(.c) c_int, arg: ?*anyopaque) c_int;
pub extern fn onig_noname_group_capture_is_active(reg: OnigRegex) c_int;
pub extern fn onig_get_encoding(reg: OnigRegex) OnigEncoding;
pub extern fn onig_get_options(reg: OnigRegex) OnigOptionType;
pub extern fn onig_get_case_fold_flag(reg: OnigRegex) OnigCaseFoldType;
pub extern fn onig_get_syntax(reg: OnigRegex) [*c]OnigSyntaxType;
pub extern fn onig_set_default_syntax(syntax: [*c]OnigSyntaxType) c_int;
pub extern fn onig_copy_syntax(to: [*c]OnigSyntaxType, from: [*c]OnigSyntaxType) void;
pub extern fn onig_get_syntax_op(syntax: [*c]OnigSyntaxType) c_uint;
pub extern fn onig_get_syntax_op2(syntax: [*c]OnigSyntaxType) c_uint;
pub extern fn onig_get_syntax_behavior(syntax: [*c]OnigSyntaxType) c_uint;
pub extern fn onig_get_syntax_options(syntax: [*c]OnigSyntaxType) OnigOptionType;
pub extern fn onig_set_syntax_op(syntax: [*c]OnigSyntaxType, op: c_uint) void;
pub extern fn onig_set_syntax_op2(syntax: [*c]OnigSyntaxType, op2: c_uint) void;
pub extern fn onig_set_syntax_behavior(syntax: [*c]OnigSyntaxType, behavior: c_uint) void;
pub extern fn onig_set_syntax_options(syntax: [*c]OnigSyntaxType, options: OnigOptionType) void;
pub extern fn onig_set_meta_char(syntax: [*c]OnigSyntaxType, what: c_uint, code: OnigCodePoint) c_int;
pub extern fn onig_copy_encoding(to: OnigEncoding, from: OnigEncoding) void;
pub extern fn onig_get_default_case_fold_flag() OnigCaseFoldType;
pub extern fn onig_set_default_case_fold_flag(case_fold_flag: OnigCaseFoldType) c_int;
pub extern fn onig_get_match_stack_limit_size() c_uint;
pub extern fn onig_set_match_stack_limit_size(size: c_uint) c_int;
pub extern fn onig_get_retry_limit_in_match() c_ulong;
pub extern fn onig_set_retry_limit_in_match(n: c_ulong) c_int;
pub extern fn onig_get_retry_limit_in_search() c_ulong;
pub extern fn onig_set_retry_limit_in_search(n: c_ulong) c_int;
pub extern fn onig_get_parse_depth_limit() c_uint;
pub extern fn onig_set_capture_num_limit(num: c_int) c_int;
pub extern fn onig_set_parse_depth_limit(depth: c_uint) c_int;
pub extern fn onig_get_subexp_call_limit_in_search() c_ulong;
pub extern fn onig_set_subexp_call_limit_in_search(n: c_ulong) c_int;
pub extern fn onig_get_subexp_call_max_nest_level() c_int;
pub extern fn onig_set_subexp_call_max_nest_level(level: c_int) c_int;
pub extern fn onig_unicode_define_user_property(name: [*c]const u8, ranges: [*c]OnigCodePoint) c_int;
pub extern fn onig_end() c_int;
pub extern fn onig_version() [*c]const u8;
pub extern fn onig_copyright() [*c]const u8;
pub extern fn onig_get_callback_each_match() OnigCallbackEachMatchFunc;
pub extern fn onig_set_callback_each_match(f: OnigCallbackEachMatchFunc) c_int;
pub extern fn onig_new_match_param() ?*OnigMatchParam;
pub extern fn onig_free_match_param(p: ?*OnigMatchParam) void;
pub extern fn onig_free_match_param_content(p: ?*OnigMatchParam) void;
pub extern fn onig_initialize_match_param(mp: ?*OnigMatchParam) c_int;
pub extern fn onig_set_match_stack_limit_size_of_match_param(param: ?*OnigMatchParam, limit: c_uint) c_int;
pub extern fn onig_set_retry_limit_in_match_of_match_param(param: ?*OnigMatchParam, limit: c_ulong) c_int;
pub extern fn onig_set_retry_limit_in_search_of_match_param(param: ?*OnigMatchParam, limit: c_ulong) c_int;
pub extern fn onig_set_progress_callout_of_match_param(param: ?*OnigMatchParam, f: OnigCalloutFunc) c_int;
pub extern fn onig_set_retraction_callout_of_match_param(param: ?*OnigMatchParam, f: OnigCalloutFunc) c_int;
pub extern fn onig_set_callout_user_data_of_match_param(param: ?*OnigMatchParam, user_data: ?*anyopaque) c_int;
pub extern fn onig_get_progress_callout() OnigCalloutFunc;
pub extern fn onig_set_progress_callout(f: OnigCalloutFunc) c_int;
pub extern fn onig_get_retraction_callout() OnigCalloutFunc;
pub extern fn onig_set_retraction_callout(f: OnigCalloutFunc) c_int;
pub extern fn onig_set_callout_of_name(enc: OnigEncoding, @"type": OnigCalloutType, name: [*c]OnigUChar, name_end: [*c]OnigUChar, callout_in: c_int, callout: OnigCalloutFunc, end_callout: OnigCalloutFunc, arg_num: c_int, arg_types: [*c]c_uint, optional_arg_num: c_int, opt_defaults: [*c]OnigValue) c_int;
pub extern fn onig_get_callout_name_by_name_id(id: c_int) [*c]OnigUChar;
pub extern fn onig_get_callout_num_by_tag(reg: OnigRegex, tag: [*c]const OnigUChar, tag_end: [*c]const OnigUChar) c_int;
pub extern fn onig_get_callout_data_by_tag(reg: OnigRegex, mp: ?*OnigMatchParam, tag: [*c]const OnigUChar, tag_end: [*c]const OnigUChar, slot: c_int, @"type": [*c]OnigType, val: [*c]OnigValue) c_int;
pub extern fn onig_set_callout_data_by_tag(reg: OnigRegex, mp: ?*OnigMatchParam, tag: [*c]const OnigUChar, tag_end: [*c]const OnigUChar, slot: c_int, @"type": OnigType, val: [*c]OnigValue) c_int;
pub extern fn onig_get_callout_data_by_tag_dont_clear_old(reg: OnigRegex, mp: ?*OnigMatchParam, tag: [*c]const OnigUChar, tag_end: [*c]const OnigUChar, slot: c_int, @"type": [*c]OnigType, val: [*c]OnigValue) c_int;
pub extern fn onig_get_callout_num_by_callout_args(args: ?*OnigCalloutArgs) c_int;
pub extern fn onig_get_callout_in_by_callout_args(args: ?*OnigCalloutArgs) OnigCalloutIn;
pub extern fn onig_get_name_id_by_callout_args(args: ?*OnigCalloutArgs) c_int;
pub extern fn onig_get_contents_by_callout_args(args: ?*OnigCalloutArgs) [*c]const OnigUChar;
pub extern fn onig_get_contents_end_by_callout_args(args: ?*OnigCalloutArgs) [*c]const OnigUChar;
pub extern fn onig_get_args_num_by_callout_args(args: ?*OnigCalloutArgs) c_int;
pub extern fn onig_get_passed_args_num_by_callout_args(args: ?*OnigCalloutArgs) c_int;
pub extern fn onig_get_arg_by_callout_args(args: ?*OnigCalloutArgs, index: c_int, @"type": [*c]OnigType, val: [*c]OnigValue) c_int;
pub extern fn onig_get_string_by_callout_args(args: ?*OnigCalloutArgs) [*c]const OnigUChar;
pub extern fn onig_get_string_end_by_callout_args(args: ?*OnigCalloutArgs) [*c]const OnigUChar;
pub extern fn onig_get_start_by_callout_args(args: ?*OnigCalloutArgs) [*c]const OnigUChar;
pub extern fn onig_get_right_range_by_callout_args(args: ?*OnigCalloutArgs) [*c]const OnigUChar;
pub extern fn onig_get_current_by_callout_args(args: ?*OnigCalloutArgs) [*c]const OnigUChar;
pub extern fn onig_get_regex_by_callout_args(args: ?*OnigCalloutArgs) OnigRegex;
pub extern fn onig_get_retry_counter_by_callout_args(args: ?*OnigCalloutArgs) c_ulong;
pub extern fn onig_callout_tag_is_exist_at_callout_num(reg: OnigRegex, callout_num: c_int) c_int;
pub extern fn onig_get_callout_tag_start(reg: OnigRegex, callout_num: c_int) [*c]const OnigUChar;
pub extern fn onig_get_callout_tag_end(reg: OnigRegex, callout_num: c_int) [*c]const OnigUChar;
pub extern fn onig_get_callout_data_dont_clear_old(reg: OnigRegex, mp: ?*OnigMatchParam, callout_num: c_int, slot: c_int, @"type": [*c]OnigType, val: [*c]OnigValue) c_int;
pub extern fn onig_get_callout_data_by_callout_args_self_dont_clear_old(args: ?*OnigCalloutArgs, slot: c_int, @"type": [*c]OnigType, val: [*c]OnigValue) c_int;
pub extern fn onig_get_callout_data(reg: OnigRegex, mp: ?*OnigMatchParam, callout_num: c_int, slot: c_int, @"type": [*c]OnigType, val: [*c]OnigValue) c_int;
pub extern fn onig_get_callout_data_by_callout_args(args: ?*OnigCalloutArgs, callout_num: c_int, slot: c_int, @"type": [*c]OnigType, val: [*c]OnigValue) c_int;
pub extern fn onig_get_callout_data_by_callout_args_self(args: ?*OnigCalloutArgs, slot: c_int, @"type": [*c]OnigType, val: [*c]OnigValue) c_int;
pub extern fn onig_set_callout_data(reg: OnigRegex, mp: ?*OnigMatchParam, callout_num: c_int, slot: c_int, @"type": OnigType, val: [*c]OnigValue) c_int;
pub extern fn onig_set_callout_data_by_callout_args(args: ?*OnigCalloutArgs, callout_num: c_int, slot: c_int, @"type": OnigType, val: [*c]OnigValue) c_int;
pub extern fn onig_set_callout_data_by_callout_args_self(args: ?*OnigCalloutArgs, slot: c_int, @"type": OnigType, val: [*c]OnigValue) c_int;
pub extern fn onig_get_capture_range_in_callout(args: ?*OnigCalloutArgs, mem_num: c_int, begin: [*c]c_int, end: [*c]c_int) c_int;
pub extern fn onig_get_used_stack_size_in_callout(args: ?*OnigCalloutArgs, used_num: [*c]c_int, used_bytes: [*c]c_int) c_int;
pub extern fn onig_builtin_fail(args: ?*OnigCalloutArgs, user_data: ?*anyopaque) c_int;
pub extern fn onig_builtin_mismatch(args: ?*OnigCalloutArgs, user_data: ?*anyopaque) c_int;
pub extern fn onig_builtin_error(args: ?*OnigCalloutArgs, user_data: ?*anyopaque) c_int;
pub extern fn onig_builtin_count(args: ?*OnigCalloutArgs, user_data: ?*anyopaque) c_int;
pub extern fn onig_builtin_total_count(args: ?*OnigCalloutArgs, user_data: ?*anyopaque) c_int;
pub extern fn onig_builtin_max(args: ?*OnigCalloutArgs, user_data: ?*anyopaque) c_int;
pub extern fn onig_builtin_cmp(args: ?*OnigCalloutArgs, user_data: ?*anyopaque) c_int;
pub extern fn onig_setup_builtin_monitors_by_ascii_encoded_name(fp: ?*anyopaque) c_int;

pub const __VERSION__ = "Aro aro-zig";
pub const __Aro__ = "";
pub const __STDC__ = @as(c_int, 1);
pub const __STDC_HOSTED__ = @as(c_int, 1);
pub const __STDC_UTF_16__ = @as(c_int, 1);
pub const __STDC_UTF_32__ = @as(c_int, 1);
pub const __STDC_EMBED_NOT_FOUND__ = @as(c_int, 0);
pub const __STDC_EMBED_FOUND__ = @as(c_int, 1);
pub const __STDC_EMBED_EMPTY__ = @as(c_int, 2);
pub const __STDC_VERSION__ = @as(c_long, 201710);
pub const __GNUC__ = @as(c_int, 7);
pub const __GNUC_MINOR__ = @as(c_int, 1);
pub const __GNUC_PATCHLEVEL__ = @as(c_int, 0);
pub const __ARO_EMULATE_NO__ = @as(c_int, 0);
pub const __ARO_EMULATE_CLANG__ = @as(c_int, 1);
pub const __ARO_EMULATE_GCC__ = @as(c_int, 2);
pub const __ARO_EMULATE_MSVC__ = @as(c_int, 3);
pub const __ARO_EMULATE__ = __ARO_EMULATE_GCC__;
pub inline fn __building_module(x: anytype) @TypeOf(@as(c_int, 0)) {
    _ = &x;
    return @as(c_int, 0);
}
pub const linux = @as(c_int, 1);
pub const __linux = @as(c_int, 1);
pub const __linux__ = @as(c_int, 1);
pub const unix = @as(c_int, 1);
pub const __unix = @as(c_int, 1);
pub const __unix__ = @as(c_int, 1);
pub const __code_model_small__ = @as(c_int, 1);
pub const __amd64__ = @as(c_int, 1);
pub const __amd64 = @as(c_int, 1);
pub const __x86_64__ = @as(c_int, 1);
pub const __x86_64 = @as(c_int, 1);
pub const __SEG_GS = @as(c_int, 1);
pub const __SEG_FS = @as(c_int, 1);
pub const __seg_gs = @compileError("unable to translate macro: undefined identifier `address_space`");
// <builtin>:33:9
pub const __seg_fs = @compileError("unable to translate macro: undefined identifier `address_space`");
// <builtin>:34:9
pub const __LAHF_SAHF__ = @as(c_int, 1);
pub const __AES__ = @as(c_int, 1);
pub const __VAES__ = @as(c_int, 1);
pub const __PCLMUL__ = @as(c_int, 1);
pub const __VPCLMULQDQ__ = @as(c_int, 1);
pub const __LZCNT__ = @as(c_int, 1);
pub const __RDRND__ = @as(c_int, 1);
pub const __FSGSBASE__ = @as(c_int, 1);
pub const __BMI__ = @as(c_int, 1);
pub const __BMI2__ = @as(c_int, 1);
pub const __POPCNT__ = @as(c_int, 1);
pub const __PRFCHW__ = @as(c_int, 1);
pub const __RDSEED__ = @as(c_int, 1);
pub const __ADX__ = @as(c_int, 1);
pub const __MOVBE__ = @as(c_int, 1);
pub const __SSE4A__ = @as(c_int, 1);
pub const __FMA__ = @as(c_int, 1);
pub const __F16C__ = @as(c_int, 1);
pub const __SHA__ = @as(c_int, 1);
pub const __FXSR__ = @as(c_int, 1);
pub const __XSAVE__ = @as(c_int, 1);
pub const __XSAVEOPT__ = @as(c_int, 1);
pub const __XSAVEC__ = @as(c_int, 1);
pub const __XSAVES__ = @as(c_int, 1);
pub const __PKU__ = @as(c_int, 1);
pub const __CLFLUSHOPT__ = @as(c_int, 1);
pub const __CLWB__ = @as(c_int, 1);
pub const __WBNOINVD__ = @as(c_int, 1);
pub const __CLZERO__ = @as(c_int, 1);
pub const __RDPID__ = @as(c_int, 1);
pub const __INVPCID__ = @as(c_int, 1);
pub const __CRC32__ = @as(c_int, 1);
pub const __AVX2__ = @as(c_int, 1);
pub const __AVX__ = @as(c_int, 1);
pub const __SSE4_2__ = @as(c_int, 1);
pub const __SSE4_1__ = @as(c_int, 1);
pub const __SSSE3__ = @as(c_int, 1);
pub const __SSE3__ = @as(c_int, 1);
pub const __SSE2__ = @as(c_int, 1);
pub const __SSE__ = @as(c_int, 1);
pub const __SSE_MATH__ = @as(c_int, 1);
pub const __MMX__ = @as(c_int, 1);
pub const __GCC_HAVE_SYNC_COMPARE_AND_SWAP_8 = @as(c_int, 1);
pub const __SIZEOF_FLOAT128__ = @as(c_int, 16);
pub const _LP64 = @as(c_int, 1);
pub const __LP64__ = @as(c_int, 1);
pub const __FLOAT128__ = @as(c_int, 1);
pub const __ORDER_LITTLE_ENDIAN__ = @as(c_int, 1234);
pub const __ORDER_BIG_ENDIAN__ = @as(c_int, 4321);
pub const __ORDER_PDP_ENDIAN__ = @as(c_int, 3412);
pub const __BYTE_ORDER__ = __ORDER_LITTLE_ENDIAN__;
pub const __LITTLE_ENDIAN__ = @as(c_int, 1);
pub const __ELF__ = @as(c_int, 1);
pub const __ATOMIC_RELAXED = @as(c_int, 0);
pub const __ATOMIC_CONSUME = @as(c_int, 1);
pub const __ATOMIC_ACQUIRE = @as(c_int, 2);
pub const __ATOMIC_RELEASE = @as(c_int, 3);
pub const __ATOMIC_ACQ_REL = @as(c_int, 4);
pub const __ATOMIC_SEQ_CST = @as(c_int, 5);
pub const __ATOMIC_BOOL_LOCK_FREE = @as(c_int, 1);
pub const __ATOMIC_CHAR_LOCK_FREE = @as(c_int, 1);
pub const __ATOMIC_CHAR16_T_LOCK_FREE = @as(c_int, 1);
pub const __ATOMIC_CHAR32_T_LOCK_FREE = @as(c_int, 1);
pub const __ATOMIC_WCHAR_T_LOCK_FREE = @as(c_int, 1);
pub const __ATOMIC_WINT_T_LOCK_FREE = @as(c_int, 1);
pub const __ATOMIC_SHORT_LOCK_FREE = @as(c_int, 1);
pub const __ATOMIC_INT_LOCK_FREE = @as(c_int, 1);
pub const __ATOMIC_LONG_LOCK_FREE = @as(c_int, 1);
pub const __ATOMIC_LLONG_LOCK_FREE = @as(c_int, 1);
pub const __ATOMIC_POINTER_LOCK_FREE = @as(c_int, 1);
pub const __WINT_UNSIGNED__ = @as(c_int, 1);
pub const __CHAR_BIT__ = @as(c_int, 8);
pub const __BOOL_WIDTH__ = @as(c_int, 8);
pub const __SCHAR_MAX__ = @as(c_int, 127);
pub const __SCHAR_WIDTH__ = @as(c_int, 8);
pub const __SHRT_MAX__ = @as(c_int, 32767);
pub const __SHRT_WIDTH__ = @as(c_int, 16);
pub const __INT_MAX__ = __helpers.promoteIntLiteral(c_int, 2147483647, .decimal);
pub const __INT_WIDTH__ = @as(c_int, 32);
pub const __LONG_MAX__ = __helpers.promoteIntLiteral(c_long, 9223372036854775807, .decimal);
pub const __LONG_WIDTH__ = @as(c_int, 64);
pub const __LONG_LONG_MAX__ = @as(c_longlong, 9223372036854775807);
pub const __LONG_LONG_WIDTH__ = @as(c_int, 64);
pub const __WCHAR_MAX__ = __helpers.promoteIntLiteral(c_int, 2147483647, .decimal);
pub const __WCHAR_WIDTH__ = @as(c_int, 32);
pub const __WINT_MAX__ = __helpers.promoteIntLiteral(c_uint, 4294967295, .decimal);
pub const __WINT_WIDTH__ = @as(c_int, 32);
pub const __INTMAX_MAX__ = __helpers.promoteIntLiteral(c_long, 9223372036854775807, .decimal);
pub const __INTMAX_WIDTH__ = @as(c_int, 64);
pub const __SIZE_MAX__ = __helpers.promoteIntLiteral(c_ulong, 18446744073709551615, .decimal);
pub const __SIZE_WIDTH__ = @as(c_int, 64);
pub const __UINTMAX_MAX__ = __helpers.promoteIntLiteral(c_ulong, 18446744073709551615, .decimal);
pub const __UINTMAX_WIDTH__ = @as(c_int, 64);
pub const __PTRDIFF_MAX__ = __helpers.promoteIntLiteral(c_long, 9223372036854775807, .decimal);
pub const __PTRDIFF_WIDTH__ = @as(c_int, 64);
pub const __INTPTR_MAX__ = __helpers.promoteIntLiteral(c_long, 9223372036854775807, .decimal);
pub const __INTPTR_WIDTH__ = @as(c_int, 64);
pub const __UINTPTR_MAX__ = __helpers.promoteIntLiteral(c_ulong, 18446744073709551615, .decimal);
pub const __UINTPTR_WIDTH__ = @as(c_int, 64);
pub const __SIG_ATOMIC_MAX__ = __helpers.promoteIntLiteral(c_int, 2147483647, .decimal);
pub const __SIG_ATOMIC_WIDTH__ = @as(c_int, 32);
pub const __BITINT_MAXWIDTH__ = __helpers.promoteIntLiteral(c_int, 65535, .decimal);
pub const __SIZEOF_FLOAT__ = @as(c_int, 4);
pub const __SIZEOF_DOUBLE__ = @as(c_int, 8);
pub const __SIZEOF_LONG_DOUBLE__ = @as(c_int, 10);
pub const __SIZEOF_SHORT__ = @as(c_int, 2);
pub const __SIZEOF_INT__ = @as(c_int, 4);
pub const __SIZEOF_LONG__ = @as(c_int, 8);
pub const __SIZEOF_LONG_LONG__ = @as(c_int, 8);
pub const __SIZEOF_POINTER__ = @as(c_int, 8);
pub const __SIZEOF_PTRDIFF_T__ = @as(c_int, 8);
pub const __SIZEOF_SIZE_T__ = @as(c_int, 8);
pub const __SIZEOF_WCHAR_T__ = @as(c_int, 4);
pub const __SIZEOF_WINT_T__ = @as(c_int, 4);
pub const __SIZEOF_INT128__ = @as(c_int, 16);
pub const __INTPTR_TYPE__ = c_long;
pub const __UINTPTR_TYPE__ = c_ulong;
pub const __INTMAX_TYPE__ = c_long;
pub const __INTMAX_C_SUFFIX__ = @compileError("unable to translate macro: undefined identifier `L`");
// <builtin>:154:9
pub const __INTMAX_C = __helpers.L_SUFFIX;
pub const __UINTMAX_TYPE__ = c_ulong;
pub const __UINTMAX_C_SUFFIX__ = @compileError("unable to translate macro: undefined identifier `UL`");
// <builtin>:157:9
pub const __UINTMAX_C = __helpers.UL_SUFFIX;
pub const __PTRDIFF_TYPE__ = c_long;
pub const __SIZE_TYPE__ = c_ulong;
pub const __WCHAR_TYPE__ = c_int;
pub const __WINT_TYPE__ = c_uint;
pub const __CHAR16_TYPE__ = c_ushort;
pub const __CHAR32_TYPE__ = c_uint;
pub const __INT8_TYPE__ = i8;
pub const __INT8_FMTd__ = "hhd";
pub const __INT8_FMTi__ = "hhi";
pub const __INT8_C_SUFFIX__ = "";
pub inline fn __INT8_C(c: anytype) @TypeOf(c) {
    _ = &c;
    return c;
}
pub const __INT16_TYPE__ = c_short;
pub const __INT16_FMTd__ = "hd";
pub const __INT16_FMTi__ = "hi";
pub const __INT16_C_SUFFIX__ = "";
pub inline fn __INT16_C(c: anytype) @TypeOf(c) {
    _ = &c;
    return c;
}
pub const __INT32_TYPE__ = c_int;
pub const __INT32_FMTd__ = "d";
pub const __INT32_FMTi__ = "i";
pub const __INT32_C_SUFFIX__ = "";
pub inline fn __INT32_C(c: anytype) @TypeOf(c) {
    _ = &c;
    return c;
}
pub const __INT64_TYPE__ = c_long;
pub const __INT64_FMTd__ = "ld";
pub const __INT64_FMTi__ = "li";
pub const __INT64_C_SUFFIX__ = @compileError("unable to translate macro: undefined identifier `L`");
// <builtin>:183:9
pub const __INT64_C = __helpers.L_SUFFIX;
pub const __UINT8_TYPE__ = u8;
pub const __UINT8_FMTo__ = "hho";
pub const __UINT8_FMTu__ = "hhu";
pub const __UINT8_FMTx__ = "hhx";
pub const __UINT8_FMTX__ = "hhX";
pub const __UINT8_C_SUFFIX__ = "";
pub inline fn __UINT8_C(c: anytype) @TypeOf(c) {
    _ = &c;
    return c;
}
pub const __UINT8_MAX__ = @as(c_int, 255);
pub const __INT8_MAX__ = @as(c_int, 127);
pub const __UINT16_TYPE__ = c_ushort;
pub const __UINT16_FMTo__ = "ho";
pub const __UINT16_FMTu__ = "hu";
pub const __UINT16_FMTx__ = "hx";
pub const __UINT16_FMTX__ = "hX";
pub const __UINT16_C_SUFFIX__ = "";
pub inline fn __UINT16_C(c: anytype) @TypeOf(c) {
    _ = &c;
    return c;
}
pub const __UINT16_MAX__ = __helpers.promoteIntLiteral(c_int, 65535, .decimal);
pub const __INT16_MAX__ = @as(c_int, 32767);
pub const __UINT32_TYPE__ = c_uint;
pub const __UINT32_FMTo__ = "o";
pub const __UINT32_FMTu__ = "u";
pub const __UINT32_FMTx__ = "x";
pub const __UINT32_FMTX__ = "X";
pub const __UINT32_C_SUFFIX__ = @compileError("unable to translate macro: undefined identifier `U`");
// <builtin>:208:9
pub const __UINT32_C = __helpers.U_SUFFIX;
pub const __UINT32_MAX__ = __helpers.promoteIntLiteral(c_uint, 4294967295, .decimal);
pub const __INT32_MAX__ = __helpers.promoteIntLiteral(c_int, 2147483647, .decimal);
pub const __UINT64_TYPE__ = c_ulong;
pub const __UINT64_FMTo__ = "lo";
pub const __UINT64_FMTu__ = "lu";
pub const __UINT64_FMTx__ = "lx";
pub const __UINT64_FMTX__ = "lX";
pub const __UINT64_C_SUFFIX__ = @compileError("unable to translate macro: undefined identifier `UL`");
// <builtin>:217:9
pub const __UINT64_C = __helpers.UL_SUFFIX;
pub const __UINT64_MAX__ = __helpers.promoteIntLiteral(c_ulong, 18446744073709551615, .decimal);
pub const __INT64_MAX__ = __helpers.promoteIntLiteral(c_long, 9223372036854775807, .decimal);
pub const __INT_LEAST8_TYPE__ = i8;
pub const __INT_LEAST8_MAX__ = @as(c_int, 127);
pub const __INT_LEAST8_WIDTH__ = @as(c_int, 8);
pub const INT_LEAST8_FMTd__ = "hhd";
pub const INT_LEAST8_FMTi__ = "hhi";
pub const __UINT_LEAST8_TYPE__ = u8;
pub const __UINT_LEAST8_MAX__ = @as(c_int, 255);
pub const UINT_LEAST8_FMTo__ = "hho";
pub const UINT_LEAST8_FMTu__ = "hhu";
pub const UINT_LEAST8_FMTx__ = "hhx";
pub const UINT_LEAST8_FMTX__ = "hhX";
pub const __INT_FAST8_TYPE__ = i8;
pub const __INT_FAST8_MAX__ = @as(c_int, 127);
pub const __INT_FAST8_WIDTH__ = @as(c_int, 8);
pub const INT_FAST8_FMTd__ = "hhd";
pub const INT_FAST8_FMTi__ = "hhi";
pub const __UINT_FAST8_TYPE__ = u8;
pub const __UINT_FAST8_MAX__ = @as(c_int, 255);
pub const UINT_FAST8_FMTo__ = "hho";
pub const UINT_FAST8_FMTu__ = "hhu";
pub const UINT_FAST8_FMTx__ = "hhx";
pub const UINT_FAST8_FMTX__ = "hhX";
pub const __INT_LEAST16_TYPE__ = c_short;
pub const __INT_LEAST16_MAX__ = @as(c_int, 32767);
pub const __INT_LEAST16_WIDTH__ = @as(c_int, 16);
pub const INT_LEAST16_FMTd__ = "hd";
pub const INT_LEAST16_FMTi__ = "hi";
pub const __UINT_LEAST16_TYPE__ = c_ushort;
pub const __UINT_LEAST16_MAX__ = __helpers.promoteIntLiteral(c_int, 65535, .decimal);
pub const UINT_LEAST16_FMTo__ = "ho";
pub const UINT_LEAST16_FMTu__ = "hu";
pub const UINT_LEAST16_FMTx__ = "hx";
pub const UINT_LEAST16_FMTX__ = "hX";
pub const __INT_FAST16_TYPE__ = c_short;
pub const __INT_FAST16_MAX__ = @as(c_int, 32767);
pub const __INT_FAST16_WIDTH__ = @as(c_int, 16);
pub const INT_FAST16_FMTd__ = "hd";
pub const INT_FAST16_FMTi__ = "hi";
pub const __UINT_FAST16_TYPE__ = c_ushort;
pub const __UINT_FAST16_MAX__ = __helpers.promoteIntLiteral(c_int, 65535, .decimal);
pub const UINT_FAST16_FMTo__ = "ho";
pub const UINT_FAST16_FMTu__ = "hu";
pub const UINT_FAST16_FMTx__ = "hx";
pub const UINT_FAST16_FMTX__ = "hX";
pub const __INT_LEAST32_TYPE__ = c_int;
pub const __INT_LEAST32_MAX__ = __helpers.promoteIntLiteral(c_int, 2147483647, .decimal);
pub const __INT_LEAST32_WIDTH__ = @as(c_int, 32);
pub const INT_LEAST32_FMTd__ = "d";
pub const INT_LEAST32_FMTi__ = "i";
pub const __UINT_LEAST32_TYPE__ = c_uint;
pub const __UINT_LEAST32_MAX__ = __helpers.promoteIntLiteral(c_uint, 4294967295, .decimal);
pub const UINT_LEAST32_FMTo__ = "o";
pub const UINT_LEAST32_FMTu__ = "u";
pub const UINT_LEAST32_FMTx__ = "x";
pub const UINT_LEAST32_FMTX__ = "X";
pub const __INT_FAST32_TYPE__ = c_int;
pub const __INT_FAST32_MAX__ = __helpers.promoteIntLiteral(c_int, 2147483647, .decimal);
pub const __INT_FAST32_WIDTH__ = @as(c_int, 32);
pub const INT_FAST32_FMTd__ = "d";
pub const INT_FAST32_FMTi__ = "i";
pub const __UINT_FAST32_TYPE__ = c_uint;
pub const __UINT_FAST32_MAX__ = __helpers.promoteIntLiteral(c_uint, 4294967295, .decimal);
pub const UINT_FAST32_FMTo__ = "o";
pub const UINT_FAST32_FMTu__ = "u";
pub const UINT_FAST32_FMTx__ = "x";
pub const UINT_FAST32_FMTX__ = "X";
pub const __INT_LEAST64_TYPE__ = c_long;
pub const __INT_LEAST64_MAX__ = __helpers.promoteIntLiteral(c_long, 9223372036854775807, .decimal);
pub const __INT_LEAST64_WIDTH__ = @as(c_int, 64);
pub const INT_LEAST64_FMTd__ = "ld";
pub const INT_LEAST64_FMTi__ = "li";
pub const __UINT_LEAST64_TYPE__ = c_ulong;
pub const __UINT_LEAST64_MAX__ = __helpers.promoteIntLiteral(c_ulong, 18446744073709551615, .decimal);
pub const UINT_LEAST64_FMTo__ = "lo";
pub const UINT_LEAST64_FMTu__ = "lu";
pub const UINT_LEAST64_FMTx__ = "lx";
pub const UINT_LEAST64_FMTX__ = "lX";
pub const __INT_FAST64_TYPE__ = c_long;
pub const __INT_FAST64_MAX__ = __helpers.promoteIntLiteral(c_long, 9223372036854775807, .decimal);
pub const __INT_FAST64_WIDTH__ = @as(c_int, 64);
pub const INT_FAST64_FMTd__ = "ld";
pub const INT_FAST64_FMTi__ = "li";
pub const __UINT_FAST64_TYPE__ = c_ulong;
pub const __UINT_FAST64_MAX__ = __helpers.promoteIntLiteral(c_ulong, 18446744073709551615, .decimal);
pub const UINT_FAST64_FMTo__ = "lo";
pub const UINT_FAST64_FMTu__ = "lu";
pub const UINT_FAST64_FMTx__ = "lx";
pub const UINT_FAST64_FMTX__ = "lX";
pub const __FLT16_DENORM_MIN__ = @as(f16, 5.9604644775390625e-8);
pub const __FLT16_HAS_DENORM__ = "";
pub const __FLT16_DIG__ = @as(c_int, 3);
pub const __FLT16_DECIMAL_DIG__ = @as(c_int, 5);
pub const __FLT16_EPSILON__ = @as(f16, 9.765625e-4);
pub const __FLT16_HAS_INFINITY__ = "";
pub const __FLT16_HAS_QUIET_NAN__ = "";
pub const __FLT16_MANT_DIG__ = @as(c_int, 11);
pub const __FLT16_MAX_10_EXP__ = @as(c_int, 4);
pub const __FLT16_MAX_EXP__ = @as(c_int, 16);
pub const __FLT16_MAX__ = @as(f16, 6.5504e+4);
pub const __FLT16_MIN_10_EXP__ = -@as(c_int, 4);
pub const __FLT16_MIN_EXP__ = -@as(c_int, 13);
pub const __FLT16_MIN__ = @as(f16, 6.103515625e-5);
pub const __FLT_DENORM_MIN__ = @as(f32, 1.40129846e-45);
pub const __FLT_HAS_DENORM__ = "";
pub const __FLT_DIG__ = @as(c_int, 6);
pub const __FLT_DECIMAL_DIG__ = @as(c_int, 9);
pub const __FLT_EPSILON__ = @as(f32, 1.19209290e-7);
pub const __FLT_HAS_INFINITY__ = "";
pub const __FLT_HAS_QUIET_NAN__ = "";
pub const __FLT_MANT_DIG__ = @as(c_int, 24);
pub const __FLT_MAX_10_EXP__ = @as(c_int, 38);
pub const __FLT_MAX_EXP__ = @as(c_int, 128);
pub const __FLT_MAX__ = @as(f32, 3.40282347e+38);
pub const __FLT_MIN_10_EXP__ = -@as(c_int, 37);
pub const __FLT_MIN_EXP__ = -@as(c_int, 125);
pub const __FLT_MIN__ = @as(f32, 1.17549435e-38);
pub const __DBL_DENORM_MIN__ = @as(f64, 4.9406564584124654e-324);
pub const __DBL_HAS_DENORM__ = "";
pub const __DBL_DIG__ = @as(c_int, 15);
pub const __DBL_DECIMAL_DIG__ = @as(c_int, 17);
pub const __DBL_EPSILON__ = @as(f64, 2.2204460492503131e-16);
pub const __DBL_HAS_INFINITY__ = "";
pub const __DBL_HAS_QUIET_NAN__ = "";
pub const __DBL_MANT_DIG__ = @as(c_int, 53);
pub const __DBL_MAX_10_EXP__ = @as(c_int, 308);
pub const __DBL_MAX_EXP__ = @as(c_int, 1024);
pub const __DBL_MAX__ = @as(f64, 1.7976931348623157e+308);
pub const __DBL_MIN_10_EXP__ = -@as(c_int, 307);
pub const __DBL_MIN_EXP__ = -@as(c_int, 1021);
pub const __DBL_MIN__ = @as(f64, 2.2250738585072014e-308);
pub const __LDBL_DENORM_MIN__ = @as(c_longdouble, 3.64519953188247460253e-4951);
pub const __LDBL_HAS_DENORM__ = "";
pub const __LDBL_DIG__ = @as(c_int, 18);
pub const __LDBL_DECIMAL_DIG__ = @as(c_int, 21);
pub const __LDBL_EPSILON__ = @as(c_longdouble, 1.08420217248550443401e-19);
pub const __LDBL_HAS_INFINITY__ = "";
pub const __LDBL_HAS_QUIET_NAN__ = "";
pub const __LDBL_MANT_DIG__ = @as(c_int, 64);
pub const __LDBL_MAX_10_EXP__ = @as(c_int, 4932);
pub const __LDBL_MAX_EXP__ = @as(c_int, 16384);
pub const __LDBL_MAX__ = @as(c_longdouble, 1.18973149535723176502e+4932);
pub const __LDBL_MIN_10_EXP__ = -@as(c_int, 4931);
pub const __LDBL_MIN_EXP__ = -@as(c_int, 16381);
pub const __LDBL_MIN__ = @as(c_longdouble, 3.36210314311209350626e-4932);
pub const __FLT_EVAL_METHOD__ = @as(c_int, 0);
pub const __FLT_RADIX__ = @as(c_int, 2);
pub const __DECIMAL_DIG__ = __LDBL_DECIMAL_DIG__;
pub const __pic__ = @as(c_int, 2);
pub const __PIC__ = @as(c_int, 2);
pub const __GLIBC_MINOR__ = @as(c_int, 41);
pub const VSCODE_TEXTMATE_ONIGURUMA_H = "";
pub const ONIGURUMA_H = "";
pub const ONIGURUMA = "";
pub const ONIGURUMA_VERSION_MAJOR = @as(c_int, 6);
pub const ONIGURUMA_VERSION_MINOR = @as(c_int, 9);
pub const ONIGURUMA_VERSION_TEENY = @as(c_int, 9);
pub const ONIGURUMA_VERSION_INT = __helpers.promoteIntLiteral(c_int, 60909, .decimal);
pub inline fn P_(args: anytype) @TypeOf(args) {
    _ = &args;
    return args;
}
pub inline fn PV_(args: anytype) @TypeOf(args) {
    _ = &args;
    return args;
}
pub const ONIG_EXTERN = @compileError("unable to translate C expr: unexpected token 'extern'");
// /usr/include/oniguruma.h:67:9
pub const ONIG_VARIADIC_FUNC_ATTR = "";
pub const UChar = OnigUChar;
pub const ONIG_INFINITE_DISTANCE = ~__helpers.cast(OnigLen, @as(c_int, 0));
pub const ONIGENC_CASE_FOLD_ASCII_ONLY = @as(c_int, 1);
pub const ONIGENC_CASE_FOLD_TURKISH_AZERI = @as(c_int, 1) << @as(c_int, 20);
pub const INTERNAL_ONIGENC_CASE_FOLD_MULTI_CHAR = @as(c_int, 1) << @as(c_int, 30);
pub const ONIGENC_CASE_FOLD_MIN = INTERNAL_ONIGENC_CASE_FOLD_MULTI_CHAR;

// /usr/include/oniguruma.h:101:9: warning: macro 'ONIGENC_CASE_FOLD_DEFAULT' contains a runtime value, translated to function
pub inline fn ONIGENC_CASE_FOLD_DEFAULT() @TypeOf(OnigDefaultCaseFoldFlag) {
    return OnigDefaultCaseFoldFlag;
}
pub const ONIGENC_MAX_COMP_CASE_FOLD_CODE_LEN = @as(c_int, 3);
pub const ONIGENC_GET_CASE_FOLD_CODES_MAX_NUM = @as(c_int, 13);
pub inline fn ONIGENC_CODE_RANGE_NUM(range: anytype) c_int {
    _ = &range;
    return __helpers.cast(c_int, range[@as(usize, @intCast(@as(c_int, 0)))]);
}
pub inline fn ONIGENC_CODE_RANGE_FROM(range: anytype, i: anytype) @TypeOf(range[@as(usize, @intCast((i * @as(c_int, 2)) + @as(c_int, 1)))]) {
    _ = &range;
    _ = &i;
    return range[@as(usize, @intCast((i * @as(c_int, 2)) + @as(c_int, 1)))];
}
pub inline fn ONIGENC_CODE_RANGE_TO(range: anytype, i: anytype) @TypeOf(range[@as(usize, @intCast((i * @as(c_int, 2)) + @as(c_int, 2)))]) {
    _ = &range;
    _ = &i;
    return range[@as(usize, @intCast((i * @as(c_int, 2)) + @as(c_int, 2)))];
}

// /usr/include/oniguruma.h:189:9: warning: macro 'ONIG_ENCODING_ASCII' contains a runtime value, translated to function
pub inline fn ONIG_ENCODING_ASCII() @TypeOf(&OnigEncodingASCII) {
    return &OnigEncodingASCII;
}

// /usr/include/oniguruma.h:190:9: warning: macro 'ONIG_ENCODING_ISO_8859_1' contains a runtime value, translated to function
pub inline fn ONIG_ENCODING_ISO_8859_1() @TypeOf(&OnigEncodingISO_8859_1) {
    return &OnigEncodingISO_8859_1;
}

// /usr/include/oniguruma.h:191:9: warning: macro 'ONIG_ENCODING_ISO_8859_2' contains a runtime value, translated to function
pub inline fn ONIG_ENCODING_ISO_8859_2() @TypeOf(&OnigEncodingISO_8859_2) {
    return &OnigEncodingISO_8859_2;
}

// /usr/include/oniguruma.h:192:9: warning: macro 'ONIG_ENCODING_ISO_8859_3' contains a runtime value, translated to function
pub inline fn ONIG_ENCODING_ISO_8859_3() @TypeOf(&OnigEncodingISO_8859_3) {
    return &OnigEncodingISO_8859_3;
}

// /usr/include/oniguruma.h:193:9: warning: macro 'ONIG_ENCODING_ISO_8859_4' contains a runtime value, translated to function
pub inline fn ONIG_ENCODING_ISO_8859_4() @TypeOf(&OnigEncodingISO_8859_4) {
    return &OnigEncodingISO_8859_4;
}

// /usr/include/oniguruma.h:194:9: warning: macro 'ONIG_ENCODING_ISO_8859_5' contains a runtime value, translated to function
pub inline fn ONIG_ENCODING_ISO_8859_5() @TypeOf(&OnigEncodingISO_8859_5) {
    return &OnigEncodingISO_8859_5;
}

// /usr/include/oniguruma.h:195:9: warning: macro 'ONIG_ENCODING_ISO_8859_6' contains a runtime value, translated to function
pub inline fn ONIG_ENCODING_ISO_8859_6() @TypeOf(&OnigEncodingISO_8859_6) {
    return &OnigEncodingISO_8859_6;
}

// /usr/include/oniguruma.h:196:9: warning: macro 'ONIG_ENCODING_ISO_8859_7' contains a runtime value, translated to function
pub inline fn ONIG_ENCODING_ISO_8859_7() @TypeOf(&OnigEncodingISO_8859_7) {
    return &OnigEncodingISO_8859_7;
}

// /usr/include/oniguruma.h:197:9: warning: macro 'ONIG_ENCODING_ISO_8859_8' contains a runtime value, translated to function
pub inline fn ONIG_ENCODING_ISO_8859_8() @TypeOf(&OnigEncodingISO_8859_8) {
    return &OnigEncodingISO_8859_8;
}

// /usr/include/oniguruma.h:198:9: warning: macro 'ONIG_ENCODING_ISO_8859_9' contains a runtime value, translated to function
pub inline fn ONIG_ENCODING_ISO_8859_9() @TypeOf(&OnigEncodingISO_8859_9) {
    return &OnigEncodingISO_8859_9;
}

// /usr/include/oniguruma.h:199:9: warning: macro 'ONIG_ENCODING_ISO_8859_10' contains a runtime value, translated to function
pub inline fn ONIG_ENCODING_ISO_8859_10() @TypeOf(&OnigEncodingISO_8859_10) {
    return &OnigEncodingISO_8859_10;
}

// /usr/include/oniguruma.h:200:9: warning: macro 'ONIG_ENCODING_ISO_8859_11' contains a runtime value, translated to function
pub inline fn ONIG_ENCODING_ISO_8859_11() @TypeOf(&OnigEncodingISO_8859_11) {
    return &OnigEncodingISO_8859_11;
}

// /usr/include/oniguruma.h:201:9: warning: macro 'ONIG_ENCODING_ISO_8859_13' contains a runtime value, translated to function
pub inline fn ONIG_ENCODING_ISO_8859_13() @TypeOf(&OnigEncodingISO_8859_13) {
    return &OnigEncodingISO_8859_13;
}

// /usr/include/oniguruma.h:202:9: warning: macro 'ONIG_ENCODING_ISO_8859_14' contains a runtime value, translated to function
pub inline fn ONIG_ENCODING_ISO_8859_14() @TypeOf(&OnigEncodingISO_8859_14) {
    return &OnigEncodingISO_8859_14;
}

// /usr/include/oniguruma.h:203:9: warning: macro 'ONIG_ENCODING_ISO_8859_15' contains a runtime value, translated to function
pub inline fn ONIG_ENCODING_ISO_8859_15() @TypeOf(&OnigEncodingISO_8859_15) {
    return &OnigEncodingISO_8859_15;
}

// /usr/include/oniguruma.h:204:9: warning: macro 'ONIG_ENCODING_ISO_8859_16' contains a runtime value, translated to function
pub inline fn ONIG_ENCODING_ISO_8859_16() @TypeOf(&OnigEncodingISO_8859_16) {
    return &OnigEncodingISO_8859_16;
}

// /usr/include/oniguruma.h:205:9: warning: macro 'ONIG_ENCODING_UTF8' contains a runtime value, translated to function
pub inline fn ONIG_ENCODING_UTF8() @TypeOf(&OnigEncodingUTF8) {
    return &OnigEncodingUTF8;
}

// /usr/include/oniguruma.h:206:9: warning: macro 'ONIG_ENCODING_UTF16_BE' contains a runtime value, translated to function
pub inline fn ONIG_ENCODING_UTF16_BE() @TypeOf(&OnigEncodingUTF16_BE) {
    return &OnigEncodingUTF16_BE;
}

// /usr/include/oniguruma.h:207:9: warning: macro 'ONIG_ENCODING_UTF16_LE' contains a runtime value, translated to function
pub inline fn ONIG_ENCODING_UTF16_LE() @TypeOf(&OnigEncodingUTF16_LE) {
    return &OnigEncodingUTF16_LE;
}

// /usr/include/oniguruma.h:208:9: warning: macro 'ONIG_ENCODING_UTF32_BE' contains a runtime value, translated to function
pub inline fn ONIG_ENCODING_UTF32_BE() @TypeOf(&OnigEncodingUTF32_BE) {
    return &OnigEncodingUTF32_BE;
}

// /usr/include/oniguruma.h:209:9: warning: macro 'ONIG_ENCODING_UTF32_LE' contains a runtime value, translated to function
pub inline fn ONIG_ENCODING_UTF32_LE() @TypeOf(&OnigEncodingUTF32_LE) {
    return &OnigEncodingUTF32_LE;
}

// /usr/include/oniguruma.h:210:9: warning: macro 'ONIG_ENCODING_EUC_JP' contains a runtime value, translated to function
pub inline fn ONIG_ENCODING_EUC_JP() @TypeOf(&OnigEncodingEUC_JP) {
    return &OnigEncodingEUC_JP;
}

// /usr/include/oniguruma.h:211:9: warning: macro 'ONIG_ENCODING_EUC_TW' contains a runtime value, translated to function
pub inline fn ONIG_ENCODING_EUC_TW() @TypeOf(&OnigEncodingEUC_TW) {
    return &OnigEncodingEUC_TW;
}

// /usr/include/oniguruma.h:212:9: warning: macro 'ONIG_ENCODING_EUC_KR' contains a runtime value, translated to function
pub inline fn ONIG_ENCODING_EUC_KR() @TypeOf(&OnigEncodingEUC_KR) {
    return &OnigEncodingEUC_KR;
}

// /usr/include/oniguruma.h:213:9: warning: macro 'ONIG_ENCODING_EUC_CN' contains a runtime value, translated to function
pub inline fn ONIG_ENCODING_EUC_CN() @TypeOf(&OnigEncodingEUC_CN) {
    return &OnigEncodingEUC_CN;
}

// /usr/include/oniguruma.h:214:9: warning: macro 'ONIG_ENCODING_SJIS' contains a runtime value, translated to function
pub inline fn ONIG_ENCODING_SJIS() @TypeOf(&OnigEncodingSJIS) {
    return &OnigEncodingSJIS;
}

// /usr/include/oniguruma.h:215:9: warning: macro 'ONIG_ENCODING_KOI8' contains a runtime value, translated to function
pub inline fn ONIG_ENCODING_KOI8() @TypeOf(&OnigEncodingKOI8) {
    return &OnigEncodingKOI8;
}

// /usr/include/oniguruma.h:216:9: warning: macro 'ONIG_ENCODING_KOI8_R' contains a runtime value, translated to function
pub inline fn ONIG_ENCODING_KOI8_R() @TypeOf(&OnigEncodingKOI8_R) {
    return &OnigEncodingKOI8_R;
}

// /usr/include/oniguruma.h:217:9: warning: macro 'ONIG_ENCODING_CP1251' contains a runtime value, translated to function
pub inline fn ONIG_ENCODING_CP1251() @TypeOf(&OnigEncodingCP1251) {
    return &OnigEncodingCP1251;
}

// /usr/include/oniguruma.h:218:9: warning: macro 'ONIG_ENCODING_BIG5' contains a runtime value, translated to function
pub inline fn ONIG_ENCODING_BIG5() @TypeOf(&OnigEncodingBIG5) {
    return &OnigEncodingBIG5;
}

// /usr/include/oniguruma.h:219:9: warning: macro 'ONIG_ENCODING_GB18030' contains a runtime value, translated to function
pub inline fn ONIG_ENCODING_GB18030() @TypeOf(&OnigEncodingGB18030) {
    return &OnigEncodingGB18030;
}
pub const ONIG_ENCODING_UNDEF = __helpers.cast(OnigEncoding, @as(c_int, 0));
pub const ONIGENC_CODE_TO_MBC_MAXLEN = @as(c_int, 7);
pub const ONIGENC_MBC_CASE_FOLD_MAXLEN = @as(c_int, 18);
pub const ONIGENC_MAX_STD_CTYPE = ONIGENC_CTYPE_ASCII;
pub inline fn onig_enc_len(enc: anytype, p: anytype, end: anytype) @TypeOf(ONIGENC_MBC_ENC_LEN(enc, p)) {
    _ = &enc;
    _ = &p;
    _ = &end;
    return ONIGENC_MBC_ENC_LEN(enc, p);
}
pub inline fn ONIGENC_IS_UNDEF(enc: anytype) @TypeOf(enc == ONIG_ENCODING_UNDEF) {
    _ = &enc;
    return enc == ONIG_ENCODING_UNDEF;
}
pub inline fn ONIGENC_IS_SINGLEBYTE(enc: anytype) @TypeOf(ONIGENC_MBC_MAXLEN(enc) == @as(c_int, 1)) {
    _ = &enc;
    return ONIGENC_MBC_MAXLEN(enc) == @as(c_int, 1);
}
pub inline fn ONIGENC_IS_MBC_HEAD(enc: anytype, p: anytype) @TypeOf(ONIGENC_MBC_ENC_LEN(enc, p) != @as(c_int, 1)) {
    _ = &enc;
    _ = &p;
    return ONIGENC_MBC_ENC_LEN(enc, p) != @as(c_int, 1);
}
pub inline fn ONIGENC_IS_MBC_ASCII(p: anytype) @TypeOf(p.* < @as(c_int, 128)) {
    _ = &p;
    return p.* < @as(c_int, 128);
}
pub inline fn ONIGENC_IS_CODE_ASCII(code: anytype) @TypeOf(code < @as(c_int, 128)) {
    _ = &code;
    return code < @as(c_int, 128);
}
pub inline fn ONIGENC_IS_MBC_WORD(enc: anytype, s: anytype, end: anytype) @TypeOf(ONIGENC_IS_CODE_WORD(enc, ONIGENC_MBC_TO_CODE(enc, s, end))) {
    _ = &enc;
    _ = &s;
    _ = &end;
    return ONIGENC_IS_CODE_WORD(enc, ONIGENC_MBC_TO_CODE(enc, s, end));
}
pub const ONIGENC_IS_MBC_WORD_ASCII = @compileError("unable to translate macro: undefined identifier `onigenc_is_mbc_word_ascii`");
// /usr/include/oniguruma.h:260:9
pub inline fn ONIGENC_NAME(enc: anytype) @TypeOf(enc.*.name) {
    _ = &enc;
    return enc.*.name;
}
pub const ONIGENC_MBC_CASE_FOLD = @compileError("unable to translate C expr: unexpected token 'const'");
// /usr/include/oniguruma.h:264:9
pub inline fn ONIGENC_IS_ALLOWED_REVERSE_MATCH(enc: anytype, s: anytype, end: anytype) @TypeOf(enc.*.is_allowed_reverse_match(s, end)) {
    _ = &enc;
    _ = &s;
    _ = &end;
    return enc.*.is_allowed_reverse_match(s, end);
}
pub inline fn ONIGENC_LEFT_ADJUST_CHAR_HEAD(enc: anytype, start: anytype, s: anytype) @TypeOf(enc.*.left_adjust_char_head(start, s)) {
    _ = &enc;
    _ = &start;
    _ = &s;
    return enc.*.left_adjust_char_head(start, s);
}
pub inline fn ONIGENC_IS_VALID_MBC_STRING(enc: anytype, s: anytype, end: anytype) @TypeOf(enc.*.is_valid_mbc_string(s, end)) {
    _ = &enc;
    _ = &s;
    _ = &end;
    return enc.*.is_valid_mbc_string(s, end);
}
pub inline fn ONIGENC_APPLY_ALL_CASE_FOLD(enc: anytype, case_fold_flag: anytype, f: anytype, arg: anytype) @TypeOf(enc.*.apply_all_case_fold(case_fold_flag, f, arg)) {
    _ = &enc;
    _ = &case_fold_flag;
    _ = &f;
    _ = &arg;
    return enc.*.apply_all_case_fold(case_fold_flag, f, arg);
}
pub inline fn ONIGENC_GET_CASE_FOLD_CODES_BY_STR(enc: anytype, case_fold_flag: anytype, p: anytype, end: anytype, acs: anytype) @TypeOf(enc.*.get_case_fold_codes_by_str(case_fold_flag, p, end, acs)) {
    _ = &enc;
    _ = &case_fold_flag;
    _ = &p;
    _ = &end;
    _ = &acs;
    return enc.*.get_case_fold_codes_by_str(case_fold_flag, p, end, acs);
}
pub inline fn ONIGENC_STEP_BACK(enc: anytype, start: anytype, s: anytype, n: anytype) @TypeOf(onigenc_step_back(enc, start, s, n)) {
    _ = &enc;
    _ = &start;
    _ = &s;
    _ = &n;
    return onigenc_step_back(enc, start, s, n);
}
pub inline fn ONIGENC_MBC_ENC_LEN(enc: anytype, p: anytype) @TypeOf(enc.*.mbc_enc_len(p)) {
    _ = &enc;
    _ = &p;
    return enc.*.mbc_enc_len(p);
}
pub inline fn ONIGENC_MBC_MAXLEN(enc: anytype) @TypeOf(enc.*.max_enc_len) {
    _ = &enc;
    return enc.*.max_enc_len;
}
pub inline fn ONIGENC_MBC_MAXLEN_DIST(enc: anytype) @TypeOf(ONIGENC_MBC_MAXLEN(enc)) {
    _ = &enc;
    return ONIGENC_MBC_MAXLEN(enc);
}
pub inline fn ONIGENC_MBC_MINLEN(enc: anytype) @TypeOf(enc.*.min_enc_len) {
    _ = &enc;
    return enc.*.min_enc_len;
}
pub inline fn ONIGENC_IS_MBC_NEWLINE(enc: anytype, p: anytype, end: anytype) @TypeOf(enc.*.is_mbc_newline(p, end)) {
    _ = &enc;
    _ = &p;
    _ = &end;
    return enc.*.is_mbc_newline(p, end);
}
pub inline fn ONIGENC_MBC_TO_CODE(enc: anytype, p: anytype, end: anytype) @TypeOf(enc.*.mbc_to_code(p, end)) {
    _ = &enc;
    _ = &p;
    _ = &end;
    return enc.*.mbc_to_code(p, end);
}
pub inline fn ONIGENC_CODE_TO_MBCLEN(enc: anytype, code: anytype) @TypeOf(enc.*.code_to_mbclen(code)) {
    _ = &enc;
    _ = &code;
    return enc.*.code_to_mbclen(code);
}
pub inline fn ONIGENC_CODE_TO_MBC(enc: anytype, code: anytype, buf: anytype) @TypeOf(enc.*.code_to_mbc(code, buf)) {
    _ = &enc;
    _ = &code;
    _ = &buf;
    return enc.*.code_to_mbc(code, buf);
}
pub inline fn ONIGENC_PROPERTY_NAME_TO_CTYPE(enc: anytype, p: anytype, end: anytype) @TypeOf(enc.*.property_name_to_ctype(enc, p, end)) {
    _ = &enc;
    _ = &p;
    _ = &end;
    return enc.*.property_name_to_ctype(enc, p, end);
}
pub inline fn ONIGENC_IS_CODE_CTYPE(enc: anytype, code: anytype, ctype: anytype) @TypeOf(enc.*.is_code_ctype(code, ctype)) {
    _ = &enc;
    _ = &code;
    _ = &ctype;
    return enc.*.is_code_ctype(code, ctype);
}
pub inline fn ONIGENC_IS_CODE_NEWLINE(enc: anytype, code: anytype) @TypeOf(ONIGENC_IS_CODE_CTYPE(enc, code, ONIGENC_CTYPE_NEWLINE)) {
    _ = &enc;
    _ = &code;
    return ONIGENC_IS_CODE_CTYPE(enc, code, ONIGENC_CTYPE_NEWLINE);
}
pub inline fn ONIGENC_IS_CODE_GRAPH(enc: anytype, code: anytype) @TypeOf(ONIGENC_IS_CODE_CTYPE(enc, code, ONIGENC_CTYPE_GRAPH)) {
    _ = &enc;
    _ = &code;
    return ONIGENC_IS_CODE_CTYPE(enc, code, ONIGENC_CTYPE_GRAPH);
}
pub inline fn ONIGENC_IS_CODE_PRINT(enc: anytype, code: anytype) @TypeOf(ONIGENC_IS_CODE_CTYPE(enc, code, ONIGENC_CTYPE_PRINT)) {
    _ = &enc;
    _ = &code;
    return ONIGENC_IS_CODE_CTYPE(enc, code, ONIGENC_CTYPE_PRINT);
}
pub inline fn ONIGENC_IS_CODE_ALNUM(enc: anytype, code: anytype) @TypeOf(ONIGENC_IS_CODE_CTYPE(enc, code, ONIGENC_CTYPE_ALNUM)) {
    _ = &enc;
    _ = &code;
    return ONIGENC_IS_CODE_CTYPE(enc, code, ONIGENC_CTYPE_ALNUM);
}
pub inline fn ONIGENC_IS_CODE_ALPHA(enc: anytype, code: anytype) @TypeOf(ONIGENC_IS_CODE_CTYPE(enc, code, ONIGENC_CTYPE_ALPHA)) {
    _ = &enc;
    _ = &code;
    return ONIGENC_IS_CODE_CTYPE(enc, code, ONIGENC_CTYPE_ALPHA);
}
pub inline fn ONIGENC_IS_CODE_LOWER(enc: anytype, code: anytype) @TypeOf(ONIGENC_IS_CODE_CTYPE(enc, code, ONIGENC_CTYPE_LOWER)) {
    _ = &enc;
    _ = &code;
    return ONIGENC_IS_CODE_CTYPE(enc, code, ONIGENC_CTYPE_LOWER);
}
pub inline fn ONIGENC_IS_CODE_UPPER(enc: anytype, code: anytype) @TypeOf(ONIGENC_IS_CODE_CTYPE(enc, code, ONIGENC_CTYPE_UPPER)) {
    _ = &enc;
    _ = &code;
    return ONIGENC_IS_CODE_CTYPE(enc, code, ONIGENC_CTYPE_UPPER);
}
pub inline fn ONIGENC_IS_CODE_CNTRL(enc: anytype, code: anytype) @TypeOf(ONIGENC_IS_CODE_CTYPE(enc, code, ONIGENC_CTYPE_CNTRL)) {
    _ = &enc;
    _ = &code;
    return ONIGENC_IS_CODE_CTYPE(enc, code, ONIGENC_CTYPE_CNTRL);
}
pub inline fn ONIGENC_IS_CODE_PUNCT(enc: anytype, code: anytype) @TypeOf(ONIGENC_IS_CODE_CTYPE(enc, code, ONIGENC_CTYPE_PUNCT)) {
    _ = &enc;
    _ = &code;
    return ONIGENC_IS_CODE_CTYPE(enc, code, ONIGENC_CTYPE_PUNCT);
}
pub inline fn ONIGENC_IS_CODE_SPACE(enc: anytype, code: anytype) @TypeOf(ONIGENC_IS_CODE_CTYPE(enc, code, ONIGENC_CTYPE_SPACE)) {
    _ = &enc;
    _ = &code;
    return ONIGENC_IS_CODE_CTYPE(enc, code, ONIGENC_CTYPE_SPACE);
}
pub inline fn ONIGENC_IS_CODE_BLANK(enc: anytype, code: anytype) @TypeOf(ONIGENC_IS_CODE_CTYPE(enc, code, ONIGENC_CTYPE_BLANK)) {
    _ = &enc;
    _ = &code;
    return ONIGENC_IS_CODE_CTYPE(enc, code, ONIGENC_CTYPE_BLANK);
}
pub inline fn ONIGENC_IS_CODE_DIGIT(enc: anytype, code: anytype) @TypeOf(ONIGENC_IS_CODE_CTYPE(enc, code, ONIGENC_CTYPE_DIGIT)) {
    _ = &enc;
    _ = &code;
    return ONIGENC_IS_CODE_CTYPE(enc, code, ONIGENC_CTYPE_DIGIT);
}
pub inline fn ONIGENC_IS_CODE_XDIGIT(enc: anytype, code: anytype) @TypeOf(ONIGENC_IS_CODE_CTYPE(enc, code, ONIGENC_CTYPE_XDIGIT)) {
    _ = &enc;
    _ = &code;
    return ONIGENC_IS_CODE_CTYPE(enc, code, ONIGENC_CTYPE_XDIGIT);
}
pub inline fn ONIGENC_IS_CODE_WORD(enc: anytype, code: anytype) @TypeOf(ONIGENC_IS_CODE_CTYPE(enc, code, ONIGENC_CTYPE_WORD)) {
    _ = &enc;
    _ = &code;
    return ONIGENC_IS_CODE_CTYPE(enc, code, ONIGENC_CTYPE_WORD);
}
pub inline fn ONIGENC_GET_CTYPE_CODE_RANGE(enc: anytype, ctype: anytype, sbout: anytype, ranges: anytype) @TypeOf(enc.*.get_ctype_code_range(ctype, sbout, ranges)) {
    _ = &enc;
    _ = &ctype;
    _ = &sbout;
    _ = &ranges;
    return enc.*.get_ctype_code_range(ctype, sbout, ranges);
}
pub const ONIG_NREGION = @as(c_int, 10);
pub const ONIG_MAX_CAPTURE_NUM = __helpers.promoteIntLiteral(c_int, 2147483647, .decimal);
pub const ONIG_MAX_BACKREF_NUM = @as(c_int, 1000);
pub const ONIG_MAX_REPEAT_NUM = __helpers.promoteIntLiteral(c_int, 100000, .decimal);
pub const ONIG_MAX_MULTI_BYTE_RANGES_NUM = @as(c_int, 10000);
pub const ONIG_MAX_ERROR_MESSAGE_LEN = @as(c_int, 90);
pub const ONIG_OPTION_DEFAULT = ONIG_OPTION_NONE;
pub const ONIG_OPTION_NONE = @as(c_uint, 0);
pub const ONIG_OPTION_IGNORECASE = @as(c_uint, 1);
pub const ONIG_OPTION_EXTEND = ONIG_OPTION_IGNORECASE << @as(c_int, 1);
pub const ONIG_OPTION_MULTILINE = ONIG_OPTION_EXTEND << @as(c_int, 1);
pub const ONIG_OPTION_SINGLELINE = ONIG_OPTION_MULTILINE << @as(c_int, 1);
pub const ONIG_OPTION_FIND_LONGEST = ONIG_OPTION_SINGLELINE << @as(c_int, 1);
pub const ONIG_OPTION_FIND_NOT_EMPTY = ONIG_OPTION_FIND_LONGEST << @as(c_int, 1);
pub const ONIG_OPTION_NEGATE_SINGLELINE = ONIG_OPTION_FIND_NOT_EMPTY << @as(c_int, 1);
pub const ONIG_OPTION_DONT_CAPTURE_GROUP = ONIG_OPTION_NEGATE_SINGLELINE << @as(c_int, 1);
pub const ONIG_OPTION_CAPTURE_GROUP = ONIG_OPTION_DONT_CAPTURE_GROUP << @as(c_int, 1);
pub const ONIG_OPTION_NOTBOL = ONIG_OPTION_CAPTURE_GROUP << @as(c_int, 1);
pub const ONIG_OPTION_NOTEOL = ONIG_OPTION_NOTBOL << @as(c_int, 1);
pub const ONIG_OPTION_POSIX_REGION = ONIG_OPTION_NOTEOL << @as(c_int, 1);
pub const ONIG_OPTION_CHECK_VALIDITY_OF_STRING = ONIG_OPTION_POSIX_REGION << @as(c_int, 1);
pub const ONIG_OPTION_IGNORECASE_IS_ASCII = ONIG_OPTION_CHECK_VALIDITY_OF_STRING << @as(c_int, 3);
pub const ONIG_OPTION_WORD_IS_ASCII = ONIG_OPTION_IGNORECASE_IS_ASCII << @as(c_int, 1);
pub const ONIG_OPTION_DIGIT_IS_ASCII = ONIG_OPTION_WORD_IS_ASCII << @as(c_int, 1);
pub const ONIG_OPTION_SPACE_IS_ASCII = ONIG_OPTION_DIGIT_IS_ASCII << @as(c_int, 1);
pub const ONIG_OPTION_POSIX_IS_ASCII = ONIG_OPTION_SPACE_IS_ASCII << @as(c_int, 1);
pub const ONIG_OPTION_TEXT_SEGMENT_EXTENDED_GRAPHEME_CLUSTER = ONIG_OPTION_POSIX_IS_ASCII << @as(c_int, 1);
pub const ONIG_OPTION_TEXT_SEGMENT_WORD = ONIG_OPTION_TEXT_SEGMENT_EXTENDED_GRAPHEME_CLUSTER << @as(c_int, 1);
pub const ONIG_OPTION_NOT_BEGIN_STRING = ONIG_OPTION_TEXT_SEGMENT_WORD << @as(c_int, 1);
pub const ONIG_OPTION_NOT_END_STRING = ONIG_OPTION_NOT_BEGIN_STRING << @as(c_int, 1);
pub const ONIG_OPTION_NOT_BEGIN_POSITION = ONIG_OPTION_NOT_END_STRING << @as(c_int, 1);
pub const ONIG_OPTION_CALLBACK_EACH_MATCH = ONIG_OPTION_NOT_BEGIN_POSITION << @as(c_int, 1);
pub const ONIG_OPTION_MATCH_WHOLE_STRING = ONIG_OPTION_CALLBACK_EACH_MATCH << @as(c_int, 1);
pub const ONIG_OPTION_MAXBIT = ONIG_OPTION_MATCH_WHOLE_STRING;
pub const ONIG_OPTION_ON = @compileError("unable to translate C expr: expected ')' instead got '|='");
// /usr/include/oniguruma.h:408:9
pub const ONIG_OPTION_OFF = @compileError("unable to translate C expr: expected ')' instead got '&='");
// /usr/include/oniguruma.h:409:9
pub inline fn ONIG_IS_OPTION_ON(options: anytype, option: anytype) @TypeOf(options & option) {
    _ = &options;
    _ = &option;
    return options & option;
}

// /usr/include/oniguruma.h:435:9: warning: macro 'ONIG_SYNTAX_ASIS' contains a runtime value, translated to function
pub inline fn ONIG_SYNTAX_ASIS() @TypeOf(&OnigSyntaxASIS) {
    return &OnigSyntaxASIS;
}

// /usr/include/oniguruma.h:436:9: warning: macro 'ONIG_SYNTAX_POSIX_BASIC' contains a runtime value, translated to function
pub inline fn ONIG_SYNTAX_POSIX_BASIC() @TypeOf(&OnigSyntaxPosixBasic) {
    return &OnigSyntaxPosixBasic;
}

// /usr/include/oniguruma.h:437:9: warning: macro 'ONIG_SYNTAX_POSIX_EXTENDED' contains a runtime value, translated to function
pub inline fn ONIG_SYNTAX_POSIX_EXTENDED() @TypeOf(&OnigSyntaxPosixExtended) {
    return &OnigSyntaxPosixExtended;
}

// /usr/include/oniguruma.h:438:9: warning: macro 'ONIG_SYNTAX_EMACS' contains a runtime value, translated to function
pub inline fn ONIG_SYNTAX_EMACS() @TypeOf(&OnigSyntaxEmacs) {
    return &OnigSyntaxEmacs;
}

// /usr/include/oniguruma.h:439:9: warning: macro 'ONIG_SYNTAX_GREP' contains a runtime value, translated to function
pub inline fn ONIG_SYNTAX_GREP() @TypeOf(&OnigSyntaxGrep) {
    return &OnigSyntaxGrep;
}

// /usr/include/oniguruma.h:440:9: warning: macro 'ONIG_SYNTAX_GNU_REGEX' contains a runtime value, translated to function
pub inline fn ONIG_SYNTAX_GNU_REGEX() @TypeOf(&OnigSyntaxGnuRegex) {
    return &OnigSyntaxGnuRegex;
}

// /usr/include/oniguruma.h:441:9: warning: macro 'ONIG_SYNTAX_JAVA' contains a runtime value, translated to function
pub inline fn ONIG_SYNTAX_JAVA() @TypeOf(&OnigSyntaxJava) {
    return &OnigSyntaxJava;
}

// /usr/include/oniguruma.h:442:9: warning: macro 'ONIG_SYNTAX_PERL' contains a runtime value, translated to function
pub inline fn ONIG_SYNTAX_PERL() @TypeOf(&OnigSyntaxPerl) {
    return &OnigSyntaxPerl;
}

// /usr/include/oniguruma.h:443:9: warning: macro 'ONIG_SYNTAX_PERL_NG' contains a runtime value, translated to function
pub inline fn ONIG_SYNTAX_PERL_NG() @TypeOf(&OnigSyntaxPerl_NG) {
    return &OnigSyntaxPerl_NG;
}

// /usr/include/oniguruma.h:444:9: warning: macro 'ONIG_SYNTAX_RUBY' contains a runtime value, translated to function
pub inline fn ONIG_SYNTAX_RUBY() @TypeOf(&OnigSyntaxRuby) {
    return &OnigSyntaxRuby;
}

// /usr/include/oniguruma.h:445:9: warning: macro 'ONIG_SYNTAX_PYTHON' contains a runtime value, translated to function
pub inline fn ONIG_SYNTAX_PYTHON() @TypeOf(&OnigSyntaxPython) {
    return &OnigSyntaxPython;
}

// /usr/include/oniguruma.h:446:9: warning: macro 'ONIG_SYNTAX_ONIGURUMA' contains a runtime value, translated to function
pub inline fn ONIG_SYNTAX_ONIGURUMA() @TypeOf(&OnigSyntaxOniguruma) {
    return &OnigSyntaxOniguruma;
}

// /usr/include/oniguruma.h:450:9: warning: macro 'ONIG_SYNTAX_DEFAULT' contains a runtime value, translated to function
pub inline fn ONIG_SYNTAX_DEFAULT() @TypeOf(OnigDefaultSyntax) {
    return OnigDefaultSyntax;
}
pub const ONIG_SYN_OP_VARIABLE_META_CHARACTERS = @as(c_uint, 1) << @as(c_int, 0);
pub const ONIG_SYN_OP_DOT_ANYCHAR = @as(c_uint, 1) << @as(c_int, 1);
pub const ONIG_SYN_OP_ASTERISK_ZERO_INF = @as(c_uint, 1) << @as(c_int, 2);
pub const ONIG_SYN_OP_ESC_ASTERISK_ZERO_INF = @as(c_uint, 1) << @as(c_int, 3);
pub const ONIG_SYN_OP_PLUS_ONE_INF = @as(c_uint, 1) << @as(c_int, 4);
pub const ONIG_SYN_OP_ESC_PLUS_ONE_INF = @as(c_uint, 1) << @as(c_int, 5);
pub const ONIG_SYN_OP_QMARK_ZERO_ONE = @as(c_uint, 1) << @as(c_int, 6);
pub const ONIG_SYN_OP_ESC_QMARK_ZERO_ONE = @as(c_uint, 1) << @as(c_int, 7);
pub const ONIG_SYN_OP_BRACE_INTERVAL = @as(c_uint, 1) << @as(c_int, 8);
pub const ONIG_SYN_OP_ESC_BRACE_INTERVAL = @as(c_uint, 1) << @as(c_int, 9);
pub const ONIG_SYN_OP_VBAR_ALT = @as(c_uint, 1) << @as(c_int, 10);
pub const ONIG_SYN_OP_ESC_VBAR_ALT = @as(c_uint, 1) << @as(c_int, 11);
pub const ONIG_SYN_OP_LPAREN_SUBEXP = @as(c_uint, 1) << @as(c_int, 12);
pub const ONIG_SYN_OP_ESC_LPAREN_SUBEXP = @as(c_uint, 1) << @as(c_int, 13);
pub const ONIG_SYN_OP_ESC_AZ_BUF_ANCHOR = @as(c_uint, 1) << @as(c_int, 14);
pub const ONIG_SYN_OP_ESC_CAPITAL_G_BEGIN_ANCHOR = @as(c_uint, 1) << @as(c_int, 15);
pub const ONIG_SYN_OP_DECIMAL_BACKREF = @as(c_uint, 1) << @as(c_int, 16);
pub const ONIG_SYN_OP_BRACKET_CC = @as(c_uint, 1) << @as(c_int, 17);
pub const ONIG_SYN_OP_ESC_W_WORD = @as(c_uint, 1) << @as(c_int, 18);
pub const ONIG_SYN_OP_ESC_LTGT_WORD_BEGIN_END = @as(c_uint, 1) << @as(c_int, 19);
pub const ONIG_SYN_OP_ESC_B_WORD_BOUND = @as(c_uint, 1) << @as(c_int, 20);
pub const ONIG_SYN_OP_ESC_S_WHITE_SPACE = @as(c_uint, 1) << @as(c_int, 21);
pub const ONIG_SYN_OP_ESC_D_DIGIT = @as(c_uint, 1) << @as(c_int, 22);
pub const ONIG_SYN_OP_LINE_ANCHOR = @as(c_uint, 1) << @as(c_int, 23);
pub const ONIG_SYN_OP_POSIX_BRACKET = @as(c_uint, 1) << @as(c_int, 24);
pub const ONIG_SYN_OP_QMARK_NON_GREEDY = @as(c_uint, 1) << @as(c_int, 25);
pub const ONIG_SYN_OP_ESC_CONTROL_CHARS = @as(c_uint, 1) << @as(c_int, 26);
pub const ONIG_SYN_OP_ESC_C_CONTROL = @as(c_uint, 1) << @as(c_int, 27);
pub const ONIG_SYN_OP_ESC_OCTAL3 = @as(c_uint, 1) << @as(c_int, 28);
pub const ONIG_SYN_OP_ESC_X_HEX2 = @as(c_uint, 1) << @as(c_int, 29);
pub const ONIG_SYN_OP_ESC_X_BRACE_HEX8 = @as(c_uint, 1) << @as(c_int, 30);
pub const ONIG_SYN_OP_ESC_O_BRACE_OCTAL = @as(c_uint, 1) << @as(c_int, 31);
pub const ONIG_SYN_OP2_ESC_CAPITAL_Q_QUOTE = @as(c_uint, 1) << @as(c_int, 0);
pub const ONIG_SYN_OP2_QMARK_GROUP_EFFECT = @as(c_uint, 1) << @as(c_int, 1);
pub const ONIG_SYN_OP2_OPTION_PERL = @as(c_uint, 1) << @as(c_int, 2);
pub const ONIG_SYN_OP2_OPTION_RUBY = @as(c_uint, 1) << @as(c_int, 3);
pub const ONIG_SYN_OP2_PLUS_POSSESSIVE_REPEAT = @as(c_uint, 1) << @as(c_int, 4);
pub const ONIG_SYN_OP2_PLUS_POSSESSIVE_INTERVAL = @as(c_uint, 1) << @as(c_int, 5);
pub const ONIG_SYN_OP2_CCLASS_SET_OP = @as(c_uint, 1) << @as(c_int, 6);
pub const ONIG_SYN_OP2_QMARK_LT_NAMED_GROUP = @as(c_uint, 1) << @as(c_int, 7);
pub const ONIG_SYN_OP2_ESC_K_NAMED_BACKREF = @as(c_uint, 1) << @as(c_int, 8);
pub const ONIG_SYN_OP2_ESC_G_SUBEXP_CALL = @as(c_uint, 1) << @as(c_int, 9);
pub const ONIG_SYN_OP2_ATMARK_CAPTURE_HISTORY = @as(c_uint, 1) << @as(c_int, 10);
pub const ONIG_SYN_OP2_ESC_CAPITAL_C_BAR_CONTROL = @as(c_uint, 1) << @as(c_int, 11);
pub const ONIG_SYN_OP2_ESC_CAPITAL_M_BAR_META = @as(c_uint, 1) << @as(c_int, 12);
pub const ONIG_SYN_OP2_ESC_V_VTAB = @as(c_uint, 1) << @as(c_int, 13);
pub const ONIG_SYN_OP2_ESC_U_HEX4 = @as(c_uint, 1) << @as(c_int, 14);
pub const ONIG_SYN_OP2_ESC_GNU_BUF_ANCHOR = @as(c_uint, 1) << @as(c_int, 15);
pub const ONIG_SYN_OP2_ESC_P_BRACE_CHAR_PROPERTY = @as(c_uint, 1) << @as(c_int, 16);
pub const ONIG_SYN_OP2_ESC_P_BRACE_CIRCUMFLEX_NOT = @as(c_uint, 1) << @as(c_int, 17);
pub const ONIG_SYN_OP2_ESC_H_XDIGIT = @as(c_uint, 1) << @as(c_int, 19);
pub const ONIG_SYN_OP2_INEFFECTIVE_ESCAPE = @as(c_uint, 1) << @as(c_int, 20);
pub const ONIG_SYN_OP2_QMARK_LPAREN_IF_ELSE = @as(c_uint, 1) << @as(c_int, 21);
pub const ONIG_SYN_OP2_ESC_CAPITAL_K_KEEP = @as(c_uint, 1) << @as(c_int, 22);
pub const ONIG_SYN_OP2_ESC_CAPITAL_R_GENERAL_NEWLINE = @as(c_uint, 1) << @as(c_int, 23);
pub const ONIG_SYN_OP2_ESC_CAPITAL_N_O_SUPER_DOT = @as(c_uint, 1) << @as(c_int, 24);
pub const ONIG_SYN_OP2_QMARK_TILDE_ABSENT_GROUP = @as(c_uint, 1) << @as(c_int, 25);
pub const ONIG_SYN_OP2_ESC_X_Y_GRAPHEME_CLUSTER = @as(c_uint, 1) << @as(c_int, 26);
pub const ONIG_SYN_OP2_ESC_X_Y_TEXT_SEGMENT = @as(c_uint, 1) << @as(c_int, 26);
pub const ONIG_SYN_OP2_QMARK_PERL_SUBEXP_CALL = @as(c_uint, 1) << @as(c_int, 27);
pub const ONIG_SYN_OP2_QMARK_BRACE_CALLOUT_CONTENTS = @as(c_uint, 1) << @as(c_int, 28);
pub const ONIG_SYN_OP2_ASTERISK_CALLOUT_NAME = @as(c_uint, 1) << @as(c_int, 29);
pub const ONIG_SYN_OP2_OPTION_ONIGURUMA = @as(c_uint, 1) << @as(c_int, 30);
pub const ONIG_SYN_OP2_QMARK_CAPITAL_P_NAME = @as(c_uint, 1) << @as(c_int, 31);
pub const ONIG_SYN_CONTEXT_INDEP_ANCHORS = @as(c_uint, 1) << @as(c_int, 31);
pub const ONIG_SYN_CONTEXT_INDEP_REPEAT_OPS = @as(c_uint, 1) << @as(c_int, 0);
pub const ONIG_SYN_CONTEXT_INVALID_REPEAT_OPS = @as(c_uint, 1) << @as(c_int, 1);
pub const ONIG_SYN_ALLOW_UNMATCHED_CLOSE_SUBEXP = @as(c_uint, 1) << @as(c_int, 2);
pub const ONIG_SYN_ALLOW_INVALID_INTERVAL = @as(c_uint, 1) << @as(c_int, 3);
pub const ONIG_SYN_ALLOW_INTERVAL_LOW_ABBREV = @as(c_uint, 1) << @as(c_int, 4);
pub const ONIG_SYN_STRICT_CHECK_BACKREF = @as(c_uint, 1) << @as(c_int, 5);
pub const ONIG_SYN_DIFFERENT_LEN_ALT_LOOK_BEHIND = @as(c_uint, 1) << @as(c_int, 6);
pub const ONIG_SYN_CAPTURE_ONLY_NAMED_GROUP = @as(c_uint, 1) << @as(c_int, 7);
pub const ONIG_SYN_ALLOW_MULTIPLEX_DEFINITION_NAME = @as(c_uint, 1) << @as(c_int, 8);
pub const ONIG_SYN_FIXED_INTERVAL_IS_GREEDY_ONLY = @as(c_uint, 1) << @as(c_int, 9);
pub const ONIG_SYN_ISOLATED_OPTION_CONTINUE_BRANCH = @as(c_uint, 1) << @as(c_int, 10);
pub const ONIG_SYN_VARIABLE_LEN_LOOK_BEHIND = @as(c_uint, 1) << @as(c_int, 11);
pub const ONIG_SYN_PYTHON = @as(c_uint, 1) << @as(c_int, 12);
pub const ONIG_SYN_WHOLE_OPTIONS = @as(c_uint, 1) << @as(c_int, 13);
pub const ONIG_SYN_BRE_ANCHOR_AT_EDGE_OF_SUBEXP = @as(c_uint, 1) << @as(c_int, 14);
pub const ONIG_SYN_NOT_NEWLINE_IN_NEGATIVE_CC = @as(c_uint, 1) << @as(c_int, 20);
pub const ONIG_SYN_BACKSLASH_ESCAPE_IN_CC = @as(c_uint, 1) << @as(c_int, 21);
pub const ONIG_SYN_ALLOW_EMPTY_RANGE_IN_CC = @as(c_uint, 1) << @as(c_int, 22);
pub const ONIG_SYN_ALLOW_DOUBLE_RANGE_OP_IN_CC = @as(c_uint, 1) << @as(c_int, 23);
pub const ONIG_SYN_ALLOW_INVALID_CODE_END_OF_RANGE_IN_CC = @as(c_uint, 1) << @as(c_int, 26);
pub const ONIG_SYN_WARN_CC_OP_NOT_ESCAPED = @as(c_uint, 1) << @as(c_int, 24);
pub const ONIG_SYN_WARN_REDUNDANT_NESTED_REPEAT = @as(c_uint, 1) << @as(c_int, 25);
pub const ONIG_META_CHAR_ESCAPE = @as(c_int, 0);
pub const ONIG_META_CHAR_ANYCHAR = @as(c_int, 1);
pub const ONIG_META_CHAR_ANYTIME = @as(c_int, 2);
pub const ONIG_META_CHAR_ZERO_OR_ONE_TIME = @as(c_int, 3);
pub const ONIG_META_CHAR_ONE_OR_MORE_TIME = @as(c_int, 4);
pub const ONIG_META_CHAR_ANYCHAR_ANYTIME = @as(c_int, 5);
pub const ONIG_INEFFECTIVE_META_CHAR = @as(c_int, 0);
pub inline fn ONIG_IS_PATTERN_ERROR(ecode: anytype) @TypeOf((ecode <= -@as(c_int, 100)) and (ecode > -@as(c_int, 1000))) {
    _ = &ecode;
    return (ecode <= -@as(c_int, 100)) and (ecode > -@as(c_int, 1000));
}
pub const ONIG_NORMAL = @as(c_int, 0);
pub const ONIG_VALUE_IS_NOT_SET = @as(c_int, 1);
pub const ONIG_MISMATCH = -@as(c_int, 1);
pub const ONIG_NO_SUPPORT_CONFIG = -@as(c_int, 2);
pub const ONIG_ABORT = -@as(c_int, 3);
pub const ONIGERR_MEMORY = -@as(c_int, 5);
pub const ONIGERR_TYPE_BUG = -@as(c_int, 6);
pub const ONIGERR_PARSER_BUG = -@as(c_int, 11);
pub const ONIGERR_STACK_BUG = -@as(c_int, 12);
pub const ONIGERR_UNDEFINED_BYTECODE = -@as(c_int, 13);
pub const ONIGERR_UNEXPECTED_BYTECODE = -@as(c_int, 14);
pub const ONIGERR_MATCH_STACK_LIMIT_OVER = -@as(c_int, 15);
pub const ONIGERR_PARSE_DEPTH_LIMIT_OVER = -@as(c_int, 16);
pub const ONIGERR_RETRY_LIMIT_IN_MATCH_OVER = -@as(c_int, 17);
pub const ONIGERR_RETRY_LIMIT_IN_SEARCH_OVER = -@as(c_int, 18);
pub const ONIGERR_SUBEXP_CALL_LIMIT_IN_SEARCH_OVER = -@as(c_int, 19);
pub const ONIGERR_DEFAULT_ENCODING_IS_NOT_SETTED = -@as(c_int, 21);
pub const ONIGERR_DEFAULT_ENCODING_IS_NOT_SET = -@as(c_int, 21);
pub const ONIGERR_SPECIFIED_ENCODING_CANT_CONVERT_TO_WIDE_CHAR = -@as(c_int, 22);
pub const ONIGERR_FAIL_TO_INITIALIZE = -@as(c_int, 23);
pub const ONIGERR_INVALID_ARGUMENT = -@as(c_int, 30);
pub const ONIGERR_END_PATTERN_AT_LEFT_BRACE = -@as(c_int, 100);
pub const ONIGERR_END_PATTERN_AT_LEFT_BRACKET = -@as(c_int, 101);
pub const ONIGERR_EMPTY_CHAR_CLASS = -@as(c_int, 102);
pub const ONIGERR_PREMATURE_END_OF_CHAR_CLASS = -@as(c_int, 103);
pub const ONIGERR_END_PATTERN_AT_ESCAPE = -@as(c_int, 104);
pub const ONIGERR_END_PATTERN_AT_META = -@as(c_int, 105);
pub const ONIGERR_END_PATTERN_AT_CONTROL = -@as(c_int, 106);
pub const ONIGERR_META_CODE_SYNTAX = -@as(c_int, 108);
pub const ONIGERR_CONTROL_CODE_SYNTAX = -@as(c_int, 109);
pub const ONIGERR_CHAR_CLASS_VALUE_AT_END_OF_RANGE = -@as(c_int, 110);
pub const ONIGERR_CHAR_CLASS_VALUE_AT_START_OF_RANGE = -@as(c_int, 111);
pub const ONIGERR_UNMATCHED_RANGE_SPECIFIER_IN_CHAR_CLASS = -@as(c_int, 112);
pub const ONIGERR_TARGET_OF_REPEAT_OPERATOR_NOT_SPECIFIED = -@as(c_int, 113);
pub const ONIGERR_TARGET_OF_REPEAT_OPERATOR_INVALID = -@as(c_int, 114);
pub const ONIGERR_NESTED_REPEAT_OPERATOR = -@as(c_int, 115);
pub const ONIGERR_UNMATCHED_CLOSE_PARENTHESIS = -@as(c_int, 116);
pub const ONIGERR_END_PATTERN_WITH_UNMATCHED_PARENTHESIS = -@as(c_int, 117);
pub const ONIGERR_END_PATTERN_IN_GROUP = -@as(c_int, 118);
pub const ONIGERR_UNDEFINED_GROUP_OPTION = -@as(c_int, 119);
pub const ONIGERR_INVALID_GROUP_OPTION = -@as(c_int, 120);
pub const ONIGERR_INVALID_POSIX_BRACKET_TYPE = -@as(c_int, 121);
pub const ONIGERR_INVALID_LOOK_BEHIND_PATTERN = -@as(c_int, 122);
pub const ONIGERR_INVALID_REPEAT_RANGE_PATTERN = -@as(c_int, 123);
pub const ONIGERR_TOO_BIG_NUMBER = -@as(c_int, 200);
pub const ONIGERR_TOO_BIG_NUMBER_FOR_REPEAT_RANGE = -@as(c_int, 201);
pub const ONIGERR_UPPER_SMALLER_THAN_LOWER_IN_REPEAT_RANGE = -@as(c_int, 202);
pub const ONIGERR_EMPTY_RANGE_IN_CHAR_CLASS = -@as(c_int, 203);
pub const ONIGERR_MISMATCH_CODE_LENGTH_IN_CLASS_RANGE = -@as(c_int, 204);
pub const ONIGERR_TOO_MANY_MULTI_BYTE_RANGES = -@as(c_int, 205);
pub const ONIGERR_TOO_SHORT_MULTI_BYTE_STRING = -@as(c_int, 206);
pub const ONIGERR_TOO_BIG_BACKREF_NUMBER = -@as(c_int, 207);
pub const ONIGERR_INVALID_BACKREF = -@as(c_int, 208);
pub const ONIGERR_NUMBERED_BACKREF_OR_CALL_NOT_ALLOWED = -@as(c_int, 209);
pub const ONIGERR_TOO_MANY_CAPTURES = -@as(c_int, 210);
pub const ONIGERR_TOO_LONG_WIDE_CHAR_VALUE = -@as(c_int, 212);
pub const ONIGERR_UNDEFINED_OPERATOR = -@as(c_int, 213);
pub const ONIGERR_EMPTY_GROUP_NAME = -@as(c_int, 214);
pub const ONIGERR_INVALID_GROUP_NAME = -@as(c_int, 215);
pub const ONIGERR_INVALID_CHAR_IN_GROUP_NAME = -@as(c_int, 216);
pub const ONIGERR_UNDEFINED_NAME_REFERENCE = -@as(c_int, 217);
pub const ONIGERR_UNDEFINED_GROUP_REFERENCE = -@as(c_int, 218);
pub const ONIGERR_MULTIPLEX_DEFINED_NAME = -@as(c_int, 219);
pub const ONIGERR_MULTIPLEX_DEFINITION_NAME_CALL = -@as(c_int, 220);
pub const ONIGERR_NEVER_ENDING_RECURSION = -@as(c_int, 221);
pub const ONIGERR_GROUP_NUMBER_OVER_FOR_CAPTURE_HISTORY = -@as(c_int, 222);
pub const ONIGERR_INVALID_CHAR_PROPERTY_NAME = -@as(c_int, 223);
pub const ONIGERR_INVALID_IF_ELSE_SYNTAX = -@as(c_int, 224);
pub const ONIGERR_INVALID_ABSENT_GROUP_PATTERN = -@as(c_int, 225);
pub const ONIGERR_INVALID_ABSENT_GROUP_GENERATOR_PATTERN = -@as(c_int, 226);
pub const ONIGERR_INVALID_CALLOUT_PATTERN = -@as(c_int, 227);
pub const ONIGERR_INVALID_CALLOUT_NAME = -@as(c_int, 228);
pub const ONIGERR_UNDEFINED_CALLOUT_NAME = -@as(c_int, 229);
pub const ONIGERR_INVALID_CALLOUT_BODY = -@as(c_int, 230);
pub const ONIGERR_INVALID_CALLOUT_TAG_NAME = -@as(c_int, 231);
pub const ONIGERR_INVALID_CALLOUT_ARG = -@as(c_int, 232);
pub const ONIGERR_INVALID_CODE_POINT_VALUE = -@as(c_int, 400);
pub const ONIGERR_INVALID_WIDE_CHAR_VALUE = -@as(c_int, 400);
pub const ONIGERR_TOO_BIG_WIDE_CHAR_VALUE = -@as(c_int, 401);
pub const ONIGERR_NOT_SUPPORTED_ENCODING_COMBINATION = -@as(c_int, 402);
pub const ONIGERR_INVALID_COMBINATION_OF_OPTIONS = -@as(c_int, 403);
pub const ONIGERR_TOO_MANY_USER_DEFINED_OBJECTS = -@as(c_int, 404);
pub const ONIGERR_TOO_LONG_PROPERTY_NAME = -@as(c_int, 405);
pub const ONIGERR_VERY_INEFFICIENT_PATTERN = -@as(c_int, 406);
pub const ONIGERR_LIBRARY_IS_NOT_INITIALIZED = -@as(c_int, 500);
pub const ONIG_MAX_CAPTURE_HISTORY_GROUP = @as(c_int, 31);
pub inline fn ONIG_IS_CAPTURE_HISTORY_GROUP(r: anytype, i: anytype) @TypeOf(((i <= ONIG_MAX_CAPTURE_HISTORY_GROUP) and (r.*.list != 0)) and (r.*.list[@as(usize, @intCast(i))] != 0)) {
    _ = &r;
    _ = &i;
    return ((i <= ONIG_MAX_CAPTURE_HISTORY_GROUP) and (r.*.list != 0)) and (r.*.list[@as(usize, @intCast(i))] != 0);
}
pub const ONIG_TRAVERSE_CALLBACK_AT_FIRST = @as(c_int, 1);
pub const ONIG_TRAVERSE_CALLBACK_AT_LAST = @as(c_int, 2);
pub const ONIG_TRAVERSE_CALLBACK_AT_BOTH = ONIG_TRAVERSE_CALLBACK_AT_FIRST | ONIG_TRAVERSE_CALLBACK_AT_LAST;
pub const ONIG_REGION_NOTPOS = -@as(c_int, 1);
pub const ONIG_NULL_WARN = onig_null_warn;
pub const ONIG_CHAR_TABLE_SIZE = @as(c_int, 256);
pub const ONIG_CALLOUT_IN_BOTH = ONIG_CALLOUT_IN_PROGRESS | ONIG_CALLOUT_IN_RETRACTION;
pub const ONIG_NON_NAME_ID = -@as(c_int, 1);
pub const ONIG_NON_CALLOUT_NUM = @as(c_int, 0);
pub const ONIG_CALLOUT_MAX_ARGS_NUM = @as(c_int, 4);
pub const ONIG_CALLOUT_DATA_SLOT_NUM = @as(c_int, 5);
pub const OnigEncodingTypeST = struct_OnigEncodingTypeST;
pub const OnigCaptureTreeNodeStruct = struct_OnigCaptureTreeNodeStruct;
pub const re_registers = struct_re_registers;
pub const re_pattern_buffer = struct_re_pattern_buffer;
pub const OnigRegSetStruct = struct_OnigRegSetStruct;
pub const OnigCalloutArgsStruct = struct_OnigCalloutArgsStruct;
pub const OnigMatchParamStruct = struct_OnigMatchParamStruct;
