// Node launcher for the pinned VS Code extension host (docs/extensions.md §6).
//
// This replaces `src/vs/workbench/api/node/extensionHostProcess.ts`: it owns
// the fd 3/4 transport, the Ready/init-data/Initialized handshake and the
// trimmed service registrations, then hands the RPC stream to the unmodified
// upstream `ExtensionHostMain`. It does not vendor VS Code sources.
//
// A deliberate divergence from the real bootstrap: the `natives` blocklist
// and the process.exit/process.crash patches are not installed yet. See
// docs/extensions.md §16.

import * as fs from 'node:fs';
import * as net from 'node:net';
import { ExtensionHostMain } from '../../vscode/src/vs/workbench/api/common/extensionHostMain.js';
import type { IMessagePassingProtocol } from '../../vscode/src/vs/base/parts/ipc/common/ipc.js';
import type { IExtensionHostInitData } from '../../vscode/src/vs/workbench/services/extensions/common/extensionHostProtocol.js';
import { Promises } from '../../vscode/src/vs/base/node/pfs.js';
import '../../vscode/src/vs/workbench/api/common/extHost.common.services.js';
import '../../vscode/src/vs/workbench/api/node/extHost.node.services.js';
const PIPE_IN_FD = Number(process.env.VSCODE_EXTENSION_HOST_IN_FD ?? 3);
const PIPE_OUT_FD = Number(process.env.VSCODE_EXTENSION_HOST_OUT_FD ?? 4);
const MAX_FRAME = 64 * 1024 * 1024;

function log(message: string): void {
	// Use a raw write: ExtHostConsoleForwarder patches process.stderr.write
	// once the node extension service is constructed, and forwarding a log
	// would re-enter the RPC sender.
	try {
		fs.writeSync(2, `[extension-host] ${message}\n`);
	} catch {
		// stderr may be closed during shutdown.
	}
}

class FrameWriter {
	private readonly _stream: { write(chunk: Buffer, callback?: (error?: Error | null) => void): boolean };
	private readonly _pending: Buffer[] = [];
	private _writing = false;

	constructor(stream: { write(chunk: Buffer, callback?: (error?: Error | null) => void): boolean; on(event: 'error', listener: (err: Error) => void): unknown }) {
		this._stream = stream;
		this._stream.on('error', err => log(`write error: ${String(err)}`));
	}

	send(payload: Uint8Array | { buffer: Uint8Array; byteLength: number }): void {
		const bytes = payload instanceof Uint8Array ? payload : payload.buffer;
		if (bytes.byteLength > MAX_FRAME) {
			log(`refusing oversized frame (${bytes.byteLength} bytes)`);
			return;
		}
		const frame = Buffer.allocUnsafe(4 + bytes.byteLength);
		frame.writeUInt32BE(bytes.byteLength, 0);
		frame.set(bytes, 4);
		this._pending.push(frame);
		this._flush();
	}

	private _flush(): void {
		if (this._writing) {
			return;
		}
		const next = this._pending.shift();
		if (!next) {
			return;
		}
		this._writing = true;
		this._stream.write(next, () => {
			this._writing = false;
			this._flush();
		});
	}
}

class FrameReader {
	private _buffer: Buffer = Buffer.alloc(0);
	private readonly _onFrame: (payload: Uint8Array) => void;

	constructor(stream: { on(event: string, listener: (...args: any[]) => void): unknown }, onFrame: (payload: Uint8Array) => void) {
		this._onFrame = onFrame;
		stream.on('data', (chunk: Buffer | string) => {
			const data = typeof chunk === 'string' ? Buffer.from(chunk) : chunk;
			this._buffer = this._buffer.length === 0 ? data : Buffer.concat([this._buffer, data]);
			this._drain();
		});
		stream.on('end', () => {
			log('input closed');
			process.exit(0);
		});
		stream.on('error', err => {
			log(`read error: ${String(err)}`);
			process.exit(1);
		});
	}

	private _drain(): void {
		while (this._buffer.length >= 4) {
			const length = this._buffer.readUInt32BE(0);
			if (length > MAX_FRAME) {
				log(`received oversized frame (${length} bytes)`);
				process.exit(1);
			}
			if (this._buffer.length < 4 + length) {
				return;
			}
			const payload = this._buffer.subarray(4, 4 + length);
			this._buffer = this._buffer.subarray(4 + length);
			this._onFrame(payload);
		}
	}
}

class HostProtocol implements IMessagePassingProtocol {
	private readonly _writer: FrameWriter;
	private readonly _listeners = new Set<(message: Uint8Array) => void>();
	private _disposed = false;

	constructor(writer: FrameWriter) {
		this._writer = writer;
	}

	send(message: Uint8Array): void {
		if (!this._disposed) {
			this._writer.send(message);
		}
	}

	onMessage(listener: (message: Uint8Array) => void): { dispose(): void } {
		this._listeners.add(listener);
		return {
			dispose: () => {
				this._listeners.delete(listener);
			}
		};
	}

	dispatch(message: Uint8Array): void {
		if (this._disposed) {
			return;
		}
		for (const listener of this._listeners) {
			listener(message);
		}
	}

	dispose(): void {
		this._disposed = true;
		this._listeners.clear();
	}
}

const socketArg = process.argv.indexOf('--socket');
const socketPath = socketArg >= 0 ? process.argv[socketArg + 1] : process.env.VSCODE_EXTENSION_HOST_SOCKET;
let writer: FrameWriter;
let inputStream: { on(event: string, listener: (...args: any[]) => void): unknown; on(event: 'end', listener: () => void): unknown };
if (socketPath) {
	const socket = net.createConnection(socketPath);
	socket.on('error', err => log(`socket error: ${String(err)}`));
	writer = new FrameWriter(socket);
	inputStream = socket;
} else {
	writer = new FrameWriter(fs.createWriteStream('', { fd: PIPE_OUT_FD, autoClose: false }));
	inputStream = fs.createReadStream('', { fd: PIPE_IN_FD, autoClose: false });
	inputStream.on('end', () => {
		log('input closed');
		process.exit(0);
	});
	inputStream.on('error', (err: Error) => {
		log(`read error: ${String(err)}`);
		process.exit(1);
	});
}
const protocol = new HostProtocol(writer);
let main: ExtensionHostMain | null = null;
let initialized = false;

const reader = new FrameReader(inputStream, payload => {
	if (!initialized) {
		initialized = true;
		let initData: IExtensionHostInitData;
		try {
			initData = JSON.parse(Buffer.from(payload).toString('utf8'));
		} catch (err) {
			log(`invalid init data: ${String(err)}`);
			process.exit(1);
			return;
		}
		start(initData);
		return;
	}

	// The bootstrap filters Terminate before the RPC layer sees it. A
	// Terminate payload is a single byte with value 3.
	if (payload.length === 1 && payload[0] === 3) {
		main?.terminate('Extension host terminated by the workbench');
		return;
	}
	protocol.dispatch(payload);
});

// Ready is sent before the init data is read, and Initialized afterwards.
writer.send(Uint8Array.of(2));

function start(initData: IExtensionHostInitData): void {
	const hostUtils = {
		_serviceBrand: undefined,
		pid: process.pid,
		exit(code: number) {
			process.exit(code);
		},
		fsExists(path: string) {
			return Promises.exists(path);
		},
		fsRealpath(path: string) {
			return Promises.realpath(path);
		}
	};

	try {
		main = new ExtensionHostMain(protocol, initData, hostUtils, null);
	} catch (err) {
		log(`failed to create extension host: ${err instanceof Error ? err.stack ?? err.message : String(err)}`);
		process.exit(1);
		return;
	}

	log(`initialized pid=${process.pid}`);
	writer.send(Uint8Array.of(1));
}

process.on('unhandledRejection', err => {
	log(`unhandled rejection: ${err instanceof Error ? err.stack ?? err.message : String(err)}`);
});
process.on('uncaughtException', err => {
	log(`uncaught exception: ${err instanceof Error ? err.stack ?? err.message : String(err)}`);
});

void reader;
