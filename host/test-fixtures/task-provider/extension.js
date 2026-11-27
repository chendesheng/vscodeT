const vscode = require('vscode');

exports.activate = async function (context) {
    // Exercise the wait for activation as well as the provider promise.
    await new Promise(resolve => setTimeout(resolve, 20));
    context.subscriptions.push(vscode.tasks.registerTaskProvider('fixture', {
        async provideTasks() {
            await new Promise(resolve => setTimeout(resolve, 20));
            return [new vscode.Task({ type: 'fixture' }, vscode.TaskScope.Workspace,
                'Fixture task', 'fixture', new vscode.ProcessExecution('echo', ['fixture']))];
        },
        resolveTask() {}
    }));
};
