#!/usr/bin/env node
// Smoke test for the bundled JSON language server.
'use strict';
const { spawn } = require('node:child_process');
const path = require('node:path');

const child = spawn(process.execPath, [path.join(__dirname, 'dist/jsonServer.mjs'), '--stdio'], {
	stdio: ['pipe', 'pipe', 'inherit']
});
let buffer = Buffer.alloc(0);
let nextId = 1;
const pending = new Map();

function send(message) {
	const body = Buffer.from(JSON.stringify(message), 'utf8');
	child.stdin.write(`Content-Length: ${body.length}\r\n\r\n`);
	child.stdin.write(body);
}

function request(method, params) {
	const id = nextId++;
	return new Promise((resolve, reject) => {
		pending.set(id, { resolve, reject });
		send({ jsonrpc: '2.0', id, method, params });
	});
}

child.stdout.on('data', chunk => {
	buffer = Buffer.concat([buffer, chunk]);
	while (true) {
		const headerEnd = buffer.indexOf('\r\n\r\n');
		if (headerEnd < 0) return;
		const match = /Content-Length: (\d+)/.exec(buffer.subarray(0, headerEnd).toString());
		const length = match ? Number(match[1]) : 0;
		if (buffer.length < headerEnd + 4 + length) return;
		const message = JSON.parse(buffer.subarray(headerEnd + 4, headerEnd + 4 + length).toString());
		buffer = buffer.subarray(headerEnd + 4 + length);
		if (message.id && pending.has(message.id)) {
			const entry = pending.get(message.id);
			pending.delete(message.id);
			if (message.error) entry.reject(new Error(message.error.message));
			else entry.resolve(message.result);
		} else if (message.id && message.method) {
			const result = message.method === 'workspace/configuration'
				? message.params.items.map(() => ({}))
				: null;
			send({ jsonrpc: '2.0', id: message.id, result });
		}
	}
});

(async () => {
	await request('initialize', {
		processId: process.pid,
		rootUri: 'file:///tmp',
		capabilities: { textDocument: { diagnostic: {}, completion: {} } },
		workspaceFolders: [{ uri: 'file:///tmp', name: 'tmp' }]
	});
	send({ jsonrpc: '2.0', method: 'initialized', params: {} });
	send({
		jsonrpc: '2.0',
		method: 'workspace/didChangeConfiguration',
		params: { settings: { json: { validate: { enable: true } } } }
	});
	const uri = 'file:///tmp/test.json';
	send({
		jsonrpc: '2.0',
		method: 'textDocument/didOpen',
		params: {
			textDocument: {
				uri,
				languageId: 'json',
				version: 1,
				text: '{\n  "a": 1\n'
			}
		}
	});
	const report = await request('textDocument/diagnostic', { textDocument: { uri } });
	const diagnostics = report && report.items ? report.items.length : 0;
	await request('textDocument/completion', {
		textDocument: { uri },
		position: { line: 1, character: 4 }
	});
	console.log(`JSON server: ${diagnostics} diagnostic(s), completion request OK`);
	send({ jsonrpc: '2.0', method: 'exit', params: null });
	setTimeout(() => process.exit(diagnostics > 0 ? 0 : 1), 200);
})().catch(error => {
	console.error(error);
	child.kill('SIGKILL');
	process.exit(1);
});
