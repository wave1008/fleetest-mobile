# 設計: WebView とブラウザの中身

| 種別 | 範囲 | 読む場面 | 扱わないこと |
|---|---|---|---|
| 正典 | 木の出どころ・ブラウザと自作アプリの WebView を DOM から読むしくみ(DS-19〜21) | WebView / ブラウザの読み取りを変える前 | ブリッジ全般(→ [bridge.md](bridge.md)) |

WebView の中身をどの経路で読むかの設計。

## DS-19 木はどこから来るか(WebView / ブラウザの一覧)

**軸は2つ**(対象 × ブリッジ)。ここが唯一の一覧で、以下の節はその詳細。

| 対象 | ブリッジ | 木の出どころ | 殺しスイッチ |
|---|---|---|---|
| 自作アプリの WebView | Android の a11y ブリッジ | **DOM**(CDP。`webView` ノードがある画面だけ) | `FT_WEBVIEW_DOM=off` |
| 自作アプリの WebView | iOS **in-app** | **DOM**(`InAppWebViewDOM`) | `FT_WEBVIEW_DOM=off` |
| 自作アプリの WebView | iOS **xcuitest** | **a11y** | — |
| **ブラウザ**(Safari / Chrome) | ホスト側 | **a11y。足りないときだけ DOM** | `FT_BROWSER_DOM=off` |

**スイッチは2つで意味が割れている**: `FT_WEBVIEW_DOM` = 自作アプリの WebView(OS 共通)/
`FT_BROWSER_DOM` = ブラウザ本体(OS 共通)。**1つに束ねない** —— 束ねると
「ブラウザだけ止めて A/B」が取れない。

**iOS in-app が DOM なのは別の事情**: あちらは in-app ブリッジから WKWebView の a11y ツリーが
そもそも見えない(別プロセス提供)。

**Android の自作アプリが DOM なのは版差**(詳細は次節「Android の自作アプリも
DOM から読む」)。「a11y で読めるなら +147ms を払う理由が無い」とはしない ——
**読めることと、どの端末でも同じ属性で読めることは別**。

**どちらの木を見ているかの判別**: 要素の `web: true` が DOM 由来の印。ブラウザなのに
DOM 由来が1件も無ければ `browserA11yFallbackNote` が「a11y から来ている」と言う
(**粒度と命名を揃えてあるので中身では見分けられない**)。

**Android の自作アプリで DOM が読めなかったときは黙らない**: `route` が `.appWebView`
なのに `AndroidWebViewDOM.read` が nil のとき、`WebViewDOMFallback` が stderr へ理由を言う
(`warnBlankCaptureOnce` と同じく判定・文言は純粋関数、メモは static)。
**stderr の警告は 1 回でも、木には毎回申告する**: 結論の理由を (serial, package) ごとに控え、
以後の snapshot に iOS in-app と同じ `webViewPath = dom-unread` + `note`(短い理由)を載せる。DSL は注記
`webview-unread` と失敗文言(申告の note を引く)、MCP は目録の `webViewUnreadNote` で引用する —— stderr だけだと
MCP の応答にも結果 JSON にも残らない。
実測の起点: E2E-RN の `placeholder=` 検査が **local(`android-35/google_apis` = userdebug・
`ro.debuggable=1`)では緑・ランナー(`google_apis_playstore` = user・`ro.debuggable=0`)では決定的に
赤**で、APK も WebView 版も同一だった。SUT は release ビルド(非 debuggable)なので Chromium は
`webview_devtools_remote_<pid>` を開かず、DOM 読みが黙って a11y へ落ちていた。
**言うのは端末の事実で決まる2つだけ**: ①ソケットが無く、かつシステムもアプリも非 debuggable と
確認できた(構造的に開かない)/ ②同名プロセスが複数でソケットを1つに選べない。
**nil の大半は正常な過渡**(WebView 未生成・タブ未選択・遷移直後)なので、ソケットがある回・
debuggable なのにソケットがまだ無い回・事実が読めなかった回は**黙る**(鳴らすと健全な構成でも
毎回鳴る)。**回数は (serial, package) ごとに診断1回**: ソケット解決が結論(有り / 無し / 曖昧)を
返した時点でメモし、以後は問い合わせも警告もしない。未起動・adb 不能は結論ではないので次の
miss で引き直す。追加コストは miss 経路の adb 1往復(構造的の回だけ debuggable の問い合わせが
もう1往復)で、結論後は 0。文言では**アプリ自身の `setWebContentsDebuggingEnabled(true)` という
3つ目の口**に必ず触れる —— 「2つのフラグだけで決まる」と断定すると、その呼び出しを持つ受け手に
誤った直し方を指す(`WebViewDOMFallbackTests` が断定文言を否定で固定)。**挙動は変えない**
(警告だけ)。子の stderr を中継する `ScenarioHost` は、ドライバが自分で `⚠️` を付けた行に
重ねない(重ねると `⚠️ ⚠️` になる)。受け手向けの説明は
docs/user-docs/reference/selector/webview(.md/_ja.md)。

## DS-20 ブラウザの中身は DOM から読む

殺しスイッチは `FT_BROWSER_DOM=off`(自作アプリ側の `FT_WEBVIEW_DOM=off` とは別の口)。
**自作アプリの WebView は別の理由で別の門**(次節)。

### なぜ

「`android.webkit.WebView` は `<table>` のセルを a11y へ1つも公開しない」は根拠にならない
(セルは a11y に在る。取りこぼしは `SnapshotBuilder.mappedType` の葉テキスト救済の側にあった。
4 SUT で揃って再現したのは WebView の性質ではなく共通のフィルタ。教訓は docs/verification/)。

本物の根拠は**ブラウザ本体**。あちらは実際にページを部分的にしか a11y へ出さない
(監査22/23/25 の実 web ページ。Android Chrome が本文を1要素も公開しない形が2サイトで再現)。
a11y からは埋めようがないので DOM を直接読む。

### 既定は a11y。足りないときだけ DOM

**「ブラウザでは常に DOM」にはしない。** 「ページごとに a11y の充実度が変わるので条件で切り替えると
**このページでは通るが別のページでは落ちる**」という前提が実測で崩れたため:

- 充実度が変わって見えた正体は **a11y サービス接続から木が出来るまでの数秒の窓**で、
  ページの性質ではなかった(§実機だけの罠 の ⑵ と同じ現象)
- 窓を過ぎた実ページでは **a11y と DOM のラベル集合が完全に一致**した
  (Wikipedia 34 / 気象庁 61 / tenki.jp 75、いずれも差 0)
- **a11y は 6〜20 倍速い**(126ms 対 1430ms)

判定は `WebViewDOM.browserA11yLooksSufficient` の1箇所。足りないと見なすのは
**`webView` ノードが無い / その内側にラベルが1つも無い**の2つだけ。
DOM を入れるときは `webView` ノードの内側の a11y 要素を落としてから足す
(素朴に append すると本文が二重に並ぶ)。ノード自身とブラウザ chrome は a11y のまま残す。

判定は `FTCore.WebViewDOM` の1箇所(`WebViewDOMTree.swift`)。**`WebViewDOMSnapshot.swift` へ
置かない** —— あちらは `BridgeSourceSet` の inApp ブリッジ入力なので、ホスト専用の関数を足すと
dylib に無駄なコードが入り `BridgeContractTests` の指紋が鳴る。

### 口は3つ、その上の層は1つ

プロトコル層(JS・座標写し・差し込み)は共通で、**開け方だけが違う**。

| 相手 | 口 | 備考 |
|---|---|---|
| iOS 自作アプリの WKWebView | in-app ブリッジから直に JS | `InAppWebViewDOM` |
| Android Chrome | CDP。`adb forward localabstract:chrome_devtools_remote` | **pid が付かない**ので WebView の pid 一致規則とは別規則 |
| iOS Safari(シミュレータ) | `webinspectord_sim` の unix ソケット | 根が `/private/var/tmp` と `/private/tmp` の**2つ**ある |

**Chrome は debuggable でなくても `@chrome_devtools_remote` を公開する**(`chrome://inspect` が
成り立つ理由)。a11y が6要素しか返さなかった Wikipedia のページから、同じ JS で 64 ノードを
9ms で取得できた。

### 能動タブの選択は「順序」では決まらない

**`/json` は MRU 順ではない**(7タブの Chrome で先頭は前面ではない別サイトだった)。しかも
同じページを2タブ開くと**題名が一致する**。順序や題名で1つに決めると背面タブを掴み、
**Chrome は背面タブの JS を止めるので評価が返らない**(実測 183 秒待っても返らなかった)。

確からしい順に並べ(`rankedTabs`)、**上から試して応答したものを能動タブとみなす**。
根拠は強い順に ①アドレス欄と URL が一致 → ②フラグメントを落とせば一致 → ③部分一致 →
④題名一致 → ⑤残り。**フラグメントを最初から落とさない** —— 同じページの2タブを分ける
唯一の材料がそれのことがある。

**`URLSessionWebSocketTask.receive()` には締切が無い**ので必ず番犬を付ける。snapshot は
最頻の操作で、ここが無期限だと run ごと固まる。

### DOM は a11y の粒度・命名へ揃える

同じ画面を a11y と DOM で読んで**セレクタの書き方が変わらない**ようにする。

- **子孫が全部インラインのテキストなら1ノードへ畳む**。Chromium の accname は
  `<td><span>19</span> / <span>24</span></td>` を「19 / 24」1件で出すが、素の DOM 走査は
  葉ごとに3件出す。役割を持つ子孫(link/button/input/img)が1つでもあれば畳まない
- **`alt` の無い画像は `src` のファイル名を名前にする**(`logo_small.svg` → `logo_small`)。
  Chromium がそうしており、揃えないと置き換えた瞬間に名前が消える

**揃えた副作用**: ラベルだけでは a11y と DOM を見分けられない。**検証は木の構造で行う**
(ブラウザ chrome の後に id 無しノードが続くか。ラベルで見ると a11y の木を「DOM が効いている」と誤読する)。

### 実機(iOS)は口が違う

シミュレータの unix ソケットは実機に無い。実機は **usbmuxd → lockdownd → TLS → webinspectord**:

    /var/run/usbmuxd に ReadPairRecord / ListDevices / Connect(62078)
      → lockdown: QueryType → StartSession(EnableSessionSSL)→ **クライアント証明書付き TLS**
      → StartService "com.apple.webinspector" → Port と EnableServiceSSL
      → その Port へもう1本 Connect し、**同じ証明書で TLS**
      → 以後はシミュレータと同じ WIR プロトコル

**root は要らない**(ペアリング記録は `/var/db/lockdown/` を読めなくても usbmuxd が渡す)。
**外部ツールも要らない**(`ios-webkit-debug-proxy` は不要)。
iOS 17 以降 RemoteXPC/RSD へ移ったサービスもあるが、`com.apple.webinspector` は
**iOS 26.6 でも従来の lockdown から起こせた**(実測)。移された合図は `InvalidService` で、
そのときだけ stderr に出す。

`SecIdentity` は PKCS#12 を `kSecImportToMemoryOnly` で読む(**キーチェーンに触れない**)。

**Android の実機は特別扱い不要**(Pixel 4a で確認。Chrome は同じく `@chrome_devtools_remote`)。

### 実機だけの罠(3つとも実測で踏んだ)

**⑴ 1通が大きいと黙って捨てられる。** エラーも応答も返らず、60 秒待っても来ない。
しかも**上限は固定ではない** —— 同じ端末・同じページで2回測って境界がフレーム
7917/7981 と 8493/8557 に割れた(約 600 バイトの揺れ)。`Runtime.compileScript` でも同じで、
**コマンドの種類ではなく1通の大きさ**が効く。共有 JS(約 9.7KB)は1通で送れない。

対処は**分割して積む**(`assemblyExpressions`)。`globalThis.__ftSrc` へ `=`/`+=` で積み、
最後に eval して削除する。**共有 JS は1文字も変えない**(変えると他の3経路と別物になる)。
予算は **7000 → 駄目なら 4000**(境界のギリギリは狙わない。壊れ方が沈黙なので気付けない)。
**退避は繋ぎ直す**(同じ接続で RPC をやり直すと2周目のアプリ一覧が返らない)。
**閉じた直後の再接続も失敗する**ので 1.5 秒置く —— どちらも実機で陽性対照を通して確かめた
(予算を 200 に落として退避を強制的に走らせる)。**全体の締切は 30 秒**で、退避も内側。
**切るのはソース長ではなくフレーム長** —— JSON のリテラル化で 1.2 倍に膨らみ、
膨張率は場所によって違う(ソース 3000 → フレーム 5546 / 4000 → 8630)。
**文字単位で切る**(JS に日本語コメントがあり、バイトで切ると UTF-8 が割れる)。

**⑵ Web インスペクタが無効だと、TLS までは通って直後に切られる。**
`_rpc_reportIdentifier:` すら送れない。設定 → Safari → 詳細 → Web インスペクタ。

**⑶ 有効にする前から動いていた Safari は webinspectord に登録されない。**
アプリ一覧にデーモンだけが並び Safari が居ない。起動し直せば載る。

⑵⑶ は**人の操作でしか直せない**ので、黙って a11y へ落ちるだけにせず
**stderr で原因を名指しする**(`inspectorHint`)。**一覧が空のときは何も言わない** ——
単に Safari 未起動の可能性があり、そこで「起動し直せ」は的外れ(誤った助言は無いより悪い)。

## DS-21 Android の自作アプリの WebView も DOM から読む

**ブラウザとは理由も門も違う。** ブラウザは「a11y に本文が出ない」だが、こちらは
**同じ HTML・同じアプリでも WebView の版で属性が入れ替わる**(実測。記録は
`Sources/FTAndroid/AndroidWebViewVersions.swift` 冒頭):

    WebView 124 : textField ph="WebView 入力"   (placeholder あり / id なし)
    WebView 150 : textField id=wv_input          (id あり / placeholder なし)

トレードではなく**入れ替え**なので、`#id` も `placeholder=` も混在フリートでは移植できない。
**DOM から読めば木が両方を持つ**ので、版差が供給源で消える。

**だから門も違う**: ブラウザは a11y が足りていれば読まないが、**自作アプリは足りて見えても読む**
(問うているのは「読めているか」ではなく「**どの端末でも同じ属性が出るか**」)。
自作アプリ側の門は **`webView` ノードの有無だけ** —— 無い画面で pid 引きと forward を払わない。
判定は `AndroidWebViewDOM.route`(純粋)の1箇所。

**ソケット規則が2つある**:

| 相手 | ソケット | 解決 |
|---|---|---|
| Chrome | `@chrome_devtools_remote`(**pid なし**) | パッケージ名 → 固定名 |
| 自作アプリの WebView | `@webview_devtools_remote_<pid>` | `pidof <package>` の**アプリ自身の pid** |

**成立条件は debuggable だけ**(emulator-5554 / `com.ftester.e2e` で実測)。
**アプリが `setWebContentsDebuggingEnabled(true)` を呼ぶ必要は無い** —— debuggable なら
WebView が1つでも生成された時点でソケットが開く(確認した版は Chrome/150.0.7871.181)。
**アプリの協力を要る退化は足さない**(release ビルドは id を難読化するので、id で指すテスト自体が
debug ビルドの活動)。取れないときは例外にせず黙って従来の a11y。

**注入は ref の名前空間が違う**(踏みやすい罠)。ブリッジの `/type` `/clear` は
**自分の snapshot の ref しか受け付けない**(`BridgeRouter.centerOf` は未知の ref を 404)。
DOM ノードにはホストが新しい ref を振るので、そのままでは**入力だけが 404 で落ちる**
(タップは座標をホストが持っているので通る = 落ち方が入力に偏る)。
`AndroidWebViewDOM.bridgeRefMap`(中心点を含む最小の a11y 入力欄)で写してから送り、
注入は従来どおり SET_TEXT + resource-id 追跡 + 読み返しの経路に乗せる。
**木の ref そのものは書き換えない** —— `z` を持たない要素の塗り順は ref 順に落ちるので、
入力欄だけ小さい ref にすると**その欄が兄弟の裏にあると判定される**。
**ブラウザ経路には対応表を作らない**(今日の挙動のまま)。

**推測で1つ選ばない**: 一覧(`/proc/net/unix`)には他アプリの `webview_devtools_remote_<別 pid>`
も Chrome の口も並ぶ。採るのは**自分の pid と厳密一致する名前だけ**で、複数当たれば
`ambiguous` = a11y のまま(外すと**別プロセスの DOM を本物の画面として木へ差し込む**)。
pid 引きとソケット一覧は**1往復に畳む**(adb は1回ごとに数十 ms かかり、ここは毎 snapshot の経路)。
