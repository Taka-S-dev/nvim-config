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
```

すでに入っているものはスキップしてよい。

> **なぜ ripgrep が必要?** LazyVim は `grepprg` を `rg --vimgrep` に固定し、grep のピッカー(`<leader>/`、`<leader>sg`)も `rg` を直接呼ぶ。入っていないと `:grep` もプロジェクト検索も動かない。ファイル名検索(`<leader>ff`)は `fd` があれば `fd`、なければ `rg` を使うので、`rg` だけ入れておけば両方動く。
>

> **なぜ zig が必要?** treesitter パーサ (C コード) のコンパイルに `zig cc` を使う。詳細は[このセクション](#treesitter-ビルドが-zig-cc-経由な理由)。
>
> **なぜ gtags が必要?** clangd を当てづらい C プロジェクトで定義ジャンプ・参照検索するため。詳細は[このセクション](#レガシー-c-ナビゲーション-gtags--cscope_mapsnvim)。
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

### 作業ディレクトリを移す

`<leader>ff` や `<leader>sg` は、開いているファイルから判定したプロジェクトのルートを対象にする。`.git` も `GTAGS` もない場所のファイルでは、作業ディレクトリ (cwd) が対象になる。大文字の `<leader>fF` と `<leader>sG`、`:grep`、ターミナルは、常に cwd を基準にする。

| キー / コマンド | 動作 |
|---|---|
| `:pwd` | 今の cwd を表示する |
| `:cd %:h` | 今のファイルのあるフォルダへ移る |
| `:cd -` | 直前の cwd へ戻る |
| `<C-c>` (ツリー内) | カーソル位置のフォルダを、今のタブの cwd にする (`:tcd`) |
| `.` (ツリー内) | ツリーの表示をカーソル位置のフォルダに絞る。cwd は変わらない |
| `<leader>fp` | 過去に開いたプロジェクトから選んで移る |
| `:LazyRoot` | 今のルートと、その判定の根拠を表示する |

`nvim some\dir` のようにフォルダを 1 つ渡して起動した場合は、そのフォルダが cwd になる。エクスプローラの「送る」でフォルダを渡した場合も同じ。

**オプション:** フォルダを絞り込んで選ぶ外部のピッカー(端末に選択画面を描き、選ばれたフォルダを標準出力に書くプログラム)を使って、cwd を移せる(`lua/config/cd_picker.lua`)。使うピッカーは、マシンごとに `lua/config/local.lua` の `vim.g.cd_picker` で指定する(書式は `cd_picker.lua` の冒頭)。指定がない環境や、そのプログラムが入っていない環境では、下のコマンドとキーは定義されず、ほかの機能にも影響しない。

| キー / コマンド | 動作 |
|---|---|
| `:C [絞り込み語]`、`<leader>fd` | cwd の下のフォルダを選んで移る |
| `:C -` | 直前の cwd へ戻る |
| `:Cf [絞り込み語]` | ファイルを選び、そのファイルのあるフォルダへ移る |
| `:Zi [絞り込み語]`、`<leader>fD` | zoxide の履歴から選んで移る |

ユーザー定義のコマンドは大文字で始まる。小文字の `:c` と `:cf` は標準コマンド(`:change`、`:cfile`)の略なので、上書きしていない。

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
| `<leader>um` | Markdown の整形表示を切り替える。既定はオンで、見出しの強調、表の罫線、コードブロックの背景を、編集中の画面にそのまま描く。カーソルのある行は元の記法に戻る |
| `gf` (Markdown) | カーソル位置のリンクをたどる。`[文字](リンク先)` のどこにカーソルがあってもよい。リンク先はファイル、`#見出し`、`ファイル#見出し`、URL(ブラウザで開く)。`<C-o>` で戻る。見出しの一覧は `gO`、前後の見出しへは `[[` / `]]` |
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
| `<C-q>` | **全候補を quickfix に送る** → `:copen` で一覧、`:cn`/`:cp` で巡回 |
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

**引用符を付けないこと**。ピッカーはシェルを経由せず、入力を自前で分割して ripgrep に直接渡すため、`-g "*.c"` と書くと引用符ごと glob として扱われ 0 件になる。`:grep` コマンドは cmd.exe を通るが、cmd.exe は `*` を展開しないので、引用符があってもなくても同じ結果になる。つまり引用符なしの書き方に揃えておけば、どちらでも動く。

| 書き方 | `<leader>/`(ピッカー) | `:grep`(コマンド) |
|---|---|---|
| `-t c` | 動く | 動く |
| `-g *.c` | 動く | 動く |
| `-g "*.c"` | 0 件になる | 動く |

**`-g` は 1 つの引数しか取らない**。`-g *.h ssl/**` と書くと `ssl/**` が検索対象パスとして扱われて破綻する。また複数の `-g` は AND ではなく **OR** なので、`-g *.h -g ssl/**` は「.h またはssl/ 配下」で件数が増える。「ssl 配下の .h」は `-g ssl/**/*.h` と 1 つにまとめる。

**`*` と `**` の違い**: `*` はディレクトリ区切り `/` をまたげず、`**` は何階層でもまたげる。openssl ツリーの .h ファイル 264 個で数えると `**/*.h` は 264 個、`*/*.h` は 31 個(ちょうど 1 階層下)しか一致しない。迷ったら `**` を使う。なお `/` を 1 つも含まないパターン(`*.h`)はファイル名だけで判定され、階層を問わない。

**glob は検索の基準ディレクトリからの相対パス**で判定される。`<leader>/` は Root Dir 版なので、`.git` の無いツリーでは基準が意図とずれることがある。`ssl/**/*.h` が 0 件になったら、基準が既に `ssl/` の中にある可能性が高い。`:pwd` で確認するか、cwd 基準の `<leader>sG` を使う。

**索引ファイルとバックアップは検索対象から外してある**: `tags`・`GTAGS`・`GRTAGS`・`GPATH`・`cscope.out`・`ctags.out` と、`*.BAK`・`*.bak`・`*~` は、どの検索でも除外される。ctags の `tags` はテキストなので、外さないとシンボルごとに索引の行(数百桁)が結果に混ざり、バックアップは元ファイルの一致をそのまま重複させる。除外の一覧はリポジトリ直下の `ripgreprc` にあり、nvim が `RIPGREP_CONFIG_PATH` でそれを指すので、`:grep`・ピッカー・`<leader>sr` のすべてに効く。足したいものは `ripgreprc` に 1 行足す。マシンに既に `RIPGREP_CONFIG_PATH` が設定されていればそちらが優先される。

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

`:grep` は黙って実行され、結果があれば下に quickfix の一覧が自動で開く。一覧の行で `Enter` を押すと、その場所が上の窓で開く(一覧は残る)。`rg` の生の出力は表示しない: あれは `ファイル:行:桁:` のテキストが流れるだけで、そこからは飛べない。

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

ヘッドレスの nvim がこの設定を読み込み、過去に実際に壊れた箇所を 30 秒ほどで確かめる: 手を付けていないファイルの全行に変更マークが付く、`:grep` が返ってこない、索引ファイルやバックアップが検索結果に混ざる、定義ジャンプの着地先、ピークの小窓に実ファイルが入り込む、`tags` の出来る場所、ctags の複数候補の表示、ステータスラインの表示が消えない、Markdown が整形されずに素のまま表示される、Markdown のリンクを `gf` でたどれない、この README のリンク切れ、ピン留めした行に戻れない、ピンの階層や順番が崩れる、プロセスを延々と起動する。失敗した項目の数が終了コードになる。

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

### GTAGS を別のディレクトリに作ってしまった

`<leader>jb` は、開いているファイルを覆う GTAGS が既にあれば、その場所で作り直す。まだ無いツリーでは cwd に作るので、**作る前にそのディレクトリを表示して確認を求める**。違う場所なら No で止め、`:cd <project_root>` してから押し直す。誤って作ってしまった場合は、そこに出来た 3 ファイル (`GTAGS`, `GRTAGS`, `GPATH`) を削除する。残しておくと、その下の階層にあるファイルがすべてその GTAGS を見つけてしまう。

既に GTAGS があるツリーのファイルを開いていれば、cwd はそのルートに自動で移る(ウィンドウローカルの `lcd`)。cwd を意識する必要があるのは**まだ DB が無いツリーの初回生成**だけ。

---

## レガシー C ナビゲーション (gtags + cscope_maps.nvim)

clangd を当てづらいレガシー C プロジェクト向けに、定義ジャンプ・呼び出し元検索を gtags (GNU Global) で実現している。LSP 不要・ビルドシステム不要・古い C 方言でも動く。検索はすべて `global` を直接・非同期で呼ぶので、待ち時間があっても操作は止まらない。検索のたびにステータスラインの右側にスピナーと `gtags: <探しているもの>` が出て、答えが来ると `gtags: SSL_new  18 ms (global)` のように所要時間と出所(`global` = `global.exe` を起動した / `memory` = 前に引いた結果を返した)に変わり、2 秒で消える。

### 初回セットアップ(プロジェクトごと)

```powershell
cd <project_root>
nvim .
```

nvim 内で `<leader>jb` を押すと、作る場所を確認したうえで `gtags` がバックグラウンドで走り、`GTAGS`, `GRTAGS`, `GPATH` の 3 ファイルが生成される(openssl で 1〜2 秒。ツリーが大きいほど長い)。その間も操作は止まらず、ステータスラインにスピナーと経過秒数が出て、終わると所要時間に変わる。これで全機能が使えるようになる。

### キーマップ早見

| キー | 動作 |
|---|---|
| `<C-]>` / `Ctrl+クリック` | カーソル下の定義へジャンプ |
| `<C-t>` | ジャンプ元に戻る |
| `<leader>jp` | カーソル下の定義をジャンプせずに小窓で読む(ピーク)。窓内はスクロール可。`q` / `Esc` で閉じる、`Enter` でそこへジャンプ。窓内で `<C-]>` / `Ctrl+クリック` を押すと、その語の定義を次の小窓で開き、`<C-t>` で前の小窓に戻る(小窓のまま辿れる) |
| `<leader>jb` | gtags DB を作り直す(バックグラウンドで実行。初回は作る場所を確認する) |
| `<leader>ju` | gtags DB を差分更新(変更したファイルだけ読み直す。コードを編集した後はこちら) |
| `<leader>jB` | ctags の `tags` を作り直す。作る場所の考え方は `<leader>jb` と同じ(下の「ctags フォールバック」を参照) |
| `<leader>js` | このシンボルの全出現箇所 |
| `<leader>jg` | グローバル定義へ |
| `<leader>jc` | この関数の呼び出し元(callers)。enum の値やマクロは gtags が定義として記録しないので 0 件になる。使われている箇所は `<leader>js` で探す |
| `<leader>jt` | テキスト文字列検索 |
| `<leader>jf` | ファイル名検索 |
| `<leader>ji` | カーソル下のファイルを `#include` しているファイル(※下記) |
| `<leader>jm` | 今の行をピン留めする。メモを聞かれる(空でもよい)。新しいピンは常に一覧の最後尾、最上位に入る。ピン留めした行には、行番号の横に印が、行末にメモが出る。すでにピンのある行で押すと、2 つ目は作らず、そのピンの「メモを編集」か「ピンを外す」を選べる(外したピンは、パネルの `u` で戻せる) |
| `<leader>jM` | ピンを探す。メモ・関数名・ファイル名で絞り込み、Enter でジャンプ。一覧の中で `<A-e>` はメモの編集、`<A-d>` は削除 |
| `<leader>jo` | ピンのパネルを右に開閉する。ピンを階層に整理する場所。パネル内のキーは下の表 |

結果は snacks picker で表示される(LazyVim デフォルトの picker)。

`<leader>ji` は、gtags が include 関係を索引しないため `#include "foo.h"` の行を文字列として探している。cscope にある「この関数が呼んでいる関数一覧」(callees)と「この変数への代入」は gtags に相当する情報が無く、用意していない。

**ピン**は、何段も関数を追った後で戻りたくなる場所に、自分の言葉のメモを付けて残すためのもの。マークは 26 個までで理由を書けず、ジャンプリストには通った場所が全部入る。ピンはプロジェクト(`GTAGS` か `.git` のあるディレクトリ)ごとに、nvim のデータディレクトリ(`stdpath("data")/pins/`)に保存され、ソースツリーには何も作らない。ピンは行の内容も覚えているので、ファイルが編集されて行がずれても、同じ内容の一番近い行に着地し、記録も追従する。行の横の印も同じで、ファイルを開いたときと保存したときに行の内容で探し直すので、エディタの外で(`git pull` などで)行がずれた後でも、印は今その行がある場所に出る。

パネル(`<leader>jo`)は、ファイルツリーと同じ作りのサイドバーで、画面の右に出る(左にはファイルツリーがあり、snacks は同じ側のサイドバー 2 つを上下に積んだものとして高さを半分にするので、左右に並べると画面の下半分が空く)。上に絞り込みの入力欄、下にピンの木が並ぶ。ジャンプしても開いたままになる。子のピンは、ファイルツリーと同じ補助線(`├╴` `└╴` `│`)で親につながる。最上位のピンには補助線を引かない(ファイルツリーのプロジェクト名にあたる、線の出どころになる行がないため)。印は、しおりの形で統一してある。子のないピンは 1 枚のしおり、子を持つピンは重なったしおりで、開いている間は輪郭だけ、閉じている間は塗りつぶしになる(フォルダの開閉と同じ考え方)。どの行にも同じ幅の印があるので、同じ階層のメモは同じ桁から始まる。各行は、左にメモ、右端にファイル名と行番号を表示する。右端に寄せてあるので、パネルの幅やメモの長さに関係なく、場所は必ず見える(メモが長すぎるときに隠れるのはメモの末尾)。関数名はパネルには出さず、`<leader>jM` の一覧に出る。絞り込みは、パネルでも関数名に一致する。

入力欄(`/` か `i` で移る)に文字を打つと、メモ・行の内容・関数名・ファイル名で絞り込まれる。絞り込みは、ファイルツリーと同じく木の形を保つ: 一致したピンが、それがぶら下がっている親のピンと一緒に表示され、一致しない枝は消える。閉じているピンの下も探す。あいまい検索ではなく、打った文字列を含むものだけが一致する。**絞り込みの間は、並べ替え・階層の変更・開閉は無効になる**(入力欄を空にすると戻る)。ジャンプ、メモの編集、削除は、絞り込みの間も使える。

パネルの中のキー:

| キー | 動作 |
|---|---|
| `Enter` | そのピンへジャンプ(パネルの隣のウィンドウで開く) |
| `K` / `J` | 同じ階層の中で、1 つ上 / 下と入れ替える。下にぶら下がっているピンも一緒に動く |
| `>` | すぐ上のピンの子にする |
| `<` | 1 段外に出す(親のすぐ後ろに並ぶ) |
| `h` / `l` | 下にぶら下がっているピンを閉じる / 開く(`za` で切り替え)。閉じた状態は保存される |
| `r` | メモを編集 |
| `dd` | 削除。1 個なら確認なしで消えるので、続けて消せる(`u` で戻せる)。`Tab` で印を付けたピンがあれば、それをまとめて消す。2 個以上をまとめて消すときだけ、確認が出る。子を持つピンを消すと、子は消えずに 1 段外へ出て、消したピンの位置に残る |
| `u` / `<C-r>` | 元に戻す / やり直す。対象は削除・並べ替え・階層の変更・メモの編集・ピンの追加。まとめて消したピンは `u` 1 回で全部戻る。履歴は nvim を閉じるまで |
| `Tab` / `<S-Tab>` | ピンに印を付けて次 / 前の行へ(ファイルツリーやほかのピッカーと同じ)。`<C-a>` で全部に印 |
| `q` | パネルを閉じる |

### 設計メモ

- **なぜ vim-gutentags でなく cscope_maps?** Neovim ≥ 0.9 が cscope サポートを削除したため、gutentags の `gtags_cscope` モジュールがロード時にエラー終了する。cscope_maps.nvim は cscope プロトコルを Lua で再実装しているのでこの制約を回避できる。
- **なぜ `<leader>j` プレフィックス?** LazyVim の `<leader>c*` は code 系(format, action, rename 等)と衝突するため別名前空間に分けた。`j` = jump。
- **なぜ `<leader>jb` は `gtags` を直接起動する?** cscope_maps の `:Cs db build` はカスタム script に `-d <db>::<path>` 引数を自動付与する設計だが、`gtags` バイナリはその引数を受け付けないため。
- **なぜ `<C-LeftMouse>` も再マップ?** Vim 標準の `<C-LeftMouse>` は内部で `:tag <cword>` を直接実行し、`<C-]>` の再マップを経由しない。クリック位置にカーソルを移してから、`<C-]>` と同じ定義ジャンプに流している。
- **なぜ cscope_maps を通さない?** cscope_maps は 1 回の検索ごとに `gtags-cscope.exe` を起動し、それがさらに `global.exe` を起動して、両方の終了を待つ間エディタが固まる。`<C-]>` と `<leader>j*` は `global` を直接・非同期で呼ぶ。openssl ツリーでの実測は 1 回あたり約 90 ms → 約 20 ms。定義ジャンプは一度引いたシンボルを GTAGS が更新されるまでメモリから返す。cscope の各検索は `global` の同等のオプション(定義 `-d`・参照 `-r`・その他のシンボル `-s`・テキスト `-g`・ファイル `-P`)に置き換えてあり、openssl で `SSL_new` の呼び出し元 39 件は 1 件単位で一致した。
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

- `<leader>jB` で `tags` を作る。開いているファイルを gutentags がプロジェクトとみなしていれば(バージョン管理されているディレクトリ、または空の `.gutctags-root` を置いたディレクトリ)、gutentags 経由でそのルートに作る。それ以外 — ファイルを開いていない、展開しただけのソースツリー、複数のチェックアウトを並べた親ディレクトリ — では `ctags -R` を直接バックグラウンドで実行し、`GTAGS` のあるディレクトリ、無ければ cwd に作る(cwd のときは場所を表示して確認する)
- 保存時に自動で更新されるのは、gutentags 経由で作った `tags` だけ。直接作った `tags` は `<leader>jB` で作り直す。展開しただけのツリーでも自動更新したければ、ルートに空の `.gutctags-root` を置く
- `tags` はプロジェクトのルートに出来る。Vim は設定なしでも上の階層へ `tags` を探しに行くので、gutentags の無い環境や他のツールからも同じファイルが使える。`GTAGS` と同じ場所でもある。検索結果には混ざらない(`ripgreprc` で除外している)。git 管理のツリーでは未追跡ファイルとして見えるので、個人のグローバル gitignore に `tags` を入れておく
- 索引はバックグラウンドで走り、その間ステータスラインにスピナーと `ctags: indexing`、1 秒を超えると経過秒数が出る。終わると所要時間が 2 秒表示され、3 秒以上かかった索引は通知でも知らせる
- 以後はファイル保存のたびに差分更新
- 何もしなければ tags は作られない。複数のソースツリーを並べただけの親ディレクトリで巨大な tags を作ってしまう事故を防ぐため、自動生成は無効にしてある
- 除外したいディレクトリなど、マシン固有の設定は `lua/config/local.lua`(git 管理外)に書く。例:

  ```lua
  vim.g.gutentags_exclude_project_root = { vim.fn.expand("~/src/all-projects") }
  ```
- 定義ジャンプ(`<C-]>` / `Ctrl+クリック`)は gtags が空振りすると **自動で ctags にフォールバック** するので、gtags で引ける箇所は gtags、引けない箇所は ctags、と透過的に切り替わる。ctags 側で候補が複数あるときも、Vim 標準の番号選択ではなく、gtags のときと同じピッカーが開く
- タグ名は大文字小文字を区別して照合する(`tagcase=match`)。LazyVim の `ignorecase` のままだと `SSL_new` と `ssl_new` を同じタグとみなし、ジャンプのたびに候補選択で止まる
- エディタのローカル履歴(`.history/`)やバックアップ、他ツールの索引ファイルは ctags の索引から除外している。古いコピーが索引に入ると、フォールバック時にそちらへ着地するため

### 注意点

- vim-gutentags 付属のバッチは、ログファイルを渡されないと進行状況をコンソール(`CON`)に直接書く。nvim のパイプを通らないので、そのままだと索引のたび、保存のたびに画面の上に文字が乗る。`bin/gutentags/update_tags.cmd` が、出力先を `NUL` にして元のバッチを呼び直している
- **Strawberry Perl 同梱の Exuberant Ctags 5.8 (2009) は使わない**。`winget install universal-ctags.ctags` で Universal Ctags を入れ、PATH 優先度を上げる
- Shift-JIS ソースを扱う場合は、Universal Ctags なら `--input-encoding=shift_jis` を `~/.ctags.d/*.ctags` で指定可能
- gtags でも動かない・ctags でも動かない言語の場合は、ファイル拡張子のマッピング(`--langmap`)を ctags 設定に追加する必要がある

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
├── lua\
│   ├── config\
│   │   ├── options.lua     # CC 設定はここ
│   │   ├── gtags_global.lua # global の起動と、出力が届かない global.exe の回避
│   │   ├── local.lua       # マシン固有の設定 (git 管理外、あれば読む)
│   │   ├── cd_picker.lua   # 外部のピッカーで cwd を移す :C / :Cf / :Zi (オプション)
│   │   ├── keymaps.lua
│   │   ├── markdown_links.lua # Markdown のリンクを gf でたどる
│   │   ├── pins.lua        # 行をメモつきでピン留めし、階層に整理して後で戻る (<leader>jm / jM / jo)
│   │   ├── autocmds.lua
│   │   └── lazy.lua
│   └── plugins\            # 追加プラグイン定義
│       ├── aerial.lua      # シンボルアウトライン
│       ├── gtags.lua       # gtags ナビ(定義ジャンプ・<leader>j*)
│       ├── gutentags.lua   # ctags で tags を維持 (gtags fallback)
│       ├── markdown.lua    # Markdown を画面上で整形表示 (render-markdown.nvim)
│       └── treesitter.lua  # 追加パーサ
├── init.lua
├── lazy-lock.json          # プラグイン版数ロック (commit する)
├── ripgreprc               # nvim から呼ぶ rg の共通引数 (索引ファイルとバックアップの除外)
└── README.md               # このファイル
```
