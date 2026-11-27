const vscode = require('vscode');

exports.activate = context => {
  context.subscriptions.push(vscode.commands.registerCommand('fixture.transportEcho', value => ({
    value,
    document: vscode.window.activeTextEditor?.document.uri.fsPath,
    extension: context.extensionUri.fsPath
  })));
};
