# Remote-SSH workspaces for minecode

Proposed implementation against the [pinned VS Code source](../vscode) at `e31c2e52f563620846caab877103f630ea361b9c`.

The first milestone is a complete editing session. From the local terminal workbench, a user chooses **Remote-SSH: Connect to Host...**, selects an SSH host, opens a folder on it, edits and saves a file, then opens an integrated terminal in that folder. The status bar identifies the host throughout. This follows the [VS Code Remote-SSH workflow](https://code.visualstudio.com/docs/remote/ssh).

## Design choices

Start with a native POSIX client, a Linux SSH host with an SFTP subsystem, and one remote authority per window. Use the system OpenSSH client for host configuration, identity selection, jump hosts, host-key checks and authentication. Use SFTP over SSH for file operations and an SSH session with a PTY for the terminal. This gives the editing milestone a standard server-side dependency. Remote search, watching and extension execution can introduce a minecode-owned helper when they need one.

Port the workbench contracts from the pinned tree. The [remote indicator](../vscode/src/vs/workbench/contrib/remote/browser/remoteIndicator.ts) drives connection actions and status. The [remote filesystem client](../vscode/src/vs/workbench/services/remote/common/remoteFileSystemProviderClient.ts) registers a provider for `vscode-remote`. The [remote terminal backend](../vscode/src/vs/workbench/contrib/terminal/browser/remoteTerminalBackend.ts) gives a terminal an execution location. SFTP is a minecode transport choice. The upstream filesystem client uses the VS Code Server IPC channel.

## Implementation order

1. **Preserve resource identity.** Reuse the [URI type](../src/vs/base/common/uri.zig) and the [existing provider registry](../src/vs/platform/files/common/fileService.zig). Today the registry splits a resource into scheme and path and collapses leading slashes. Carry the authority separately through provider dispatch, folder joins, tab identity and session serialization. For example, the provider for `vscode-remote://ssh-remote+dev/srv/app` must receive host `ssh-remote+dev` and path `/srv/app`. Cover identical paths on two hosts, escaped filenames, existing local session files, Windows drive paths and in-memory provider tests before adding network I/O.

2. **Connect through the normal workbench UI.** Add the connect command to the existing Command Palette and remote status entry. Accept an SSH config alias or an explicit destination. Let OpenSSH resolve the effective configuration and handle interactive authentication in a prompt the user can see. Keep connection setup and file requests off the UI thread. Show the selected host, connection progress, errors, retry and close actions. Publish a connected workspace only after the remote filesystem session is ready. Cancelling a connection should return the user to the original workspace.

3. **Open and save a remote folder.** Register the SFTP-backed provider and implement stat, directory listing, read and write. Route the folder picker, [Explorer](../src/vs/workbench/contrib/files/common/explorerModel.zig), and [text-file service](../src/vs/workbench/services/textfile/common/textFileService.zig) through it. Explorer currently opens directories directly, and the text-file service stores a concrete disk service. Retain the existing encoding and save-participant behavior. Audit workspace actions with direct disk access, including [closed-file edits in Replace All](../src/vs/workbench/browser/workbench.zig). Enable each action for remote resources once its entire path uses the provider. Gate other disk-only actions in a remote window so they cannot operate on a similarly named local checkout.

4. **Launch a terminal on the selected host.** Select the backend when the [terminal instance](../src/vs/workbench/contrib/terminal/browser/terminalInstance.zig) is created. Reuse the [local PTY integration](../src/vs/platform/terminal/node/pty.zig) to drive the interactive SSH process. Start the remote shell in the selected folder, including folders with spaces or shell metacharacters. Forward input and resize events, propagate exit status, and release the SSH process when the terminal closes. Surface a failed remote launch in that terminal.

5. **Recover from disconnects.** Preserve open buffers, dirty state and host identity during an outage. On reconnect, revalidate the remote file before retrying a save. A dropped acknowledgement can mean the server already wrote the file. Compare the server contents with the intended bytes and the last known version before reporting success, retrying, or asking the user to resolve a conflict. Restore remote tabs using their saved authority.

## First milestone acceptance

Use an isolated SSH server and a temporary workspace that also exists at the same absolute path on the client. Give the two copies different contents. Drive the real TUI through the Command Palette, folder picker, Explorer, editor and terminal.

| Exercise | Required evidence |
| --- | --- |
| Connect by SSH config alias and select the folder | The status bar names the alias. Explorer lists a server-only file. Cancelling or failing host verification leaves the original workspace usable. |
| Edit, save, close and reopen a file | A server-side byte comparison confirms the edit. The local copy retains its original contents. Repeat with spaces and non-ASCII characters in the filename. |
| Start and resize a terminal | A server-only marker identifies the host, `pwd` gives the selected folder and `stty size` reflects the resize. Closing the tab ends its SSH session. |
| Interrupt a save and reconnect | The buffer survives. Verify the outcome both when the write reached the server and when another writer changed the file. |
| Restore a session and open a local workspace | Restored tabs resolve to the recorded host. Existing local open, save, session restore and terminal tests pass. |

## Follow-on parity

Add remote file operations and change notifications, then route Quick Open and workspace search to the host. Next, run workspace Git and language services against the remote checkout and place workspace extensions in a remote extension host. Track port forwarding, persistent remote terminals and additional server platforms separately. Each feature should have an end-to-end check with a resource or executable available only on the server.
