// Independent LSP integration fixture: use the real pinned client, not
// vscode.languages.register* directly. Server features are negotiated over
// stdio on every native CI platform.
const vscode = require('vscode');
const { LanguageClient } = require('vscode-languageclient/node');
const path = require('node:path');
let client;

async function activate(context) {
  const folder = vscode.workspace.workspaceFolders?.[0];
  const watcher = vscode.workspace.createFileSystemWatcher(folder ? new vscode.RelativePattern(folder, '**/*.lspfixture') : '**/*.lspfixture');
  context.subscriptions.push(watcher);
  const serverOptions = {
    command: process.execPath,
    args: [path.join(context.extensionPath, 'server.js'), '--stdio'],
    options: { cwd: context.extensionPath }
  };
  const clientOptions = {
    documentSelector: [{ scheme: 'file', language: 'plaintext' }],
    synchronize: { configurationSection: 'lspFixture', fileEvents: watcher },
    outputChannelName: 'Mock LSP Fixture',
  };
  client = new LanguageClient('minecode-mock-lsp', 'Mock LSP Fixture', serverOptions, clientOptions);
  context.subscriptions.push(
    vscode.commands.registerCommand('fixture.lsp.status', () => client.sendRequest('fixture/status')),
    vscode.commands.registerCommand('fixture.lsp.applyEdit', () => client.sendRequest('fixture/applyEdit')),
    vscode.commands.registerCommand('fixture.lsp.progress', () => client.sendRequest('fixture/progress')),
    vscode.commands.registerCommand('fixture.lsp.updateConfiguration', async () => {
      await vscode.workspace.getConfiguration('lspFixture').update('value', 'updated by extension', vscode.ConfigurationTarget.Global);
      return true;
    })
  );
  await client.start();
}

async function deactivate() {
  if (client) await client.stop();
}
module.exports = { activate, deactivate };
