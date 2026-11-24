// Native TUI adapter for GitHub's official Copilot Language Server. The
// language server owns device authentication, credentials and content policy.
const vscode = require('vscode');
const { spawn } = require('node:child_process');
const { createMessageConnection, StreamMessageReader, StreamMessageWriter } = require('vscode-jsonrpc/node');

const signInId = 'vscode-textbuffer.copilot.signIn';
const signOutId = 'vscode-textbuffer.copilot.signOut';
const acceptId = 'vscode-textbuffer.copilot.accept';
const displayName = 'vscode-textbuffer';
const version = '1.0.0';

function activate(context) {
    const executable = process.env.VSCODE_TEXTBUFFER_COPILOT_SERVER;
    if (!executable) return;

    const status = vscode.window.createStatusBarItem('copilot.inline', vscode.StatusBarAlignment.Right, 0);
    status.name = 'GitHub Copilot';
    status.text = 'Copilot: Starting';
    status.show();
    const child = spawn(executable, ['--stdio'], { stdio: ['pipe', 'pipe', 'ignore'] });
    const connection = createMessageConnection(new StreamMessageReader(child.stdout), new StreamMessageWriter(child.stdin));
    const versions = new Map();
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
    async function close(uri) {
        if (versions.delete(uri)) await connection.sendNotification('textDocument/didClose', { textDocument: { uri } });
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
            // Eagerly record each queued version so concurrent requests cannot
            // open the same document twice. JSON-RPC preserves write order.
            const previous = versions.get(uri);
            versions.set(uri, version);
            if (previous === undefined) {
                await connection.sendNotification('textDocument/didOpen', { textDocument: { uri, version, languageId: document.languageId, text: document.getText() } });
            } else if (previous !== version) {
                await connection.sendNotification('textDocument/didChange', { textDocument: { uri, version }, contentChanges: [{ text: document.getText() }] });
            }
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
