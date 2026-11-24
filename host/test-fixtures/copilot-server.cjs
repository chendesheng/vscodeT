#!/usr/bin/env node
// Deterministic stdio server for the installed editor smoke test.
const fs = require('node:fs');
const rpc = require('vscode-jsonrpc/node');
const connection = rpc.createMessageConnection(new rpc.StreamMessageReader(process.stdin), new rpc.StreamMessageWriter(process.stdout));
const documents = new Map();
const record = event => fs.appendFileSync(process.env.COPILOT_TEST_EVENTS, event + '\n');

connection.onRequest('initialize', () => {
    record('initialize');
    return { capabilities: { inlineCompletionProvider: true } };
});
connection.onNotification('initialized', () => connection.sendNotification('didChangeStatus', { kind: 'Normal', message: 'Ready' }));
connection.onNotification('textDocument/didOpen', ({ textDocument }) => documents.set(textDocument.uri, textDocument.text));
connection.onNotification('textDocument/didChange', ({ textDocument, contentChanges }) => documents.set(textDocument.uri, contentChanges.at(-1).text));
connection.onRequest('textDocument/inlineCompletion', ({ textDocument, position }) => {
    const text = documents.get(textDocument.uri);
    if (position.line !== 0 || position.character !== text.length) return { items: [] };
    return { items: [{
        range: { start: { line: 0, character: 0 }, end: position },
        insertText: text + ' = 42',
        command: { command: 'github.copilot.didAcceptCompletionItem', arguments: ['fixture'] }
    }] };
});
connection.onNotification('textDocument/didShowCompletion', ({ item }) => record('shown ' + item.insertText));
connection.onRequest('workspace/executeCommand', ({ command, arguments: args }) => { record(command + ' ' + args.join(',')); return null; });
connection.listen();
