// Port of the build-supplied product configuration used by
// `src/vs/platform/product/common/product.ts` and
// `src/vs/platform/product/common/productService.ts`.
//
// `dataFolderName` is a product input, not editor logic: Stable builds use
// `.vscode`, Insiders `.vscode-insiders`, the OSS build `.vscode-oss`, and the
// server products use their `serverDataFolderName`. Minecode owns a separate
// extension directory so Open VSX installs and updates do not modify VS Code.
// The upstream explicit directory and portable-mode overrides still apply.
pub const data_folder_name = ".minecode";

// Open VSX provides the Code - OSS-compatible extension gallery API.
pub const extension_gallery_service_url = "https://open-vsx.org/vscode/gallery";
pub const extension_gallery_item_url = "https://open-vsx.org/vscode/item";
pub const extension_engine_version = "1.147.0";
