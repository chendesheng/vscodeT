const vscode = require('vscode');

exports.activate = function (context) {
    const changed = new vscode.EventEmitter();
    const provider = {
        onDidChangeSessions: changed.event,
        async getSessions(scopes) {
            const saved = await context.secrets.get('session');
            if (!saved) return [];
            const session = JSON.parse(saved);
            return !scopes || scopes.every(scope => session.scopes.includes(scope)) ? [session] : [];
        },
        async createSession(scopes) {
            const session = { id: 'fixture-id', scopes, accessToken: 'local-test-value', account: { id: 'fixture-account', label: 'Fixture user' } };
            await context.secrets.store('session', JSON.stringify(session));
            changed.fire({ added: [session], changed: [], removed: [] });
            return session;
        },
        async removeSession() {
            const removed = await this.getSessions();
            await context.secrets.delete('session');
            changed.fire({ removed, changed: [], added: [] });
        }
    };
    context.subscriptions.push(changed, vscode.authentication.registerAuthenticationProvider('fixture', 'Fixture accounts', provider));
    context.subscriptions.push(vscode.commands.registerCommand('fixture.account', async (interactive, scope) => {
        const session = await vscode.authentication.getSession('fixture', [scope], interactive ? { createIfNone: true } : { silent: true });
        return session?.accessToken === 'local-test-value';
    }));
};
