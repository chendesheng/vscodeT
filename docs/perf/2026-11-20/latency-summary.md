> Historical: VSCodeVim was removed; Vim is now the compiled-in `vscode-textbuffer.vim` extension. See `docs/vim.md`.


## ReleaseFast + VSCodeVim
| group | n | median ms | mean ms | min ms | max ms | frames/edit | last frame ms |
|---|---:|---:|---:|---:|---:|---:|---:|
| motion | 10 | 60.2 | 42.8 | 5.2 | 70.7 | 2 | 60 |
| mode | 2 | 39.0 | 39.0 | 9.1 | 68.9 | 2 | 66 |
| insert char | 5 | 12.0 | 10.0 | 5.6 | 13.3 | 5 | 422 |
| undo/redo | 2 | 36.1 | 36.1 | 10.2 | 62.1 | 5 | 450 |
ALL n=19 median=13.4 mean=33.0
motion<30ms: 4 30-50: 0 >=50: 6

## ReleaseFast native
| group | n | median ms | mean ms | min ms | max ms | frames/edit | last frame ms |
|---|---:|---:|---:|---:|---:|---:|---:|
| undo/redo | 2 | 14.1 | 14.1 | 13.1 | 15.2 | 3 | 421 |
| cursor | 8 | 4.8 | 5.1 | 2.5 | 8.1 | 1 | 5 |
| edit char | 2 | 6.8 | 6.8 | 5.8 | 8.0 | 3 | 420 |
ALL n=12 median=5.6 mean=6.9

## Debug + VSCodeVim
| group | n | median ms | mean ms | min ms | max ms | frames/edit | last frame ms |
|---|---:|---:|---:|---:|---:|---:|---:|
| motion | 10 | 165.4 | 170.4 | 126.6 | 222.2 | 2 | 180 |
| mode | 2 | 248.6 | 248.6 | 135.9 | 361.2 | 3 | 278 |
| insert char | 5 | 160.4 | 194.5 | 139.3 | 368.8 | 4 | 381 |
| undo/redo | 2 | 146.6 | 146.6 | 127.6 | 165.5 | 4 | 610 |
ALL n=19 median=160.4 mean=182.5
motion<30ms: 0 30-50: 0 >=50: 10

## Debug native
| group | n | median ms | mean ms | min ms | max ms | frames/edit | last frame ms |
|---|---:|---:|---:|---:|---:|---:|---:|
| undo/redo | 2 | 127.7 | 127.7 | 85.3 | 170.0 | 2 | 361 |
| cursor | 8 | 95.7 | 112.8 | 87.5 | 216.2 | 1 | 101 |
| edit char | 2 | 194.0 | 194.0 | 125.5 | 262.6 | 2 | 409 |
ALL n=12 median=101.4 mean=128.8
