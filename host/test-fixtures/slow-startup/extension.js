// An eager activation that publishes a provider before its activation promise
// settles, as real extensions can do while waiting for a service or prompt.
const vscode = require('vscode');

async function activate(context) {
  let release;
  const gate = new Promise(resolve => { release = resolve; });
  context.subscriptions.push(
    vscode.commands.registerCommand('fixture.slowStartup.release', () => release()),
    vscode.languages.registerCodeLensProvider({ scheme: 'file', language: 'plaintext' }, {
      async provideCodeLenses() {
        await gate;
        return [new vscode.CodeLens(new vscode.Range(0, 0, 0, 1), {
          title: 'Slow startup ready', command: 'fixture.slowStartup.release'
        })];
      }
    })
  );
  await gate;
}

module.exports = { activate };
