// based on https://github.com/tailscale/tailscale/blob/v1.84.3/util/truncate/truncate.go
// String returns a prefix of a UTF-8 string s, having length no greater than n
// bytes. If s exceeds this length, it is truncated at a point ≤ n so that the
// result does not end in a partial UTF-8 encoding.  If s is less than or equal
// to this length, it is returned unmodified.
pub fn safeUtf8Prefix(str: []const u8, limit: usize) []const u8 {
    var n = limit;
    if (n >= str.len) {
        return str;
    }

    // Back up until we find the beginning of a UTF-8 encoding.
    while (n > 0 and (str[n - 1] & 0b1100_0000) == 0b1000_0000) : (n -= 1) {}

    // If we're at the beginning of a multi-byte encoding, back up one more to
    // skip it. It's possible the value was already complete, but it's simpler
    // if we only have to check in one direction.
    //
    // Otherwise, we have a single-byte code (0x00... or 0x01...).
    if (n > 0 and (str[n - 1] & 0b1100_0000) == 0b1100_0000) { // 0x11... starts a multibyte encoding
        n -= 1;
    }
    return str[0..n];
}
