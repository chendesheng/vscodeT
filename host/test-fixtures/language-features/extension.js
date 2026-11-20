const vscode = require('vscode');

function activate(context) {
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
