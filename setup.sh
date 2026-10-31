#!/bin/bash
# setup.sh — high_sierra_claude (advisor) 安装脚本
#
# 目标: Mavericks(10.9) 至 High Sierra(10.13) 及之后的 Intel Mac(Tier B)。
# 这些系统自带的 curl 已支持 TLS 1.2，因此不需要额外编译即可直接使用。
# 若本机已有 ~/claude-toolchain（按 ppc_claude_cli 同样步骤编译出的
# 支持 TLS 的 curl/OpenSSL，Tier A = Snow Leopard 至 Mountain Lion 用），
# 则自动优先使用它。
#
# 本脚本做的事:
#   1. 选择要用的 AI(Gemini / Anthropic)
#   2. 引导输入并安全保存 API 密钥 (~/.claude-agent-env)
#   3. 把 claude-agent.pl 与 models.txt 放到 ~/claude-build/
#   4. 安装 ~/bin/advisor 包装命令
#   5. 安装 bash 补全（从 ~/.bash_profile source）
#   6. 生成可双击启动的 Advisor.app (GUI)（~/Applications）
#   7. 真正调一次 API 做连通性检查
#
# 多语言: 下载用户约七成在海外，所以多语言是必需的。
# 与 GUI(advisor_gui.py)、agent(claude-agent.pl) 一样，直接读 macOS 的
# 系统语言设置来判定(LANG 环境变量在 SSH/GUI 启动时
# 并不可靠)。bash 3.2(旧 Mac 的标配)没有关联数组，
# 所以用 msg() 里的 case 分支切换语言。

set -e

# --- 言語判定 ---
# 有 CLAUDE_LANG=en/ja 时最优先(用于不改系统语言、
# 只想确认英文显示的情况)。例: CLAUDE_LANG=en bash setup.sh
# 显示语言用 3 个值表示(ja / en / zh)。IS_EN 为兼容既有代码而保留。
LANGCODE="zh"
case "${CLAUDE_LANG:-}" in
  en*) LANGCODE="en" ;;
  ja*) LANGCODE="ja" ;;
  zh*) LANGCODE="zh" ;;
  *)
    if command -v defaults >/dev/null 2>&1; then
      LOCALE_DETECTED="$(defaults read -g AppleLocale 2>/dev/null || true)"
      case "$LOCALE_DETECTED" in
        ja*) LANGCODE="ja" ;;
        zh*) LANGCODE="zh" ;;
        "") LANGCODE="zh" ;;
        *) LANGCODE="en" ;;
      esac
    fi
    ;;
esac
IS_EN=0
[ "$LANGCODE" = "en" ] && IS_EN=1

# msg <key> [printf-args...]: 输出 key 对应的文案。
# 按 中文(默认) → 英文 → 日文 的顺序回退。
# 漏译也不会崩，既有的 en/ja 显示完全不变。
msg() {
  local key="$1"; shift
  local fmt=""
  # 中文。未命中时保持为空，让它回退到 en/ja。
  if [ "$LANGCODE" = "zh" ]; then
    case "$key" in
      err_no_providers) fmt="找不到厂商表：%s（providers.txt 必须和 setup.sh 放在一起）" ;;
      perl_reported) fmt="本机的 perl 是 %s。" ;;
      perl_broken) fmt="claude-agent.pl 在这台机器的 perl 上编译不通过：" ;;
      perl_broken_hint) fmt="上面是这台机器的 perl 给出的真实报错。装下去只会得到一个跑不起来的 advisor，所以先停在这里。请把这段发给维护者。" ;;
      perl_missing) fmt="找不到 perl（macOS 自带 /usr/bin/perl，可能被系统改造过）。" ;;
      err_bad_choice) fmt="无效的编号（请输入 1~%s）。" ;;
      key_intro_generic) fmt="需要 %s 的 API 密钥。还没有的话，在浏览器里打开下面这个页面：" ;;
      key_where) fmt="  %s" ;;
      api_error_nobase) fmt="models.txt 里没有 %s 的 base_url，无法连通性测试。" ;;
      tier_a) fmt="找到了 Tier A 工具链（~/claude-toolchain），将使用它。" ;;
      stock_curl) fmt="使用系统自带的 curl（Mavericks 及之后的版本已支持 TLS 1.2，无需另外编译）。" ;;
      title) fmt="=== high_sierra_claude (advisor) 安装向导 ===" ;;
      ask_provider) fmt="要使用哪一个 AI？" ;;
      enter_number) fmt="输入编号 [%s]: " ;;
      mark_has_key) fmt="  ← 已有密钥" ;;
      ask_confirm_switch) fmt="注意：你已经为 %s 配好密钥。
继续会把当前 AI 改成 %s（它还没有密钥，需要新粘一把）。
按 y 继续，直接回车保持用 %s：" ;;
      kept_previous) fmt="已保持使用 %s。" ;;
      using_provider) fmt="→ 使用 %s。" ;;
      reuse_key) fmt="直接使用已保存的 %s。" ;;
      reuse_key_hint) fmt="如果想换成别的密钥，请先执行 'rm %s' 再重新运行。" ;;
      paste_key) fmt="粘贴 API 密钥后按回车（不会显示在屏幕上）：" ;;
      err_empty_key) fmt="错误：没有输入任何内容。请重新运行。" ;;
      err_placeholder) fmt="错误：内容里含有 '<' 或 '>'。" ;;
      err_placeholder2) fmt="是不是把说明文字里的占位符号一起粘贴进来了？" ;;
      err_placeholder3) fmt="请不要带符号，只粘贴密钥本身的值。" ;;
      warn_short_key) fmt="警告：密钥只有 %s 个字符。复制是不是没复制全？" ;;
      saved_key) fmt="已保存到 %s（只有你的账户能读取该文件）" ;;
      placed_files) fmt="已把 claude-agent.pl / models.txt / advisor_gui.py 放到 %s。" ;;
      created_wrapper) fmt="已创建 %s。" ;;
      removed_old_wrapper) fmt="已删除旧的 %s。" ;;
      added_path) fmt="已把 %s 加入 PATH。" ;;
      installed_completion) fmt="已安装 bash 补全（%s）。" ;;
      path_ready) fmt="PATH 已生效，现在就能用 'advisor'。" ;;
      path_needs_source) fmt="PATH 已写入，但当前会话还没生效：执行 'source %s'，或关掉这个窗口开一个新终端。" ;;
      no_python3) fmt="没找到可用的 python3，跳过 Advisor.app 的生成。" ;;
      gui_no_tk) fmt="%s 缺少 Tk 图形库，跳过 Advisor.app 的生成。" ;;
      gui_install_hint) fmt="  命令行版 advisor 不受影响，照常可用。想用图形界面请装 python.org 的 Python 3（自带 Tk），然后重跑 setup.sh。" ;;
      created_app) fmt="已创建 %s（双击即可启动 GUI，不会打开终端）。" ;;
      created_app_hint) fmt="  拖到 Dock 或桌面上，下次就能一键打开。" ;;
      building_app) fmt="正在构建 Advisor.app（首次需要一点时间）…" ;;
      building_app_clt) fmt="正在安装 Xcode Command Line Tools（仅首次，约 190MB，签名应用需要它）…" ;;
      app_build_fallback) fmt="没能构建成正式应用，改为生成简易版（菜单栏里的应用名会显示为「Python」）。" ;;
      checking_api) fmt="正在测试 API 连通性…" ;;
      api_ok) fmt="连通性正常。准备就绪。" ;;
      usage_intro) fmt="使用方法：在终端里输入 'advisor' 即可。" ;;
      usage_help) fmt="  advisor --help            查看全部选项" ;;
      usage_select) fmt="  advisor --select-model    选择要用的模型" ;;
      usage_model) fmt="  advisor -m <ID>           仅本次指定模型" ;;
      usage_switch) fmt="  （对话中使用 /claude /gemini /deepseek /qwen /kimi /glm 切换 AI）" ;;
      model_reset_note) fmt="（已把模型从 %s 改成 %s 的默认模型 %s —— 旧的模型名不属于这家厂商，用它请求会被服务端拒绝）" ;;
      api_error) fmt="API 错误（HTTP %s）。请确认密钥是否正确，" ;;
      api_error_model_hint) fmt="如果服务器说模型名不被支持，请检查 models.txt 里该厂商的模型名（当前用的是 %s）" ;;
      api_error_body) fmt="--- 服务器返回的内容 ---" ;;
      *) : ;;
    esac
  fi
  if [ -z "$fmt" ] && [ "$IS_EN" = "1" ]; then
    case "$key" in
      err_no_providers) fmt="Provider table not found: %s (providers.txt must sit next to setup.sh)" ;;
      perl_reported) fmt="Local perl is %s." ;;
      perl_broken) fmt="claude-agent.pl does not compile with this machine's perl:" ;;
      perl_broken_hint) fmt="That is the real error from your perl. Installing anyway only produces an advisor that cannot start, so stopping here. Please send this to the maintainer." ;;
      perl_missing) fmt="perl not found (macOS ships /usr/bin/perl; this system looks modified)." ;;
      err_bad_choice) fmt="Invalid number (enter 1~%s)." ;;
      key_intro_generic) fmt="Needs a %s API key. If you do not have one, open this page in your browser:" ;;
      key_where) fmt="  %s" ;;
      api_error_nobase) fmt="models.txt has no base_url for %s, cannot run the connectivity test." ;;
      tier_a) fmt="Found the Tier A toolchain (~/claude-toolchain). Using it." ;;
      stock_curl) fmt="Using the system curl (Mavericks and later already support TLS 1.2, no extra build needed)." ;;
      title) fmt="=== high_sierra_claude (advisor) setup ===" ;;
      ask_provider) fmt="Which AI do you want to use?" ;;
      enter_number) fmt="Enter a number [%s]: " ;;
      mark_has_key) fmt="  <- key already saved" ;;
      ask_confirm_switch) fmt="Note: you already have a key for %s.
Continuing switches the current AI to %s (which has no key yet and needs a new one).
Press y to continue, or just Enter to keep using %s: " ;;
      kept_previous) fmt="Kept using %s." ;;
      using_provider) fmt="→ Using %s." ;;
      reuse_key) fmt="Using the already-saved %s." ;;
      reuse_key_hint) fmt="To use a different key, run 'rm %s' and start over." ;;
      paste_key) fmt="Paste your API key and press Enter (it won't be shown on screen): " ;;
      err_empty_key) fmt="Error: nothing was entered. Please run this again." ;;
      err_placeholder) fmt="Error: found '<' or '>' in the key." ;;
      err_placeholder2) fmt="Did you accidentally paste the placeholder brackets from the instructions too?" ;;
      err_placeholder3) fmt="Please paste just the key value, without those brackets." ;;
      warn_short_key) fmt="Warning: the key is only %s characters. Did the copy get cut off?" ;;
      saved_key) fmt="Saved to %s (readable only by your account)" ;;
      placed_files) fmt="Placed claude-agent.pl / models.txt / advisor_gui.py in %s." ;;
      created_wrapper) fmt="Created %s." ;;
      removed_old_wrapper) fmt="Removed the old %s." ;;
      added_path) fmt="Added %s to PATH." ;;
      installed_completion) fmt="Installed bash completion (%s)." ;;
      path_ready) fmt="PATH is in effect - you can run 'advisor' right now." ;;
      path_needs_source) fmt="PATH was written, but not active in this session yet: run 'source %s', or close this window and open a new Terminal." ;;
      no_python3) fmt="No usable python3 found, so skipping the Advisor.app build." ;;
      gui_no_tk) fmt="%s is missing the Tk graphics library, so skipping the Advisor.app build." ;;
      gui_install_hint) fmt="  The command-line 'advisor' is unaffected and still works. For the GUI, install Python 3 from python.org (it bundles Tk) and run setup.sh again." ;;
      created_app) fmt="Created %s (double-click to launch the GUI; no Terminal window opens)." ;;
      created_app_hint) fmt="  Drag it into the Dock or onto your Desktop for one-click access next time." ;;
      building_app) fmt="Building Advisor.app (first time may take a minute)..." ;;
      building_app_clt) fmt="Installing Xcode Command Line Tools (one-time, ~190MB, needed to sign the app)..." ;;
      app_build_fallback) fmt="Couldn't build the proper app bundle, so using the simple version instead (menu bar will show \"Python\" as the app name)." ;;
      checking_api) fmt="Checking the connection to the API..." ;;
      api_ok) fmt="Connection OK. You're all set." ;;
      usage_intro) fmt="Usage: just type 'advisor' in Terminal." ;;
      usage_help) fmt="  advisor --help            show all options" ;;
      usage_select) fmt="  advisor --select-model    choose which AI to use" ;;
      usage_model) fmt="  advisor -m <ID>           use a different AI for this session only" ;;
      usage_switch) fmt="  (mid-conversation: /claude /gemini /deepseek /qwen /kimi /glm to switch)" ;;
      model_reset_note) fmt="(Model changed from %s to %s's default %s — the old id does not belong to this vendor and would be rejected)" ;;
      api_error) fmt="API error (HTTP %s). Please check that the key is correct, and" ;;
      api_error_model_hint) fmt="If the server says the model name is unsupported, check that vendor's model id in models.txt (currently using %s)" ;;
      api_error_body) fmt="--- Response from the server ---" ;;
    esac
  fi
  if [ -z "$fmt" ]; then
    case "$key" in
      err_no_providers) fmt="プロバイダ表が見つかりません: %s（providers.txt は setup.sh と同じ場所に必要）" ;;
      perl_reported) fmt="このマシンの perl は %s です。" ;;
      perl_broken) fmt="claude-agent.pl がこのマシンの perl でコンパイルできません:" ;;
      perl_broken_hint) fmt="上はこのマシンの perl が出した本当のエラーです。このまま入れると起動しない advisor ができるだけなので、ここで止めます。この内容を保守担当に送ってください。" ;;
      perl_missing) fmt="perl が見つかりません（macOS には /usr/bin/perl が標準で入っています。システムが改造されている可能性）。" ;;
      err_bad_choice) fmt="番号が正しくありません（1~%s で入力してください）。" ;;
      key_intro_generic) fmt="%s の API キーが必要です。まだ無ければブラウザでこのページを開いてください:" ;;
      key_where) fmt="  %s" ;;
      api_error_nobase) fmt="models.txt に %s の base_url が無いため疎通確認できません。" ;;
      tier_a) fmt="Tier A toolchain (~/claude-toolchain) が見つかりました。こちらを使います。" ;;
      stock_curl) fmt="標準のcurlを使います(Mavericks以降はTLS1.2対応済みのため追加ビルド不要)。" ;;
      title) fmt="=== high_sierra_claude (advisor) セットアップ ===" ;;
      ask_provider) fmt="どちらのAIを使いますか?" ;;
      enter_number) fmt="番号を入力 [%s]: " ;;
      mark_has_key) fmt="  ← キー保存済み" ;;
      ask_confirm_switch) fmt="注意: %s のキーは既に保存されています。
このまま進むと現在の AI を %s に変えます（こちらはキー未設定で、新しく貼る必要があります）。
y で続行、Enter だけで %s のままにします: " ;;
      kept_previous) fmt="%s のままにしました。" ;;
      using_provider) fmt="→ %s を使います。" ;;
      reuse_key) fmt="保存済みの %s をそのまま使います。" ;;
      reuse_key_hint) fmt="別のキーに変えたい場合は 'rm %s' してから再実行してください。" ;;
      paste_key) fmt="APIキーを貼り付けてEnter(画面には表示されません): " ;;
      err_empty_key) fmt="エラー: 何も入力されませんでした。もう一度実行してください。" ;;
      err_placeholder) fmt="エラー: '<' か '>' が含まれています。" ;;
      err_placeholder2) fmt="説明文のプレースホルダー記号を誤って一緒に貼り付けていませんか?" ;;
      err_placeholder3) fmt="記号を含めず、キーの値だけを貼り付けてください。" ;;
      warn_short_key) fmt="警告: キーが %s 文字しかありません。コピーが途中で切れていませんか?" ;;
      saved_key) fmt="%s に保存しました(あなたのアカウントだけが読めるファイルです)" ;;
      placed_files) fmt="%s に claude-agent.pl / models.txt / advisor_gui.py を配置しました。" ;;
      created_wrapper) fmt="%s を作成しました。" ;;
      removed_old_wrapper) fmt="旧 %s を削除しました。" ;;
      added_path) fmt="PATHに %s を追加しました。" ;;
      installed_completion) fmt="bash補完を設置しました(%s)。" ;;
      path_ready) fmt="PATH が有効になりました。今すぐ 'advisor' を使えます。" ;;
      path_needs_source) fmt="PATH は書き込みましたが、このセッションではまだ有効ではありません: 'source %s' を実行するか、新しいターミナルを開いてください。" ;;
      no_python3) fmt="使える python3 が見つからないため Advisor.app の生成はスキップします。" ;;
      gui_no_tk) fmt="%s に Tk が入っていないため Advisor.app の生成はスキップします。" ;;
      gui_install_hint) fmt="  コマンド版 advisor は影響を受けず、そのまま使えます。GUI を使うには python.org の Python 3(Tk 同梱)を入れて setup.sh を再実行してください。" ;;
      created_app) fmt="%s を作成しました（ダブルクリックで GUI が起動。ターミナルは開きません）。" ;;
      created_app_hint) fmt="  Dock やデスクトップにドラッグしておくと次回から一発です。" ;;
      building_app) fmt="Advisor.app をビルドしています(初回は少し時間がかかります)..." ;;
      building_app_clt) fmt="Xcode Command Line Tools を導入しています(初回のみ・約190MB、アプリの署名に必要です)..." ;;
      app_build_fallback) fmt="正式なアプリとしてビルドできなかったため、簡易版で作成します(メニューバーのアプリ名は「Python」のままになります)。" ;;
      checking_api) fmt="APIへの疎通を確認しています..." ;;
      api_ok) fmt="疎通確認OK。準備完了です。" ;;
      usage_intro) fmt="使い方: ターミナルで 'advisor' と打つだけです。" ;;
      usage_help) fmt="  advisor --help            オプション一覧" ;;
      usage_select) fmt="  advisor --select-model    使うモデルを選ぶ" ;;
      usage_model) fmt="  advisor -m <ID>           このセッションだけモデルを指定" ;;
      usage_switch) fmt="  (会話中に /claude /gemini /deepseek /qwen /kimi /glm でAIを切り替え)" ;;
      model_reset_note) fmt="（モデルを %s から %s の既定 %s に変更しました。旧いモデル名はこのベンダーのものではなく、そのままでは拒否されます）" ;;
      api_error) fmt="APIエラー(HTTP %s)。キーが正しいか、" ;;
      api_error_model_hint) fmt="サーバーがモデル名を拒否している場合は models.txt の該当ベンダーのモデル名を確認してください（現在: %s）" ;;
      api_error_body) fmt="--- サーバーからの応答 ---" ;;
      *) fmt="$key" ;;
    esac
  fi
  if [ $# -gt 0 ]; then
    printf -- "$fmt\n" "$@"
  else
    printf '%s\n' "$fmt"
  fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# 版本号的唯一来源是仓库根目录的 VERSION 文件。
APP_VERSION="$(cat "$SCRIPT_DIR/VERSION" 2>/dev/null | tr -d ' \t\r\n')"
[ -z "$APP_VERSION" ] && APP_VERSION="0.0.0-dev"
ENV_FILE="$HOME/.claude-agent-env"
BUILD_DIR="$HOME/claude-build"
BIN_DIR="$HOME/bin"
COMPLETION_FILE="$HOME/.advisor-completion.bash"
APP_PATH="$HOME/Applications/Advisor.app"
ICON_SRC="$SCRIPT_DIR/launcher/advisor.icns"

# --- 0. 用**这台机器的 perl** 编译一遍（目标机 perl 5.26，CI 是 5.34/5.38）---
# 为什么在写任何配置之前：编译不通过的话，后面只会装出一个跑不起来的 advisor，
# 还顺带把 ~/.claude-agent-env 改成一半的状态。先验、再动手。
PERL_BIN="$(command -v perl 2>/dev/null || true)"
if [ -z "$PERL_BIN" ]; then
  msg perl_missing
  exit 1
fi
PERL_VER="$("$PERL_BIN" -e 'printf "%vd", $^V' 2>/dev/null || echo unknown)"
# ★ 必须 || true：脚本开着 set -e，赋值里命令替换失败会**立刻退出**，
#   连下面那段提示都打不出来（实测第一次就是这样，只留一个静默非 0 退出）。
PERL_C_OUT="$("$PERL_BIN" -c "$SCRIPT_DIR/agent/claude-agent.pl" 2>&1 || true)"
case "$PERL_C_OUT" in
  *"syntax OK"*) : ;;
  *)
    msg perl_reported "$PERL_VER"
    msg perl_broken
    printf '%s\n' "$PERL_C_OUT" | tail -6
    msg perl_broken_hint
    exit 1
    ;;
esac
# 顺便记一行版本：老机器上排查「为什么别人能用我不能用」时这就是第一手信息
if [ -n "${ADVISOR_SETUP_VERBOSE:-}" ]; then
  msg perl_reported "$PERL_VER"
fi

# 替换 ~/.claude-agent-env 里的一行(没有就追加)
upsert_env() {
  local var="$1" val="$2"
  touch "$ENV_FILE"
  grep -v "^export ${var}=" "$ENV_FILE" > "$ENV_FILE.tmp" 2>/dev/null || true
  mv "$ENV_FILE.tmp" "$ENV_FILE"
  printf 'export %s=%s\n' "$var" "$val" >> "$ENV_FILE"
  chmod 600 "$ENV_FILE"
}

# 有 Tier A 自编译 toolchain 就用它，没有就用系统自带的 curl
if [ -x "$HOME/claude-toolchain/bin/curl" ]; then
  CURL_BIN="$HOME/claude-toolchain/bin/curl"
  CACERT="$HOME/claude-toolchain/cacert.pem"
  msg tier_a
else
  CURL_BIN="curl"
  CACERT=""
  msg stock_curl
fi
echo ""

msg title
echo ""

# 先读入已有配置(用于判断能否复用密钥)
[ -f "$ENV_FILE" ] && . "$ENV_FILE" 2>/dev/null || true

# --- 1. 选择要用的 AI ---
# 厂商清单、密钥变量名、默认模型、取密钥的 URL 都以 providers.txt
# 为唯一来源。与 GUI 读的是同一个文件（不要在这里补厂商名）。
PROVIDERS_FILE="$SCRIPT_DIR/providers.txt"
if [ ! -f "$PROVIDERS_FILE" ]; then
  msg err_no_providers "$PROVIDERS_FILE"
  exit 1
fi

P_NAME=(); P_KENV=(); P_DMODEL=(); P_URL=(); P_LABEL=()
P_COUNT=0
while IFS='|' read -r _nm _ke _dm _ku _ja _en _zh; do
  # 不用 `case … continue ;;`：这个构造在 bash 3.2 上有解析问题（pre-commit hook 因此炸过）
  if [ -z "$_nm" ]; then continue; fi
  if [ "${_nm#\#}" != "$_nm" ]; then continue; fi
  [ -z "$_ke" ] && continue
  P_COUNT=$((P_COUNT + 1))
  P_NAME[$P_COUNT]="$_nm"
  P_KENV[$P_COUNT]="$_ke"
  P_DMODEL[$P_COUNT]="$_dm"
  P_URL[$P_COUNT]="$_ku"
  case "$LANGCODE" in
    zh) _lbl="$_zh" ;;
    en) _lbl="$_en" ;;
    *)  _lbl="$_ja" ;;
  esac
  [ -z "$_lbl" ] && _lbl="$_nm"
  P_LABEL[$P_COUNT]="$_lbl"
done < "$PROVIDERS_FILE"

if [ "$P_COUNT" -eq 0 ]; then
  msg err_no_providers "$PROVIDERS_FILE"
  exit 1
fi

# 先查已有密钥和当前正在用的 AI（避免重复覆盖造成事故）。
# 不显示值本身 —— 只说「有还是没有」。
_CUR_PROVIDER="${CLAUDE_PROVIDER:-}"
_CUR_CHOICE=0
_FIRST_KEYED=0
P_HASKEY=()
_i=1
while [ "$_i" -le "$P_COUNT" ]; do
  eval "_kv=\${${P_KENV[$_i]}}"
  if [ -n "${_kv:-}" ]; then
    P_HASKEY[$_i]=1
    [ "$_FIRST_KEYED" -eq 0 ] && _FIRST_KEYED=$_i
  else
    P_HASKEY[$_i]=0
  fi
  if [ -n "$_CUR_PROVIDER" ] && [ "${P_NAME[$_i]}" = "$_CUR_PROVIDER" ]; then
    _CUR_CHOICE=$_i
  fi
  _i=$((_i + 1))
done

msg ask_provider
_i=1
while [ "$_i" -le "$P_COUNT" ]; do
  printf "  %d) %s" "$_i" "${P_LABEL[$_i]}"
  if [ "${P_HASKEY[$_i]}" = "1" ]; then
    printf "%s" "$(msg mark_has_key)"
  fi
  printf "\n"
  _i=$((_i + 1))
done
if [ "$_CUR_CHOICE" -gt 0 ]; then
  printf "$(msg enter_number)" "$_CUR_CHOICE"
else
  printf "$(msg enter_number)" "1"
fi
read -r PROVIDER_CHOICE
if [ -z "$PROVIDER_CHOICE" ] && [ "$_CUR_CHOICE" -gt 0 ]; then
  PROVIDER_CHOICE="$_CUR_CHOICE"
fi
PROVIDER_CHOICE="${PROVIDER_CHOICE:-1}"
case "$PROVIDER_CHOICE" in
  ''|*[!0-9]*) PROVIDER_CHOICE=1 ;;
esac
if [ "$PROVIDER_CHOICE" -lt 1 ] || [ "$PROVIDER_CHOICE" -gt "$P_COUNT" ]; then
  msg err_bad_choice "$P_COUNT"
  exit 1
fi

# 只有在要切到另一家厂商（还没配密钥）时才确认一次。
# 若一声不吭就改 CLAUDE_PROVIDER，粘进来的密钥属于另一家会
# 直接失败，看起来像「密钥失效了」。
if [ "$_CUR_CHOICE" -gt 0 ] \
   && [ "$PROVIDER_CHOICE" -ne "$_CUR_CHOICE" ] \
   && [ "${P_HASKEY[$PROVIDER_CHOICE]}" != "1" ]; then
  msg ask_confirm_switch "${P_LABEL[$_CUR_CHOICE]}" "${P_LABEL[$PROVIDER_CHOICE]}" "${P_LABEL[$_CUR_CHOICE]}"
  read -r _SWITCH_YN || _SWITCH_YN=""
  case "$_SWITCH_YN" in
    y|Y|yes|YES) : ;;
    *) msg kept_previous "${P_LABEL[$_CUR_CHOICE]}"
       PROVIDER_CHOICE="$_CUR_CHOICE" ;;
  esac
fi
PROVIDER="${P_NAME[$PROVIDER_CHOICE]}"
KEY_VAR="${P_KENV[$PROVIDER_CHOICE]}"
DEFAULT_MODEL="${P_DMODEL[$PROVIDER_CHOICE]}"

# 环境文件里可能残留上一家厂商的 CLAUDE_MODEL（换了厂商后
# 那个模型名一定无效）。用不属于该厂商的模型名去请求会 400，
# 让人误以为「密钥不对」，所以这里必须对齐。
_MODEL_RESET=0
if [ -n "${CLAUDE_MODEL:-}" ]; then
  if ! awk -F'|' -v m="$CLAUDE_MODEL" -v p="$PROVIDER" \
        '$1==m && $5==p {found=1} END{exit !found}' "$SCRIPT_DIR/models.txt" 2>/dev/null; then
    _MODEL_RESET=1
  fi
else
  _MODEL_RESET=1
fi
if [ "$_MODEL_RESET" = "1" ]; then
  if [ -n "${CLAUDE_MODEL:-}" ] && [ "$CLAUDE_MODEL" != "$DEFAULT_MODEL" ]; then
    msg model_reset_note "$CLAUDE_MODEL" "${P_LABEL[$PROVIDER_CHOICE]}" "$DEFAULT_MODEL"
  fi
  CLAUDE_MODEL="$DEFAULT_MODEL"
fi
KEY_PAGE="${P_URL[$PROVIDER_CHOICE]}"
msg using_provider "$PROVIDER"
echo ""

# --- 2. API 密钥 ---
# 该厂商的密钥已保存过就直接用它
EXISTING_KEY="$(eval "printf '%s' \"\${$KEY_VAR}\"")"
if [ -n "$EXISTING_KEY" ]; then
  msg reuse_key "$KEY_VAR"
  msg reuse_key_hint "$ENV_FILE"
  API_KEY="$EXISTING_KEY"
  echo ""
else
  # 不写每家厂商「该点哪里」的步骤 —— 各家的控制台
  # 会毫无预告地改版，7 家 × 3 种语言写下来必然腐烂。只从
  # providers.txt 取密钥页面的 URL，其余交给 README。
  msg key_intro_generic "${P_LABEL[$PROVIDER_CHOICE]}"
  msg key_where "$KEY_PAGE"
  echo ""

  printf "$(msg paste_key)"
  stty -echo 2>/dev/null || true
  read -r API_KEY
  stty echo 2>/dev/null || true
  echo ""

  API_KEY=$(echo "$API_KEY" | sed 's/^[ \t]*//;s/[ \t]*$//')

  if [ -z "$API_KEY" ]; then
    msg err_empty_key
    exit 1
  fi

  case "$API_KEY" in
    \<*|*\>)
      msg err_placeholder
      msg err_placeholder2
      msg err_placeholder3
      exit 1
      ;;
  esac

  key_len=$(echo -n "$API_KEY" | wc -c | tr -d ' ')
  if [ "$key_len" -lt 30 ]; then
    msg warn_short_key "$key_len"
  fi

  upsert_env "$KEY_VAR" "$API_KEY"
  msg saved_key "$ENV_FILE"
  echo ""
fi

upsert_env "CLAUDE_PROVIDER" "$PROVIDER"
# 厂商与模型必须是同一家的：否则下次启动会用「别家的模型名」去请求 → 400，
# 看起来却像密钥失效。
if [ -n "${CLAUDE_MODEL:-}" ]; then
  upsert_env "CLAUDE_MODEL" "$CLAUDE_MODEL"
fi

# --- 3. 放置 agent 本体 ---
mkdir -p "$BUILD_DIR"
cp "$SCRIPT_DIR/agent/claude-agent.pl" "$BUILD_DIR/claude-agent.pl"
cp "$SCRIPT_DIR/models.txt" "$BUILD_DIR/models.txt"
cp "$SCRIPT_DIR/providers.txt" "$BUILD_DIR/providers.txt"
[ -f "$SCRIPT_DIR/gui/advisor_gui.py" ] && cp "$SCRIPT_DIR/gui/advisor_gui.py" "$BUILD_DIR/advisor_gui.py"
[ -f "$SCRIPT_DIR/launcher/advisor.png" ] && cp "$SCRIPT_DIR/launcher/advisor.png" "$BUILD_DIR/advisor.png"
# 连 remote/ 一起放。GUI 的远程面板要从这里找 wecom-ws.pl，
# 忘了放就会「找不到 wecom-ws.pl」而无法启动（真机上出现过）。
if [ -d "$SCRIPT_DIR/remote" ]; then
  mkdir -p "$BUILD_DIR/remote"
  cp "$SCRIPT_DIR"/remote/*.pl "$BUILD_DIR/remote/" 2>/dev/null || true
fi
msg placed_files "$BUILD_DIR"

# --- 4. 安装 advisor 命令(包装脚本) ---
mkdir -p "$BIN_DIR"
WRAP_IS_EN="$IS_EN"
WRAP_LANGCODE="$LANGCODE"
cat > "$BIN_DIR/advisor" << WRAPEOF
#!/bin/bash
# advisor — high_sierra_claude 包装命令 (由 setup.sh 自动生成)
set -e

ENV_FILE="$ENV_FILE"
MODELS_FILE="$BUILD_DIR/models.txt"
PROVIDERS_FILE="$BUILD_DIR/providers.txt"
AGENT_SCRIPT="$BUILD_DIR/claude-agent.pl"
CURL_BIN="$CURL_BIN"
CACERT="$CACERT"
# 命令行当场指定了 CLAUDE_LANG=en/ja 就优先用它，
# 否则用安装时判定的语言。
case "\${CLAUDE_LANG:-}" in
  en*) LANGCODE="en" ;;
  ja*) LANGCODE="ja" ;;
  zh*) LANGCODE="zh" ;;
  *) LANGCODE="$WRAP_LANGCODE" ;;
esac
IS_EN=0
[ "\$LANGCODE" = "en" ] && IS_EN=1

# 把终端字符编码固定为 UTF-8。若是 C locale 之类，
# 原始行输入(canonical mode)下中文一个字(3 字节)会被 tty 按字节
# 处理，Backspace 时光标与文字位置错开、还会连前面的字一起删掉。
# 所以不依赖 Terminal 的设置，一律用 UTF-8。
if [ -z "\$LANG" ] || [ "\${LANG#*.}" = "\$LANG" ]; then
  # 终端字符编码跟随显示语言(zh 时避开 ja_JP)
  if [ "\$LANGCODE" = "zh" ]; then export LANG="zh_CN.UTF-8"; else export LANG="ja_JP.UTF-8"; fi
fi
export LC_CTYPE="\${LC_CTYPE:-\$LANG}"

source "\$ENV_FILE"

show_help() {
  if [ "\$LANGCODE" = "zh" ]; then
    cat <<EOF
用法: advisor [选项]

  -h, --help              显示本帮助
      --version           显示版本
      --select-model [N]  选择要用的 AI。带上编号可立即决定（例：advisor --select-model 3）
      --list-models       列出可用的 AI
  -m, --model <ID>        仅本次改用别的 AI 启动
      --list-history      列出已保存的对话（需要口令）
      --resume            选择已保存的对话继续
      --no-history        本次不保存对话（也不询问口令）
      --change-passphrase 修改历史记录口令
      --set-recovery      设置密保问题（忘记口令时使用）

不带参数运行会使用已保存的设置启动。
启动后输入列表里的编号即可切换 AI（输入 /model 可再次显示列表）。
想从命令行决定，用 --select-model [N]。
对话默认加密保存到 ~/.claude-agent/history
（首次启动时设置口令。密保问题可选）。
EOF
  elif [ "\$LANGCODE" = "en" ]; then
    cat <<EOF
Usage: advisor [option]

  -h, --help              show this help
      --version           show the version
      --select-model [N]  choose which AI to use; add a number to decide right away (e.g. advisor --select-model 3)
      --list-models       list the available AIs
  -m, --model <ID>        use a different AI for this session only
      --list-history      list saved conversations (needs your passphrase)
      --resume            pick a saved conversation and continue it
      --no-history        don't save this conversation (and don't ask for a passphrase)
      --change-passphrase change the history passphrase
      --set-recovery      set a recovery question (used if you forget your passphrase)

Run with no arguments to start with your saved settings.
Switch AI anytime by typing its number at the prompt (type /model to see the list again).
To pick one from the shell instead, use --select-model [N].
Conversations are encrypted and saved to ~/.claude-agent/history by default
(you set a passphrase on first run; a recovery question is optional).
EOF
  else
    cat <<EOF
使い方: advisor [オプション]

  -h, --help              このヘルプを表示
      --version           バージョンを表示
      --select-model [番号] 使うAIを選ぶ。番号を付ければ即決定 (例: advisor --select-model 3)
      --list-models       使えるAIの一覧を表示
  -m, --model <ID>        今回だけ別のAIで起動
      --list-history      保存済みの会話を一覧表示 (パスフレーズが必要)
      --resume            保存済みの会話を選んで続きから再開
      --no-history        今回は会話を保存しない (パスフレーズも尋ねない)
      --change-passphrase 履歴パスフレーズを変更
      --set-recovery      合言葉 (パスフレーズを忘れたとき用の秘密の質問) を設定

引数なしで実行すると、保存済みの設定で起動します。
使うAIは、起動後に一覧の番号を入力するだけで切り替わります(一覧の再表示は /model)。
シェルから決めたいときは --select-model [番号]。
会話は既定で ~/.claude-agent/history に暗号化保存されます
(初回起動時にパスフレーズを設定。合言葉も任意で設定できます)。
EOF
  fi
}

list_models() {
  # models.txt 是 id|日文|English|中文。按 LANGCODE 选列。
  if [ "\$LANGCODE" = "zh" ]; then
    awk -F'|' '{printf "  %-32s %s\n", \$1, (\$4 != "" ? \$4 : \$2)}' "\$MODELS_FILE"
  elif [ "\$IS_EN" = "1" ]; then
    awk -F'|' '{printf "  %-32s %s\n", \$1, (\$3 != "" ? \$3 : \$2)}' "\$MODELS_FILE"
  else
    awk -F'|' '{printf "  %-32s %s\n", \$1, \$2}' "\$MODELS_FILE"
  fi
}

# 模型 ID → 厂商。models.txt 的 provider 列是唯一来源
# （以前是「gemini 开头算 gemini，其余算 anthropic」这种只考虑两家的假设）
provider_of() {
  local _p
  _p="\$(awk -F'|' -v m="\$1" '\$1==m && \$5!="" {print \$5; exit}' "\$MODELS_FILE" 2>/dev/null)"
  [ -z "\$_p" ] && _p="anthropic"
  echo "\$_p"
}

# 厂商 → 密钥的环境变量名（从 providers.txt 里查）
keyvar_of() {
  local _k
  _k="\$(awk -F'|' -v p="\$1" '\$1==p {print \$2; exit}' "\$PROVIDERS_FILE" 2>/dev/null)"
  echo "\$_k"
}

# 选择要用的 AI。带编号参数时走非交互。CLAUDE_MODEL 与 CLAUDE_PROVIDER
# 成对改写，所以不会出现「选了 Gemini 的模型、内容却还是 Claude」的情况。
select_model() {
  local want="\$1"
  local i=1
  local ids=()
  if [ "\$LANGCODE" = "zh" ]; then echo "选择要用的 AI："
  elif [ "\$IS_EN" = "1" ]; then echo "Choose which AI to use:"
  else echo "使うAIを選んでください:"; fi
  while IFS='|' read -r id desc_ja desc_en desc_zh; do
    local desc="\$desc_ja"
    if [ "\$LANGCODE" = "zh" ] && [ -n "\$desc_zh" ]; then desc="\$desc_zh"; fi
    if [ "\$IS_EN" = "1" ] && [ -n "\$desc_en" ]; then desc="\$desc_en"; fi
    printf "  %d) %s\n" "\$i" "\$desc"
    ids[\$i]="\$id"
    i=\$((i+1))
  done < "\$MODELS_FILE"
  local choice="\$want"
  if [ -z "\$choice" ]; then
    if [ "\$LANGCODE" = "zh" ]; then printf "输入编号 [1]: "
    elif [ "\$IS_EN" = "1" ]; then printf "Enter a number [1]: "
    else printf "番号を入力 [1]: "; fi
    read -r choice
  fi
  choice=\${choice:-1}
  local chosen="\${ids[\$choice]}"
  if [ -z "\$chosen" ]; then
    if [ "\$LANGCODE" = "zh" ]; then echo "无效的选择。"
    elif [ "\$IS_EN" = "1" ]; then echo "Invalid choice."
    else echo "無効な選択です。"; fi
    exit 1
  fi
  local prov
  prov="\$(provider_of "\$chosen")"
  grep -v -e '^export CLAUDE_MODEL=' -e '^export CLAUDE_PROVIDER=' "\$ENV_FILE" > "\$ENV_FILE.tmp" 2>/dev/null || true
  mv "\$ENV_FILE.tmp" "\$ENV_FILE"
  echo "export CLAUDE_MODEL=\$chosen" >> "\$ENV_FILE"
  echo "export CLAUDE_PROVIDER=\$prov" >> "\$ENV_FILE"
  chmod 600 "\$ENV_FILE"
  if [ "\$LANGCODE" = "zh" ]; then echo "→ 使用 \${chosen}。"
  elif [ "\$IS_EN" = "1" ]; then echo "→ Using \$chosen."
  else echo "→ \$chosen を使います。"; fi
  local keyvar
  keyvar="\$(keyvar_of "\$prov")"
  if [ -z "\$keyvar" ]; then
    # providers.txt 里没有的厂商（用户自己加的等）在这里放弃
    if [ "\$LANGCODE" = "zh" ]; then echo "※ providers.txt 里没有 \$prov 的密钥定义。"
    elif [ "\$IS_EN" = "1" ]; then echo "※ providers.txt has no key entry for \$prov."
    else echo "※ providers.txt に \$prov のキー定義がありません。"; fi
    return 0
  fi
  if ! grep -q "^export \$keyvar=" "\$ENV_FILE"; then
    # 会话内的命令名就是厂商名本身（/deepseek /qwen ...）。
    # 只有 anthropic 按老用户的习惯提示 /claude。
    local slash="\$prov"
    [ "\$prov" = anthropic ] && slash=claude
    if [ "\$LANGCODE" = "zh" ]; then
      echo "※ 这个 AI 的密钥还没有。启动 'advisor' 后输入 /\$slash 即可登记。"
    elif [ "\$IS_EN" = "1" ]; then
      echo "※ You don't have a key for this AI yet. Run 'advisor' and type /\$slash to register one."
    else
      echo "※ このAIのキーがまだありません。'advisor' を起動して /\$slash と打つと登録できます。"
    fi
  fi
}

PERL_ARGS=()
while [ \$# -gt 0 ]; do
  raw="\$1"
  # 先把短横线的个数(- 或 -- 或没有)和大小写归一化
  # 再判断，这样 --version、-version、version 都不会
  # 让人犹豫或放弃。
  norm="\$(printf '%s' "\$raw" | sed 's/^-*//' | tr 'A-Z' 'a-z')"
  case "\$norm" in
    "") shift ;;
    h|help|"?") show_help; exit 0 ;;
    v|version) echo "advisor (high_sierra_claude) $APP_VERSION"; exit 0 ;;
    list-models|listmodels|models) list_models; exit 0 ;;
    select-model|selectmodel|select)
      # 只写配置就退出(下次打 'advisor' 即启动)
      if [ -n "\$2" ] && [ "\$2" -eq "\$2" ] 2>/dev/null; then
        select_model "\$2"
      else
        select_model
      fi
      exit 0
      ;;
    [0-9]|[0-9][0-9])
      # 「advisor 3」= 切到第 3 个 AI 并启动
      select_model "\$norm"; shift ;;
    gui|window|app)
      PERL_ARGS[\${#PERL_ARGS[@]}]="--gui"; shift ;;
    list-history|listhistory|history|log)
      PERL_ARGS[\${#PERL_ARGS[@]}]="--list-history"; shift ;;
    resume|continue|cont)
      PERL_ARGS[\${#PERL_ARGS[@]}]="--resume"; shift ;;
    change-passphrase|changepassphrase|passphrase|password)
      PERL_ARGS[\${#PERL_ARGS[@]}]="--change-passphrase"; shift ;;
    set-recovery|setrecovery|recovery)
      PERL_ARGS[\${#PERL_ARGS[@]}]="--set-recovery"; shift ;;
    no-history|nohistory|nohist)
      export CLAUDE_NO_HISTORY=1; shift ;;
    m|model)
      export CLAUDE_MODEL="\$2"
      case "\$2" in
        gemini*) export CLAUDE_PROVIDER=gemini ;;
        claude*) export CLAUDE_PROVIDER=anthropic ;;
      esac
      shift 2
      ;;
    *)
      if [ "\$LANGCODE" = "zh" ]; then
        echo "无法识别的选项。通常不需要加任何参数:" >&2
        echo "  advisor            启动（一般这样就够）" >&2
        echo "  advisor version    显示版本" >&2
        echo "  advisor help       详细用法" >&2
        echo "（前面的短横线 - 加不加都可以）" >&2
      elif [ "\$IS_EN" = "1" ]; then
        echo "That option wasn't recognized. Usually you can just run:" >&2
        echo "  advisor            start (this is usually all you need)" >&2
        echo "  advisor version    show the version" >&2
        echo "  advisor help       detailed usage" >&2
        echo "(the leading - is optional either way)" >&2
      else
        echo "そのオプションは分かりませんでした。ふつうは何も付けずに:" >&2
        echo "  advisor            起動する(たいていこれだけでOK)" >&2
        echo "  advisor version    バージョンを表示" >&2
        echo "  advisor help       詳しい使い方" >&2
        echo "(ダッシュ - は付けても付けなくてもかまいません)" >&2
      fi
      exit 1
      ;;
  esac
done

export CLAUDE_CURL="\$CURL_BIN"
[ -n "\$CACERT" ] && export CLAUDE_CACERT="\$CACERT"
export CLAUDE_MODELS_FILE="\$MODELS_FILE"
if [ \${#PERL_ARGS[@]} -gt 0 ]; then
  exec perl "\$AGENT_SCRIPT" "\${PERL_ARGS[@]}"
else
  exec perl "\$AGENT_SCRIPT"
fi
WRAPEOF
chmod +x "$BIN_DIR/advisor"
msg created_wrapper "$BIN_DIR/advisor"
# 旧名(claude)若还在就清掉
[ -e "$BIN_DIR/claude" ] && rm -f "$BIN_DIR/claude" && msg removed_old_wrapper "$BIN_DIR/claude"

# 把 $HOME/bin 加进 PATH，并**验证真的生效**。
# 以前的写法有两个坑：
#   1) grep -F 会把注释掉的 `# export PATH=$HOME/bin:$PATH` 当成已存在 → 什么都不写，
#      用户开新终端还是 command not found；
#   2) 只写 ~/.bash_profile，但 macOS 默认 shell 是 zsh，zsh 根本不读这个文件 ——
#      写了等于没写，却照样打印「已加入 PATH」。
# 所以：跳过注释行判断 + 按登录 shell 选文件 + 最后用登录 shell 真解析一次。
PATH_WROTE_TO=""
path_ensure() {
  local target="$1"
  mkdir -p "$(dirname "$target")" 2>/dev/null || true
  [ -f "$target" ] || : > "$target"
  # 只认「生效的行」：行首（允许缩进）就是 export PATH=...$HOME/bin
  if grep -qE '^[[:space:]]*export[[:space:]]+PATH=.*\$HOME/bin' "$target" 2>/dev/null; then
    return 0
  fi
  printf '%s\n' 'export PATH=$HOME/bin:$PATH' >> "$target"
  PATH_WROTE_TO="$PATH_WROTE_TO $target"
  msg added_path "$target"
  return 0
}
path_ensure "$HOME/.bash_profile"
# zsh（macOS 默认登录 shell）读 ~/.zprofile
case "${SHELL:-}" in
  *zsh*) path_ensure "$HOME/.zprofile" ;;
esac

# --- 5. 安装 bash 补全 ---
cp "$SCRIPT_DIR/completion/advisor-completion.bash" "$COMPLETION_FILE"
if ! grep -qF "source $COMPLETION_FILE" "$HOME/.bash_profile" 2>/dev/null; then
  echo "source $COMPLETION_FILE" >> "$HOME/.bash_profile"
  msg installed_completion "$COMPLETION_FILE"
fi
# 清理旧的补全(claude)
if [ -f "$HOME/.claude-completion.bash" ]; then
  grep -v "source $HOME/.claude-completion.bash" "$HOME/.bash_profile" > "$HOME/.bash_profile.tmp" 2>/dev/null && mv "$HOME/.bash_profile.tmp" "$HOME/.bash_profile" || true
  rm -f "$HOME/.claude-completion.bash"
fi
# 用登录 shell 真解析一次：这一步才是「能不能用」的判据
if bash -lc 'command -v advisor' >/dev/null 2>&1; then
  msg path_ready
else
  msg path_needs_source "$HOME/.bash_profile"
fi
echo ""

# --- 6. 生成可双击启动的 Advisor.app (GUI) ---
# 用 py2app 构建成独立应用。只 exec python3 的简易版会让
# 菜单栏/Dock 显示系统默认的「Python」(python.org
# 分发的 python3 可执行文件本身就带这个名字，
# 经由 shell 脚本 exec 无法覆盖)。用 py2app 构建时可执行文件本身
# 生成在 bundle 内，才能正确显示为「Advisor」。
# 构建失败时(网络不通等)回退到简易版
# (行为不变，只是菜单栏显示仍是「Python」)。
# python3 的查找：每个候选都必须**真能执行**才算数。
# 以前的写法最后一路兜底写死 /usr/bin/python3 —— 但 macOS 12.3 起只有在装了
# Xcode Command Line Tools 之后才有这个 stub，于是「兜底」兜到一个不存在的路径：
# 装配上去的 app 双击必然失败（exec: /usr/bin/python3: No such file or directory），
# 而且 setup.sh 还以为一切正常。现在逐个 -x 验过才用。
find_python3() {
  local cand
  for cand in \
    "$(command -v python3 2>/dev/null || true)" \
    /Library/Frameworks/Python.framework/Versions/3.13/bin/python3 \
    /Library/Frameworks/Python.framework/Versions/3.12/bin/python3 \
    /Library/Frameworks/Python.framework/Versions/3.11/bin/python3 \
    /Library/Frameworks/Python.framework/Versions/3.10/bin/python3 \
    /opt/homebrew/bin/python3 \
    /usr/local/bin/python3 \
    /usr/bin/python3 ; do
    [ -n "$cand" ] || continue
    [ -x "$cand" ] || continue
    printf '%s' "$cand"
    return 0
  done
  return 1
}
PY3="$(find_python3 || true)"

# 图形界面还要 Tk（python.org 的 python3 自带；Apple 自带的、部分 Homebrew 的没有）
PY3_HAS_TK=0
if [ -n "$PY3" ] && "$PY3" -c 'import tkinter' >/dev/null 2>&1; then
  PY3_HAS_TK=1
fi

build_advisor_app_simple() {
  mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
  cat > "$APP_PATH/Contents/MacOS/Advisor" << APPEOF
#!/bin/bash
# 生成时已经验过这个解释器可用；但它后来可能被删/被卸载，源码目录也可能被清掉。
# 那种情况下 Finder 双击只会「没反应」，所以这里主动弹一句人能看懂的话。
GUI_PY="$PY3"
GUI_SRC="\$HOME/claude-build/advisor_gui.py"
if [ ! -x "\$GUI_PY" ] || ! "\$GUI_PY" -c 'import tkinter' >/dev/null 2>&1 || [ ! -f "\$GUI_SRC" ]; then
  TIP="Advisor 需要的 Python 3（含 Tk）或程序文件不可用，请安装 python.org 的 Python 3 后重跑 setup.sh。命令行版 advisor 不受影响。"
  # 先写文字提示再弹窗：无人值守环境（CI / 远程登录）弹窗可能没人点，
  # 不能让「能看到的信息」排在弹窗后面。
  printf 'Advisor: %s\n  解释器: %s\n  程序: %s\n' "\$TIP" "\$GUI_PY" "\$GUI_SRC" >&2
  # “giving up after”必须有：没有它 display dialog 会一直等人点「好」，
  # 在没有人操作的机器上就是永久挂住（macOS CI 上实测卡死过）。
  osascript -e "display dialog \"\$TIP\" buttons {\"好\"} default button 1 with title \"Advisor\" giving up after 10" >/dev/null 2>&1
  exit 1
fi
export PATH="\$HOME/bin:/usr/local/bin:/usr/bin:/bin"
exec "\$GUI_PY" "\$GUI_SRC"
APPEOF
  chmod +x "$APP_PATH/Contents/MacOS/Advisor"
  cat > "$APP_PATH/Contents/Info.plist" << PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Advisor</string>
  <key>CFBundleDisplayName</key><string>Advisor</string>
  <key>CFBundleIdentifier</key><string>com.high-sierra-claude.advisor</string>
  <key>CFBundleVersion</key><string>${APP_VERSION}</string>
  <key>CFBundleShortVersionString</key><string>${APP_VERSION}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>Advisor</string>
  <key>CFBundleIconFile</key><string>advisor.icns</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLISTEOF
  printf 'APPL????' > "$APP_PATH/Contents/PkgInfo"
  [ -f "$ICON_SRC" ] && cp "$ICON_SRC" "$APP_PATH/Contents/Resources/advisor.icns"
}

build_advisor_app_py2app() {
  # 代码签名需要 Xcode Command Line Tools。没有就当场安装
  # (softwareupdate 用于这个目的时不需要管理员权限也能跑)。
  if ! xcode-select -p >/dev/null 2>&1; then
    msg building_app_clt
    touch /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
    local clt_label
    clt_label="$(softwareupdate -l 2>/dev/null | grep -o 'Command Line Tools[^,]*for Xcode-[0-9.]*' | tail -1)"
    [ -n "$clt_label" ] && softwareupdate -i "$clt_label" >/dev/null 2>&1
    rm -f /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
    xcode-select -p >/dev/null 2>&1 || return 1
  fi

  # pyobjc-framework-Cocoa 用于把菜单栏里 About/隐藏/服务/退出这些
  # Tk 自身用固定英文字符串自动生成的项，改成通过访问 OS 原生菜单
  # 实现的本地化文案(在 advisor_gui.py 侧使用)。
  "$PY3" -m pip install --user --quiet py2app pyobjc-framework-Cocoa \
    >/tmp/advisor-py2app-install.log 2>&1 || return 1

  local build_dir="$HOME/.advisor-app-build"
  mkdir -p "$build_dir"
  local iconfile_opt=""
  [ -f "$ICON_SRC" ] && iconfile_opt="\"iconfile\": \"$ICON_SRC\","
  cat > "$build_dir/setup.py" << PYEOF
from setuptools import setup
APP = ["$HOME/claude-build/advisor_gui.py"]
OPTIONS = {
    "argv_emulation": False,
    $iconfile_opt
    "plist": {
        "CFBundleName": "Advisor",
        "CFBundleDisplayName": "Advisor",
        "CFBundleIdentifier": "com.high-sierra-claude.advisor",
        "CFBundleVersion": "$APP_VERSION",
        "CFBundleShortVersionString": "$APP_VERSION",
        "NSHighResolutionCapable": True,
    },
}
setup(app=APP, options={"py2app": OPTIONS}, setup_requires=["py2app"])
PYEOF
  ( cd "$build_dir" && rm -rf build dist && "$PY3" setup.py py2app -A ) \
    >/tmp/advisor-py2app-build.log 2>&1 || return 1
  [ -d "$build_dir/dist/Advisor.app" ] || return 1

  rm -rf "$APP_PATH"
  mkdir -p "$HOME/Applications"
  cp -R "$build_dir/dist/Advisor.app" "$APP_PATH"
}

if [ -n "$PY3" ] && [ "$PY3_HAS_TK" = 1 ]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/Claude.app"
  msg building_app
  if ! build_advisor_app_py2app; then
    msg app_build_fallback
    rm -rf "$APP_PATH"
    build_advisor_app_simple
  fi
  touch "$APP_PATH"

  msg created_app "$APP_PATH"
  msg created_app_hint
else
  # 以前不管 python3 能不能用都照样生成 app，结果双击必然失败而且看不出原因。
  # 现在宁可明确说清楚：命令行版照常可用，图形界面缺前置条件。
  if [ -n "$PY3" ]; then
    msg gui_no_tk "$PY3"
  else
    msg no_python3
  fi
  msg gui_install_hint
  # 光说「装 python.org 的 Python 3」不够，直接给能复制的命令。
  # 注意：只装 Xcode Command Line Tools 给的 /usr/bin/python3 **不含 Tk**，
  # 装了也起不了图形界面 —— 这一步很多人会走错。
  echo "  · python.org（自带 Tk，推荐）: https://www.python.org/downloads/macos/"
  echo "  · 已经用 Homebrew 装了 python3 的话: brew install python-tk"
  if ! xcode-select -p >/dev/null 2>&1; then
    echo "  · 注意：只装 Xcode Command Line Tools（会带来 /usr/bin/python3）仍然没有 Tk，图形界面还是起不来。"
  fi
fi
echo ""

# --- 7. 疎通確認 ---
msg checking_api
RESPONSE_FILE="/tmp/advisor-setup-check-$$.json"
if [ -n "$CACERT" ]; then
  CACERT_OPT=(--cacert "$CACERT")
else
  CACERT_OPT=()
fi

# 请求方式按「认证形态」只有三种:
#   gemini    … x-goog-api-key 头 + generateContent（模型 ID 拼进 URL）
#   anthropic … x-api-key + anthropic-version 头 + /v1/messages
#   其余      … Authorization: Bearer + <base_url>/chat/completions
# 这三个分支与 agent/claude-agent.pl 里 %PROVIDERS 的 auth 相对应。
TEST_MODEL="${CLAUDE_MODEL:-$DEFAULT_MODEL}"   # 已在上面校验为当前厂商的模型
BASE_URL="$(awk -F'|' -v m="$TEST_MODEL" '$1==m {print $6}' "$SCRIPT_DIR/models.txt" 2>/dev/null | head -1)"
if [ -z "$BASE_URL" ]; then
  BASE_URL="$(awk -F'|' -v p="$PROVIDER" '$5==p && $6!="" {print $6}' "$SCRIPT_DIR/models.txt" 2>/dev/null | head -1)"
fi

case "$PROVIDER" in
  gemini)
    case "$TEST_MODEL" in gemini*) ;; *) TEST_MODEL="$DEFAULT_MODEL" ;; esac
    HTTP_CODE=$("$CURL_BIN" -s "${CACERT_OPT[@]}" \
      "https://generativelanguage.googleapis.com/v1beta/models/${TEST_MODEL}:generateContent" \
      -H "x-goog-api-key: $API_KEY" \
      -H "content-type: application/json" \
      -d '{"contents":[{"parts":[{"text":"hi"}]}],"generationConfig":{"maxOutputTokens":8}}' \
      -o "$RESPONSE_FILE" \
      -w "%{http_code}")
    ;;
  anthropic)
    HTTP_CODE=$("$CURL_BIN" -s "${CACERT_OPT[@]}" \
      https://api.anthropic.com/v1/messages \
      -H "x-api-key: $API_KEY" \
      -H "anthropic-version: 2023-06-01" \
      -H "content-type: application/json" \
      -d "{\"model\":\"$TEST_MODEL\",\"max_tokens\":10,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}" \
      -o "$RESPONSE_FILE" \
      -w "%{http_code}")
    ;;
  *)
    if [ -z "$BASE_URL" ]; then
      msg api_error_nobase "$PROVIDER"
      HTTP_CODE="000"
    else
      HTTP_CODE=$("$CURL_BIN" -s "${CACERT_OPT[@]}" \
        "${BASE_URL%/}/chat/completions" \
        -H "Authorization: Bearer $API_KEY" \
        -H "content-type: application/json" \
        -d "{\"model\":\"$TEST_MODEL\",\"max_tokens\":16,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}" \
        -o "$RESPONSE_FILE" \
        -w "%{http_code}")
    fi
    ;;
esac

echo ""
if [ "$HTTP_CODE" = "200" ]; then
  msg api_ok
  echo ""
  msg usage_intro
  msg usage_help
  msg usage_select
  msg usage_model
  msg usage_switch
else
  msg api_error "$HTTP_CODE"
  msg key_where "$KEY_PAGE"
  msg api_error_body
  cat "$RESPONSE_FILE"
  if [ "$HTTP_CODE" = "400" ] && grep -qi 'model' "$RESPONSE_FILE" 2>/dev/null; then
    echo ""
    msg api_error_model_hint "$TEST_MODEL"
  fi
  echo ""
fi
rm -f "$RESPONSE_FILE"
