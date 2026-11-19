// Port of the build-supplied product configuration used by
// `src/vs/platform/product/common/product.ts` and
// `src/vs/platform/product/common/productService.ts`.
//
// `dataFolderName` is a product input, not editor logic: Stable builds use
// `.vscode`, Insiders `.vscode-insiders`, the OSS build `.vscode-oss`, and the
// server products use their `serverDataFolderName`. The TUI targets the Stable
// install that owns the extensions on the machine; other products are reached
// through `--extensions-dir` or `VSCODE_EXTENSIONS`, exactly like VS Code.
pub const data_folder_name = ".vscode";
