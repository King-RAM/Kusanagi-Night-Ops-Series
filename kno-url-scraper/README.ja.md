# Kusanagi Night Ops – URL Scraper

[English](README.md) | [日本語]

`kno-url` は、Kusanagi Night Ops で使用される対話型の URL ユーティリティ群であり、**認可されたオフェンシブセキュリティ**、**レッドチーム**、**アドバーサリシミュレーション**用途を想定しています。

すべての実装は同じコアコンセプトを共有します:

- `Main URL:` というプロンプトを出す
- URL とフラグを 1 行で受け取る
- **HTML モード**（ページ取得 + URL 抽出）または **Network モード**（DevTools 風のネットワークキャプチャ、対応エディションのみ）で動作する
- オプションで **Night Ops self-destruct（自己削除）** を実行し、ローカルアーティファクトをクリーンアップする

この README は以下の実装に共通で適用されます:

- `kno-url.c` – C Edition（HTML + Night Ops、Network モードはスタブ）
- `kno-url.go` – Go Edition（HTML + フル Network モード）
- `kno-url-with-network-mode.go` – Go Edition（HTML + フル Network モードの単一ファイル版）
- `kno-url.py` – Python Edition（HTML + フル Network モード）
- `kno-url.ps1` – PowerShell Edition（HTML + Night Ops、Network モードはゲート + スタブ）

コミュニティでの期待される振る舞いやルールについては、`CODE_OF_CONDUCT.md` を参照してください。

---

## 1. kno-url が行うこと

高いレベルで見ると、**kno-url は URL “scraper” REPL** です。

- 任意の言語版のツールを起動します。
- バナーが表示され、その後繰り返し以下のようなプロンプトが出ます:

  ```text
  Main URL: <url> [flags]


* 各行を読み取り、トークンをパースして以下を判断します:

  * HTML モード（デフォルト）
  * Network モード（`-n` が指定され、そのエディションで実装されている場合）
  * Night Ops クリーンアップ（`--night-ops` が指定された場合）

その後、ツールは次のような処理を行います:

* HTML モードではページを取得・解析し、URL を抽出する
* Network モードでは、Playwright を使った実ブラウザで DevTools 風のネットワークイベントをキャプチャする（対応エディションのみ）
* カテゴリ／リソースタイプのフィルタや部分一致の検索フィルタを適用する
* カテゴリごとの URL 一覧を出力し（必要に応じてファイルにも書き出し）
* 必要に応じてローカルクリーンアップ／self-destruct をスケジュールまたは即時実行する

---

## 2. 各エディションの違い

すべてのエディションはコンセプト的には互換ですが、実装の詳細と対応機能が異なります。

* **C Edition – `kno-url.c`**

  * `libcurl` を利用して HTML を取得。
  * **HTML モード**（カテゴリ選択、`--search`、`--full`、`-o`）をサポート。
  * **`--night-ops` + `-sd`** による self-destruct をサポート。
  * `-n` フラグは **レッドチーム向けの警告用スタブ** としてのみ存在します:

    * 「ノイジーでステルスではない」という警告を出す。
    * このエディションでは **Network モードはサポートされない** ことを説明する。

* **Go Edition – `kno-url.go`**

  * **HTML モード + フル Network モード** を持つ Go バイナリ。
  * Network モードは **`playwright-go`** とローカルの Playwright ブラウザインストールを利用して実装。
  * `--night-ops` と `-sd` による self-destruct をサポート。

* **Go Edition（network-mode ファイル） – `kno-url-with-network-mode.go`**

  * 単一ファイルの Go エントリポイントで、**HTML + Network モード** のセマンティクスは `kno-url.go` と同等。
  * こちらも **`playwright-go`** を使用。
  * ビルドやデプロイスタイルに合わせて好きな方のエントリポイントを選択できます（挙動は揃えています）。

* **Python Edition – `kno-url.py`**

  * **HTML モード + フル Network モード** を持つ Python 3 スクリプト（内部で Python Playwright を利用）。
  * `.kno-url/` ディレクトリでより詳細な **Playwright のトラッキング** を行い、「Network モードを初めて実行する前から Playwright が存在していたか」を記録（`--night-ops` 時のクリーンアップロジックに使用）。
  * Network モードや self-destruct の挙動について、比較的リッチなヘルプテキストを提供。

* **PowerShell Edition – `kno-url.ps1`**

  * **HTML モード + Night Ops** に対応しつつ、**Network モードはゲート付きスタブ**。
  * Network モードでは以下をチェックして環境ゲートを行います:

    * **.NET** の有無
    * Playwright CLI の存在
    * ブラウザバンドルのインストール状況
    * GUI 利用可能かどうか
  * 実ブラウザの自動操作がノイジーであり、コントロールされた環境でのみ使うべきだという点を強調。
  * このエディションでは **実際のネットワークキャプチャは行わず**、主にゲーティング・警告・UX の整合性を目的としています。
  * `--night-ops` と `-sd` を用いた Windows 向け self-destruct（クリーンアップ）も実装。

---

## 3. モードとコアコンセプト

### 3.1 インタラクティブ REPL

すべてのエディションは、インタラクティブなループとして動作します:

```text
Kusanagi Night Ops: URL Scrapper (<Language> Edition)

Main URL: <url> [flags]
```

* 空行 → “No URL detected. Use -h or --help for usage.” を表示
* `-h` または `--help` → 各言語エディション固有のヘルプ・例を表示
* `--night-ops`（`-sd` の有無を問わず） → self-destruct フローを起動

---

### 3.2 HTML モード（デフォルト）

**HTML モード** は **`-n` が指定されていないとき** に使われます。

典型的な入力例:

```text
Main URL: https://example.com -s -md --search mp4,cdn -o results.txt
```

典型的な挙動:

1. **URL 正規化**

   * URL が `http://` または `https://` で始まっていない場合、`https://` を自動で補完。
   * `cnn.com` のような素のドメインや `host:port` 表記は、`https://cnn.com` のような完全な URL に正規化される。

2. **HTML 取得**

   * `curl` / `net/http` / `requests` / PowerShell 相当の仕組みで HTML を取得。

3. **URL 抽出 & カテゴリ分け**

   抽出した URL を以下のようなカテゴリに分類:

   * `-s` – **SCRIPTS**
   * `-md` – **MEDIA**
   * `-a` – **API / ENDPOINTS**
   * `-d` – **DOCUMENTS / CONFIG**
   * `-ht` – **HTML / FRAMEWORK**
   * `-O` – **OTHER**

4. **カテゴリロジック適用**

   * **カテゴリフラグが 1 つも指定されていない** 場合は、**すべてのカテゴリ** を対象にする。
   * `--no-media`（HTML-only）を使うと、「指定したカテゴリを含める」のではなく、「指定したカテゴリを除外する」という動きに切り替わる。

5. **検索フィルタの適用**（後述）

6. **結果の出力**

   * カテゴリごとにまとめて出力し、多くのエディションでは拡張子や URL でソートされる。
   * 必要に応じてファイルにも書き出す。

よく使う HTML 向けフラグ（スペルはエディション間で揃えています）:

* `-s -md -a -d -ht -O` – カテゴリフィルタ
* `--no-media` – 指定カテゴリを **除外** として扱う
* `--search <terms>` – カンマ区切りの部分一致フィルタ
* `--full` – カテゴリや `--search` を無視し、`curl` 風に HTML 全文をダンプ
* `-o <file>` – 出力をファイルにも書き出す

---

### 3.3 Network モード（`-n`）

**Network モード** を利用できるのは以下のエディションです:

* `kno-url.go`
* `kno-url-with-network-mode.go`
* `kno-url.py`

また、以下のエディションでは **警告付きスタブのみ** 提供されます:

* `kno-url.c`
* `kno-url.ps1`（Playwright の要件やノイズ性を強調しつつ、実際のトラフィックキャプチャは行わない）

#### 挙動（Go / Python エディション）

`-n` が指定され、環境が正しくセットアップされている場合:

* ツールは **Playwright** を使って対象 URL をブラウザで開きます。

* 一定時間、または中断されるまで、**DevTools 風のネットワークイベント** をキャプチャします。

* リソースの種類は以下のようなフラグでフィルタできます:

  * `-fx` – Fetch/XHR
  * `-d` – Document
  * `-css` – CSS
  * `-js` – JavaScript
  * `-f` – Font
  * `-img` – Images
  * `-md` – Media
  * `-mf` – Manifest
  * `-s` – Socket/WebSocket
  * `-wasm` – WebAssembly
  * `-O` – Other

* 実行時間は `-t <duration>` で指定します（例: `30`, `45s`, `2m`, `1h30m`）。
  または `--live` で指定すると、Ctrl + C で止めるまで走り続けます。

* `--search <terms>` も有効で、キャプチャされた URL に対して部分一致フィルタを適用します。

* `-o <file>` を指定すると、要約をファイルに書き出します。

**重要:** Network モードはフルブラウザスタックを使うため **非常にノイジー** で、ステルス性はありません。
**ラボ環境や明確に認可されたテストでのみ** 使用してください。

---

### 3.4 検索フィルタ（`--search`）

HTML モード／Network モード共通で利用できます。

* 例: `--search mp4,cdn,api`

  * カンマ区切りで複数の検索語を指定。
  * 各 URL について、指定語のうち **1 つ以上が部分一致（大文字小文字は無視）** した場合にだけ残す。
  * 他のフィルタとも組み合わさるため、URL は **モードごとのフィルタ** と **検索語フィルタ** の両方を通過する必要があります。

---

### 3.5 Night Ops Self-Destruct（`--night-ops`, `-sd`）

すべてのエディションには、**Night Ops クリーンアップメカニズム** が実装されています。パターンは大きく 2 つです。

1. **即時クリーンアップ（スタンドアロン）**

   ```text
   Main URL: --night-ops
   ```

   典型的な挙動:

   * 確認プロンプトを出す。

   * 以下のようなローカルアーティファクトのクリーンアップを試みる:

     * `.kno-url` のキャッシュおよびトラッキングディレクトリ
     * `__pycache__` やその他の Python アーティファクト（Python / PowerShell 版）
     * Playwright 関連ディレクトリ
       ※ ただし、「Network モードを実行する前から Playwright が存在していた」場合は消さないなど、トラッキング情報に基づいて処理（Python / PowerShell 版）
     * ツールのバイナリ／スクリプト自体（OS 依存の best-effort）

   * 成功メッセージを出して終了。

2. **`-sd` 付きの遅延 self-destruct**

   ```text
   Main URL: <url> [flags] --night-ops -sd <duration>
   ```

   * 通常の HTML / Network 処理を実行。
   * `90s`, `5m`, `1h15m30s`, `"1h 15m 30s"` などの形式で指定した時間だけスリープ。
   * 上記と同じクリーンアップ処理を **確認なし** で実行。
   * 終了。

すべてのクリーンアップは **ローカルでの best-effort** です。
システムログやリモートログ等、ローカルディレクトリの外側にあるフォレンジック情報までは **削除しません**。

---

## 4. 各言語版の依存関係

### C Edition（`kno-url.c`）

* C コンパイラと `libcurl` が必要です。
* ビルド例:

  ```bash
  cc -O2 -o kno-url-c kno-url.c -lcurl
  ./kno-url-c
  ```

### Go Editions（`kno-url.go`, `kno-url-with-network-mode.go`）

* Go ツールチェーンが必要です。

* Network モードには以下が必要です:

  * `playwright-go`
  * Playwright CLI 経由でインストールされたブラウザ
    （例: `playwright install`）

* ビルド例:

  ```bash
  # HTML + Network モード
  go build -o kno-url-go kno-url.go

  # 単一ファイル Network モード版
  go build -o kno-url-net kno-url-with-network-mode.go

  ./kno-url-go
  ```

### Python Edition（`kno-url.py`）

* Python 3 が必要です。

* Network モード利用時のセットアップ例:

  ```bash
  pip install playwright
  playwright install
  ```

* 実行例:

  ```bash
  python3 kno-url.py
  ```

### PowerShell Edition（`kno-url.ps1`）

* Windows PowerShell または PowerShell Core 上で動作します。

* Network モードの**ゲート用チェック**として、以下を確認します:

  * `.NET` の利用可否
  * Playwright CLI
    （例: `dotnet tool install --global Microsoft.Playwright.CLI`）
  * `playwright install` によるブラウザバンドル
  * GUI 利用可能かどうか

* 実行例:

  ```powershell
  powershell -ExecutionPolicy Bypass -File .\kno-url.ps1
  # または
  pwsh -File ./kno-url.ps1
  ```

---

## 5. クイックスタート例

### HTML モード（全エディション共通）

```text
Main URL: https://www.example.com/video/x9v4s9g -s -md -o urls.txt
Main URL: cnn.com --search mp4,cdn
Main URL: -u 10.8.1.4:80/video/x -a -d
Main URL: https://example.com --full
```

### Network モード（Go / Python）

```text
Main URL: https://example.com -n -t 30
Main URL: https://example.com -n -t 45s -fx -img
Main URL: https://example.com -n --live -md --search mp4,cdn
Main URL: https://example.com -n -t 1m -o net.txt
```

### Night Ops

```text
# 即時 self-destruct
Main URL: --night-ops

# 実行後 5 分で self-destruct
Main URL: https://example.com -s -md --night-ops -sd 5m
```

---

## 6. セーフティ・スコープ・法的注意事項

`kno-url` は次のような用途を想定しています:

* 個人ラボやコントロールされたトレーニング環境
* 自分が所有するシステムやアプリケーション
* **明確な書面による許可** を得ているシステム
  （例: 社内のペネトレーションテスト、範囲が定義されたバグバウンティ対象）

以下のような用途には **絶対に使用しないでください**:

* 無断アクセス、エクスプロイト、データ窃取
* ランサムウェアや恐喝行為
* 法律・契約・所属組織のポリシー等に違反するあらゆる行為

ターゲットやシナリオがスコープ内かどうか不明な場合は、
**明確な許可が出るまではスコープ外として扱ってください**。

コミュニティでのルールや報告フローについては、`CODE_OF_CONDUCT.md` を参照してください。

---

## 7. このフォルダ内のファイル

* `kno-url.c`
  C Edition – HTML モード、`--search`、`--full`、`-o`、Night Ops、Network モードのスタブ。

* `kno-url.go`
  Go Edition – HTML + Network モード、Night Ops。

* `kno-url-with-network-mode.go`
  Go Edition（単一ファイル） – HTML + Network モード、Night Ops。

* `kno-url.py`
  Python Edition – HTML + Network モード、Night Ops、Playwright トラッキングロジックを実装。

* `kno-url.ps1`
  PowerShell Edition – HTML モード、Night Ops、Network ゲーティングと警告（実キャプチャなし）。
