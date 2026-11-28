// Native TUI adapter for GitHub's official Copilot Language Server. The
// language server owns device authentication, credentials and content policy.
const vscode = require('vscode');
const { spawn } = require('node:child_process');
const { createMessageConnection, StreamMessageReader, StreamMessageWriter } = require('vscode-jsonrpc/node');

const signInId = 'minecode.copilot.signIn';
const signOutId = 'minecode.copilot.signOut';
const acceptId = 'minecode.copilot.accept';
const displayName = 'minecode';
const version = '1.0.0';

function activate(context) {
    const executable = process.env.MINECODE_COPILOT_SERVER;
    if (!executable) return;

    const status = vscode.window.createStatusBarItem('copilot.inline', vscode.StatusBarAlignment.Right, 0);
    status.name = 'GitHub Copilot';
    status.text = 'Copilot: Starting';
    status.show();
    const child = spawn(executable, ['--stdio'], { stdio: ['pipe', 'pipe', 'ignore'] });
    const connection = createMessageConnection(new StreamMessageReader(child.stdout), new StreamMessageWriter(child.stdin));
    const documents = new Map();
    let focusedUri;
    const serverItems = new WeakMap();
    let deviceFlow;
    let signingIn = false;
    let disposed = false;

    function report(text, command) {
        if (disposed) return;
        status.text = 'Copilot: ' + text;
        status.command = command;
    }
    function failed() {
        if (!disposed) report('Server unavailable');
    }
    child.on('error', failed);
    connection.onClose(failed);
    connection.onNotification('didChangeStatus', state => {
        if (deviceFlow || signingIn) return;
        if (state.kind === 'Error') report(state.message || 'Sign in', signInId);
        else report(state.message || (state.busy ? 'Working' : 'Ready'), signInId);
    });
    connection.listen();

    const folderList = () => (vscode.workspace.workspaceFolders || []).map(f => ({ name: f.name, uri: f.uri.toString() }));
    const ready = (async () => {
        await connection.sendRequest('initialize', {
            processId: process.pid, rootUri: folderList()[0]?.uri ?? null, workspaceFolders: folderList(),
            capabilities: { workspace: { workspaceFolders: true }, textDocument: { inlineCompletion: {} } },
            initializationOptions: { editorInfo: { name: displayName, version: vscode.version }, editorPluginInfo: { name: 'copilot-inline', version } }
        });
        await connection.sendNotification('initialized', {});
        await updateSettings();
    })();
    ready.catch(failed);

    function enabled(document) {
        const config = vscode.workspace.getConfiguration('github.copilot', document);
        const languages = config.get('enable', { '*': true, plaintext: false, scminput: false });
        return (languages[document.languageId] ?? languages['*'] ?? true) && config.get('editor.enableAutoCompletions', true);
    }
    function updateSettings() {
        return connection.sendNotification('workspace/didChangeConfiguration', {
            settings: { telemetry: { telemetryLevel: vscode.workspace.getConfiguration('telemetry').get('telemetryLevel', 'off') } }
        });
    }
    const positionDto = p => ({ line: p.line, character: p.character });
    const rangeDto = r => ({ start: positionDto(r.start), end: positionDto(r.end) });

    function focus(uri) {
        if (focusedUri === uri) return;
        focusedUri = uri;
        return connection.sendNotification('textDocument/didFocus', uri ? { textDocument: { uri } } : {});
    }
    function sync(document, changes) {
        const uri = document.uri.toString();
        const previous = documents.get(uri);
        const version = document.version;
        if (previous?.version === version) return;
        const end = positionDto(document.lineAt(document.lineCount - 1).range.end);
        documents.set(uri, { version, end });
        if (!previous) {
            return connection.sendNotification('textDocument/didOpen', {
                textDocument: { uri, version, languageId: document.languageId, text: document.getText() }
            });
        }
        // VS Code orders range edits from the end of the document. Each edit
        // can therefore be applied sequentially to the server's previous text.
        const contentChanges = changes?.length ? changes.map(c => ({ range: rangeDto(c.range), text: c.text })) :
            [{ range: { start: { line: 0, character: 0 }, end: previous.end }, text: document.getText() }];
        return connection.sendNotification('textDocument/didChange', { textDocument: { uri, version }, contentChanges });
    }
    async function close(uri) {
        if (focusedUri === uri) await focus(undefined);
        if (documents.delete(uri)) await connection.sendNotification('textDocument/didClose', { textDocument: { uri } });
    }
    async function signIn() {
        if (signingIn) return;
        signingIn = true;
        try {
            await ready;
            if (deviceFlow) {
                const command = deviceFlow;
                deviceFlow = undefined;
                await connection.sendRequest('workspace/executeCommand', command);
                report('Ready');
            } else {
                const result = await connection.sendRequest('signIn', {});
                if (result.userCode && result.command) {
                    deviceFlow = result.command;
                    report(result.userCode + ' — Sign In again to open GitHub', signInId);
                } else report(result.status || 'Signed in');
            }
        } catch {
            deviceFlow = undefined;
            report('Sign-in failed', signInId);
        } finally {
            signingIn = false;
        }
    }

    context.subscriptions.push(status, { dispose() {
        disposed = true;
        connection.dispose();
        child.kill();
    } }, vscode.commands.registerCommand(signInId, signIn),
    vscode.commands.registerCommand(signOutId, async () => {
        await ready;
        deviceFlow = undefined;
        await connection.sendRequest('signOut', {});
        report('Signed out', signInId);
    }), vscode.commands.registerCommand(acceptId, command => connection.sendRequest('workspace/executeCommand', command)),
    vscode.window.onDidChangeActiveTextEditor(editor => {
        const uri = editor?.document.uri.toString();
        Promise.resolve(focus(documents.has(uri) ? uri : undefined)).catch(failed);
    }),
    vscode.workspace.onDidChangeTextDocument(({ document, contentChanges }) => {
        if (documents.has(document.uri.toString()) && enabled(document)) {
            Promise.resolve(sync(document, contentChanges)).catch(failed);
        }
    }),
    vscode.workspace.onDidCloseTextDocument(doc => close(doc.uri.toString()).catch(failed)),
    vscode.workspace.onDidChangeConfiguration(async () => {
        try {
            await ready;
            await updateSettings();
            for (const doc of vscode.workspace.textDocuments) {
                if (!enabled(doc)) await close(doc.uri.toString());
            }
        } catch { failed(); }
    }),
    vscode.languages.registerInlineCompletionItemProvider({ scheme: 'file' }, {
        async provideInlineCompletionItems(document, position, context, token) {
            if (!enabled(document)) return [];
            await ready;
            if (token.isCancellationRequested || document.isClosed || !enabled(document)) return [];
            const uri = document.uri.toString();
            const version = document.version;
            await sync(document);
            if (vscode.window.activeTextEditor?.document === document) await focus(uri);
            if (token.isCancellationRequested || document.version !== version) return [];
            const options = vscode.window.activeTextEditor?.options;
            const result = await connection.sendRequest('textDocument/inlineCompletion', {
                textDocument: { uri, version }, position: { line: position.line, character: position.character },
                context: { triggerKind: context.triggerKind === vscode.InlineCompletionTriggerKind.Automatic ? 2 : 1 },
                formattingOptions: { tabSize: Number(options?.tabSize) || 4, insertSpaces: options?.insertSpaces !== false }
            }, token);
            if (token.isCancellationRequested || document.version !== version) return [];
            return (result?.items ?? []).filter(i => typeof i.insertText === 'string').map(item => {
                const r = item.range;
                const range = r ? new vscode.Range(r.start.line, r.start.character, r.end.line, r.end.character) : new vscode.Range(position, position);
                const command = item.command && { command: acceptId, arguments: [item.command], title: 'Accept completion' };
                const completion = new vscode.InlineCompletionItem(item.insertText.replace(/\r\n/g, '\n'), range, command);
                serverItems.set(completion, item);
                return completion;
            });
        },
        handleDidShowCompletionItem(completion) {
            const item = serverItems.get(completion);
            if (item) connection.sendNotification('textDocument/didShowCompletion', { item }).catch(failed);
        }
    }));
}
module.exports = { activate };
