// Port of the verification service boundary in
// `src/vs/platform/extensionManagement/node/extensionSignatureVerificationService.ts`.
// Open VSX signs the raw VSIX using its registry's Ed25519 key, unlike the
// proprietary Marketplace PKCS#7 verifier. See the Eclipse Open VSX CLI's
// `cli/src/verify.ts` and registry metadata contract. The Zig implementation
// verifies the exact downloaded bytes before the staged package is published.
const std = @import("std");
const gallery = @import("../common/extensionGalleryService.zig");
const Ed25519 = std.crypto.sign.Ed25519;
const Allocator = std.mem.Allocator;

pub const VerificationStatus = enum { verified, not_signed, unsupported_gallery };

pub fn supportsGallery(service_url: []const u8) bool {
    const url = std.mem.trimEnd(u8, service_url, "/");
    return std.mem.startsWith(u8, url, "https://") and std.mem.endsWith(u8, url, "/vscode/gallery");
}

fn parsePublicKey(pem: []const u8) !Ed25519.PublicKey {
    const header = "-----BEGIN PUBLIC KEY-----";
    const footer = "-----END PUBLIC KEY-----";
    const value = std.mem.trim(u8, pem, " \t\r\n");
    if (!std.mem.startsWith(u8, value, header) or !std.mem.endsWith(u8, value, footer)) return error.InvalidExtensionSigningKey;
    const body = value[header.len .. value.len - footer.len];
    // Ed25519 SubjectPublicKeyInfo: SEQUENCE(AlgorithmIdentifier(OID
    // 1.3.101.112), BIT STRING(0 unused bits, 32 public key bytes)).
    const prefix = [_]u8{ 0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00 };
    var encoded: [60]u8 = undefined;
    var length: usize = 0;
    for (body) |ch| {
        if (std.ascii.isWhitespace(ch)) continue;
        if (length == encoded.len) return error.InvalidExtensionSigningKey;
        encoded[length] = ch;
        length += 1;
    }
    const decoder = std.base64.standard.Decoder;
    if (try decoder.calcSizeForSlice(encoded[0..length]) != prefix.len + Ed25519.PublicKey.encoded_length) return error.InvalidExtensionSigningKey;
    var der: [prefix.len + Ed25519.PublicKey.encoded_length]u8 = undefined;
    try decoder.decode(&der, encoded[0..length]);
    if (!std.mem.eql(u8, der[0..prefix.len], &prefix)) return error.InvalidExtensionSigningKey;
    return Ed25519.PublicKey.fromBytes(der[prefix.len..].*);
}

pub fn verifyBytes(package: []const u8, signature: []const u8, pem: []const u8) !void {
    if (signature.len != Ed25519.Signature.encoded_length) return error.InvalidExtensionSignature;
    const key = try parsePublicKey(pem);
    const signed = Ed25519.Signature.fromBytes(signature[0..Ed25519.Signature.encoded_length].*);
    signed.verifyStrict(package, key) catch return error.ExtensionSignatureVerificationFailed;
}

fn readSignature(io: std.Io, stage: std.Io.Dir, archive_bytes: []const u8) ![Ed25519.Signature.encoded_length]u8 {
    if (archive_bytes.len > 16 * 1024 * 1024) return error.InvalidExtensionSignature;
    try stage.writeFile(io, .{ .sub_path = "signature.sigzip", .data = archive_bytes });
    defer stage.deleteFile(io, "signature.sigzip") catch {};
    const file = try stage.openFile(io, "signature.sigzip", .{});
    defer file.close(io);
    var buffer: [8192]u8 = undefined;
    var reader = file.reader(io, &buffer);
    var iterator = try std.zip.Iterator.init(&reader);
    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    var result: ?[Ed25519.Signature.encoded_length]u8 = null;
    while (try iterator.next()) |entry| {
        const name = try entry.getFilename(&reader, &name_buf, .{});
        if (!std.mem.eql(u8, name, ".signature.sig")) continue;
        if (result != null or entry.uncompressed_size != Ed25519.Signature.encoded_length) return error.InvalidExtensionSignature;
        var data: [Ed25519.Signature.encoded_length]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&data);
        try entry.extractTo(&reader, &writer);
        if (writer.end != data.len or std.hash.Crc32.hash(&data) != entry.crc32) return error.InvalidExtensionSignature;
        result = data;
    }
    return result orelse error.InvalidExtensionSignature;
}

const Metadata = struct {
    namespace: []const u8,
    name: []const u8,
    version: []const u8,
    files: struct { signature: ?[]const u8 = null, publicKey: ?[]const u8 = null },
};

/// The metadata comes from the configured Open VSX API origin, not from the
/// extension package. This also supports a private HTTPS Open VSX registry.
/// A missing signature is distinguished from a failed verification; callers
/// decide whether an unsigned package can be explicitly installed.
pub fn verify(allocator: Allocator, io: std.Io, stage: std.Io.Dir, service_url: []const u8, identifier: []const u8, version: []const u8, target: ?[]const u8, package: []const u8) !VerificationStatus {
    if (!supportsGallery(service_url)) return .unsupported_gallery;
    const url = std.mem.trimEnd(u8, service_url, "/");
    const base = url[0 .. url.len - "/vscode/gallery".len];
    const dot = std.mem.indexOfScalar(u8, identifier, '.') orelse return error.InvalidExtensionIdentifier;
    const namespace = identifier[0..dot];
    const name = identifier[dot + 1 ..];
    // Identifier/version/target originate from the validated manifest and
    // selected gallery version, not an arbitrary user-supplied URL path.
    for ([_][]const u8{ namespace, name, version, target orelse "universal" }) |segment| {
        if (segment.len == 0 or std.mem.indexOfAny(u8, segment, "/\\?#%") != null) return error.InvalidExtensionIdentifier;
    }
    const metadata_url = if (target) |platform| try std.fmt.allocPrint(allocator, "{s}/api/{s}/{s}/{s}/{s}", .{ base, namespace, name, platform, version }) else try std.fmt.allocPrint(allocator, "{s}/api/{s}/{s}/{s}", .{ base, namespace, name, version });
    defer allocator.free(metadata_url);
    const metadata_bytes = try gallery.getAsset(allocator, io, metadata_url);
    defer allocator.free(metadata_bytes);
    const metadata = try std.json.parseFromSlice(Metadata, allocator, metadata_bytes, .{ .ignore_unknown_fields = true });
    defer metadata.deinit();
    if (!std.ascii.eqlIgnoreCase(metadata.value.namespace, namespace) or !std.ascii.eqlIgnoreCase(metadata.value.name, name) or !std.mem.eql(u8, metadata.value.version, version)) return error.ExtensionSignatureMetadataMismatch;
    const files = metadata.value.files;
    if (files.signature == null and files.publicKey == null) return .not_signed;
    const signature_url = files.signature orelse return error.InvalidExtensionSignature;
    const key_url = files.publicKey orelse return error.InvalidExtensionSigningKey;
    if (!std.mem.startsWith(u8, signature_url, "https://") or !std.mem.startsWith(u8, key_url, "https://")) return error.InsecureExtensionSignatureAsset;
    const archive = try gallery.getAsset(allocator, io, signature_url);
    defer allocator.free(archive);
    const key = try gallery.getAsset(allocator, io, key_url);
    defer allocator.free(key);
    const signature = try readSignature(io, stage, archive);
    try verifyBytes(package, &signature, key);
    return .verified;
}

test "ExtensionSignatureVerificationService: verifies package bytes and rejects tampering" {
    const pair = try Ed25519.KeyPair.generateDeterministic(@splat(0x42));
    const package = "fixture VSIX bytes";
    const signature = try pair.sign(package, null);
    const prefix = [_]u8{ 0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00 };
    const der = prefix ++ pair.public_key.toBytes();
    var encoded: [std.base64.standard.Encoder.calcSize(der.len)]u8 = undefined;
    const body = std.base64.standard.Encoder.encode(&encoded, &der);
    var buffer: [256]u8 = undefined;
    const pem = try std.fmt.bufPrint(&buffer, "-----BEGIN PUBLIC KEY-----\n{s}\n-----END PUBLIC KEY-----\n", .{body});
    try verifyBytes(package, &signature.toBytes(), pem);
    try std.testing.expectError(error.ExtensionSignatureVerificationFailed, verifyBytes("changed bytes", &signature.toBytes(), pem));
    try std.testing.expect(supportsGallery("https://open-vsx.org/vscode/gallery"));
    try std.testing.expect(!supportsGallery("https://marketplace.visualstudio.com/_apis/public/gallery"));
}
