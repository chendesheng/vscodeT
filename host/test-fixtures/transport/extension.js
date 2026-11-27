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
  context.subscriptions.push(vscode.commands.registerCommand('fixture.transportEcho', value => ({
    value,
    document: vscode.window.activeTextEditor?.document.uri.fsPath,
    extension: context.extensionUri.fsPath
  })));
};
