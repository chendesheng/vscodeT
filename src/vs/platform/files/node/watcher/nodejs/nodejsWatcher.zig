// Port of `src/vs/platform/files/node/watcher/nodejs/nodejsWatcher.ts`.
//
// The terminal manager and the per-path library live in
// `nodejsWatcherLib.zig`; this file keeps the upstream module boundary.
pub const NodeJSWatcher = @import("nodejsWatcherLib.zig").NodeJSWatcher;
