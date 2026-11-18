#!/usr/bin/env node
// Standalone interop harness for the Node extension host. It plays the
// workbench side of the wire protocol (docs/extensions.md §6.5) without Zig,
// so the launcher and the pinned host can be debugged independently.
//
//   node host/test-host.js [extensionPath]
//
// The default extension is the extracted VSCodeVim fixture under
// .cache-ext/vim/extension (see docs/extensions.md §15.2).

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { pathToFileURL } = require('node:url');

const repoRoot = path.resolve(__dirname, '..');
const extensionPath = path.resolve(process.argv[2] ?? path.join(repoRoot, '.cache-ext/vim/extension'));

const MessageType = {
	RequestJSONArgs: 1,
	RequestJSONArgsWithCancellation: 2,
	RequestMixedArgs: 3,
	RequestMixedArgsWithCancellation: 4,
	Acknowledged: 5,
	Cancel: 6,
	ReplyOKEmpty: 7,
	ReplyOKVSBuffer: 8,
	ReplyOKJSON: 9,
	ReplyOKJSONWithBuffers: 10,
	ReplyErrError: 11,
	ReplyErrEmpty: 12
};

function readManifest() {
	const file = path.join(repoRoot, 'src/vs/workbench/api/common/extHost.protocol.manifest.txt');
	const actors = new Map();
	for (const line of fs.readFileSync(file, 'utf8').split('\n')) {
		if (!line || line.startsWith('#')) {
			continue;
		}
		const [nid, key, sid] = line.split('\t');
		actors.set(Number(nid), { key, sid });
	}
	return actors;
}

const actors = readManifest();

function actorName(nid) {
	return actors.get(nid)?.sid ?? `nid:${nid}`;
}

function shortString(value) {
	const bytes = Buffer.from(value, 'utf8');
	if (bytes.length > 255) {
		throw new Error(`short string too long: ${value}`);
	}
	return Buffer.concat([Buffer.from([bytes.length]), bytes]);
}

function longString(value) {
	const bytes = Buffer.from(value, 'utf8');
	const head = Buffer.alloc(4);
	head.writeUInt32BE(bytes.length);
	return Buffer.concat([head, bytes]);
}

function serializeRequest(req, rpcId, method, args, withCancellation) {
	return Buffer.concat([
		Buffer.from([withCancellation ? MessageType.RequestJSONArgsWithCancellation : MessageType.RequestJSONArgs]),
		u32(req),
		Buffer.from([rpcId]),
		shortString(method),
		longString(JSON.stringify(args))
	]);
}

function u32(value) {
	const b = Buffer.alloc(4);
	b.writeUInt32BE(value);
	return b;
}

function readLongString(payload, offset) {
	const length = payload.readUInt32BE(offset);
	const start = offset + 4;
	return { value: payload.toString('utf8', start, start + length), offset: start + length };
}

function parseRequest(payload) {
	const type = payload[0];
	const req = payload.readUInt32BE(1);
	let offset = 5;
	const rpcId = payload[offset++];
	const methodLength = payload[offset++];
	const method = payload.toString('utf8', offset, offset + methodLength);
	offset += methodLength;
	if (type === MessageType.RequestJSONArgs || type === MessageType.RequestJSONArgsWithCancellation) {
		const json = readLongString(payload, offset);
		return { type, req, rpcId, method, args: JSON.parse(json.value) };
	}
	const count = payload[offset++];
	const args = [];
	for (let i = 0; i < count; i++) {
		const argType = payload[offset++];
		if (argType === 1) {
			const json = readLongString(payload, offset);
			offset = json.offset;
			args.push(JSON.parse(json.value));
		} else if (argType === 2) {
			const length = payload.readUInt32BE(offset);
			offset += 4 + length;
			args.push('<buffer>');
		} else if (argType === 3) {
			const buffers = payload.readUInt32BE(offset);
			offset += 4;
			const json = readLongString(payload, offset);
			offset = json.offset + buffers * 0;
			args.push(JSON.parse(json.value));
		} else if (argType === 4) {
			args.push(undefined);
		} else {
			throw new Error(`unknown mixed arg type ${argType}`);
		}
	}
	return { type, req, rpcId, method, args };
}

function extensionUri(uriPath) {
	return { $mid: 1, scheme: 'file', path: uriPath.replace(/\\/g, '/') };
}

function loadExtensionDescription() {
	const manifest = JSON.parse(fs.readFileSync(path.join(extensionPath, 'package.json'), 'utf8'));
	const id = `${manifest.publisher}.${manifest.name}`;
	const activationEvents = manifest.activationEvents ?? [];
	const description = {
		...manifest,
		id,
		identifier: { value: id, _lower: id.toLowerCase() },
		extensionLocation: extensionUri(extensionPath),
		isBuiltin: false,
		isUserBuiltin: false,
		isUnderDevelopment: true,
		targetPlatform: 'undefined',
		preRelease: false,
		activationEvents
	};
	return { manifest, id, description, activationEvents };
}

const { manifest, id, description, activationEvents } = loadExtensionDescription();
const extensionId = { value: id, _lower: id.toLowerCase() };

const initData = {
	version: '1.147.0',
	quality: 'stable',
	commit: undefined,
	date: undefined,
	parentPid: process.pid,
	environment: {
		isExtensionDevelopmentDebug: false,
		appName: 'zig-editor',
		appHost: 'node',
		appRoot: extensionUri(repoRoot),
		appLanguage: 'en',
		isExtensionTelemetryLoggingOnly: false,
		appUriScheme: 'zig-editor',
		globalStorageHome: extensionUri(path.join(repoRoot, '.cache-ext/data/globalStorage')),
		workspaceStorageHome: extensionUri(path.join(repoRoot, '.cache-ext/data/workspaceStorage')),
		useHostProxy: false,
		skipWorkspaceStorageLock: true
	},
	workspace: {
		id: 'test-workspace',
		name: 'test-workspace',
		transient: true,
		configuration: null,
		isUntitled: null
	},
	extensions: {
		versionId: 1,
		allExtensions: [description],
		activationEvents: { [id]: activationEvents },
		myExtensions: [extensionId]
	},
	telemetryInfo: {
		sessionId: '',
		machineId: '',
		sqmId: '',
		devDeviceId: '',
		firstSessionDate: ''
	},
	logLevel: 1,
	loggers: [],
	logsLocation: extensionUri(path.join(repoRoot, '.cache-ext/data/logs')),
	autoStart: false,
	remote: { isRemote: false, connectionData: null },
	consoleForward: { includeStack: false, logNative: false },
	uiKind: 1
};

const emptyModel = () => ({ contents: {}, keys: [], overrides: [] });
const configData = {
	defaults: emptyModel(),
	policy: emptyModel(),
	application: emptyModel(),
	userLocal: emptyModel(),
	userRemote: emptyModel(),
	workspace: emptyModel(),
	folders: [],
	configurationScopes: []
};

const workspaceData = {
	id: 'test-workspace',
	name: 'test-workspace',
	transient: true,
	configuration: null,
	isUntitled: null,
	folders: [{ uri: extensionUri(repoRoot), name: 'test-workspace', index: 0 }]
};

const child = spawn(process.execPath, [path.join(__dirname, 'dist/extensionHost.mjs')], {
	stdio: ['ignore', 'pipe', 'pipe', 'pipe', 'pipe'],
	env: { ...process.env, VSCODE_EXTENSION_HOST_IN_FD: '3', VSCODE_EXTENSION_HOST_OUT_FD: '4' }
});

child.stdout.on('data', chunk => process.stdout.write(`[host stdout] ${chunk}`));
child.stderr.on('data', chunk => process.stderr.write(chunk));
child.on('exit', (code, signal) => {
	console.log(`[harness] host exited code=${code} signal=${signal}`);
	process.exit(0);
});

const writeStream = child.stdio[3];
const readStream = child.stdio[4];
let buffer = Buffer.alloc(0);
let nextRequestId = 1;
const pending = new Map();
let initialized = false;
const doc = { text: 'hello', line: 1, column: 1, version: 1, editorId: '1', uri: extensionUri('/tmp/vim-test.txt') };

function frame(payload) {
	writeStream.write(Buffer.concat([u32(payload.length), payload]));
}

function sendRequest(rpcId, method, args) {
	const req = nextRequestId++;
	return new Promise((resolve, reject) => {
		pending.set(req, { resolve, reject, method, rpcId });
		console.log(`[harness] -> ${actorName(rpcId)}.${method} req=${req}`);
		frame(serializeRequest(req, rpcId, method, args, false));
	});
}

readStream.on('data', chunk => {
	buffer = Buffer.concat([buffer, chunk]);
	while (buffer.length >= 4) {
		const length = buffer.readUInt32BE(0);
		if (buffer.length < 4 + length) {
			return;
		}
		const payload = buffer.subarray(4, 4 + length);
		buffer = buffer.subarray(4 + length);
		onPayload(payload);
	}
});

function onPayload(payload) {
	if (!initialized) {
		initialized = true;
		if (payload.length === 1 && payload[0] === 2) {
			console.log('[harness] <- Ready');
			frame(Buffer.from(JSON.stringify(initData)));
			return;
		}
		console.error('[harness] expected Ready, got', payload);
		process.exit(1);
	}
	if (payload.length === 1 && payload[0] === 1) {
		console.log('[harness] <- Initialized');
		boot();
		return;
	}
	const type = payload[0];
	const req = payload.readUInt32BE(1);
	if (type >= 1 && type <= 4) {
		const request = parseRequest(payload);
		console.log(`[harness] <- request ${actorName(request.rpcId)}.${request.method} req=${req} args=${JSON.stringify(request.args).slice(0, 300)}`);
		frame(Buffer.concat([Buffer.from([MessageType.Acknowledged]), u32(req)]));
		const result = replyFor(request.rpcId, request.method, request.args);
		if (result && result.type === 'json' && result.value !== undefined) {
			frame(Buffer.concat([Buffer.from([MessageType.ReplyOKJSON]), u32(req), longString(JSON.stringify(result.value))]));
		} else {
			frame(Buffer.concat([Buffer.from([MessageType.ReplyOKEmpty]), u32(req)]));
		}
		return;
	}
	if (type === MessageType.Acknowledged) {
		return;
	}
	if (type === MessageType.ReplyOKEmpty) {
		finishReply(req, undefined);
		return;
	}
	if (type === MessageType.ReplyOKJSON) {
		const length = payload.readUInt32BE(5);
		finishReply(req, JSON.parse(payload.toString('utf8', 9, 9 + length)));
		return;
	}
	if (type === MessageType.ReplyErrError || type === MessageType.ReplyErrEmpty) {
		console.log(`[harness] <- error reply req=${req}`);
		finishReply(req, undefined);
		return;
	}
	console.log('[harness] <- unhandled payload type', type, payload.subarray(0, 40));
}

function sendNotification(rpcId, method, args) {
	const req = nextRequestId++;
	frame(serializeRequest(req, rpcId, method, args, false));
	return new Promise(resolve => pending.set(req, { resolve, reject: resolve, method, rpcId }));
}

let decorationKey = 0;

const replyTable = {
	'MainThreadTextEditors.$registerTextEditorDecorationType': () => `decoration-${++decorationKey}`,
	'MainThreadWindow.$getInitialState': () => ({ isFocused: true, isActive: true }),
	'MainThreadChatSkills.$getTools': () => [],
	'MainThreadFileSystem.$ensureActivation': () => true,
	'MainThreadLogger.$registerLogger': () => undefined,
	'MainThreadCommands.$getCommands': () => [],
	'MainThreadTextEditors.$trySetSelections': args => {
		const selection = args[1] && args[1][0];
		if (selection) {
			doc.line = selection.selectionEndLineNumber;
			doc.column = selection.selectionEndColumn;
		}
		return true;
	},
	'MainThreadTextEditors.$tryApplyEdits': () => true,
	'MainThreadTextEditors.$trySetOptions': () => undefined,
	'MainThreadCommands.$executeCommand': args => {
		const command = args[0];
		if (command === 'default:type') {
			const text = args[1][0].text;
			const index = doc.column - 1;
			doc.text = doc.text.slice(0, index) + text + doc.text.slice(index);
			doc.column += text.length;
			doc.version++;
			sendNotification(97, '$acceptModelChanged', [doc.uri, {
				changes: [{ range: { startLineNumber: doc.line, startColumn: doc.column - text.length, endLineNumber: doc.line, endColumn: doc.column - text.length }, rangeOffset: 0, rangeLength: 0, text }],
				eol: '\n', versionId: doc.version, isUndoing: false, isRedoing: false, isFlush: false, isEolChange: false, detailedReason: null
			}, false]).catch(() => {});
			console.log('[harness] default:type', JSON.stringify(text), '=>', doc.text);
		}
		return undefined;
	}
};

function replyFor(rpcId, method, args) {
	const key = `${actorName(rpcId)}.${method}`;
	const fn = replyTable[key];
	if (!fn) {
		return null;
	}
	return { type: 'json', value: fn(args) };
}

function finishReply(req, value) {
	const entry = pending.get(req);
	if (!entry) {
		return;
	}
	pending.delete(req);
	console.log(`[harness] <- reply ${entry.method} req=${req}`);
	entry.resolve(value);
}

async function boot() {
	console.log('[harness] initializing workspace/configuration');
	await sendRequest(119, '$initializeWorkspace', [workspaceData, true]);
	await sendRequest(92, '$initializeConfiguration', [configData]);
	console.log('[harness] starting extension host');
	sendRequest(112, '$startExtensionHost', [{
		versionId: 1,
		toRemove: [],
		toAdd: [],
		addActivationEvents: {},
		myToRemove: [],
		myToAdd: []
	}]);
	setTimeout(async () => {
		console.log('[harness] pushing document');
		await sendNotification(96, '$acceptDocumentsAndEditorsDelta', [{
			addedDocuments: [{ uri: doc.uri, versionId: 1, lines: [doc.text], EOL: '\n', languageId: 'plaintext', isDirty: false, encoding: 'utf8' }],
			addedEditors: [{ id: doc.editorId, documentUri: doc.uri, options: { tabSize: 4, indentSize: 4, originalIndentSize: 'tabSize', insertSpaces: true, cursorStyle: 1, lineNumbers: 1 }, selections: [{ selectionStartLineNumber: 1, selectionStartColumn: 1, positionLineNumber: 1, positionColumn: 1 }], visibleRanges: [{ startLineNumber: 1, startColumn: 1, endLineNumber: 1, endColumn: 6 }], editorPosition: 1 }],
			newActiveEditor: doc.editorId
		}]);
		await sendNotification(100, '$acceptEditorPropertiesChanged', [doc.editorId, { options: null, selections: { selections: [{ selectionStartLineNumber: 1, selectionStartColumn: 1, positionLineNumber: 1, positionColumn: 1 }], source: 'keyboard' }, visibleRanges: null }]);
		setTimeout(async () => {
			console.log('[harness] sending type i');
			await sendRequest(91, '$executeContributedCommand', ['type', { text: 'i' }]);
			setTimeout(async () => {
				console.log('[harness] sending type X');
				await sendRequest(91, '$executeContributedCommand', ['type', { text: 'X' }]);
				setTimeout(() => {
					console.log('[harness] document:', JSON.stringify(doc.text));
					frame(Buffer.from([3]));
					setTimeout(() => { child.kill('SIGKILL'); process.exit(doc.text === 'Xhello' ? 0 : 1); }, 1000);
				}, 1500);
			}, 800);
		}, 1500);
	}, 2000);
}
