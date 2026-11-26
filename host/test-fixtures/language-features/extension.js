const vscode = require('vscode');

function activate(context) {
  context.subscriptions.push(vscode.languages.registerInlineCompletionItemProvider({ language: 'json' }, {
    provideInlineCompletionItems(document, position) {
      const line = document.lineAt(position.line).text;
      return [new vscode.InlineCompletionItem(line + ' inline result', new vscode.Range(position.line, 0, position.line, position.character))];
    }
  }));
  // A more specific provider may decline, as Emmet does outside abbreviations.
  context.subscriptions.push(vscode.languages.registerInlineCompletionItemProvider({ scheme: 'file', language: 'json' }, {
    provideInlineCompletionItems() { return []; }
  }));
  context.subscriptions.push(vscode.languages.registerCodeLensProvider({ language: 'json' }, {
    provideCodeLenses(document) {
      return [new vscode.CodeLens(new vscode.Range(0, 0, 0, 0), {
        title: document.uri.query + ':' + document.lineAt(0).text,
        command: 'fixture.codeLens',
        arguments: [document.uri.toString()]
      })];
    }
  }));
  context.subscriptions.push(vscode.commands.registerCommand('fixture.codeLens', () => {}));
  context.subscriptions.push(vscode.languages.registerHoverProvider({ language: 'json' }, {
    provideHover() {
      return { contents: ['fixture hover'] };
    }
  }));
  context.subscriptions.push(vscode.languages.registerCompletionItemProvider({ language: 'json' }, {
    provideCompletionItems() {
      const item = new vscode.CompletionItem('fixture', vscode.CompletionItemKind.Text);
      item.insertText = 'fixture';
      return [item];
    }
  }, '.'));
  context.subscriptions.push(vscode.languages.registerDefinitionProvider({ language: 'json' }, {
    provideDefinition(document) {
      const range = new vscode.Range(0, 0, 0, 1);
      return [{ targetUri: document.uri, targetRange: range, targetSelectionRange: range }];
    }
  }));
  context.subscriptions.push(vscode.languages.registerDeclarationProvider({ language: 'json' }, {
    provideDeclaration(document) {
      const range = new vscode.Range(1, 0, 1, 1);
      return [{ targetUri: document.uri, targetRange: range, targetSelectionRange: range }];
    }
  }));
  context.subscriptions.push(vscode.languages.registerImplementationProvider({ language: 'json' }, {
    provideImplementation(document) {
      const range = new vscode.Range(2, 0, 2, 1);
      return [{ targetUri: document.uri, targetRange: range, targetSelectionRange: range }];
    }
  }));
  context.subscriptions.push(vscode.languages.registerTypeDefinitionProvider({ language: 'json' }, {
    provideTypeDefinition(document) {
      const range = new vscode.Range(0, 0, 0, 3);
      return [{ targetUri: document.uri, targetRange: range, targetSelectionRange: range }];
    }
  }));
  context.subscriptions.push(vscode.languages.registerReferenceProvider({ language: 'json' }, {
    provideReferences(document) {
      return [
        new vscode.Location(document.uri, new vscode.Range(0, 0, 0, 1)),
        new vscode.Location(document.uri, new vscode.Range(1, 0, 1, 1)),
      ];
    }
  }));
  context.subscriptions.push(vscode.languages.registerDocumentSymbolProvider({ language: 'json' }, {
    provideDocumentSymbols() {
      return [new vscode.DocumentSymbol(
        'root',
        '',
        vscode.SymbolKind.Object,
        new vscode.Range(0, 0, 1, 0),
        new vscode.Range(0, 0, 0, 1)
      )];
    }
  }));
}

function deactivate() {}

module.exports = { activate, deactivate };
