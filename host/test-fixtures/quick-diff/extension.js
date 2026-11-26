const vscode = require('vscode');

function activate(context) {
  const original = vscode.Uri.from({
    scheme: 'quickdiff-fixture',
    path: '/baseline #?.txt',
    query: 'source=fixture#query'
  });
  const changed = new vscode.EventEmitter();
  let baseline = 'before\nsecond\n';
  let information;
  let informationChanges = 0;
  context.subscriptions.push(changed);
  context.subscriptions.push(vscode.workspace.registerTextDocumentContentProvider('quickdiff-fixture', {
    onDidChange: changed.event,
    async provideTextDocumentContent(uri) {
      if (uri.toString() !== original.toString()) return undefined;
      await new Promise(resolve => setTimeout(resolve, 20));
      return baseline;
    }
  }));
  const provider = vscode.window.registerQuickDiffProvider({
    scheme: 'file',
    language: 'plaintext',
    pattern: '**/quickdiff-fixture.txt'
  }, {
    async provideOriginalResource() {
      await new Promise(resolve => setTimeout(resolve, 20));
      return original;
    }
  }, 'baseline', 'Fixture baseline');
  context.subscriptions.push(provider);
  context.subscriptions.push(vscode.commands.registerCommand('fixture.quickDiff.update', async value => {
    baseline = value;
    changed.fire(original);
  }));
  context.subscriptions.push(vscode.commands.registerCommand('fixture.quickDiff.documents', () =>
    vscode.workspace.textDocuments.filter(document => document.uri.scheme === original.scheme)
      .map(document => ({ uri: document.uri.toString(), text: document.getText() }))));
  context.subscriptions.push(vscode.commands.registerCommand('fixture.quickDiff.createInformation', uri => {
    information = vscode.window.createSourceControlDiffInformation(vscode.Uri.parse(uri));
    context.subscriptions.push(information);
    context.subscriptions.push(information.onDidChange(() => informationChanges++));
  }));
  context.subscriptions.push(vscode.commands.registerCommand('fixture.quickDiff.information', () => {
    const value = information?.diffInformation;
    if (!value) return null;
    return { documentVersion: value.documentVersion, original: value.original.toString(),
      modified: value.modified.toString(), changes: value.changes, isStale: value.isStale,
      events: informationChanges };
  }));
  context.subscriptions.push(vscode.commands.registerCommand('fixture.quickDiff.dispose', () => {
    provider.dispose();
    information?.dispose();
  }));
}

module.exports = { activate };
