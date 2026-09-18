# nvim 設定 (Windows / LazyVim)

LazyVim ベースの個人 Neovim 設定。複数の Windows マシンで共通利用するため、以下を仕込んである:

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
winget install GNU.GLOBAL                 # gtags (レガシー C ナビ用) -- scoop install global でも可
winget install universal-ctags.ctags      # ctags (gtags のフォールバック) -- 必ず Universal 版を!
```

すでに入っているものはスキップしてよい。

> **なぜ zig が必要?** treesitter パーサ (C コード) のコンパイルに `zig cc` を使う。詳細は[このセクション](#treesitter-ビルドが-zig-cc-経由な理由)。
>
> **なぜ gtags が必要?** clangd を当てづらい C プロジェクトで定義ジャンプ・参照検索するため。詳細は[このセクション](#レガシー-c-ナビゲーション-gtags--cscope_mapsnvim)。
>
> **なぜ Universal Ctags?** Strawberry Perl 同梱の Exuberant Ctags 5.8 は 2009 年版で、最新 C 拡張や Shift-JIS ソースで取りこぼす。新しい Universal Ctags を入れて PATH 優先度を上げる(or 古い方を消す)こと。

### 2. Nerd Font を入れる + Windows Terminal に設定

LazyVim はファイルアイコン等で Nerd Font の glyph を使う。フォントが対応してないと `◆` の連打(豆腐)になる。

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

**1 回コピペで終わるブートストラップ**(PowerShell で実行):

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

## よく使うキー / コマンド早見

> **記法**: `<leader>` は <kbd>Space</kbd>、`<C-x>` は <kbd>Ctrl</kbd>+<kbd>x</kbd>、`<A-x>` は <kbd>Alt</kbd>+<kbd>x</kbd>。

### ファイル・バッファを開く

| キー | 動作 |
|---|---|
| `<leader>ff` | ファイル名で検索 (Find File) |
| `<leader>fg` | プロジェクト全体を grep (Find by Grep) |
| `<leader>fr` | 最近開いたファイル (Recent) |
| `<leader>fb` | 開いているバッファ一覧 |
| `<leader>e` | 左サイドにファイルツリー表示/トグル |
| `<C-Left>` / `<C-Right>` (ツリー内) | ツリーの幅を 5 桁ずつ狭める / 広げる |
| `Ctrl`+ドラッグ (ツリー内) | ツリーの幅をマウス位置に合わせる |
| `<S-h>` / `<S-l>` | 前 / 次のバッファに切替 |
| `<leader>bd` | 現在のバッファを閉じる |

### ウィンドウ(分割)操作

| キー | 動作 |
|---|---|
| `<C-w>s` / `<C-w>v` | 水平 / 垂直に分割 |
| `<C-h/j/k/l>` | 左 / 下 / 上 / 右のウィンドウへ移動 |
| `<C-w>q` | 現在のウィンドウを閉じる |
| `<C-w>=` | 全ウィンドウのサイズを均等に |

### コードジャンプ(gtags / ctags / LSP 共通)

| キー | 動作 |
|---|---|
| `<C-]>` または `Ctrl+クリック` | 定義へジャンプ |
| `<C-o>` | ジャンプ元へ戻る(VS Code の戻る相当) |
| `<C-i>` | 進む |
| `gd` (LSP) | LSP 経由の定義ジャンプ |
| `gr` (LSP) | 参照一覧 |
| `K` (LSP) | カーソル下のドキュメント表示 |
| `<leader>co` | シンボルアウトライン (Aerial) を開閉 — 関数/マクロ/構造体一覧 |
| `<leader>cO` | シンボルナビゲーションのポップアップ |

`<A-Left>` / `<A-Right>` も戻る / 進むに割り当ててあるが、ターミナル側が Alt+矢印をペイン移動などに使っている環境(WezTerm 等)では届かない。`<C-o>` / `<C-i>` を基本にする。

gtags 専用機能(呼び出し元検索 等)は[このセクション](#レガシー-c-ナビゲーション-gtags--cscope_mapsnvim)参照。

### 移動・編集の基本

| キー | 動作 |
|---|---|
| `gg` / `G` | ファイル先頭 / 末尾へ |
| `<C-d>` / `<C-u>` | 半画面ぶん 下 / 上 にスクロール |
| `*` / `#` | カーソル下の単語を 前方 / 後方 検索 |
| `n` / `N` | 次 / 前の検索結果へ |
| `u` / `<C-r>` | アンドゥ / リドゥ |
| `yy` / `dd` / `p` | 行ヤンク / 行削除 / ペースト(OS クリップボードと共有) |
| `gcc` | 行コメントトグル |
| `>>` / `<<` | インデント / アンインデント |
| `<leader>yp` | 現在位置を `path:line` でコピー(ビジュアルモードでは `path:開始-終了`) |
| `<leader>uW` | タブ文字のマーカー(`>`)を表示 / 非表示。タブとスペースが混在した字下げを直すときに。末尾の空白と全角空白のマーカーは常時表示 |
| `s` | 画面内の任意の位置へジャンプ (flash) — 2 文字打ってラベルを選ぶ |

### プラグイン管理・診断

| コマンド | 動作 |
|---|---|
| `:Lazy` | プラグイン管理 UI |
| `:Lazy sync` | プラグインのインストール/更新/削除を一括反映 |
| `:Lazy restore` | `lazy-lock.json` のバージョンに固定 |
| `:LazyExtras` | LazyVim の追加機能(言語別 LSP 等)管理 |
| `:Mason` | LSP / formatter / linter のインストーラ |
| `:checkhealth` | 全体の健康診断 |
| `:checkhealth nvim-treesitter` | treesitter だけ診断 |
| `:checkhealth vim.lsp` | LSP の attach 状況を見る |
| `:messages` | 直近のメッセージを再表示(エラーを後から見たい時) |

### 終了・保存

| キー | 動作 |
|---|---|
| `:w` | 現在のバッファを保存 |
| `:q` | 現在のウィンドウだけ閉じる(分割やサイドバーが残っていると nvim は終わらない) |
| `:wq` または `ZZ` | 保存して現ウィンドウを閉じる |
| `<leader>qq` | **全ウィンドウ閉じて nvim 終了**(ターミナルに戻る) |
| `:qa` | 同上(コマンド版) |
| `:qa!` | 未保存変更も破棄して全終了 |
| `:wqa` | 全部保存してから全終了 |

---

## grep / 検索のコツ

LazyVim は内部で **ripgrep + snacks picker** を使う。

### よく使うエントリポイント

| キー | 動作 |
|---|---|
| `<leader>sg` | プロジェクト全体を grep(自由入力) |
| `<leader>sw` (Normal) | カーソル下の単語をプロジェクト全体から検索 |
| `<leader>sw` (Visual) | 選択範囲の文字列をプロジェクト全体から検索 |
| `<leader>sb` | 現在のバッファ内で grep |
| `<leader>/` | 同上(別ショートカット) |

### picker 内で使える操作

picker を開いた状態で:

| キー | 動作 |
|---|---|
| `<C-j>` / `<C-k>` | 候補を下 / 上 移動 |
| `<Enter>` | 開く |
| `<C-x>` / `<C-v>` / `<C-t>` | 水平分割 / 垂直分割 / タブ で開く |
| `<C-q>` | **全候補を quickfix に流し込む** → `:copen` で一覧、`:cn`/`:cp` で巡回 |
| `<Tab>` | 候補を multi-select(複数まとめて quickfix へ) |
| `<Esc>` | 閉じる |

### クエリの書き方(ripgrep 構文)

入力欄では **ripgrep の正規表現** がそのまま使える:

| 入力 | 意味 |
|---|---|
| `foo` | リテラル foo を含む行 |
| `foo.*bar` | foo の後に bar(同一行) |
| `^static` | 行頭が `static` |
| `\bopen\b` | 単語境界つきで `open`(`openssl` 等にはマッチしない) |
| `foo\|bar` | foo または bar(`\|` を忘れずエスケープ) |
| `(?i)foo` | 大文字小文字を無視 |

### 絞り込みテクニック

**ファイル種別で絞る**: snacks picker は `<pattern> -- <ripgrepの追加引数>` 形式で、`-- ` 以降がそのまま ripgrep に渡される。**`--` の前後に半角スペース必須**。

```
my_func -- -t c            # C 言語タイプ(.c と .h の両方。rg --type-list で一覧)
my_func -- -g *.c          # 拡張子グロブ
my_func -- -g !test/**     # test 配下を除外(! 否定)
my_func -- -g src/**       # src 配下のみ
my_func -- -g src/**/*.c   # src 配下の .c だけ(2 条件は 1 つの glob にまとめる)
my_func -- --no-ignore     # .gitignore を無視して全部探す
my_func -- -i              # 大小区別なし
```

**引用符を付けないこと**。ピッカーはシェルを経由せず、入力を自前で分割して ripgrep に直接渡すため、`-g "*.c"` と書くと引用符ごと glob として扱われ 0 件になる。逆に `:grep` コマンドは cmd.exe を通るので**引用符が必要**。`-t c` はどちらでも同じに書けるので、迷ったらこちらを使う。

| 書き方 | `<leader>/`(ピッカー) | `:grep`(コマンド) |
|---|---|---|
| `-t c` | 動く | 動く |
| `-g *.c` | 動く | 動かない |
| `-g "*.c"` | 0 件になる | 動く |

**`-g` は 1 つの引数しか取らない**。`-g *.h ssl/**` と書くと `ssl/**` が検索対象パスとして扱われて破綻する。また複数の `-g` は AND ではなく **OR** なので、`-g *.h -g ssl/**` は「.h またはssl/ 配下」で件数が増える。「ssl 配下の .h」は `-g ssl/**/*.h` と 1 つにまとめる。

**`*` と `**` の違い**: `*` はディレクトリ区切り `/` をまたげず、`**` は何階層でもまたげる。openssl ツリーの .h ファイル 264 個で数えると `**/*.h` は 264 個、`*/*.h` は 31 個(ちょうど 1 階層下)しか一致しない。迷ったら `**` を使う。なお `/` を 1 つも含まないパターン(`*.h`)はファイル名だけで判定され、階層を問わない。

**glob は検索の基準ディレクトリからの相対パス**で判定される。`<leader>/` は Root Dir 版なので、`.git` の無いツリーでは基準が意図とずれることがある。`ssl/**/*.h` が 0 件になったら、基準が既に `ssl/` の中にある可能性が高い。`:pwd` で確認するか、cwd 基準の `<leader>sG` を使う。

**よくあるパターン: 関数定義だけを探す**

```
^static\s+.*my_func\(   # static 関数の定義
^\w+\s+\*?my_func\(     # 戻り値型 + 関数定義
```

**ファイル名で絞ってから中身**:

1. `<leader>sg` で grep → 多すぎる
2. `<C-q>` で quickfix に送る
3. `:Cfilter pattern` で quickfix をさらに絞る(`:cdo` で一括編集も可)

### 直接コマンドで使う

```
:Rg pattern         <-- 引数で直接 grep
:grep pattern       <-- vim 標準 grep(ripgrep に rebind 済)
:cnext / :cprev     <-- 検索結果を巡回
:copen / :cclose    <-- 結果一覧の開閉
```

---

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

`bin/open-in-nvim.cmd` は「ファイルパスと行番号を渡すと、起動中の nvim にタブとして開く」wrapper。自作ツールやサードパーティの "open in editor" 系機能から登録して、編集対象を nvim 側に飛ばすのに使う。

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

PowerShell から直接叩いてみるのが早い:

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
- DB はあるのに見つからない場合、索引がコードより古い可能性が高い。`<leader>jb` で作り直す
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

### `database build failed` と出る

`<leader>jb` は内部で `:!gtags` を叩くので、**cwd がプロジェクトルートになっている必要がある**。別ディレクトリで叩いた場合はそこに GTAGS ができてしまうので、`gtags` で出た 3 ファイル (`GTAGS`, `GRTAGS`, `GPATH`) を削除して、ルートで再実行。

既に GTAGS があるツリーのファイルを開いていれば、cwd はそのルートに自動で移る(ウィンドウローカルの `lcd`)。cwd を意識する必要があるのは**まだ DB が無いツリーの初回生成**だけで、そのときは `cd <project_root>` してから `nvim .` で開く。

---

## レガシー C ナビゲーション (gtags + cscope_maps.nvim)

clangd を当てづらいレガシー C プロジェクト向けに、定義ジャンプ・呼び出し元検索を gtags (GNU Global) で実現している。LSP 不要・ビルドシステム不要・古い C 方言でも動く。検索はすべて `global` を直接・非同期で呼ぶので、待ち時間があっても操作は止まらない。

### 初回セットアップ(プロジェクトごと)

```powershell
cd <project_root>
nvim .
```

nvim 内で `<leader>jb` を押すと `gtags` が走り `GTAGS`, `GRTAGS`, `GPATH` の 3 ファイルが生成される(数秒〜数分)。これで全機能が使えるようになる。

### キーマップ早見

| キー | 動作 |
|---|---|
| `<C-]>` / `Ctrl+クリック` | カーソル下の定義へジャンプ |
| `<C-t>` | ジャンプ元に戻る |
| `<leader>jp` | カーソル下の定義をジャンプせずに小窓で読む(ピーク)。窓内はスクロール可。`q` / `Esc` で閉じる、`Enter` でそこへジャンプ |
| `<leader>jb` | gtags DB を再生成(コード変更後) |
| `<leader>js` | このシンボルの全出現箇所 |
| `<leader>jg` | グローバル定義へ |
| `<leader>jc` | この関数の呼び出し元(callers)。enum の値やマクロは gtags が定義として記録しないので 0 件になる。使われている箇所は `<leader>js` で探す |
| `<leader>jt` | テキスト文字列検索 |
| `<leader>jf` | ファイル名検索 |
| `<leader>ji` | カーソル下のファイルを `#include` しているファイル(※下記) |

結果は snacks picker で表示される(LazyVim デフォルトの picker)。

`<leader>ji` は、gtags が include 関係を索引しないため `#include "foo.h"` の行を文字列として探している。cscope にある「この関数が呼んでいる関数一覧」(callees)と「この変数への代入」は gtags に相当する情報が無く、用意していない。

### 設計メモ

- **なぜ vim-gutentags でなく cscope_maps?** Neovim ≥ 0.9 が cscope サポートを削除したため、gutentags の `gtags_cscope` モジュールがロード時にエラー終了する。cscope_maps.nvim は cscope プロトコルを Lua で再実装しているのでこの制約を回避できる。
- **なぜ `<leader>j` プレフィックス?** LazyVim の `<leader>c*` は code 系(format, action, rename 等)と衝突するため別名前空間に分けた。`j` = jump。
- **なぜ `<leader>jb` だけ `:!gtags` を直接叩く?** cscope_maps の `:Cs db build` はカスタム script に `-d <db>::<path>` 引数を自動付与する設計だが、`gtags` バイナリはその引数を受け付けないため。
- **なぜ `<C-LeftMouse>` も再マップ?** Vim 標準の `<C-LeftMouse>` は内部で `:tag <cword>` を直接実行し、`<C-]>` の再マップを経由しない。クリック位置にカーソルを移してから、`<C-]>` と同じ定義ジャンプに流している。
- **なぜ cscope_maps を通さない?** cscope_maps は 1 回の検索ごとに `gtags-cscope.exe` を起動し、それがさらに `global.exe` を起動して、両方の終了を待つ間エディタが固まる。`<C-]>` と `<leader>j*` は `global` を直接・非同期で呼ぶ。openssl ツリーでの実測は 1 回 91 ms → 21 ms。定義ジャンプは一度引いたシンボルを GTAGS が更新されるまでメモリから返す。cscope の各検索は `global` の同等のオプション(定義 `-d`・参照 `-r`・その他のシンボル `-s`・テキスト `-g`・ファイル `-P`)に置き換えてあり、openssl で `SSL_new` の呼び出し元 39 件は 1 件単位で一致した。
- **常駐させない理由**: `gtags-cscope` を常駐させても、内部で 1 問い合わせごとに `global.exe` を起動するため 1 回 32 ms 前後が下限だった。全定義を起動時に読み込む案は openssl なら 0.3 秒で済むが、Linux カーネルでは 75 秒・1.3 GB かかるので採らなかった。
- **cscope_maps が残っている理由**: `:Cscope` / `:Cstag` コマンドを使えるようにするため。キー操作からは使っていない。

---

## 日本語を含むソース (Shift-JIS / EUC-JP)

Neovim の既定の `fileencodings` は `ucs-bom,utf-8,default,latin1` で日本語の項目を持たないため、cp932 のコメントが文字化けする。`lua/config/options.lua` で cp932 を判定順に加えてある。

| エンコーディング | 判定 |
|---|---|
| cp932 (Shift-JIS) | できる |
| UTF-8 / BOM 付き UTF-8 / UTF-16 | できる |
| 判定不能なバイト列 | latin1 として開く(バイト列は壊れない) |
| EUC-JP | 漢字を含めば通ることが多いが、対象外(下記) |

EUC-JP を候補に入れていないのは、EUC-JP のひらがなが cp932 の半角カタカナとしても正当なバイト列で、漢字を含まない EUC-JP ファイルを cp932 と誤判定するため。使わない候補は誤判定の可能性を増やすだけなので外している。遭遇したら `:e ++enc=euc-jp` で開き直すか、`options.lua` の `cp932` の後ろに `"euc-jp"` を足す。

UTF-8 以外のバッファは、ステータスラインにエンコーディング名が警告色で出る。cp932 が表現できない文字(絵文字や他コードページ由来の記号)を打つと、編集時ではなく `:write` の瞬間に `E513` で保存に失敗するため、その予告として表示している。

判定を間違えたファイルは `:e ++enc=cp932` のように明示して開き直す。

---

## ctags フォールバック (gutentags)

gtags は C/C++/Java など主要言語以外をほぼ取りこぼす。C コードでも Shift-JIS エンコーディングや非標準拡張子で動かないケースがある。そういう時のために vim-gutentags + ctags モードを併設している。

### 動き方

- プロジェクトの直下に空の `.gutctags-root` を置き、nvim で `:GutentagsUpdate!` を 1 回実行すると `tags` ができる(`$XDG_CACHE_HOME/nvim/gutentags/` 配下に保存、プロジェクトを汚さない)
- 以後はファイル保存のたびに差分更新
- 何もしなければ tags は作られない。複数のソースツリーを並べただけの親ディレクトリで巨大な tags を作ってしまう事故を防ぐため、自動生成は無効にしてある
- 除外したいディレクトリなど、マシン固有の設定は `lua/config/local.lua`(git 管理外)に書く。例:

  ```lua
  vim.g.gutentags_exclude_project_root = { vim.fn.expand("~/src/all-projects") }
  ```
- 定義ジャンプ(`<C-]>` / `Ctrl+クリック`)は gtags が空振りすると **自動で ctags にフォールバック** するので、gtags が効く所は gtags、ダメな所は ctags、と透過的に切り替わる
- タグ名は大文字小文字を区別して照合する(`tagcase=match`)。LazyVim の `ignorecase` のままだと `SSL_new` と `ssl_new` を同じタグとみなし、ジャンプのたびに候補選択で止まる
- エディタのローカル履歴(`.history/`)やバックアップ、他ツールの索引ファイルは ctags の索引から除外している。古いコピーが索引に入ると、フォールバック時にそちらへ着地するため

### ハマりどころ

- **Strawberry Perl 同梱の Exuberant Ctags 5.8 (2009) は使わない**。`winget install universal-ctags.ctags` で Universal Ctags を入れ、PATH 優先度を上げる
- Shift-JIS ソースを扱う場合は、Universal Ctags なら `--input-encoding=shift_jis` を `~/.ctags.d/*.ctags` で指定可能
- gtags でも動かない・ctags でも動かない言語の場合は、ファイル拡張子のマッピング(`--langmap`)を ctags 設定に追加する必要がある

---

## treesitter ビルドが zig cc 経由な理由

Windows で treesitter パーサを素の MinGW (Strawberry Perl 同梱の GCC) でビルドすると 2 種類の問題が出る:

1. **`ld.exe: Invalid argument`** — nvim-treesitter が `\\?\` プレフィックス付きの拡張長パスを linker に渡すが、古い `ld.exe` がこれを解釈できない
2. **`unable to parse target query 'x86_64-pc-windows-msvc'`** — tree-sitter CLI が clang 形式 4 要素ターゲットを渡すが、zig は 3 要素形式しか受け付けない

対策として `bin/zig-cc.cmd` というラッパーを噛ませている:

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
│   └── profile-snippet.ps1 # `nv` エイリアス定義 ($PROFILE に貼り付け)
├── lua\
│   ├── config\
│   │   ├── options.lua     # CC 設定はここ
│   │   ├── gtags_global.lua # global の起動と、出力が届かない global.exe の回避
│   │   ├── local.lua       # マシン固有の設定 (git 管理外、あれば読む)
│   │   ├── keymaps.lua
│   │   ├── autocmds.lua
│   │   └── lazy.lua
│   └── plugins\            # 追加プラグイン定義
│       ├── aerial.lua      # シンボルアウトライン
│       ├── gtags.lua       # gtags ナビ(定義ジャンプ・<leader>j*)
│       ├── gutentags.lua   # ctags で tags を維持 (gtags fallback)
│       └── treesitter.lua  # 追加パーサ
├── init.lua
├── lazy-lock.json          # プラグイン版数ロック (commit する)
└── README.md               # このファイル
```
