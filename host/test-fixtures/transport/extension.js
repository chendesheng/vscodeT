const vscode = require('vscode');

exports.activate = context => {
  let output;
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
