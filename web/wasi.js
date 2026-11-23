// Minimal WASI preview1 shim for the editor wasm module.
//
// The browser demo only needs the clock, randomness and stdio. It deliberately
// does not provide a filesystem: the editor is opened from memory with a
// virtual absolute path, and the host never reads a file. Unsupported calls
// fail with WASI `BADF` so a ported code path that unexpectedly reaches the
// filesystem produces an error instead of silently blocking.

const ERRNO_BADF = 8;
const ERRNO_NOSYS = 52;

function view(memory, ptr, len) {
  return new Uint8Array(memory.buffer, ptr, len);
}

/**
 * @param {() => WebAssembly.Memory} getMemory
 * @returns {Record<string, (...args: number[]) => number>}
 */
export function createWasiImports(getMemory) {
  const memory = () => {
    const mem = getMemory();
    if (!mem) throw new Error("wasm memory is not available yet");
    return mem;
  };
  const data = () => new DataView(memory().buffer);
  const putU32 = (ptr, value) => data().setUint32(ptr, value >>> 0, true);
  const putU64 = (ptr, value) => data().setBigUint64(ptr, BigInt(value), true);

  return {
    args_sizes_get(argcPtr, argvBufSizePtr) {
      putU32(argcPtr, 0);
      putU32(argvBufSizePtr, 0);
      return 0;
    },
    args_get() {
      return 0;
    },
    environ_sizes_get(countPtr, bufSizePtr) {
      putU32(countPtr, 0);
      putU32(bufSizePtr, 0);
      return 0;
    },
    environ_get() {
      return 0;
    },
    clock_res_get(_id, outPtr) {
      putU64(outPtr, 1000); // 1 microsecond
      return 0;
    },
    clock_time_get(id, _precision, outPtr) {
      // 0 = realtime, 1 = monotonic. Date.now()/performance.now() are
      // millisecond-resolution; scale to nanoseconds.
      const ms = id === 0 ? Date.now() : performance.now();
      putU64(outPtr, Math.round(ms * 1_000_000));
      return 0;
    },
    random_get(ptr, len) {
      const bytes = view(memory(), ptr, len);
      if (globalThis.crypto?.getRandomValues) {
        globalThis.crypto.getRandomValues(bytes);
      } else {
        for (let i = 0; i < bytes.length; i++) bytes[i] = Math.floor(Math.random() * 256);
      }
      return 0;
    },
    fd_write(_fd, iovsPtr, iovsLen, nwrittenPtr) {
      const dv = data();
      let written = 0;
      let text = "";
      for (let i = 0; i < iovsLen; i++) {
        const base = iovsPtr + i * 8;
        const ptr = dv.getUint32(base, true);
        const len = dv.getUint32(base + 4, true);
        if (len === 0) continue;
        const bytes = view(memory(), ptr, len);
        text += new TextDecoder().decode(bytes);
        written += len;
      }
      putU32(nwrittenPtr, written);
      if (text && globalThis.__VSCODET_WASI_DEBUG__) {
        console.debug("[wasi]", text);
      }
      return 0;
    },
    fd_fdstat_get(_fd, ptr) {
      // __wasi_fdstat_t: filetype (u8), flags (u16), rights (u64 * 2).
      const bytes = view(memory(), ptr, 24);
      bytes.fill(0);
      bytes[0] = 2; // character device
      return 0;
    },
    fd_fdstat_set_flags() {
      return 0;
    },
    fd_close() {
      return 0;
    },
    fd_seek() {
      return ERRNO_BADF;
    },
    fd_read() {
      return ERRNO_BADF;
    },
    fd_pread() {
      return ERRNO_BADF;
    },
    fd_pwrite() {
      return ERRNO_BADF;
    },
    fd_advise() {
      return 0;
    },
    fd_allocate() {
      return ERRNO_BADF;
    },
    fd_datasync() {
      return 0;
    },
    fd_sync() {
      return 0;
    },
    fd_filestat_get() {
      return ERRNO_BADF;
    },
    fd_filestat_set_size() {
      return ERRNO_BADF;
    },
    fd_filestat_set_times() {
      return ERRNO_BADF;
    },
    fd_prestat_get() {
      return ERRNO_BADF;
    },
    fd_prestat_dir_name() {
      return ERRNO_BADF;
    },
    fd_readdir() {
      return ERRNO_BADF;
    },
    path_open() {
      return ERRNO_BADF;
    },
    path_create_directory() {
      return ERRNO_BADF;
    },
    path_filestat_get() {
      return ERRNO_BADF;
    },
    path_filestat_set_times() {
      return ERRNO_BADF;
    },
    path_link() {
      return ERRNO_BADF;
    },
    path_readlink() {
      return ERRNO_BADF;
    },
    path_symlink() {
      return ERRNO_BADF;
    },
    path_unlink_file() {
      return ERRNO_BADF;
    },
    path_remove_directory() {
      return ERRNO_BADF;
    },
    path_rename() {
      return ERRNO_BADF;
    },
    sched_yield() {
      return 0;
    },
    poll_oneoff(_subscriptions, eventsPtr, _count) {
      putU32(eventsPtr, 0);
      return 0;
    },
    proc_exit(code) {
      throw new Error(`editor.wasm exited with code ${code}`);
    },
  };
}

export { ERRNO_BADF, ERRNO_NOSYS };
