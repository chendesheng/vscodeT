const vscode = require('vscode');

exports.activate = context => {
  let output;
  let watcher;
  let watchOutput;
  let finishProgress;
  context.subscriptions.push(vscode.commands.registerCommand('fixture.progressStart', () => {
    void vscode.window.withProgress({ location: vscode.ProgressLocation.Notification, title: 'Transport progress', cancellable: true }, (progress, token) => new Promise(resolve => {
      progress.report({ message: 'working', increment: 25 });
      token.onCancellationRequested(() => {
        watchOutput.appendLine('progress cancelled');
        resolve();
      });
    }));
  }));
  context.subscriptions.push(vscode.commands.registerCommand('fixture.windowProgressStart', () => {
    void vscode.window.withProgress({ location: vscode.ProgressLocation.Window, title: 'Window progress' }, progress => new Promise(resolve => {
      finishProgress = resolve;
      progress.report({ message: 'working' });
    }));
  }));
  context.subscriptions.push(vscode.commands.registerCommand('fixture.windowProgressEnd', () => finishProgress()));
  context.subscriptions.push(vscode.commands.registerCommand('fixture.watchStart', () => {
    const root = vscode.Uri.file(require('node:path').dirname(vscode.window.activeTextEditor.document.uri.fsPath));
    watcher = vscode.workspace.createFileSystemWatcher(new vscode.RelativePattern(root, '*.watch'));
    watchOutput = vscode.window.createOutputChannel('Watcher Events');
    const record = (kind, uri) => watchOutput.appendLine(kind + ' ' + require('node:path').basename(uri.fsPath));
    context.subscriptions.push(watcher, watchOutput,
      watcher.onDidCreate(uri => record('created', uri)),
      watcher.onDidChange(uri => record('changed', uri)),
      watcher.onDidDelete(uri => record('deleted', uri)));
    watchOutput.show(true);
  }));
  context.subscriptions.push(vscode.commands.registerCommand('fixture.watchStop', () => watcher.dispose()));
  context.subscriptions.push(vscode.commands.registerCommand('fixture.outputWrite', () => {
    output = vscode.window.createOutputChannel('Transport Output');
    context.subscriptions.push(output);
    output.append('firsté\n');
    output.show(true);
  }));
  context.subscriptions.push(vscode.commands.registerCommand('fixture.outputReplace', () => output.replace('replacement\n')));
  context.subscriptions.push(vscode.commands.registerCommand('fixture.outputClear', () => output.clear()));
  context.subscriptions.push(vscode.commands.registerCommand('fixture.outputHide', () => output.hide()));
  context.subscriptions.push(vscode.commands.registerCommand('fixture.outputDispose', () => output.dispose()));
  context.subscriptions.push(vscode.commands.registerCommand('fixture.transportEcho', async value => {
    const document = vscode.window.activeTextEditor.document.uri;
    const root = vscode.Uri.file(require('node:path').dirname(document.fsPath));
    const background = await vscode.workspace.openTextDocument(vscode.Uri.joinPath(root, 'background.txt'));
    let missingRejected = false;
    try { await vscode.workspace.openTextDocument(vscode.Uri.joinPath(root, 'missing.txt')); }
    catch { missingRejected = true; }
    return {
      value, document: document.fsPath, extension: context.extensionUri.fsPath,
      background: background.getText(), missingRejected,
      activeUnchanged: vscode.window.activeTextEditor?.document.uri.toString() === document.toString(),
      backgroundHidden: !vscode.window.visibleTextEditors.some(editor => editor.document === background),
      missingMirrored: vscode.workspace.textDocuments.some(doc => doc.uri.path.endsWith('/missing.txt'))
    };
  }));
};
