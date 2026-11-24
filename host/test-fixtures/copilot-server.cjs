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
connection.onNotification('textDocument/didFocus', ({ textDocument }) => record(textDocument ? 'focused' : 'blurred'));
connection.onNotification('textDocument/didChange', ({ textDocument, contentChanges }) => {
    let text = documents.get(textDocument.uri);
    for (const change of contentChanges) {
        const offset = p => text.split('\n').slice(0, p.line).reduce((n, line) => n + line.length + 1, 0) + p.character;
        const { start, end } = change.range;
        text = text.slice(0, offset(start)) + change.text + text.slice(offset(end));
    }
    documents.set(textDocument.uri, text);
    record('changed ' + text);
});
connection.onRequest('textDocument/inlineCompletion', ({ textDocument, position }) => {
    const text = documents.get(textDocument.uri);
    const midline = text === '+value' && position.character === 1;
    const rewrite = text === '~+value' && position.character === 1;
    if (position.line !== 0 || (!midline && !rewrite && position.character !== text.length)) return { items: [] };
    return { items: [{
        range: { start: { line: 0, character: 0 }, end: { line: 0, character: text.length } },
        insertText: rewrite ? '~result' : midline ? '+ 2 + value' : text + ' = 42',
        command: { command: 'github.copilot.didAcceptCompletionItem', arguments: ['fixture'] }
    }] };
});
connection.onNotification('textDocument/didShowCompletion', ({ item }) => record('shown ' + item.insertText));
connection.onRequest('workspace/executeCommand', ({ command, arguments: args }) => { record(command + ' ' + args.join(',')); return null; });
connection.listen();
