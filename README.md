<p align="center">
  <img src="docs/assets/romajime-logo.png" alt="romajime logo" width="160">
</p>

# romajime

romajime は、ローマ字で日本語を入力するための macOS InputMethodKit 実験実装です。

英語版の README は [README.en.md](README.en.md) にあります。

## 現在のフェーズ

Phase 1 は実装済みです。

- InputMethodKit コントローラでローマ字入力をバッファします。
- 長めのローマ字下書きに使えるよう、変換中バッファ内のスペースを保持します。
- 入力中の IME 風変換や候補巡回は行いません。
- 入力が止まったあと、バッファ全体を自動で変換して確定します。
- Return とテンキー Enter は、デフォルトでは変換中バッファ内の改行として扱います。
- Enter は無視する設定にもできるため、チャットアプリの送信ショートカットが意図しない生文字列の確定経路になりません。
- 変換中に Escape を押すと、即座に変換して確定します。
- 変換中でないときに Escape を押すと、フレーズジャンプモードを開始します。ジャンプラベルは読み順の英字ラベルまたは数字エイリアスに対応し、ラベルを入力してから Space でジャンプします。
- ルールベースのローマ字かな変換コアと、単純な `memory.md` 用語置換を使います。
- 利用可能な場合は、オンデバイスの Foundation Models でかな下書きを漢字に変換します。タイムアウト、エラー、古い macOS ではかな結果にフォールバックします。長文下書きでもモデル読み込み待ちが起きにくいよう、入力開始時にモデルを事前ウォームアップします。
- フォーカス喪失または入力ソース切り替え時は、OS が戻り値の前に変換中テキストの解決を期待するため、同期的にかな結果を確定します。
- marked text には適切な TSM hilite 属性を付けているため、クライアントをまたいでもキャレットは変換中バッファの末尾に留まります。

デフォルトのアイドル変換待ち時間は 1.2 秒です。非常に速く入力している場合は 1.8 秒まで延長されるため、長文下書きが途中で分断されにくくなります。romajime は Control+Enter や Command+Enter を必要としません。これらのキーはチャットアプリで送信ショートカットとしてよく使われるためです。

ジャンプモードでは、アクティブな `IMKTextInput` から周辺テキストを読み取り、空白区切りの単語ごとではなく、句読点や改行を使って大きめのフレーズにまとめます。その後、Space で入力済みラベルを確定すると、選んだフレーズへ挿入位置を移動します。英字ラベルは `a` から `z`、続いて `aa`、`ab` のように進みます。数字エイリアスは `1`、`2`、`3` のように進みます。ジャンプモードは 3 秒間操作がないとキャンセルされます。ジャンプ対象の先頭には短命なリンク風ラベルバッジを重ねて表示します。クライアントアプリが文字位置を返さない場合は、バッジ表示だけを省略し、キーボードによるジャンプ機能は維持します。

共有変換コアは `RomajimeCore` にあります。今後の AI 変換や iOS キーボードでも、同じ状態管理とバックエンド契約を再利用できるようにするためです。

## 設定

romajime は任意設定を次の場所から読み込みます。

```text
~/Library/Application Support/Romajime/config.json
```

ファイルがない場合や無効な場合、romajime は下記のデフォルトを使います。文字入力キーは設定できません。設定できるのは、非入力の制御キーとタイミングだけです。

```json
{
  "keyBindings": {
    "bufferSpace": { "keyCode": 49 },
    "newlineCommit": [{ "keyCode": 36 }, { "keyCode": 76 }],
    "ignoredCommit": [],
    "deleteBackward": { "keyCode": 51 },
    "convertOrJump": { "keyCode": 53 },
    "jumpConfirm": { "keyCode": 49 },
    "jumpCancel": { "keyCode": 53 }
  },
  "timing": {
    "idleBaseDelay": 1.2,
    "idleFastTypingDelay": 1.8,
    "idleFastTypingThreshold": 0.18,
    "idleSentenceBoundaryDelay": 0.45,
    "maxComposingDelay": 8.0,
    "localIntelligenceEnabled": true,
    "localIntelligenceTimeout": 0.3,
    "kanjiConversionEnabled": true,
    "kanjiConversionTimeout": 2.0,
    "jumpModeTimeout": 3.0
  }
}
```

デフォルトのキーコードは、Space `49`、Return `36`、テンキー Enter `76`、Delete `51`、Escape `53` です。完全一致の修飾キーが必要なバインディングには `"requiredModifiers"` を追加してください。

以前の Enter 動作に戻すには、`"newlineCommit": []` と `"ignoredCommit": [{ "keyCode": 36 }, { "keyCode": 76 }]` を設定してください。

## ビルドとインストール（推奨: Justfile）

### 前提条件

- macOS 26 SDK 以降。
- `xcodegen`（`brew install xcodegen`）と `just`（`brew install just`）。
- **Apple Development** 署名証明書。無料の Apple ID で十分です。
  Xcode -> Settings -> Accounts -> Apple ID を追加 -> Manage Certificates -> `+` -> Apple Development。

### クイックセットアップ

```bash
# ビルド、署名、~/Library/Input Methods へのインストール、登録を行います（再起動不要）
just install

# その後、romajime を手動で追加します。
#   System Settings -> Keyboard -> Input Sources -> Edit -> '+' -> Japanese -> romajime -> Add

# 登録確認 / テスト手順の表示
just check
just test
```

### 利用できる Justfile レシピ

すべてのレシピは `just help` で確認できます。

- **`just build`** - xcodebuild でプロジェクトをコンパイルします。
- **`just sign`** - Apple Development 証明書で署名します。
- **`just install`** - ビルド、署名、`~/Library/Input Methods` へのコピー、登録を行います。
- **`just register`** - インストール済みアプリを Text Input Services に再登録します。
- **`just check`** - 入力ソースがシステムから見えているか確認します。
- **`just setup`** - インストールし、System Settings での設定手順を表示します。
- **`just test`** - 手動テスト手順を表示します。
- **`just dev-run`** - 開発用にアプリを直接起動します。
- **`just clean`** - ビルド成果物を削除します。
- **`just uninstall`** - `~/Library/Input Methods` から入力メソッドを削除します。
- **`just test-unit`** - RomajimeCoreTests を実行します。
- **`just info`** - ビルド設定を表示します。

## 入力メソッドバンドル

デバッグ用の入力メソッドアプリは次の場所に生成されます。

```text
DerivedData/Build/Products/Debug/RomajimeInputMethod.app
```

## macOS 登録メモ（実地で得た知見）

開発署名した IME を macOS 26 の System Settings に表示するには、次の条件がすべて必要でした。`just install` はこれらの手順をすべて処理します。

1. **Bundle ID は途中のコンポーネントとして `.inputmethod.` を含む必要があります。**
   `com.f12o.inputmethod.Romajime` は動作しますが、`com.f12o.Romajime.inputmethod` のように末尾コンポーネントにしたものは入力ソーススキャンで黙って無視されます。実在する IME もすべてこの形です: `com.justsystems.inputmethod.atok35`、`dev.ensan.inputmethod.azooKeyMac`、`com.apple.inputmethod.Kotoeri`。
2. **`ENABLE_DEBUG_DYLIB: NO`。** Xcode のデバッグビルドは、通常スタブ実行ファイルと `*.debug.dylib` を生成します。これは IME バンドルを壊します。
3. **有効なコード署名。** `CODE_SIGNING_ALLOWED: NO` の ad-hoc ビルドは壊れた署名を残します。先にフレームワークへ署名し、その後アプリへ署名します（`codesign --force --options runtime --sign "Apple Development: ..."`）。
4. **コピーには `cp -r` ではなく `ditto` を使います。** `cp` はフレームワークのシンボリックリンク構造を平坦化し、署名を無効にします。
5. **ユーザーごとの入力ソースキャッシュを原子的に再構築します。** キャッシュは `$(getconf DARWIN_USER_CACHE_DIR)/com.apple.IntlDataCache.le*` にあります。古いキャッシュは新しい IME を隠します。削除と再スキャンは 1 つのプロセス内（`script/imesetup.swift refresh`）で行う必要があります。サンドボックス化されたプロセスが先にキャッシュを再構築すると、`~/Library/Input Methods` を読めず、ユーザー IME を含まないキャッシュを書き込んでしまいます。
6. **macOS 26 ではヘルパーから `TISRegisterInputSource` / `TISEnableInputSource` を呼ばないでください。** どちらも、他プロセスから見るとユーザーインストール済みバンドルを落とすストアを書き戻します。ディレクトリスキャンでバンドルを発見させ、ユーザーが System Settings で有効化する流れに任せます。

## メモリ

romajime は任意の用語置換を次の場所から読み込みます。

```text
~/Library/Application Support/Romajime/memory.md
```

各マッピングは 1 行です。

```text
mtg -> ミーティング
todo -> TODO
```

秘密情報やモデルレジストリトークンをここに保存しないでください。将来モデル関連の認証情報が必要になった場合は、1Password Developer Environments またはランタイム注入を使います。
