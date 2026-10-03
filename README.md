# nvim 設定 (Windows / LazyVim)

LazyVim ベースの個人 Neovim 設定。複数の Windows マシンで共通利用するため、以下に対応している:

- treesitter パーサのビルド問題を `zig cc` ラッパーで回避
- レガシー C コードを gtags (GNU Global) でナビ(clangd を当てづらいコードベース向け)
- gtags が指標化できないソース(Shift-JIS、特殊拡張子等)向けに ctags フォールバック

## セットアップ手順 (新しい Windows マシン)

### 1. 必要なツールを入れる

PowerShell で:

```powershell
winget install Neovim.Neovim
winget install zig.zig
winget install Git.Git
winget install BurntSushi.ripgrep.MSVC    # ripgrep (grep とファイル検索) -- scoop install ripgrep でも可
winget install GNU.GLOBAL                 # gtags (レガシー C ナビ用) -- scoop install global でも可
winget install universal-ctags.ctags      # ctags (gtags のフォールバック) -- Universal 版を入れること
winget install TortoiseSVN.TortoiseSVN    # 任意: SVN の作業コピーで変更行に印を出す場合。インストーラで command line client tools を有効にする
```

すでに入っているものはスキップしてよい。

> **なぜ ripgrep が必要?** LazyVim は `grepprg` を `rg --vimgrep` に固定し、grep のピッカー(`<leader>/`、`<leader>sg`)も `rg` を直接呼ぶ。入っていないと `:grep` もプロジェクト検索も動かない。ファイル名検索(`<leader>ff`)は `fd` があれば `fd`、なければ `rg` を使うので、`rg` だけ入れておけば両方動く。
>

> **なぜ zig が必要?** treesitter パーサ (C コード) のコンパイルに `zig cc` を使う。詳細は[このセクション](#treesitter-ビルドが-zig-cc-経由な理由)。
>
> **なぜ gtags が必要?** clangd を当てづらい C プロジェクトで定義ジャンプ・参照検索するため。使い方は nvim の中で `:h cfg-c`。
>
> **なぜ Universal Ctags?** Strawberry Perl 同梱の Exuberant Ctags 5.8 は 2009 年版で、最新 C 拡張や Shift-JIS ソースで取りこぼす。新しい Universal Ctags を入れて PATH 優先度を上げる(or 古い方を消す)こと。

### 2. Nerd Font を入れる + Windows Terminal に設定

LazyVim はファイルアイコン等で Nerd Font の glyph を使う。フォントが対応していないと、アイコンが `◆` などの代替文字で表示される。

```powershell
scoop bucket add nerd-fonts
scoop install JetBrainsMono-NF
```

> scoop が無ければ <https://www.nerdfonts.com/font-downloads> から好きな Nerd Font の zip を DL → 全 .ttf を右クリック → 「すべてのユーザーにインストール」でも可。

インストール後、Windows Terminal の設定 (`Ctrl+,`) → 使うプロファイル → 外観 → **フォントフェイス** を `JetBrainsMono Nerd Font Mono` に変更(`Mono` 付きを推奨。アイコンが 1 セル幅に強制されて TUI レイアウトが崩れない)。

### 3. 設定をクローン

```powershell
git clone https://github.com/Taka-S-dev/nvim-config.git $env:LOCALAPPDATA\nvim
```

> 既存の `$env:LOCALAPPDATA\nvim` がある場合は退避してから。

### 4. PowerShell プロファイルから `nv` を読み込む

`bin/open-in-nvim.cmd`(外部ツールから nvim にファイルを送る wrapper)は、`\\.\pipe\nvim` で listen してる nvim インスタンスを前提にしている。これを `nv` で起動するため、PowerShell プロファイルから [`bin/profile-snippet.ps1`](bin/profile-snippet.ps1) を dot-source する。

**1 回実行すれば済む初期設定**(PowerShell で実行):

```powershell
$line = '. "$env:LOCALAPPDATA\nvim\bin\profile-snippet.ps1"'
if (-not (Test-Path $PROFILE)) { New-Item -ItemType File -Path $PROFILE -Force | Out-Null }
if (-not (Select-String -Path $PROFILE -Pattern ([regex]::Escape($line)) -Quiet)) {
    Add-Content $PROFILE "`n$line"
}
```

PowerShell を開き直せば `nv` が使える。

> **なぜ dot-source?** 中身を `$PROFILE` に貼り付けると、エイリアスを修正するたび全マシンで貼り直しになる。dot-source なら repo を pull するだけで全マシンに反映される。
>
> `open-in-nvim.cmd` を使わない(外部からファイルを送らない)なら、この手順はスキップして `nvim` を直接使えばよい。

### 5. 初回起動

```powershell
nv
```

- LazyVim が自動でプラグインを取得
- treesitter パーサも `bin/zig-cc.cmd` 経由で自動ビルド
- 初回は zig が compiler-rt / libc を構築するため数分かかる(2 回目以降はキャッシュで高速)

### 6. 確認

`:checkhealth nvim-treesitter` で全パーサが入っていれば完了。アイコンが正しく描画されていれば Nerd Font も問題ない。

---

## 使い方

キー、パネルの中の操作、検索のコツ、C の読み方、SVN の使い方は、nvim の中でヘルプとして読める。中身は [doc/cfg.txt](doc/cfg.txt)。このファイル(README)は、入れ方、マシン間の同期、困ったときの対処、設計の理由を書く場所。

| 見たいもの | 開き方 |
|---|---|
| 目次 | `:h cfg` |
| ある機能の節 | `:h cfg-pins` のように、`cfg-` に続けて名前。`:h cfg-` まで打って `Tab` を押すと候補が出る |
| ヘルプ全体から探す | `<leader>sh` で `cfg` と打つ |
| いま押せるキー | `<leader>` を押して少し待つ(which-key)。`<leader>sk` で、キーを説明の言葉から探す |

主な機能と、その節:

- gtags / ctags の定義ジャンプ、ピーク、呼び出し元の検索: `:h cfg-c`
- 名前に値を入れている所の一覧(代入の一覧): `:h cfg-writes`
- コールツリー: `:h cfg-call-tree`、ジャンプスタック: `:h cfg-jump-stack`、ピン: `:h cfg-pins`
- 複数の単語を色分けして光らせる: `:h cfg-words`、選んだ文字列と同じものを光らせる: `:h cfg-selection`
- 差分の帯と、下に出る差分のペイン: `:h cfg-diff`
- C の名前の色分け(マクロと enum の値を見分ける): `:h cfg-c-colours`
- SVN(状態の一覧、BASE との比較、ログ、行ごとに誰が書いたか(blame)): `:h cfg-svn`、Shift-JIS のソース: `:h cfg-encoding`、ctags の予備: `:h cfg-ctags`
- 検索のコツ(ripgrep の書き方、絞り込み): `:h cfg-grep`
- ssh 越しに `y` でコピーしたものを手元の PC へ渡す(OSC 52): `:h cfg-clipboard`

## 複数マシン間の同期

### 変更を push する (作業した側)

```powershell
cd $env:LOCALAPPDATA\nvim
git add -A
git commit -m "..."
git push
```

### 変更を取り込む (もう一方)

```powershell
cd $env:LOCALAPPDATA\nvim
git pull
```

その後 nvim を起動 → 必要なら `:Lazy restore`(下表参照)。

### Lazy コマンドの使い分け早見

| シチュエーション | 必要な操作 | 理由 |
|---|---|---|
| **新マシンで初回起動** | **何もしなくて自動** | `nvim` 起動時に lazy.nvim が `lazy-lock.json` に従って全プラグインを自動 install。treesitter パーサも自動ビルド。 |
| **プラグイン追加した別マシンで `git pull`** | 起動するだけ | 起動時に新プラグインが自動 install される |
| **`lazy-lock.json` が更新された pull の後** | `:Lazy restore` | lockfile の commit に合わせてプラグイン版数を固定。マシン間で完全同一にしたい時。 |
| **全プラグインを最新版に上げたい** | `:Lazy sync` または `:Lazy update` | git で最新を fetch + install。`lazy-lock.json` も更新される(commit して push する想定)。 |
| **プラグイン削除した側 / 取り込んだ側** | `:Lazy clean` (or `:Lazy sync`) | 不要になったプラグインを削除 |

→ 普段は **「起動するだけ」** で済むケースがほとんど。`:Lazy sync` を打つのは「自分から最新化したい時」だけ。

### マシンごとに有効にする extra

`:LazyExtras` で有効にした extra は `lazyvim.json` に書かれ、pull した全マシンで有効になる。ツールチェインがそのマシンにしか入っていない言語の extra のように、マシンごとに決めたいものは `lua/config/local.lua`(git 管理外)に書く:

```lua
vim.g.local_extras = {
  "lazyvim.plugins.extras.lang.rust",
  "lazyvim.plugins.extras.lang.go",
}
```

書いたマシンでだけ読み込まれる。名前は `:LazyExtras` の一覧にあるものと同じ。

---

## プラグイン更新後の確認 (bin/test.cmd)

`:Lazy update` の後に、PowerShell か cmd で:

```powershell
& "$env:LOCALAPPDATA\nvim\bin\test.cmd"
```

ヘッドレスの nvim がこの設定を読み込み、過去に実際に壊れた箇所を 1 分かからずに確かめる: 手を付けていないファイルの全行に変更マークが付く、`:grep` が返ってこない、索引ファイルやバックアップが検索結果に混ざる、定義ジャンプの着地先、ピークの小窓に実ファイルが入り込む、`tags` の出来る場所、ctags の複数候補の表示、ステータスラインの表示が消えない、Markdown が整形されずに素のまま表示される、Markdown のリンクを `gf` でたどれない、この README のリンク切れ、ピン留めした行に戻れない、ピンの階層や順番が崩れる、SVN の作業コピーで変更行に印が出ない、差分の場所を示す帯が左右でずれる、左右の窓がホイールで一緒にスクロールしない、下のペインが長い行の変更を見せない、C のマクロと enum の値が同じ色になる、コールツリーが関数の中の呼び出しを取り違える、ジャンプスタックの段の関数名が出ない、選んだ文字列と同じものが光らない、代入の一覧が比較やコメントまで拾う、ssh 越しのコピーが手元に届かない、SVN の blame の行が手元の編集でずれる、足したキーがヘルプ(`:h cfg`)に載っていない、ヘルプのリンクが切れている、プロセスを延々と起動する。失敗した項目の数が終了コードになる(`tests/run.lua` 自体が読み込めないときは 99)。

- 材料は毎回一時フォルダに作って消すので、手元のソースツリーには触れない
- `gtags` / `ctags` / `rg` / `git` が入っていないマシンでは、その項目は失敗ではなくスキップになる
- 画面でしか分からないこと(ピークの小窓の位置、クリックの体感速度)は対象外

---

## VS Code の nvim 拡張 (vscode-neovim)

`asvetliakov.vscode-neovim` は本物の nvim をバックグラウンドで動かすため、この設定がそのまま読み込まれる。UI は VS Code 側が描くので、UI 系プラグインまで起動すると無駄なうえにキーが衝突する。`lazyvim.json` の `vscode` extra でそれを絞っている。

| | ターミナルの nvim | VS Code 内の nvim |
|---|---|---|
| 読み込まれるプラグイン | 35 | 9 |
| flash (`s`) / mini.ai (`vif`) / treesitter テキストオブジェクト | 読み込む | 読み込む |
| lualine・bufferline・which-key・gitsigns・noice・trouble・aerial | 読み込む | 読み込まない(VS Code の UI を使う) |
| conform(保存時整形) / nvim-lspconfig / mason | 読み込む | 読み込まない(VS Code 側の言語拡張に一本化) |
| gtags (cscope_maps) | 読み込む | 読み込まない(定義ジャンプは VS Code の F12) |

整形と LSP を VS Code 側に一本化しているのは、同じバッファに 2 つのツールチェインが保存時に手を入れるのを避けるため。

VS Code 側だけキーが変わるものがある: `<S-h>` / `<S-l>` はタブ切替、`<leader>/` は全文検索、`<C-/>` はターミナル開閉で、いずれも VS Code のコマンドに繋がる。

extra は `vim.g.vscode` が立っていないと空を返すので、ターミナルの nvim には影響しない。

---

## 外部ツールから nvim にファイルを送る (open-in-nvim.cmd)

`bin/open-in-nvim.cmd` は「ファイルパスと行番号を渡すと、起動中の nvim にタブとして開く」wrapper。自作ツールやサードパーティの "open in editor" 系機能から登録して、編集対象を nvim 側で開くのに使う。

### 前提

- 受け側の nvim が `nv`(= `nvim --listen \\.\pipe\nvim`) で起動済みであること
- `nv` 未設定の場合は[セットアップ手順 4](#4-powershell-プロファイルから-nv-を読み込む) を先にやる
- listener がいない時は cmd が即エラーで抜けるので、外部ツール側はブロックされない

### 登録する設定文字列の例

外部ツール側で「エディタコマンド」「外部エディタ」等の項目にこの形で登録する。`{file}` / `{line}` は外部ツール側のプレースホルダ名に置き換える(ツールによって `%f` / `%l` 等の場合あり)。

```text
"%LOCALAPPDATA%\nvim\bin\open-in-nvim.cmd" "{file}" {line}
```

環境変数を展開しないツール向けには絶対パスでも可:

```text
"C:\Users\<user>\AppData\Local\nvim\bin\open-in-nvim.cmd" "{file}" {line}
```

ポイント:

- ファイルパスは **必ずダブルクォートで囲む**(スペース対策)
- 行番号はクォート不要(数値として扱う)
- 第 1 引数 = ファイル、第 2 引数 = 行番号、の 2 引数固定

### 動作確認

PowerShell から直接実行して確かめる:

```powershell
nv                                                    # listener を立てておく(別ウィンドウ)
& "$env:LOCALAPPDATA\nvim\bin\open-in-nvim.cmd" "C:\path\to\file.txt" 42
```

listener 側 nvim に `file.txt` がタブで開き、42 行目にカーソルが飛べば成功。

---

## トラブルシュート

### `winget install zig.zig` を忘れて起動した

起動時に「`zig not found on PATH...`」と警告が出る。zig を入れ直して再起動。

### 既存の zig キャッシュ含めて作り直したい

```powershell
Remove-Item -Recurse -Force $env:LOCALAPPDATA\nvim-data\site\parser
Remove-Item -Recurse -Force $env:LOCALAPPDATA\Temp\nvim
```

→ `nvim` 起動 → `:TSUpdate`

### `:checkhealth nvim-treesitter` で一部パーサが赤い

`:TSInstall! <言語名>` で個別再インストール。

### 定義ジャンプで `No definition found` が出る

- GTAGS DB が無ければ `<leader>jb` で生成(下の「初回セットアップ」を参照)。DB が無いファイルでは ctags だけが引かれる
- DB はあるのに見つからない場合、索引がコードより古い可能性が高い。`<leader>ju` で差分更新する(直らなければ `<leader>jb` で作り直す)
- `<leader>j*` も含め、単体で `global -xr 関数名` を実行すると結果が出るのに nvim からは空になる場合は、下の「global を単体で実行すると出るのに nvim からは空になる」を参照

### global を単体で実行すると出るのに nvim からは空になる

Windows 向けの `global.exe` には Cygwin ビルドがあり、nvim のような通常の Windows プロセスが用意したパイプには結果を書き込めない。終了コードは 0 のまま出力だけが空になる。

これは自動で回避している。直接起動の結果が空だと、ファイルへ出力させる方法、bash(Git for Windows / Cygwin)経由の方法の順に試し、結果が出た方法を覚える。覚えた方法は `stdpath("state")/gtags-transport` に保存し、次回の起動でも最初からそれを使う。セキュリティソフトがプロセス起動のたびに検査する環境では、失敗すると分かっている方法を毎回試すと 1 回あたり数秒かかるため。

- `:GtagsTransport` で現在の方法(`direct` / `file` / `bash`)と、それで結果が出た実績があるかを表示する
- `global.exe` を入れ替えた後などは `:GtagsTransport reset` で覚えた方法を捨てる
- `GTAGSROOT` / `GTAGSDBPATH` はバックスラッシュ区切りで渡している。Cygwin ビルドはスラッシュ区切りのパスだと空を返すため

起動位置は問わない。検索対象の DB は編集中のファイルから親方向に `GTAGS` を探して選ばれるので、別プロジェクトのファイルをタブで開いても、そのファイルが属するツリーの DB が使われる。

### ピークの小窓(`<leader>jp`)が読みたい行に重なる

窓は開いた後に画面上の位置を測り直し、カーソル行から 2 行離れるまで動かしている。それでも重なる場合は `:GtagsPeekDebug` で、最後に開いた窓の判断材料(ウィンドウの大きさ、カーソル行の位置、上下・横それぞれの空き、実際に置かれた位置)が 1 行で出る。

### 定義ジャンプが入力によって速さが違う(Ctrl+クリックだけ遅い、等)

`:GtagsJumpDebug` が最後のジャンプについて「引き金(key / click)・答えの出所・答えるまでの時間・着地までの時間」を 1 行で出す。

- 出所が `memory` なら、そのシンボルは前に引いた結果をメモリから返している。`global` は `global.exe` を起動した回で、セキュリティソフトがプロセス起動を検査する環境では数百 ms〜数秒かかる。キーで速くクリックで遅いと感じる場合、まずここが違っていないか(キーは同じシンボルへの再ジャンプが多く、クリックは毎回新しいシンボル)を見る
- 出所も時間も同じなのに体感が違うなら、遅れは nvim にクリックが届く前、つまり端末側にある

### ssh で入ると gtags が何も見つけない(ctags に切り替わる)

scoop はツールを `scoop\apps\<ツール>\current` から起動する。`current` は、入っているバージョンのフォルダ(`apps\global\6.6.14` など)へのジャンクションで、PATH に置かれる中継役の shim(`scoop\shims\global.exe` など)もここを通る。Windows の OpenSSH で入ったセッションでは、`current` を通るパスが開けない(「信頼されていないマウント ポイントが含まれているため、パスを走査できません」、エラー 448)。同じパスが、デスクトップで直接開いたシェルでは開ける。shim は `Shim: Could not create process` で失敗し、nvim から `global` を呼んでも空が返って、定義は ctags で探すことになっていた。

そのため nvim は起動時に、使うツール(`global`, `gtags`, `gtags-cscope`, `ctags`, `readtags`, `rg`)について、shim が指すパスの `current` を行き先のバージョンのフォルダに読み替え、そのフォルダを nvim の中の PATH の先頭に足している(`lua/config/scoop_shims.lua`)。ジャンクションは行き先を読むだけで通らない。ssh のセッションでも、これで gtags が答えることを確かめた。`scoop update` でバージョンが変わっても、起動のたびに読み直す。nvim を起動したシェルの PATH は変えないので、ssh のシェルで直接 `global` を打つと、今も同じエラーになる。そのときはバージョンのフォルダ(`%USERPROFILE%\scoop\apps\global\6.6.14\bin\global.exe` など)を直接呼ぶ。

### GTAGS を別のディレクトリに作ってしまった

`<leader>jb` は、開いているファイルを覆う GTAGS が既にあれば、その場所で作り直す。まだ無いツリーでは cwd に作るので、**作る前にそのディレクトリを表示して確認を求める**。違う場所なら No で止め、`:cd <project_root>` してから押し直す。誤って作ってしまった場合は、そこに出来た 3 ファイル (`GTAGS`, `GRTAGS`, `GPATH`) を削除する。残しておくと、その下の階層にあるファイルがすべてその GTAGS を見つけてしまう。

既に GTAGS があるツリーのファイルを開いていれば、cwd はそのルートに自動で移る(ウィンドウローカルの `lcd`)。cwd を意識する必要があるのは**まだ DB が無いツリーの初回生成**だけ。

---

## gtags まわりの設計メモ

- **なぜ vim-gutentags でなく cscope_maps?** Neovim ≥ 0.9 が cscope サポートを削除したため、gutentags の `gtags_cscope` モジュールがロード時にエラー終了する。cscope_maps.nvim は cscope プロトコルを Lua で再実装しているのでこの制約を回避できる。
- **なぜ `<leader>j` プレフィックス?** LazyVim の `<leader>c*` は code 系(format, action, rename 等)と衝突するため別名前空間に分けた。`j` = jump。
- **なぜ `<leader>jb` は `gtags` を直接起動する?** cscope_maps の `:Cs db build` はカスタム script に `-d <db>::<path>` 引数を自動付与する設計だが、`gtags` バイナリはその引数を受け付けないため。
- **なぜ `<C-LeftMouse>` も再マップ?** Vim 標準の `<C-LeftMouse>` は内部で `:tag <cword>` を直接実行し、`<C-]>` の再マップを経由しない。クリック位置にカーソルを移してから、`<C-]>` と同じ定義ジャンプに流している。
- **なぜ cscope_maps を通さない?** cscope_maps は 1 回の検索ごとに `gtags-cscope.exe` を起動し、それがさらに `global.exe` を起動して、両方の終了を待つ間エディタが固まる。`<C-]>` と `<leader>j*` は `global` を直接・非同期で呼ぶ。openssl ツリーでの実測は 1 回あたり約 90 ms → 約 20 ms。定義ジャンプは一度引いたシンボルを GTAGS が更新されるまでメモリから返す。cscope の各検索は `global` の同等のオプション(定義 `-d`・参照 `-r`・その他のシンボル `-s`・テキスト `-g`・ファイル `-P`)に置き換えてあり、openssl で `SSL_new` の呼び出し元 39 件は 1 件単位で一致した。
- **常駐させない理由**: `gtags-cscope` を常駐させても、内部で 1 問い合わせごとに `global.exe` を起動するため 1 回 32 ms 前後が下限だった。全定義を起動時に読み込む案は openssl なら 0.3 秒で済むが、Linux カーネルでは 75 秒・1.3 GB かかるので採らなかった。
- **cscope_maps が残っている理由**: `:Cscope` / `:Cstag` コマンドを使えるようにするため。キー操作からは使っていない。

---

## treesitter ビルドが zig cc 経由な理由

Windows で treesitter パーサを素の MinGW (Strawberry Perl 同梱の GCC) でビルドすると 2 種類の問題が出る:

1. **`ld.exe: Invalid argument`** — nvim-treesitter が `\\?\` プレフィックス付きの拡張長パスを linker に渡すが、古い `ld.exe` がこれを解釈できない
2. **`unable to parse target query 'x86_64-pc-windows-msvc'`** — tree-sitter CLI が clang 形式 4 要素ターゲットを渡すが、zig は 3 要素形式しか受け付けない

対策として `bin/zig-cc.cmd` というラッパーを挟んでいる:

- `\\?\` 対応 → zig 同梱の lld が解決
- ターゲット文字列の書き換え → `x86_64-pc-windows-msvc` を `x86_64-windows-gnu` に置換

`lua/config/options.lua` で `vim.env.CC` をこのラッパーに向けることで、nvim-treesitter / tree-sitter CLI から透過的に使われる。

---

## ディレクトリ構成 (抜粋)

```
$env:LOCALAPPDATA\nvim\
├── bin\
│   ├── zig-cc.cmd          # zig cc ラッパー (Windows 用)
│   ├── open-in-nvim.cmd    # 外部ツールから nvim にファイルを送る wrapper
│   ├── test.cmd            # プラグイン更新後の確認 (tests\run.lua を実行)
│   ├── gutentags\update_tags.cmd # gutentags 付属バッチの出力を NUL に向ける wrapper
│   └── profile-snippet.ps1 # `nv` エイリアス定義 ($PROFILE に貼り付け)
├── doc\
│   └── cfg.txt             # 使い方のヘルプ (:h cfg)。doc\tags は起動時に作る (git 管理外)
├── lua\
│   ├── config\            # 設定そのもの
│   │   ├── options.lua     # CC 設定はここ
│   │   ├── keymaps.lua
│   │   ├── autocmds.lua
│   │   ├── features.lua    # 下の taka\ の道具を読み込む
│   │   ├── clipboard.lua   # ssh で入っているとき、コピーを手元の端末へ渡す (OSC 52)
│   │   ├── scoop_shims.lua # scoop のツールを shim とジャンクションを通さずに呼ぶ (ssh のセッション向け)
│   │   ├── local.lua       # マシン固有の設定 (git 管理外、あれば読む)
│   │   └── lazy.lua
│   ├── taka\              # この設定が足す道具。ほかの道具は init.lua の関数だけを使う
│   │   ├── lib\           # 複数の道具が使う部品
│   │   │   ├── gtags_global.lua # global の起動と、出力が届かない global.exe の回避
│   │   │   ├── c_outline.lua    # C ファイルの関数・呼び出し・マクロ・プロトタイプを構文から読む
│   │   │   ├── enclosing.lua    # ある行を囲む関数の名前を、言語を問わず treesitter で取る
│   │   │   ├── sidebar.lua      # 脇のパネル(ピン、コールツリー、ジャンプスタック)が共有する部品
│   │   │   └── activity.lua     # 裏で動いている処理をステータスラインに出す
│   │   ├── diff\
│   │   │   ├── map.lua     # 比べている窓の右端に、違いの場所を示す帯
│   │   │   ├── scroll.lua  # 比べている左右の窓を、ホイールでも一緒にスクロールさせる
│   │   │   ├── pane.lua    # 比べている窓の下に、カーソルのある変更の左右を上下に並べるペイン (<leader>uP)
│   │   │   └── quit.lua    # 比べている画面を、どの窓でも q で終える
│   │   ├── svn\
│   │   │   ├── init.lua    # SVN の status / log / リビジョン差分 (<leader>v)
│   │   │   └── blame.lua   # 行ごとに誰がどのリビジョンで書いたかを、左の窓に出す (<leader>vb)
│   │   ├── call_tree\
│   │   │   ├── init.lua    # コールツリーのパネル (<leader>jh / jH)
│   │   │   └── gtags.lua   # GTAGS とファイルの構文から、呼び出し元と呼んでいる先を出す
│   │   ├── pins.lua        # 行をメモつきでピン留めし、階層に整理して後で戻る (<leader>jm / jM / jo)
│   │   ├── jump_stack.lua  # 定義・参照へ飛んで潜っている段を右のパネルに出す (<leader>jy)
│   │   ├── writes.lua      # C の名前に値を入れている所の一覧 (<leader>jw)
│   │   ├── c_macros.lua    # C のマクロと enum の値を、使っている所で色分けする
│   │   ├── words.lua       # 複数の単語を色分けして光らせる (<leader>hh)
│   │   ├── selection_matches.lua # 選んだ文字列と同じものを、選んでいる間だけ光らせる
│   │   ├── scope_pin.lua   # いまのスコープの線を固定する (<leader>jl)
│   │   ├── markdown_links.lua # Markdown のリンクを gf でたどる
│   │   └── cd_picker.lua   # 外部のピッカーで cwd を移す :C / :Cf / :Zi (オプション)
│   └── plugins\            # 追加プラグイン定義
│       ├── aerial.lua      # シンボルアウトライン
│       ├── gtags.lua       # gtags ナビ(定義ジャンプ・<leader>j*)
│       ├── gutentags.lua   # ctags で tags を維持 (gtags fallback)
│       ├── svn.lua         # SVN: 変更行の印 (vim-signify、svn のみ) と <leader>v のキー
│       ├── snacks-scroll.lua # 差分の窓ではなめらかスクロールを切る
│       ├── markdown.lua    # Markdown を画面上で整形表示 (render-markdown.nvim)
│       └── treesitter.lua  # 追加パーサ
├── init.lua
├── lazy-lock.json          # プラグイン版数ロック (commit する)
├── ripgreprc               # nvim から呼ぶ rg の共通引数 (索引ファイルとバックアップの除外)
└── README.md               # このファイル
```
