#!/usr/bin/perl
# claude-agent.pl (advisor) — 古いIntel Mac (Snow Leopard 〜 High Sierra 世代)
# 向けの自己完結型 AIエージェント。外部CPANモジュールに依存しない。
# Anthropic (Claude) と Google (Gemini) の両APIに対応。
#
# Mavericks(10.9)以降(Tier B)は標準のcurlが既にTLS1.2対応のため、追加の
# ビルドなしでそのまま動く。Snow Leopard〜Mountain Lion(Tier A, 10.6-10.8)
# では ppc_claude_cli と同じ手順でOpenSSL/curlをソースからビルドし、
# CLAUDE_CURL / CLAUDE_CACERT でその場所を指定する。
#
# 使い方:
#   export ANTHROPIC_API_KEY=sk-ant-...      # または GEMINI_API_KEY=...
#   export CLAUDE_PROVIDER=anthropic          # または gemini
#   perl claude-agent.pl

use strict;
use warnings;
use utf8;  # このファイル自身に書かれた日本語リテラルをUTF-8として解釈する
use Encode qw(decode FB_DEFAULT);
use File::Basename qw(dirname);
use Cwd ();

# 画面出力は明示的にUTF-8として扱う。
binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

# STDINはあえて生バイトのまま(:encoding層を付けない)にしておく。
# Perl 5.8.6のPerlIO :encoding(UTF-8) は、実際のキーボード入力のように
# バイトが少しずつ届く対話的な読み込みだと、マルチバイト文字の途中で
# 読み込みバッファが分割されてしまい "utf8 does not map to Unicode" と
# いう文字化けエラーを起こすことがある(パイプ経由の一括入力では再現
# しない)。そのため、行を読み終えてバイト列が全部揃った後にまとめて
# デコードする(下のwhileループ内)方式にしている。

# :encoding層を付けるとSTDOUTの自動フラッシュが効かなくなり、プロンプトの
# 表示がAPI応答まで遅延して見えることがあるため、明示的に毎回flushする。
$| = 1;

# 端末設定を起動時に控えておき、どんな終わり方をしても必ず元に戻す。
# read_line_interactive は端末を raw モードにするので、途中で die すると
# 端末が壊れたまま(入力が見えない・改行されない)になってしまう。
# --- ログ2種 ---
# blog(): 常時ONの「パンくず」ログ。会話の中身は書かず、動作の節目と
#   終了理由だけを ~/.claude-agent/session.log に残す(起動時に消す)。
#   次に落ちたとき、環境変数の設定なしで最後の様子が分かるように。
# dbg():  CLAUDE_DEBUG_LOG=<path> のときだけ動く詳細ログ。APIの生の
#   やり取りまで書く。
my $BLOG_PATH = ($ENV{HOME} || '.') . '/.claude-agent/session.log';
{
    my $d = ($ENV{HOME} || '.') . '/.claude-agent';
    mkdir($d, 0700) unless -d $d;
    if (open(my $fh, '>', $BLOG_PATH)) { print $fh ''; close $fh; chmod 0600, $BLOG_PATH; }
}
sub _logline {
    my ($path, $msg) = @_;
    return unless $path;
    if (open(my $fh, '>>:encoding(UTF-8)', $path)) {
        my @t = localtime;
        printf $fh "[%02d:%02d:%02d] %s\n", $t[2], $t[1], $t[0], $msg;
        close $fh;
    }
}
sub blog { _logline($BLOG_PATH, join('', @_)); }
sub dbg  {
    my $line = join('', @_);
    blog(substr($line, 0, 200)) if $line !~ /^BODY:/;       # 本文以外は節目としてパンくずにも
    _logline($ENV{CLAUDE_DEBUG_LOG}, $line) if $ENV{CLAUDE_DEBUG_LOG};
}

# ------------------------------------------------------------------
# 言語(日英)。ダウンロードの7割が海外ユーザーとのことで必須になった。
# GUI側(advisor_gui.py)と同じくmacOSのシステム言語設定を直接見る
# (LANG環境変数はGUIアプリ起動時に空なことがあり、あてにできない)。
# 判定できなければ、この項目の既存ユーザーに合わせて日本語を既定にする。
# ------------------------------------------------------------------
# バージョンの出所はリポジトリ直下の VERSION ファイルだけ（tag と一致させる）。
# 配布アプリでは VERSION を同梱するので、スクリプトと同じ場所も見る。
sub app_version {
    my $dir = $0;
    $dir =~ s{/[^/]*$}{};
    for my $p ("$dir/../VERSION", "$dir/VERSION") {
        next unless -f $p;
        open(my $fh, '<', $p) or next;
        my $v = <$fh>;
        close $fh;
        next unless defined $v;
        $v =~ s/\s+//g;
        return $v if $v ne '';
    }
    return 'unknown';
}

my $LANGCODE = 'ja';
if (defined $ENV{CLAUDE_LANG} && $ENV{CLAUDE_LANG} =~ /^(en|ja|zh)/i) {
    # CLAUDE_LANG=en/ja/zh があれば最優先(システム言語を変えずに表示言語を
    # 確認したいとき用)。zh-Hans / zh_CN のような書き方も zh として扱う。
    $LANGCODE = lc(substr($1, 0, 2));
}
else {
    my $out = `defaults read -g AppleLocale 2>/dev/null`;
    $out = '' unless defined $out;
    if ($out =~ /^ja/i) {
        $LANGCODE = 'ja';
    }
    elsif ($out =~ /^zh/i) {
        # zh-Hans / zh-Hant / zh_CN / zh_TW などをまとめて中国語にする。
        # 繁体字を簡体字で出す問題はあるが、まず「中国語で読める」ことを優先。
        $LANGCODE = 'zh';
    }
    elsif ($out ne '') {
        $LANGCODE = 'en';
    }
    # 判定できない環境(非macOS など)は従来通り日本語のまま。
}

# 表示言語の一覧(優先順)。%S 側に無い言語はこの順で落とす。
#   例: zh が未訳 → en → ja。空文字を返すことは無い。
my @LANG_FALLBACK = (
    $LANGCODE,
    ($LANGCODE eq 'zh' ? ('en', 'ja') : ()),
    ($LANGCODE eq 'en' ? ('ja') : ()),
);
if ($LANGCODE ne 'ja' && $LANGCODE ne 'en' && $LANGCODE ne 'zh') {
    @LANG_FALLBACK = ('ja', 'en');
}

# key => 文言。2 通り書ける:
#   [ja, en]                     … 従来形式(中国語は en にフォールバック)
#   { ja => .., en => .., zh => .. } … 中国語を足した形式
# %s プレースホルダは sprintf で埋める(L(key, arg1, arg2...))。
# 引数の順序と個数は全言語で揃えること(ずれると表示が壊れる)。
my %S = (
    need_key             => {
        ja => "%s を設定してください\n",
        en => "Please set %s\n",
        zh => "请设置 %s\n",
    },
    unknown_provider     => {
        ja => "不明なプロバイダ: '%s'\n(選べるのは: %s)\n",
        en => "Unknown provider: '%s'\n(available: %s)\n",
        zh => "未知的提供商：'%s'\n（可选：%s）\n",
    },
    cannot_connect       => {
        ja => "サーバーに接続できませんでした。通信環境を確認して、もう一度どうぞ。\n",
        en => "Could not reach the server. Please check your connection and try again.\n",
        zh => "无法连接到服务器。请检查网络后重试。\n",
    },
    api_error            => {
        ja => "APIエラー (HTTP %s): %s\n",
        en => "API error (HTTP %s): %s\n",
        zh => "API 错误（HTTP %s）：%s\n",
    },
    api_error_short      => {
        ja => "APIエラー: %s",
        en => "API error: %s",
        zh => "API 错误：%s",
    },
    bad_response         => {
        ja => "応答をうまく解釈できませんでした。もう一度どうぞ。\n",
        en => "Could not parse the response. Please try again.\n",
        zh => "无法解析响应内容。请重试。\n",
    },
    cannot_make_tmp      => {
        ja => "一時ファイルを作成できません: %s\n",
        en => "Could not create temp file: %s\n",
        zh => "无法创建临时文件：%s\n",
    },
    history_prompt       => {
        ja => "履歴パスフレーズ",
        en => "History passphrase",
        zh => "历史记录口令",
    },
    new_history_prompt   => {
        ja => "新しい履歴パスフレーズを決めてください",
        en => "Choose a new history passphrase",
        zh => "请设置新的历史记录口令",
    },
    wrong_answer         => {
        ja => "合言葉の答えが違います。",
        en => "That answer doesn't match.",
        zh => "密保答案不正确。",
    },
    recovered            => {
        ja => "復旧しました。",
        en => "Recovered.",
        zh => "已恢复。",
    },
    wrong_passphrase     => {
        ja => "パスフレーズが違います。もう一度どうぞ。",
        en => "Wrong passphrase. Please try again.",
        zh => "口令不正确。请重试。",
    },
    no_recovery_set      => {
        ja => "合言葉が設定されなかったので、今回は履歴を保存しません。",
        en => "No recovery answer was set, so history won't be saved this time.",
        zh => "未设置密保，本次不保存历史记录。",
    },
    could_not_load_conv  => {
        ja => "その会話を読み込めませんでした。",
        en => "Could not load that conversation.",
        zh => "无法读取该对话。",
    },
    turn_failed          => {
        ja => "うまく処理できませんでした(続けられます)。",
        en => "Something went wrong (you can keep going).",
        zh => "处理没有成功（可以继续）。",
    },
    empty_response       => {
        ja => "(AIからの応答が空でした。言い方を変えてもう一度どうぞ)",
        en => "(The AI's response was empty. Try rephrasing.)",
        zh => "（AI 返回了空响应。换个说法再试试）",
    },
    tool_error           => {
        ja => "ツール実行でエラーが出ました: %s",
        en => "The tool raised an error: %s",
        zh => "工具执行出错：%s",
    },
    already_on           => {
        ja => "すでに [%s / %s] です。",
        en => "Already using [%s / %s].",
        zh => "已经是 [%s / %s]。",
    },
    switched_to          => {
        ja => "→ [%s / %s] にしました。",
        en => "→ switched to [%s / %s].",
        zh => "→ 已切换到 [%s / %s]。",
    },
    switched_to_kept     => {
        ja => "→ [%s / %s] にしました。会話はそのまま引き継がれます。",
        en => "→ switched to [%s / %s]. Conversation continues as-is.",
        zh => "→ 已切换到 [%s / %s]。当前对话会继续保留。",
    },
    cannot_open_read     => {
        ja => "エラー: %s を開けません: %s",
        en => "Error: could not open %s: %s",
        zh => "错误：无法打开 %s：%s",
    },
    cannot_open_write    => {
        ja => "エラー: %s に書き込めません: %s",
        en => "Error: could not write %s: %s",
        zh => "错误：无法写入 %s：%s",
    },
    confirm_write_file   => {
        ja => "ファイル '%s' に書き込みます",
        en => "Write to file '%s'",
        zh => "将写入文件 '%s'",
    },
    write_cancelled      => {
        ja => "ユーザーが書き込みをキャンセルしました",
        en => "The user cancelled the write",
        zh => "用户取消了写入",
    },
    write_done           => {
        ja => "書き込み完了: %s",
        en => "Wrote: %s",
        zh => "写入完成：%s",
    },
    confirm_run_shell    => {
        ja => "コマンドを実行します: %s",
        en => "Run this command: %s",
        zh => "将执行命令：%s",
    },
    run_cancelled        => {
        ja => "ユーザーが実行をキャンセルしました",
        en => "The user cancelled the run",
        zh => "用户取消了执行",
    },
    no_output            => {
        ja => "(出力なし)",
        en => "(no output)",
        zh => "（无输出）",
    },
    unknown_tool         => {
        ja => "不明なツール: %s",
        en => "Unknown tool: %s",
        zh => "未知的工具：%s",
    },
    # ---- 端末(CLIのみ、--gui無し)向け ----
    interrupted          => {
        ja => "\n中断しました。\n",
        en => "\nInterrupted.\n",
        zh => "\n已中断。\n",
    },
    key_missing_prompt   => {
        ja => "\n%s は未設定です。このメーカーを使うにはキーが必要です。貼り付けてEnter(空Enterでキャンセル): ",
        en => "\n%s is not set. Using this vendor needs a key. Paste it and press Enter (empty to cancel): ",
        zh => "\n未检测到 %s，使用这个厂商需要先填密钥。粘贴后按回车（直接回车取消）：",
    },
    # 一覧で「まだキーが無い」ことを先に示す。選んでから初めて分かる状態は
    # 「動かないボタン」と同じで、ユーザーから見ると不具合に見える。
    menu_no_key          => {
        ja => "  [キー未設定]",
        en => "  [no key yet]",
        zh => "  [未配置密钥]",
    },
    menu_vendor_no_key   => {
        ja => "  ※ %s はまだキーが未設定です（%s）。選ぶと貼り付けを求められます。\n",
        en => "  Note: %s has no key yet (%s). Picking it will ask you to paste one.\n",
        zh => "  注：%s 还没有配置密钥（%s）。选择后会提示你粘贴。\n",
    },
    switch_cancelled     => {
        ja => "キャンセルしました。[%s / %s] のままです。\n",
        en => "Cancelled. Still using [%s / %s].\n",
        zh => "已取消。仍使用 [%s / %s]。\n",
    },
    switch_failed        => {
        ja => "それでも切り替えられませんでした: %s",
        en => "Still couldn't switch: %s",
        zh => "仍然无法切换：%s",
    },
    save_key_prompt      => {
        ja => "このキーを %s に保存しますか? [y/N] ",
        en => "Save this key to %s? [y/N] ",
        zh => "要把这个密钥保存到 %s 吗？[y/N] ",
    },
    saved_plain          => {
        ja => "保存しました。\n",
        en => "Saved.\n",
        zh => "已保存。\n",
    },
    model_list_unavail   => {
        ja => "\n(モデル一覧が読み込めません)\n",
        en => "\n(Could not load the model list)\n",
        zh => "\n（无法读取模型列表）\n",
    },
    currently_using_cli  => {
        ja => " ← 使用中",
        en => " ← current",
        zh => " ← 使用中",
    },
    model_menu_pick_vendor => {
        ja => "メーカーを番号で選んでください（Enter だけなら取消）。\n",
        en => "Pick a vendor by number (press Enter alone to cancel).\n",
        zh => "用编号选择厂商（只按回车则取消）。\n",
    },
    model_menu_pick_model => {
        ja => "モデルを番号で選んでください（Enter だけなら取消）。\n",
        en => "Pick a model by number (press Enter alone to cancel).\n",
        zh => "用编号选择模型（只按回车则取消）。\n",
    },
    model_none_for_vendor => {
        ja => "%s のモデルが models.txt にありません。\n",
        en => "No models for %s in models.txt.\n",
        zh => "models.txt 里没有 %s 的模型。\n",
    },
    menu_bad_number => {
        ja => "その番号はありません。\n",
        en => "No such number.\n",
        zh => "没有这个编号。\n",
    },
    tool_not_allowed => {
        ja => "このモードで使えるツールは %s だけです（%s は使えません）。\n",
        en => "Only %s are available in this mode (%s is not).\n",
        zh => "此模式只允许 %s（%s 不可用）。\n",
    },
    menu_cancelled => {
        ja => "取消しました。\n",
        en => "Cancelled.\n",
        zh => "已取消。\n",
    },
    key_where => {
        ja => "キー取得ページ: %s\n",
        en => "Get a key here: %s\n",
        zh => "密钥获取页面：%s\n",
    },
    thinking_status      => {
        ja => "問い合わせ中",
        en => "thinking",
        zh => "思考中",
    },
    hidden_input_hint    => {
        ja => "（入力中の文字は画面に表示されません。そのまま打って Enter）\n",
        en => "(What you type won't be shown on screen. Just type it and press Enter.)\n",
        zh => "（输入的内容不会显示在屏幕上。直接输入后按回车）\n",
    },
    ask_secret_question  => {
        ja => "質問を入力してください (例: 初めて買った車の名前は?): ",
        en => "Enter your recovery question (example: What was your first car?): ",
        zh => "请输入密保问题（例：第一辆车的名字？）：",
    },
    secret_q_empty       => {
        ja => "質問が空です。合言葉は設定しませんでした。\n",
        en => "The question was empty. No recovery answer was set.\n",
        zh => "问题为空，未设置密保。\n",
    },
    secret_answer_1      => {
        ja => "答え: ",
        en => "Answer: ",
        zh => "答案：",
    },
    secret_answer_again  => {
        ja => "もう一度入力: ",
        en => "Enter it again: ",
        zh => "再输入一次：",
    },
    secret_mismatch      => {
        ja => "一致しませんでした。合言葉は設定しませんでした。\n",
        en => "They didn't match. No recovery answer was set.\n",
        zh => "两次输入不一致，未设置密保。\n",
    },
    secret_save_failed   => {
        ja => "合言葉の保存に失敗しました。\n",
        en => "Could not save the recovery answer.\n",
        zh => "密保保存失败。\n",
    },
    secret_set_done      => {
        ja => "合言葉を設定しました(答えは大文字小文字と前後の空白を区別しません)。\n",
        en => "Recovery answer set (it's not case-sensitive and ignores leading/trailing spaces).\n",
        zh => "密保已设置（答案不区分大小写，忽略首尾空格）。\n",
    },
    new_passphrase_1     => {
        ja => "新しいパスフレーズ: ",
        en => "New passphrase: ",
        zh => "新口令：",
    },
    passphrase_mismatch  => {
        ja => "一致しませんでした。パスフレーズは変更しません。\n",
        en => "They didn't match. The passphrase was not changed.\n",
        zh => "两次输入不一致，口令未修改。\n",
    },
    changed_done         => {
        ja => "変更しました。\n",
        en => "Changed.\n",
        zh => "已修改。\n",
    },
    change_failed        => {
        ja => "変更に失敗しました。\n",
        en => "Could not change it.\n",
        zh => "修改失败。\n",
    },
    secret_question_is   => {
        ja => "合言葉の質問: %s\n",
        en => "Recovery question: %s\n",
        zh => "密保问题：%s\n",
    },
    secret_answer_try    => {
        ja => "答え (空Enterで中止): ",
        en => "Answer (empty to cancel): ",
        zh => "答案（直接回车中止）：",
    },
    set_new_passphrase_q  => {
        ja => "新しいパスフレーズを設定しますか? [y/N] ",
        en => "Set a new passphrase now? [y/N] ",
        zh => "现在设置新口令吗？[y/N] ",
    },
    secret_wrong         => {
        ja => "答えが違います。もう一度どうぞ。\n",
        en => "That answer doesn't match. Please try again.\n",
        zh => "答案不正确。请重试。\n",
    },
    hist_migrate_intro   => {
        ja => "履歴の保存形式を更新します。現在のパスフレーズを入力してください。\n",
        en => "Updating the history storage format. Please enter your current passphrase.\n",
        zh => "将更新历史记录的保存格式。请输入当前口令。\n",
    },
    hist_passphrase_cancel  => {
        ja => "履歴パスフレーズ (空Enterで中止): ",
        en => "History passphrase (empty to cancel): ",
        zh => "历史记录口令（直接回车中止）：",
    },
    migrate_failed       => {
        ja => "更新に失敗しました。今回は履歴を保存せずに続けます。\n",
        en => "The update failed. Continuing this time without saving history.\n",
        zh => "更新失败。本次不保存历史记录，继续运行。\n",
    },
    updated_done         => {
        ja => "更新しました。\n",
        en => "Updated.\n",
        zh => "已更新。\n",
    },
    hist_pass_no_recovery  => {
        ja => "履歴パスフレーズ (空Enter=履歴なしで起動 / r=合言葉で復旧): ",
        en => "History passphrase (empty = start without history / r = recover with your answer): ",
        zh => "历史记录口令（直接回车＝不使用历史启动 / r＝用密保恢复）：",
    },
    hist_pass_no_recovery2  => {
        ja => "履歴パスフレーズ (空Enterで履歴なしのまま起動): ",
        en => "History passphrase (empty = start without history): ",
        zh => "历史记录口令（直接回车＝不使用历史启动）：",
    },
    starting_no_history  => {
        ja => "今回は履歴を保存せずに起動します。\n",
        en => "Starting this time without saving history.\n",
        zh => "本次启动不保存历史记录。\n",
    },
    wrong_pass_recover_hint  => {
        ja => " (合言葉で復旧するには r)\n",
        en => " (press r to recover with your answer)\n",
        zh => " (用密保恢复请按 r)\n",
    },
    hist_encrypt_intro   => {
        ja => "会話履歴を暗号化して %s に保存します。\n",
        en => "Conversation history will be encrypted and saved to %s.\n",
        zh => "对话历史将加密保存到 %s。\n",
    },
    choose_passphrase    => {
        ja => "パスフレーズを決めてください(忘れると履歴は復号できなくなります)。\n",
        en => "Choose a passphrase (if you forget it, history can't be decrypted).\n",
        zh => "请设置口令（忘记后历史记录将无法解密）。\n",
    },
    key_gen_failed       => {
        ja => "鍵の生成に失敗しました(openssl rand)。今回は履歴を保存せずに続けます。\n",
        en => "Could not generate a key (openssl rand). Continuing without saving history.\n",
        zh => "密钥生成失败（openssl rand）。本次不保存历史记录，继续运行。\n",
    },
    key_save_failed      => {
        ja => "鍵の保存に失敗しました。今回は履歴を保存せずに続けます。\n",
        en => "Could not save the key. Continuing without saving history.\n",
        zh => "密钥保存失败。本次不保存历史记录，继续运行。\n",
    },
    secret_optional_intro  => {
        ja => "\n合言葉(秘密の質問)も設定できます。パスフレーズを忘れたときの復旧用です。任意。\n",
        en => "\nYou can also set a recovery question. It's used if you forget your passphrase. Optional.\n",
        zh => "\n也可以设置密保问题，用于忘记口令时恢复。此项可选。\n",
    },
    set_it_q             => {
        ja => "設定しますか? [y/N] ",
        en => "Set one now? [y/N] ",
        zh => "要设置吗？[y/N] ",
    },
    passphrase_mismatch_continue  => {
        ja => "一致しませんでした。今回は履歴を保存せずに続けます。\n",
        en => "They didn't match. Continuing this time without saving history.\n",
        zh => "两次输入不一致。本次不保存历史记录，继续运行。\n",
    },
    set_done             => {
        ja => "設定しました。\n",
        en => "Set.\n",
        zh => "已设置。\n",
    },
    confirm_banner       => {
        ja => "──────── 確認 ────────\n",
        en => "──────── Confirm ────────\n",
        zh => "──────── 确认 ────────\n",
    },
    confirm_about_to     => {
        ja => "AIが次のことをしようとしています:\n",
        en => "The AI is about to do the following:\n",
        zh => "AI 即将执行以下操作：\n",
    },
    confirm_yn_hint      => {
        ja => "許可するなら y、やめるなら n を入力してEnterしてください。\n",
        en => "Type y to allow it, n to decline, then press Enter.\n",
        zh => "允许请输入 y，拒绝请输入 n，然后按回车。\n",
    },
    confirm_not_instruct  => {
        ja => "(ここはAIへの指示を書く欄ではありません。指示は y か n のあとで)\n",
        en => "(This is not where you type instructions for the AI — do that after y or n)\n",
        zh => "（这里不是给 AI 写指令的地方。指令请在 y 或 n 之后再输入）\n",
    },
    confirm_yn_only      => {
        ja => "  → 「y」か「n」だけを入力してください(今の入力は実行しません)。\n",
        en => "  → Please type just 'y' or 'n' (what you typed won't be run).\n",
        zh => "  → 请只输入「y」或「n」（当前输入不会被执行）。\n",
    },
    exit_hint            => {
        ja => "\r\n(終了するなら exit と入力するか、もう一度 Ctrl-D)\n",
        en => "\r\n(To quit, type exit, or press Ctrl-D again)\n",
        zh => "\r\n（要退出请输入 exit，或再按一次 Ctrl-D）\n",
    },
    history_unavailable  => {
        ja => "履歴は利用できません。\n",
        en => "History is not available.\n",
        zh => "历史记录不可用。\n",
    },
    no_saved_conv        => {
        ja => "保存済みの会話はありません。\n",
        en => "No saved conversations.\n",
        zh => "没有已保存的对话。\n",
    },
    no_resumable_conv    => {
        ja => "再開できる会話はありません。\n",
        en => "No conversations to resume.\n",
        zh => "没有可继续的对话。\n",
    },
    unreadable_file      => {
        ja => "%s (読めません)",
        en => "%s (unreadable)",
        zh => "%s（无法读取）",
    },
    resume_number        => {
        ja => "再開する番号を入力 [1]: ",
        en => "Enter a number to resume [1]: ",
        zh => "输入要继续的编号 [1]：",
    },
    resuming_conv        => {
        ja => "会話を再開します(%s メッセージ)。\n",
        en => "Resuming the conversation (%s messages).\n",
        zh => "继续对话（%s 条消息）。\n",
    },
    could_not_load_new   => {
        ja => "その会話は読み込めませんでした。新しい会話を始めます。\n",
        en => "Could not load that conversation. Starting a new one.\n",
        zh => "无法读取该对话，将开始新对话。\n",
    },
    hist_will_encrypt    => {
        ja => "履歴: 暗号化して保存します\n",
        en => "History: saved encrypted\n",
        zh => "历史记录：加密保存\n",
    },
    hist_will_not_save   => {
        ja => "履歴: 保存しません\n",
        en => "History: not saved\n",
        zh => "历史记录：不保存\n",
    },
    greeting             => {
        ja => "\nこんにちは。(終了するときは exit と入力)\n",
        en => "\nHello. (type exit to quit)\n",
        zh => "\n你好。（退出时请输入 exit）\n",
    },
    your_turn_prompt     => {
        ja => "\nご用件をどうぞ> ",
        en => "\nWhat can I help with> ",
        zh => "\n有什么需要？> ",
    },
    input_error          => {
        ja => "\n[入力エラー] 続けます。\n",
        en => "\n[input error] continuing.\n",
        zh => "\n[输入错误] 继续运行。\n",
    },
    turn_failed_cli      => {
        ja => "うまく処理できませんでした(このまま続けられます)。\n",
        en => "Something went wrong (you can keep going).\n",
        zh => "处理没有成功（可以继续）。\n",
    },
    debug_hint_1         => {
        ja => "何度も起きるようなら、一度 exit して\n",
        en => "If this keeps happening, type exit once, then\n",
        zh => "如果反复出现，请先输入 exit 退出，再用下面的命令重新启动：\n",
    },
    debug_hint_2         => {
        ja => "で起動し直し、~/advisor-debug.txt を見せてください。\n",
        en => "restart with that, and share ~/advisor-debug.txt.\n",
        zh => "重启后请把 ~/advisor-debug.txt 发给我看。\n",
    },
    farewell             => {
        ja => "\nさようなら。\n",
        en => "\nGoodbye.\n",
        zh => "\n再见。\n",
    },
    cannot_decrypt       => {
        ja => "(復号できません)",
        en => "(could not decrypt)",
        zh => "（无法解密）",
    },
    corrupted            => {
        ja => "(壊れています)",
        en => "(corrupted)",
        zh => "（已损坏）",
    },
    no_message           => {
        ja => "(発言なし)",
        en => "(no message)",
        zh => "（无发言）",
    },
    mode_bad             => {
        ja => "モード名が正しくありません: %s（%s のいずれか）\n",
        en => "Unknown mode: %s (use one of: %s)\n",
        zh => "模式名不正确：%s（可选：%s）\n",
    },
    mode_banner          => {
        ja => "モード: %s\n",
        en => "Mode: %s\n",
        zh => "模式：%s\n",
    },
    mode_now             => {
        ja => "いまのモード: %s\n",
        en => "Current mode: %s\n",
        zh => "当前模式：%s\n",
    },
    mode_now_writable    => {
        ja => "書き込み可: %s\n",
        en => "Writable: %s\n",
        zh => "可写目录：%s\n",
    },
    temp_dir_label       => {
        ja => "一時ディレクトリ",
        en => "temp dir",
        zh => "临时目录",
    },
    mode_now_log         => {
        ja => "自動承認の記録: %s（/approvals で直近 10 件）\n",
        en => "Auto-approval log: %s (/approvals shows the last 10)\n",
        zh => "自动批准记录：%s（/approvals 查看最近 10 条）\n",
    },
    mode_switched        => {
        ja => "モードを %s にしました。\n",
        en => "Mode is now %s.\n",
        zh => "模式已切换为 %s。\n",
    },
    mode_bypass_warn     => {
        ja => "\nbypass モードにすると、通常の書き込みとコマンド実行は確認なしで走ります。\n危険なコマンド（削除・権限変更・システム操作など）と、書き込み範囲の外側だけは\nこれまで通り確認します。応答が無い場合は自動的に拒否します。\n切り替えるには yes と入力してください（やめるなら Enter）: ",
        en => "\nIn bypass mode, ordinary writes and commands run without asking.\nDangerous commands (deletes, permission changes, system actions) and anything\noutside the writable roots still ask, and an unanswered prompt is treated as\nrefused. Type yes to switch (Enter cancels): ",
        zh => "\n切到 bypass 模式后，普通写文件和执行命令都不再询问。\n危险命令（删除、改权限、系统操作等）以及可写范围之外仍会询问；\n没人应答时按拒绝处理。请输入 yes 切换（直接回车取消）：",
    },
    mode_bypass_cancelled => {
        ja => "切り替えをやめました。\n",
        en => "Switch cancelled.\n",
        zh => "已取消切换。\n",
    },
    mode_auto_approved   => {
        ja => "・自動承認: %s  %s\n",
        en => "- auto-approved: %s  %s\n",
        zh => "· 已自动批准：%s  %s\n",
    },
    confirm_run_shell_danger => {
        ja => "危険な操作に該当します: %s",
        en => "This looks dangerous: %s",
        zh => "这属于危险操作：%s",
    },
    danger_banner        => {
        ja => "★ 危険な操作です。内容を確認してください。\n",
        en => "* This is a dangerous operation. Please read it carefully.\n",
        zh => "★ 这是危险操作，请仔细确认。\n",
    },
    danger_timeout_note  => {
        ja => "（%d 秒応答が無かったため拒否しました）\n",
        en => "(%d seconds with no answer, so it was refused)\n",
        zh => "（%d 秒无人应答，已按拒绝处理）\n",
    },
    danger_refused       => {
        ja => "危険な操作のため実行しません: %s\n",
        en => "Not running it because it is a dangerous operation: %s\n",
        zh => "因为是危险操作，已拒绝执行：%s\n",
    },
    danger_declined      => {
        ja => "確認で拒否されました",
        en => "declined at the prompt",
        zh => "在确认时被拒绝",
    },
    danger_no_answer     => {
        ja => "確認に応答がありませんでした（待ち続けると固まるだけなので拒否）",
        en => "nobody answered the confirmation (refused rather than hanging)",
        zh => "确认无人应答（继续等待只会把会话卡住，因此拒绝）",
    },
    danger_no_channel    => {
        ja => "確認できる画面がありません（端末もGUIも無い）",
        en => "no channel to ask on (neither terminal nor GUI)",
        zh => "没有可以确认的通道（既无终端也无界面）",
    },
    confirm_cmd_write_outside => {
        ja => "このコマンドは許可範囲の外に書き込みます: %s\n  %s",
        en => "This command writes outside the writable roots: %s\n  %s",
        zh => "这条命令会写到可写范围之外：%s\n  %s",
    },
    cmd_write_refused     => {
        ja => "コマンドの書き込み先が許可範囲外のため実行しません: %s（%s）\n",
        en => "Not running it: the command writes outside the writable roots: %s (%s)\n",
        zh => "命令的写入目标在可写范围外，已拒绝执行：%s（%s）\n",
    },
    cmd_write_always_denied => {
        ja => "コマンドの書き込み先が永久禁止の場所です: %s\n",
        en => "The command writes to a location that is never allowed: %s\n",
        zh => "命令的写入目标是永久禁止的位置：%s\n",
    },
    write_out_of_scope   => {
        ja => "書き込み先が許可範囲の外です: %s\n  /allow-write <dir> で追加できます（/allow-write で一覧）\n",
        en => "That path is outside the writable roots: %s\n  add it with /allow-write <dir> (list them with /allow-write)\n",
        zh => "该路径不在可写范围内：%s\n  可用 /allow-write <dir> 添加（/allow-write 查看列表）\n",
    },
    write_always_denied  => {
        ja => "この場所への書き込みは許可できません（明示的に追加しても不可）: %s\n",
        en => "Writes here are never allowed, even if added explicitly: %s\n",
        zh => "该位置永远不允许写入（即使显式加入也不行）：%s\n",
    },
    allow_write_usage    => {
        ja => "使い方: /allow-write <dir> [<dir>...]  追加 / /allow-write  一覧 / /allow-write clear  追加分を消す\n",
        en => "Usage: /allow-write <dir> [<dir>...]  add / /allow-write  list / /allow-write clear  remove the added ones\n",
        zh => "用法：/allow-write <dir> [<dir>...] 添加 / /allow-write 查看 / /allow-write clear 清空追加项\n",
    },
    allow_write_added    => {
        ja => "書き込みを許可しました: %s\n",
        en => "Now writable: %s\n",
        zh => "已允许写入：%s\n",
    },
    allow_write_cleared  => {
        ja => "追加した書き込み先をすべて外しました。\n",
        en => "Removed all additional writable roots.\n",
        zh => "已清空所有额外可写目录。\n",
    },
    allow_write_bad      => {
        ja => "使えないパスでした: %s\n",
        en => "Unusable path: %s\n",
        zh => "路径不可用：%s\n",
    },
    shell_timed_out      => {
        ja => "\n[タイムアウト: %d 秒を超えたので中断しました]\n",
        en => "\n[timed out after %d seconds and was stopped]\n",
        zh => "\n[超时：超过 %d 秒，已中断]\n",
    },
    shell_truncated      => {
        ja => "\n[出力が大きいので先頭 %d KB だけ返します（全体 %s）]\n",
        en => "\n[output was large, so only the first %d KB is shown (total %s)]\n",
        zh => "\n[输出较大，只返回前 %d KB（共 %s）]\n",
    },
    shell_fork_failed    => {
        ja => "[コマンドを起動できませんでした]",
        en => "[could not start the command]",
        zh => "[无法启动命令]",
    },
    approvals_none       => {
        ja => "自動承認の記録はまだありません。\n",
        en => "No auto-approvals recorded yet.\n",
        zh => "还没有自动批准记录。\n",
    },
    approvals_head       => {
        ja => "直近の自動承認（%s）:\n",
        en => "Recent auto-approvals (%s):\n",
        zh => "最近的自动批准（%s）：\n",
    },
);

sub L {
    my ($key, @args) = @_;
    my $pair = $S{$key};
    return "[$key]" unless $pair;

    my $s;
    if (ref $pair eq 'HASH') {
        for my $lang (@LANG_FALLBACK) {
            my $v = $pair->{$lang};
            next unless defined $v && $v ne '';
            $s = $v;
            last;
        }
    }
    else {
        # 従来の [ja, en]。中国語は未訳なので英語に落とす(日英の挙動は不変)。
        $s = ($LANGCODE eq 'ja') ? $pair->[0] : $pair->[1];
    }
    $s = $pair->[0] unless defined $s && $s ne '';
    return @args ? sprintf($s, @args) : $s;
}

# perl の警告(Deep recursion / Out of memory / uninitialized など)も
# 残す。無限ループやメモリ枯渇の手前が見えることがある。
$SIG{__WARN__} = sub { my $w = shift; blog("WARN: $w"); dbg("WARN: $w"); warn $w; };

blog("=== advisor start (pid $$) ===");

# 端末設定を起動時に控えておき、どんな終わり方をしても必ず元に戻す。
# read_line_interactive は端末を raw モードにするので、途中で die すると
# 端末が壊れたまま(入力が見えない・改行されない)になってしまう。
our $ORIG_STTY = `stty -g 2>/dev/null`;
chomp $ORIG_STTY;
sub restore_tty { system('stty', $ORIG_STTY) if $ORIG_STTY ne ''; }
END { blog("END reached (exit=$?)"); restore_tty(); }
$SIG{INT}  = sub { blog("SIGINT");  restore_tty(); print L('interrupted'); exit 130; };
$SIG{TERM} = sub { blog("SIGTERM"); restore_tty(); exit 143; };
$SIG{HUP}  = sub { blog("SIGHUP (端末が閉じられた?)"); restore_tty(); exit 129; };
$SIG{__DIE__} = sub { blog("DIE" . ($^S ? "(in eval)" : "(FATAL)") . ": " . substr($_[0],0,300)); return; };

# ------------------------------------------------------------------
# providers.txt — キー環境変数名・既定モデル・キー取得URL・表示名の唯一の出所。
# ここに書いておけば GUI の初回画面とメニューが自動で追従する。コード側に
# URL やキー名を二重管理しない。
# ------------------------------------------------------------------
my %PROVIDER_INFO;   # provider => { key_env, default_model, key_url, ja, en, zh }
my @PROVIDER_ORDER;  # providers.txt の並び順（メニューの順序に使う）
{
    my @cand;
    push @cand, $ENV{CLAUDE_PROVIDERS_FILE} if $ENV{CLAUDE_PROVIDERS_FILE};
    my $here = dirname(Cwd::abs_path($0) // $0);
    push @cand, "$here/providers.txt", "$here/../providers.txt";
    my $path;
    for my $c (@cand) { if (defined $c && -f $c) { $path = $c; last } }
    if (!$path) {
        die "providers.txt が見つかりません。リポジトリ同梱のファイルが必要です。\n";
    }
    if (open(my $pf, '<:encoding(UTF-8)', $path)) {
        while (my $l = <$pf>) {
            chomp $l;
            next unless $l =~ /\S/;
            next if $l =~ /^\s*#/;
            my ($name, $kenv, $dmodel, $kurl, $ja, $en, $zh) = split /\|/, $l, 7;
            next unless defined $name && $name =~ /\S/;
            for ($name, $kenv, $dmodel, $kurl) { $_ = '' unless defined $_; s/^\s+//; s/\s+$// }
            $ja = $name unless defined $ja && $ja =~ /\S/;
            $en = $name unless defined $en && $en =~ /\S/;
            $zh = $name unless defined $zh && $zh =~ /\S/;
            for ($ja, $en, $zh) { s/^\s+//; s/\s+$// }
            $PROVIDER_INFO{$name} = {
                key_env       => $kenv,
                default_model => $dmodel,
                key_url       => $kurl,
                ja            => $ja,
                en            => $en,
                zh            => $zh,
            };
            push @PROVIDER_ORDER, $name;
        }
        close $pf;
    }
}

# providers.txt の1項目を取り出す。無ければ即死（半端な既定値で動かさない）。
sub provider_info {
    my ($name, $field) = @_;
    my $info = $PROVIDER_INFO{$name};
    die "providers.txt に '$name' の行がありません。\n" unless $info;
    return $info->{$field};
}

# 言語コードに応じた表示名
# 这个厂商现在有没有可用的密钥（只看当前进程环境：~/.claude-agent-env 与
# 手工 export 的都会在启动时进到 %ENV，所以这一个判断就是全量）。
sub provider_has_key {
    my ($p) = @_;
    my $env = provider_info($p, 'key_env');
    return 0 unless defined $env && $env ne '';
    my $v = $ENV{$env};
    return (defined $v && $v =~ /\S/) ? 1 : 0;
}

sub provider_label {
    my ($name) = @_;
    my $info = $PROVIDER_INFO{$name} or return $name;
    my $k = ($LANGCODE eq 'ja' || $LANGCODE eq 'zh' || $LANGCODE eq 'en') ? $LANGCODE : 'ja';
    my $v = $info->{$k};
    return (defined $v && $v ne '') ? $v : $name;
}

# ------------------------------------------------------------------
# コマンドライン引数 (--help / --version はAPIキー無しでも動作させる)
# モデル切り替えは ~/bin/claude (シェルラッパー) 側の -m/--select-model で
# 行い、ここではCLAUDE_MODEL環境変数を読むだけにして本体は単純に保つ。
# ------------------------------------------------------------------
my $LIST_HISTORY   = 0;   # --list-history: 保存済みの会話を一覧表示して終了
my $RESUME         = 0;   # --resume: 保存済みの会話を選んで続きから再開
my $CHANGE_PASS    = 0;   # --change-passphrase: 履歴パスフレーズを変更して終了
my $SET_RECOVERY   = 0;   # --set-recovery: 合言葉(復旧用の秘密の質問)を設定して終了
my $GUI            = 0;   # --gui: 端末用の表示をやめ、1行1件のJSONで入出力する
# --tools=a,b : 使えるツールを絞る（能力の絞り込み。増やす方向には働かない）
# 遠隔から使う場合はここで read_file,list_dir を渡す —— ただしその判断は
# 呼び出し側の都合で決まる。本体は「ツールを絞れる」以上のことを知らない。
my $TOOLS_ALLOW    = '';
my @TOOLS_ALLOWED;   # 空 = 制限なし

# ------------------------------------------------------------------
# 交互モード（--mode=default|accept-edits|bypass）
#
# 「確認を出すかどうか」だけを切り替える。能力（ツール）は --tools の担当で、
# この 2 つは直交する —— モードで新しいことは出来ない。
#
#   default      : write_file / run_shell とも毎回確認（従来通り）
#   accept-edits : 可写範囲内の write_file だけ自動。run_shell は毎回確認
#   bypass       : 通常操作は自動。危険なコマンドだけ確認する
#
# 危険なコマンドの確認は「応答が無ければ拒否」で閉じる（fail-closed）。
# 人が居ないときに待ち続けても何も安全にならず、セッションが固まるだけ。
# ------------------------------------------------------------------
my @MODE_ORDER = ('default', 'accept-edits', 'bypass');
my %MODE_VALID = map { $_ => 1 } @MODE_ORDER;
my $MODE = 'default';
my $MODE_ARG = '';
my @WRITE_ROOTS_RAW;      # --allow-write / CLAUDE_ALLOW_WRITE の生値
my @WRITE_ROOTS;          # 解決済みの追加可写ディレクトリ
my @WRITE_ROOTS_DENY;     # 明示的に足しても許可しない場所
my $CONFIRM_REASON = '';  # 直前の confirm() が拒否した理由
my $PENDING_MODE = '';    # /mode bypass の「yes 待ち」状態
                          #        (Python/tkinter のGUIから裏で駆動するため)

# --tools は「--tools=a,b」と「--tools a,b」の両方を受ける。
# 値を取る引数を for ループで扱うと、値の側が「未知の引数」として黙って
# 捨てられる —— 実際にそれで能力制限が丸ごと効かなくなった（1行も警告が出ない）。
# 先に正規化しておく。
for my $i (0 .. $#ARGV) {
    if ($ARGV[$i] eq '--tools' && defined $ARGV[$i + 1]) {
        $ARGV[$i] = "--tools=$ARGV[$i + 1]";
        splice(@ARGV, $i + 1, 1);
    }
}

# --mode / --allow-write も「--mode x」の形を受ける。値の側が「未知の引数」と
# して黙って捨てられると、指定したつもりで効かない（--tools で実際に起きた）。
for my $i (0 .. $#ARGV) {
    for my $opt ('--mode', '--allow-write') {
        if ($ARGV[$i] eq $opt && defined $ARGV[$i + 1]) {
            $ARGV[$i] = "$opt=$ARGV[$i + 1]";
            splice(@ARGV, $i + 1, 1);
        }
    }
}

for my $arg (@ARGV) {
    if ($arg eq '--help' || $arg eq '-h') {
        print_help();
        exit 0;
    }
    if ($arg eq '--version') {
        print "advisor (high_sierra_claude) " . app_version() . "\n";
        exit 0;
    }
    if ($arg eq '--list-history')      { $LIST_HISTORY = 1; }
    if ($arg eq '--resume')            { $RESUME = 1; }
    if ($arg eq '--change-passphrase') { $CHANGE_PASS = 1; }
    if ($arg eq '--set-recovery')      { $SET_RECOVERY = 1; }
    if ($arg eq '--gui')               { $GUI = 1; }
    # --rpc は --gui と完全に同じプロトコル。名前だけ用途で分けている
    # (GUI は画面が相手、rpc はプログラムが相手)。
    if ($arg eq '--rpc')               { $GUI = 1; }
    if ($arg =~ /^--tools=(.*)$/)      { $TOOLS_ALLOW = $1; }
    if ($arg =~ /^--mode=(.*)$/)       { $MODE_ARG = $1; }
    if ($arg =~ /^--allow-write=(.*)$/) { push @WRITE_ROOTS_RAW, $1; }
}

# --- モードと可写範囲の確定（引数 > 環境変数 > 既定） ------------------
{
    my $raw = $MODE_ARG;
    $raw = $ENV{CLAUDE_MODE} if $raw eq '' && defined $ENV{CLAUDE_MODE};
    $raw = '' unless defined $raw;
    $raw =~ s/^\s+//; $raw =~ s/\s+$//;
    $raw = 'default' if $raw eq '';
    unless ($MODE_VALID{$raw}) {
        # 既定へ黙って落とさない。落とすと「bypass のつもりが実は default」に
        # なる（安全側に見えて、実際はユーザーの意図を無言で書き換えている）。
        print STDERR L('mode_bad', $raw, join(' / ', @MODE_ORDER));
        exit 2;
    }
    $MODE = $raw;
}
if (!@WRITE_ROOTS_RAW && defined $ENV{CLAUDE_ALLOW_WRITE} && $ENV{CLAUDE_ALLOW_WRITE} ne '') {
    push @WRITE_ROOTS_RAW, split(/:/, $ENV{CLAUDE_ALLOW_WRITE});
}
@WRITE_ROOTS = grep { $_ ne '' } map { resolve_path($_) } @WRITE_ROOTS_RAW;
@WRITE_ROOTS_DENY = grep { $_ ne '' } map { resolve_path($_) } (
    '/etc', '/private/etc', '/usr', '/bin', '/sbin', '/System', '/Library',
    '/dev', '/private/var/db', '/var/db',
    ($ENV{HOME} || '') . '/.ssh',
    ($ENV{HOME} || '') . '/.claude-agent',
    ($ENV{HOME} || '') . '/.claude-agent-env',
);

# --help に出す「どの環境変数に何を入れるか」の表。providers.txt から生成する
# (ここにベンダー名やキー変数名を書き足さない)。
sub provider_key_table {
    return '' unless @PROVIDER_ORDER;
    my $out = '';
    if ($LANGCODE eq 'zh') {
        $out .= "\n各厂商的密钥变量与默认模型:\n";
        $out .= sprintf("  %-10s %-22s %s\n", '厂商', '环境变量', '默认模型');
    } elsif ($LANGCODE eq 'en') {
        $out .= "\nKey variable and default model per vendor:\n";
        $out .= sprintf("  %-10s %-22s %s\n", 'vendor', 'env var', 'default model');
    } else {
        $out .= "\nベンダーごとのキー変数と既定モデル:\n";
        $out .= sprintf("  %-10s %-22s %s\n", 'ベンダー', '環境変数', '既定モデル');
    }
    for my $p (@PROVIDER_ORDER) {
        $out .= sprintf("  %-10s %-22s %s\n", $p,
                        provider_info($p, 'key_env'),
                        provider_info($p, 'default_model'));
    }
    return $out;
}


sub print_help {
    # 中国語。未対応言語は従来通り日本語へ落ちる(この下の本文)。
    if ($LANGCODE eq 'zh') {
        my $h = <<'EOH';
用法: advisor [选项]

  -h, --help            显示本帮助
      --version         显示版本
      --list-history    列出已保存的对话并退出
      --resume          选择已保存的对话继续
      --change-passphrase 修改历史记录口令并退出
      --set-recovery    设置密保问题（找回口令用）并退出
      --tools=<a,b>     只用列出的工具（能力收窄；名字写错会报错退出）
      --mode=<名字>     交互模式：default / accept-edits / bypass（默认 default）
      --allow-write=<目录> 追加可写目录（可重复；默认只有当前目录与临时目录）
      --rpc             与 --gui 相同的 JSON 行协议（给程序化前端用）

环境变量:
  CLAUDE_PROVIDER    要用的 AI: %s（默认 anthropic）
  <厂商>_API_KEY     该厂商的密钥（变量名见下表；用哪家就设哪个）
  CLAUDE_MODEL       使用的模型（默认取该厂商的默认模型，见 providers.txt）
  CLAUDE_GEMINI_THINKING  设为 high 可让 Gemini 思考更深（默认 low=更快）
  CLAUDE_CURL        curl 命令路径（默认: curl，使用 PATH 上的那个）
  CLAUDE_CACERT      CA 证书文件（默认: 未指定，使用系统 curl 的信任库）
  CLAUDE_HISTORY_DIR 历史记录目录（默认 ~/.claude-agent/history）
  CLAUDE_NO_HISTORY  设为 1 则不保存对话（也不询问口令）
  CLAUDE_OPENSSL     openssl 命令路径（默认: openssl）
  CLAUDE_MODE        交互模式 default / accept-edits / bypass（等同 --mode）
  CLAUDE_ALLOW_WRITE 追加可写目录，冒号分隔（等同 --allow-write）
  CLAUDE_SHELL_TIMEOUT 命令超时秒数（默认 120，0=不限）
  CLAUDE_CONFIRM_TIMEOUT 危险操作确认等待秒数（默认 60，超时按拒绝处理）

对话中可用 /claude・/gemini 切换 AI（对话内容会保留）。
/mode 查看或切换交互模式；/allow-write 管理可写目录；/approvals 看最近自动批准。
模型选择用 `advisor --select-model` / `advisor -m <ID>`（由 shell 包装脚本处理）。
EOH
        $h =~ s{%s}{join(" / ", @PROVIDER_ORDER)}e;
        print $h;
        print provider_key_table();
        return;
    }
    my $hj = <<'EOH';
使い方: advisor [オプション]

  -h, --help            このヘルプを表示
      --version         バージョンを表示
      --list-history    保存済みの会話を一覧表示して終了
      --resume          保存済みの会話を選んで続きから再開
      --change-passphrase 履歴パスフレーズを変更して終了
      --set-recovery    合言葉(復旧用の秘密の質問)を設定して終了
      --tools=<a,b>     指定したツールだけ使う (絞る方向のみ。名前を間違えると終了)
      --mode=<名前>     対話モード: default / accept-edits / bypass (既定 default)
      --allow-write=<dir> 書き込みを許すディレクトリを追加 (複数可。既定は現在地と一時領域)
      --rpc             --gui と同じ JSON 行プロトコル (プログラム向け)

環境変数:
  CLAUDE_PROVIDER    使うAI: %s (既定 anthropic)
  <ベンダー>_API_KEY そのベンダーのキー (変数名は下の表。使う社のものだけ設定すればよい)
  CLAUDE_MODEL       使用するモデル (既定は各ベンダーの既定モデル。providers.txt 参照)
  CLAUDE_GEMINI_THINKING  high にすると Gemini の思考を深くする (既定 low=速い)
  CLAUDE_CURL        curlコマンドのパス (既定: curl。PATH上のものを使用)
  CLAUDE_CACERT      CA証明書ファイル (既定: 未指定。システムcurlの信頼ストアを使用)
  CLAUDE_HISTORY_DIR 履歴ディレクトリ (既定 ~/.claude-agent/history)
  CLAUDE_NO_HISTORY  1にすると会話を保存しない(パスフレーズも尋ねない)
  CLAUDE_OPENSSL     opensslコマンドのパス (既定: openssl)
  CLAUDE_MODE        対話モード default / accept-edits / bypass (--mode と同じ)
  CLAUDE_ALLOW_WRITE 書き込みを許すディレクトリを追加 (コロン区切り)
  CLAUDE_SHELL_TIMEOUT コマンドのタイムアウト秒 (既定 120、0=無制限)
  CLAUDE_CONFIRM_TIMEOUT 危険な操作の確認待ち秒 (既定 60、超過は拒否)

会話中に /claude・/gemini でAIを切り替えられる(会話は引き継がれる)。
/mode で対話モードの表示・切り替え、/allow-write で書き込み先の管理、/approvals で自動承認の履歴。
モデルの選択は `advisor --select-model` / `advisor -m <ID>` (シェルラッパー側)。
EOH
    $hj =~ s{%s}{join(" / ", @PROVIDER_ORDER)}e;
    print $hj;
    print provider_key_table();
}

# ------------------------------------------------------------------
# 設定
# ------------------------------------------------------------------
my $CURL       = $ENV{CLAUDE_CURL} || 'curl';
my $CACERT     = $ENV{CLAUDE_CACERT} || '';
my $MAX_TOKENS = 4096;
# setup.sh を介さず、会話中の /claude・/gemini で入力したキーを保存する先。
my $ENV_FILE_PATH = ($ENV{HOME} || '.') . '/.claude-agent-env';

# プロバイダ切り替え。CLAUDE_PROVIDER=gemini でクレジットカード登録不要の
# Gemini API 無料枠を、既定(anthropic)では従量課金の Claude を使う。
# 会話中に /claude・/gemini でも切り替えられる(下の会話ループ参照)。
my ($PROVIDER, $API_KEY, $MODEL, $API_URL, $ANTHROPIC_VERSION);
my $NOTOOLS = 0;            # 1 なら tools を送らない(非対応モデル)
my %MODEL_META;             # モデルID => { provider, base_url, notools }

# $provider に応じて $API_KEY / $MODEL / $API_URL 等を(再)設定する。
# 起動時と、会話中の /claude・/gemini の両方から呼ばれる。対応する
# 環境変数(ANTHROPIC_API_KEY / GEMINI_API_KEY)が無ければ die する
# — 起動時はそれで終了、切り替え時は呼び出し側で eval して握り、
# 今のプロバイダのまま継続する。
# ------------------------------------------------------------------
# プロバイダ登録表
#
# 「キーの環境変数名 / 既定モデル / 投げ先URL / リクエスト構築 / 応答解析」を
# 1箇所にまとめる。以前はこの情報が configure_provider・build_headers・
# build_request・parse_response の4箇所に if/elsif で散っており、
# プロバイダを1つ増やすには4箇所を同時に直す必要があった
# (直し忘れがそのまま不具合になる)。ここに1エントリ足せば済む形にする。
#
# 各項目:
#   （key_env と default_model は providers.txt 側。コードに二重管理しない）
#   auth           ヘッダの流儀: 'goog' 以外は x-api-key 系(既定)
#   model_prefix   CLAUDE_MODEL を採用してよいモデルIDの接頭辞

#   url            固定エンドポイント(url_template が無いとき使う)
#   url_template   %s にモデルIDを埋めるエンドポイント
#   api_version    anthropic-version ヘッダの値(必要なときだけ)
#   build / parse  内部形式(Anthropic content blocks)との相互変換
# ------------------------------------------------------------------
# ------------------------------------------------------------------
# プロバイダ登録表
#
# 「キーの環境変数名・既定モデル・投げ先URL・リクエスト構築・応答解析」を
# 1箇所にまとめる。以前はこの情報が configure_provider / build_headers /
# build_request / parse_response の4箇所に if/elsif で散っており、
# プロバイダを1つ増やすには4箇所を同時に直す必要があった(直し忘れが
# そのまま不具合になる)。ここに1エントリ足せば済む形にしておく。
#
# 各エントリの項目:
#   （key_env と default_model は providers.txt 側。コードに二重管理しない）
#   auth           ヘッダの流儀: 'x-api-key'(既定) / 'goog' / 'bearer'
#   model_prefix   CLAUDE_MODEL を採用してよいモデルIDの接頭辞

#   url            固定エンドポイント(anthropic)
#   url_template   %s にモデルIDを埋めるエンドポイント(gemini)
#   base_url       OpenAI互換エンドポイントの基底(末尾に /chat/completions を足す)
#   api_version    anthropic-version ヘッダの値(必要な場合のみ)
#   build / parse  内部形式(Anthropic content blocks)との変換関数
#
# OpenAI系(openai / deepseek / dashscope / moonshot / zhipu)は build/parse を
# 共有する。ベンダーごとに違うのはキーの環境変数名・既定モデル・base_url だけ。
# ------------------------------------------------------------------

my %PROVIDERS = (
    anthropic => {
        auth          => 'x-api-key',
        model_prefix  => 'claude',
        url           => 'https://api.anthropic.com/v1/messages',
        api_version   => '2023-06-01',
        build         => \&build_request_anthropic,
        parse         => \&parse_response_anthropic,
    },
    gemini => {
        auth          => 'goog',
        model_prefix  => 'gemini',
        url_template  => 'https://generativelanguage.googleapis.com/v1beta/models/%s:generateContent',
        build         => \&build_request_gemini,
        parse         => \&parse_response_gemini,
    },
    openai => {
        auth          => 'bearer',
        model_prefix  => 'gpt',
        base_url      => 'https://api.openai.com/v1',
        build         => \&build_request_openai,
        parse         => \&parse_response_openai,
    },
    deepseek => {
        auth          => 'bearer',
        model_prefix  => 'deepseek',
        base_url      => 'https://api.deepseek.com/v1',
        build         => \&build_request_openai,
        parse         => \&parse_response_openai,
    },
    dashscope => {
        auth          => 'bearer',
        model_prefix  => 'qwen',
        base_url      => 'https://dashscope.aliyuncs.com/compatible-mode/v1',
        build         => \&build_request_openai,
        parse         => \&parse_response_openai,
    },
    moonshot => {
        auth          => 'bearer',
        model_prefix  => 'kimi',
        base_url      => 'https://api.moonshot.cn/v1',
        build         => \&build_request_openai,
        parse         => \&parse_response_openai,
    },
    zhipu => {
        auth          => 'bearer',
        model_prefix  => 'glm',
        base_url      => 'https://open.bigmodel.cn/api/paas/v4',
        build         => \&build_request_openai,
        parse         => \&parse_response_openai,
    },
);

# 会話中に打つコマンド名のうち、プロバイダ名と違うもの。
# (/claude は既存ユーザーの指が覚えているので残す)
my %PROVIDER_ALIAS = (
    claude => 'anthropic',
    qwen   => 'dashscope',
    tongyi => 'dashscope',
    kimi   => 'moonshot',
    glm    => 'zhipu',
);

# コマンド名 → プロバイダ名。該当なしは空文字。
sub provider_from_command {
    my ($cmd) = @_;
    return $cmd if $PROVIDERS{$cmd};
    my $t = $PROVIDER_ALIAS{$cmd};
    return ($t && $PROVIDERS{$t}) ? $t : '';
}

# 未登録のプロバイダ名はここで弾く(各関数が個別に判定しない)。
sub provider_spec {
    my ($name) = @_;
    return $PROVIDERS{$name}
        || die L('unknown_provider', $name, join(' / ', sort keys %PROVIDERS));
}


# モデルIDから担当プロバイダを引く(接頭辞が一致する最初のもの)。
# どれにも一致しなければ anthropic に倒す — 既存の受け皿を変えないため。
# モデルIDから担当プロバイダを引く(接頭辞が一致する最初のもの)。
# models.txt にプロバイダ列があればそちらが優先される(switch_to_model 参照)。
# どれにも一致しなければ anthropic に倒す — 既存の受け皿を変えないため。
sub provider_for_model {
    my ($id) = @_;
    return 'anthropic' unless defined $id && $id ne '';
    for my $name (sort keys %PROVIDERS) {
        my $pfx = $PROVIDERS{$name}{model_prefix} || next;
        return $name if $id =~ /^\Q$pfx\E/;
    }
    return 'anthropic';
}


sub configure_provider {
    my ($provider) = @_;
    my $spec = provider_spec($provider);

    my $env_key = provider_info($provider, 'key_env');
    $ENV{$env_key} or die L('need_key', $env_key);
    $API_KEY = $ENV{$env_key};

    # CLAUDE_MODEL はプロバイダをまたぐと食い違うので、その provider の
    # 接頭辞で始まるときだけ採用し、そうでなければ既定モデルにする。
    my $env_model = $ENV{CLAUDE_MODEL} || '';
    my $pfx       = $spec->{model_prefix} || '';
    $MODEL = ($pfx ne '' && $env_model =~ /^\Q$pfx\E/)
        ? $env_model
        : provider_info($provider, 'default_model');

    # 投げ先URLの決め方は3通り:
    #   url           固定(anthropic)
    #   url_template  モデルIDを埋める(gemini)
    #   base_url      OpenAI互換。モデルごとの base_url が models.txt に
    #                 あればそれを、無ければプロバイダ既定を使う。
    #                 CLAUDE_BASE_URL で丸ごと差し替えられる(自前のプロキシ等)。
    if (defined $spec->{url}) {
        $API_URL = $spec->{url};
    }
    elsif (defined $spec->{url_template}) {
        $API_URL = sprintf($spec->{url_template}, $MODEL);
    }
    else {
        my $base = '';
        my $meta = $MODEL_META{$MODEL};
        $base = $meta->{base_url} if $meta && defined $meta->{base_url} && $meta->{base_url} ne '';
        $base = $ENV{CLAUDE_BASE_URL}
            if defined $ENV{CLAUDE_BASE_URL} && $ENV{CLAUDE_BASE_URL} ne '';
        $base = $spec->{base_url} if $base eq '';
        $base =~ s{/+$}{};
        $API_URL = $base . '/chat/completions';
    }

    # ツール非対応モデルは tools を送らない(送ると 400 になる実装がある)。
    $NOTOOLS = ($MODEL_META{$MODEL} && $MODEL_META{$MODEL}{notools}) ? 1 : 0;

    $ANTHROPIC_VERSION = $spec->{api_version};
    $PROVIDER = $provider;
}

# 選べるAIの一覧 ([id, 説明], ...)。ラッパーが CLAUDE_MODELS_FILE で場所を教える。
# models.txt は id|日本語の説明|English description の3列(後方互換で2列でも可)。
# 選べるAIの一覧 ([id, 説明], ...)。ラッパーが CLAUDE_MODELS_FILE で場所を教える。
# models.txt の列: id|日本語|English|中文|provider|base_url|flags
#   後方互換: 説明文の列が無くても、provider 以降が無くても動く
#   flags は空白/カンマ区切り。現在は notools のみ。
my @MODEL_CHOICES;
if ($ENV{CLAUDE_MODELS_FILE} && open(my $mf, '<:encoding(UTF-8)', $ENV{CLAUDE_MODELS_FILE})) {
    while (my $l = <$mf>) {
        chomp $l;
        next unless $l =~ /\S/;
        next if $l =~ /^\s*#/;
        my ($id, $desc_ja, $desc_en, $desc_zh, $mprov, $mbase, $mflags) = split /\|/, $l, 7;
        $id = '' unless defined $id;
        $id =~ s/^\s+|\s+$//g;
        next if $id eq '';

        # 表示言語に合わせて説明文の列を選ぶ(空なら ja → id の順に落とす)。
        my $desc;
        if ($LANGCODE eq 'zh') {
            $desc = $desc_zh;
            $desc = $desc_en if !defined $desc || $desc eq '';
        }
        elsif ($LANGCODE eq 'en') {
            $desc = $desc_en;
        }
        $desc = $desc_ja if !defined $desc || $desc eq '';
        $desc = $id if !defined $desc || $desc eq '';
        $desc =~ s/^\s+|\s+$//g;

        my $prov = defined $mprov ? $mprov : '';
        my $base = defined $mbase ? $mbase : '';
        $prov =~ s/^\s+|\s+$//g;
        $base =~ s/^\s+|\s+$//g;
        my $flags = defined $mflags ? $mflags : '';
        $flags = lc $flags;

        %{ $MODEL_META{$id} } = (
            provider => $prov,
            base_url => $base,
            notools  => ($flags =~ /\bnotools\b/) ? 1 : 0,
        );
        push @MODEL_CHOICES, [ $id, $desc, $prov ];
    }
    close $mf;
}

# ~/.claude-agent-env の1行を差し替える(無ければ追記)。会話中の切り替えを
# 次回起動にも引き継ぐため。
sub persist_env {
    my ($var, $val) = @_;
    return unless $ENV_FILE_PATH;
    my @lines;
    if (open(my $in, '<', $ENV_FILE_PATH)) {
        while (my $l = <$in>) {
            push @lines, $l unless $l =~ /^export \Q$var\E=/;
        }
        close $in;
    }
    push @lines, "export $var=$val\n";
    if (open(my $out, '>', $ENV_FILE_PATH)) {
        print $out @lines;
        close $out;
        chmod 0600, $ENV_FILE_PATH;
    }
}

# 会話中にプロバイダ(Claude/Gemini)を切り替える。キーが無ければその場で
# 入力してもらい、任意で保存する。成功したら 1、中止/失敗なら 0。
sub switch_provider {
    my ($target) = @_;
    eval { configure_provider($target) };
    return 1 unless $@;   # キーが揃っていてそのまま切り替えOK

    # キー名も登録表から引く(以前はここでプロバイダ名を直書きしていた)
    my $spec = eval { provider_spec($target) };
    return 0 unless $spec;
    my $key_name = provider_info($target, 'key_env');

    # GUIモードでは、GUI側にキー取得ページの案内・入力・疎通確認まで
    # 任せ、検証済みのキーを {"t":"key","value":...} で受け取る
    # (need_passphraseと同じ「投げて待つ」パターン)。
    if ($GUI) {
        gui_send({ t => 'need_key', provider => $target, key_name => $key_name });
        my $r = gui_read_typed('key');
        return 0 unless $r;                # EOF/終了
        my $key = $r->{value};
        if (!defined $key || $key eq '') {
            return 0;                       # キャンセル
        }
        $ENV{$key_name} = $key;
        eval { configure_provider($target) };
        if ($@) { emit_error(L('switch_failed', $@)); return 0; }
        persist_env($key_name, $key);
        return 1;
    }

    my $kurl = provider_info($target, 'key_url');
    print L('key_where', $kurl) if $kurl ne '';
    my $key = read_secret(L('key_missing_prompt', $key_name));
    if (!defined $key || $key eq '') {
        print L('switch_cancelled', $PROVIDER, $MODEL);
        return 0;
    }
    $ENV{$key_name} = $key;
    eval { configure_provider($target) };
    if ($@) { print L('switch_failed', $@); return 0; }
    print L('save_key_prompt', $ENV_FILE_PATH);
    my $yn = <STDIN>;
    if (defined $yn && $yn =~ /^y/i) {
        persist_env($key_name, $key);
        print L('saved_plain');
    }
    return 1;
}

# モデル選択は二段階。1段目でメーカー、2段目でそのメーカーのモデル。
# 12件が一次元に並ぶと目的のものを探せないので、providers.txt の並び順で束ねる。
my $MENU_STAGE = '';      # '' | 'vendor' | 'model:<provider>'
my %MENU_VENDORS;         # 番号 => provider
my %MENU_MODELS;          # 番号 => model_id

sub _models_of {
    my ($p) = @_;
    return grep { defined $_->[2] && $_->[2] eq $p } @MODEL_CHOICES;
}

# 1段目: メーカー一覧
sub show_model_menu {
    unless (@MODEL_CHOICES) {
        print L('model_list_unavail');
        $MENU_STAGE = '';
        return;
    }
    print "\n";
    my $i = 1;
    %MENU_VENDORS = ();
    for my $p (@PROVIDER_ORDER) {
        my @ms = _models_of($p);
        next unless @ms;
        my $mark = ($p eq $PROVIDER) ? L('currently_using_cli') : '';
        $mark .= L('menu_no_key') unless provider_has_key($p);
        printf "  %d) %s%s\n", $i, provider_label($p), $mark;
        $MENU_VENDORS{$i} = $p;
        $i++;
    }
    print L('model_menu_pick_vendor');
    $MENU_STAGE = 'vendor';
}

# 2段目: そのメーカーのモデル一覧
sub show_vendor_models {
    my ($p) = @_;
    my @ms = _models_of($p);
    unless (@ms) {
        print L('model_none_for_vendor', provider_label($p));
        show_model_menu();
        return;
    }
    print "\n";
    printf "  [%s]\n", provider_label($p);
    unless (provider_has_key($p)) {
        print L('menu_vendor_no_key', provider_label($p), provider_info($p, 'key_env'));
    }
    my $i = 1;
    %MENU_MODELS = ();
    for my $m (@ms) {
        my $mark = ($m->[0] eq $MODEL) ? L('currently_using_cli') : '';
        printf "  %d) %s%s\n", $i, $m->[1], $mark;
        $MENU_MODELS{$i} = $m->[0];
        $i++;
    }
    print L('model_menu_pick_model');
    $MENU_STAGE = "model:$p";
}

# 指定したモデルIDに切り替える。必要ならプロバイダも一緒に切り替え、
# 次回起動に引き継ぐため ~/.claude-agent-env にも書く。
sub switch_to_model {
    my ($id) = @_;
    # models.txt に provider 列があればそれを優先する。無ければモデルIDの
    # 接頭辞から推測(既存の受け皿を変えない)。
    my $declared = ($MODEL_META{$id} && $MODEL_META{$id}{provider}) ? $MODEL_META{$id}{provider} : '';
    my $target_provider = $declared ne '' ? $declared : provider_for_model($id);

    my $prev_model = $ENV{CLAUDE_MODEL};
    $ENV{CLAUDE_MODEL} = $id;

    my $ok = 1;
    if ($target_provider ne $PROVIDER) {
        $ok = switch_provider($target_provider);
    }
    else {
        eval { configure_provider($PROVIDER) };  # $MODEL と投げ先URLを作り直す
        if ($@) { print $@; $ok = 0; }
    }

    unless ($ok) {
        # 切り替え失敗。元のモデルに戻す。
        if (defined $prev_model) { $ENV{CLAUDE_MODEL} = $prev_model } else { delete $ENV{CLAUDE_MODEL} }
        eval { configure_provider($PROVIDER) };
        return;
    }

    persist_env('CLAUDE_MODEL', $MODEL);
    persist_env('CLAUDE_PROVIDER', $PROVIDER);
    emit_note(L('switched_to', $PROVIDER, $MODEL));
    gui_send({ t => 'model', provider => $PROVIDER, model => $MODEL }) if $GUI;
}

configure_provider($ENV{CLAUDE_PROVIDER} || 'anthropic');

# ------------------------------------------------------------------
# 出力の抽象化。端末モードでは今まで通り print、GUI モード($GUI)では
# 1行1件の JSON を STDOUT に書く。会話ループや run_tool はどちらか
# 意識しない。GUI 側 (Python/tkinter) がこの JSON を読んで画面を作る。
# ------------------------------------------------------------------
sub gui_send {
    my ($obj) = @_;
    print MiniJSON::encode($obj), "\n";
}
# GUI からの1行(JSON)を読んでデコード。EOF は undef、それ以外は必ずハッシュ参照。
sub gui_read {
    my $line = <STDIN>;
    return undef unless defined $line;
    $line =~ s/\r?\n\z//;
    my $text = decode('UTF-8', $line, FB_DEFAULT);
    my $obj  = eval { MiniJSON::decode($text) };
    return (ref $obj eq 'HASH') ? $obj : {};
}
# 指定した t の入力が来るまで読み飛ばして返す。EOF なら undef。
sub gui_read_typed {
    my ($want) = @_;
    while (1) {
        my $r = gui_read();
        return undef unless defined $r;
        return $r if ($r->{t} || '') eq $want;
        return undef if ($r->{t} || '') eq 'quit';
    }
}

sub emit_text {
    my ($text) = @_;
    if ($GUI) { gui_send({ t => 'text', text => $text }); }
    else      { print "\n$PROVIDER> $text\n"; }
}
sub emit_tool {
    my ($name, $input) = @_;
    if ($GUI) { gui_send({ t => 'tool', name => $name, input => $input }); }
    else      { print "\n[tool_use] $name(" . MiniJSON::encode($input) . ")\n"; }
}
sub emit_status {
    my ($text) = @_;
    if ($GUI) { gui_send({ t => 'status', text => $text }); }
    elsif ($text ne '') { print "\n... $text\n"; }
}
sub emit_error {
    my ($text) = @_;
    if ($GUI) { gui_send({ t => 'error', text => $text }); }
    else      { print "\n$text"; }
}
sub emit_note {   # 補助的なお知らせ(切り替え完了など)
    my ($text) = @_;
    if ($GUI) { gui_send({ t => 'note', text => $text }); }
    else      { print "\n$text\n"; }
}

# --- 会話履歴(暗号化してローカル保存) ---
# ランダムなマスター鍵で履歴ファイルを暗号化し、そのマスター鍵自体を
# パスフレーズ(と、任意で「合言葉」)で包んで保存する。どちらか一方で
# マスター鍵を取り出せるので、パスフレーズを忘れても合言葉で復旧できる。
my $HISTORY_ENABLED = $ENV{CLAUDE_NO_HISTORY} ? 0 : 1;
# 履歴ディレクトリは環境変数で差し替えられる。ディレクトリが変われば鍵
# ファイルも別になり、結果として「別のパスフレーズで守られた別の履歴」になる。
# 本体は誰がなぜ差し替えたのかを知らない（ローカルの複数プロファイルでも、
# 遠隔用の別領域でも、同じ仕組みで足りる）。
my $HISTORY_DIR     = (defined $ENV{CLAUDE_HISTORY_DIR} && $ENV{CLAUDE_HISTORY_DIR} ne '')
                      ? $ENV{CLAUDE_HISTORY_DIR}
                      : "$ENV{HOME}/.claude-agent/history";
my $KEY_FILE        = "$HISTORY_DIR/key.enc";           # マスター鍵をパスフレーズで包んだもの
my $KEY_RECOVERY    = "$HISTORY_DIR/key.recovery.enc";  # 同じマスター鍵を合言葉の答えで包んだもの(任意)
my $KEY_RECOVERY_Q  = "$HISTORY_DIR/key.recovery.q";    # 合言葉の質問文(平文)
my $HISTORY_CHECK   = "$HISTORY_DIR/.check";            # 旧形式。存在すればマスター鍵方式へ移行する
my $OPENSSL         = $ENV{CLAUDE_OPENSSL} || 'openssl';
my $STARTED         = _timestamp();
my $SESSION_FILE;                                       # この会話の保存先(unlock後に決定)

my $SYSTEM_PROMPT = <<'EOS';
You are a lightweight coding assistant running in the terminal of an
older Intel Mac (High Sierra era) that's being kept useful instead of
thrown away. Many users here are not programmers; they want you to build
small personal tools for them. You have four tools: read_file,
write_file, list_dir, and run_shell. Use them to read/write files and
run commands in the user's working directory. Keep replies concise, and
always reply in the same language the user wrote in.

__MODE_CONFIRM_NOTE__

Before a multi-step build, tell the user in one or two lines what files
you'll create and what you'll run, so the confirmation prompts make sense.

Environment: `python3` is Python 3.10 (in the user's PATH via
~/.bash_profile; from run_shell use `python3` and it resolves). tkinter
is available. For extra libraries use `python3 -m pip install --user
<pkg>`. Prefer the standard library when it's enough.
EOS

# 確認の説明はモードで変わる。bypass では「毎回聞かれる」と書いてあると
# モデルが「まず聞きますね」と無駄に断って進まなくなる。
my %MODE_NOTE = (
    'default' => <<'EON',
write_file and run_shell each ask the user for a y/n confirmation before
running. If a call comes back cancelled, it only means the user declined
THAT ONE action right then (often they were still typing a thought, or
want a change first) - it does NOT mean the environment blocks tools.
Never conclude that file writes or commands are disabled. Instead, stop,
say plainly what you were about to do, ask what they want to adjust, and
try again once they're ready. Do not silently retry the same write.
EON
    'accept-edits' => <<'EON',
File writes inside the allowed writable roots are approved automatically
in the current mode (accept-edits), so do not ask before writing inside
them; a write outside those roots still asks the user. run_shell always
asks before running. If something comes back cancelled or refused, say
plainly what you were about to do and what you need, instead of silently
retrying the same call.
EON
    'bypass' => <<'EON',
In the current mode (bypass) ordinary file writes inside the writable
roots and ordinary commands are approved automatically - do not ask
beforehand and do not wait for a confirmation that will not come. Two
things still stop you: dangerous commands (recursive deletes, sudo,
permission changes, power/system actions, download-and-run, interactive
programs) always ask the user, and writes outside the writable roots are
refused outright. Before a multi-step job, state in one or two lines what
you are about to create and run; if a call is refused, explain the reason
to the user rather than retrying the same thing.
EON
);

sub system_prompt {
    my $note = $MODE_NOTE{$MODE};
    $note = $MODE_NOTE{'default'} unless defined $note;
    my $p = $SYSTEM_PROMPT;
    $p =~ s/__MODE_CONFIRM_NOTE__/$note/;
    return $p;
}

# ------------------------------------------------------------------
# 最小限のJSONエンコーダ/デコーダ (依存ゼロ、Claude APIのメッセージ
# 構造に必要な範囲をカバーする再帰下降パーサー)
# ------------------------------------------------------------------
package MiniJSON;

sub encode {
    my ($v) = @_;
    my $r = ref $v;
    if ($r eq 'HASH') {
        return '{' . join(',', map {
            encode_string($_) . ':' . encode($v->{$_})
        } sort keys %$v) . '}';
    } elsif ($r eq 'ARRAY') {
        return '[' . join(',', map { encode($_) } @$v) . ']';
    } elsif (!defined $v) {
        return 'null';
    } elsif ($r eq 'SCALAR') {
        return $$v ? 'true' : 'false';
    } elsif ($v =~ /^-?\d+(\.\d+)?([eE][+-]?\d+)?$/) {
        return $v;
    } else {
        return encode_string($v);
    }
}

sub encode_string {
    my ($s) = @_;
    $s =~ s/([\\"])/\\$1/g;
    $s =~ s/\n/\\n/g;
    $s =~ s/\r/\\r/g;
    $s =~ s/\t/\\t/g;
    $s =~ s/([\x00-\x1f])/sprintf('\\u%04x', ord($1))/ge;
    return '"' . $s . '"';
}

# decode: 文字列 -> Perlデータ構造。posを進めながら解析する。
sub decode {
    my ($text) = @_;
    my $pos = 0;
    my $val = _decode_value(\$text, \$pos);
    return $val;
}

sub _skip_ws {
    my ($t, $p) = @_;
    $$p++ while $$p < length($$t) && substr($$t, $$p, 1) =~ /[\s]/;
}

sub _decode_value {
    my ($t, $p) = @_;
    _skip_ws($t, $p);
    my $c = substr($$t, $$p, 1);
    if ($c eq '{') { return _decode_object($t, $p); }
    if ($c eq '[') { return _decode_array($t, $p); }
    if ($c eq '"') { return _decode_string($t, $p); }
    if (substr($$t, $$p, 4) eq 'true') { $$p += 4; return 1; }
    if (substr($$t, $$p, 5) eq 'false') { $$p += 5; return 0; }
    if (substr($$t, $$p, 4) eq 'null') { $$p += 4; return undef; }
    # number
    if (substr($$t, $$p) =~ /^(-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)/) {
        $$p += length($1);
        return $1 + 0;
    }
    die "JSON parse error at pos $$p: " . substr($$t, $$p, 30) . "\n";
}

sub _decode_object {
    my ($t, $p) = @_;
    my %h;
    $$p++; # {
    _skip_ws($t, $p);
    if (substr($$t, $$p, 1) eq '}') { $$p++; return \%h; }
    while (1) {
        _skip_ws($t, $p);
        my $key = _decode_string($t, $p);
        _skip_ws($t, $p);
        $$p++; # :
        my $val = _decode_value($t, $p);
        $h{$key} = $val;
        _skip_ws($t, $p);
        my $c = substr($$t, $$p, 1);
        if ($c eq ',') { $$p++; next; }
        if ($c eq '}') { $$p++; last; }
        die "JSON parse error in object at pos $$p\n";
    }
    return \%h;
}

sub _decode_array {
    my ($t, $p) = @_;
    my @a;
    $$p++; # [
    _skip_ws($t, $p);
    if (substr($$t, $$p, 1) eq ']') { $$p++; return \@a; }
    while (1) {
        my $val = _decode_value($t, $p);
        push @a, $val;
        _skip_ws($t, $p);
        my $c = substr($$t, $$p, 1);
        if ($c eq ',') { $$p++; next; }
        if ($c eq ']') { $$p++; last; }
        die "JSON parse error in array at pos $$p\n";
    }
    return \@a;
}

sub _decode_string {
    my ($t, $p) = @_;
    $$p++; # opening "
    my $out = '';
    while (1) {
        my $c = substr($$t, $$p, 1);
        die "unterminated string\n" if $c eq '';
        if ($c eq '"') { $$p++; last; }
        if ($c eq '\\') {
            $$p++;
            my $e = substr($$t, $$p, 1);
            if ($e eq 'n') { $out .= "\n"; }
            elsif ($e eq 't') { $out .= "\t"; }
            elsif ($e eq 'r') { $out .= "\r"; }
            elsif ($e eq 'b') { $out .= "\b"; }
            elsif ($e eq 'f') { $out .= "\f"; }
            elsif ($e eq 'u') {
                my $hex = substr($$t, $$p + 1, 4);
                $out .= chr(hex($hex));
                $$p += 4;
            } else { $out .= $e; }
            $$p++;
        } else {
            $out .= $c;
            $$p++;
        }
    }
    return $out;
}

package main;

# ------------------------------------------------------------------
# curl 呼び出し
# ------------------------------------------------------------------
# プロバイダごとのHTTPヘッダ。APIキーはここで組み立て、call_api には
# ヘッダ文字列の配列として渡す(call_api自体はどっちのAIか知らない)。
sub build_headers {
    my $spec = provider_spec($PROVIDER);
    my $auth = $spec->{auth} || 'x-api-key';

    # APIキーはここで組み立て、call_api にはヘッダ文字列の配列として渡す
    # (call_api 自体はどのAIか知らない)。
    if ($auth eq 'goog') {
        return [ "x-goog-api-key: $API_KEY", "content-type: application/json" ];
    }
    if ($auth eq 'bearer') {
        # OpenAI互換(OpenAI / DeepSeek / 通義千問 / Kimi / 智谱)
        return [ "Authorization: Bearer $API_KEY", "content-type: application/json" ];
    }
    my @headers = ("x-api-key: $API_KEY");
    push @headers, "anthropic-version: $ANTHROPIC_VERSION" if defined $ANTHROPIC_VERSION;
    push @headers, "content-type: application/json";
    return \@headers;
}

sub call_api {
    my ($url, $headers, $body_json) = @_;

    my $tmp_req    = "/tmp/claude-agent-req-$$.json";
    my $tmp_resp   = "/tmp/claude-agent-resp-$$.json";
    my $tmp_config = "/tmp/claude-agent-curlcfg-$$.txt";

    open(my $fh, '>:encoding(UTF-8)', $tmp_req) or die "cannot write $tmp_req: $!\n";
    print $fh $body_json;
    close $fh;

    # APIキーを ps 出力に晒さないよう、コマンドライン引数ではなく
    # curlの設定ファイル(-K)経由でヘッダを渡す
    open(my $cf, '>', $tmp_config) or die "cannot write $tmp_config: $!\n";
    chmod 0600, $tmp_config;
    print $cf qq(url = "$url"\n);
    print $cf qq(request = "POST"\n);
    print $cf qq(cacert = "$CACERT"\n) if $CACERT;
    for my $h (@$headers) {
        print $cf qq(header = "$h"\n);
    }
    print $cf qq(data-binary = "\@$tmp_req"\n);
    print $cf qq(output = "$tmp_resp"\n);
    # http_codeに加え、各段階の所要時間もログに残す。「応答がものすごく
    # 遅い」という報告が2026-09-25にあったが、同じリクエストを直接curlで
    # 叩くと1〜3秒台で返ってきて再現しなかった(GUI・curlの呼び出し方式
    # どちらにも原因は無かった)。IPv6のhappy-eyeballs遅延など、たまに
    # しか起きないネットワーク側の要因が疑わしいので、次に起きた時すぐ
    # 原因の段階(名前解決/接続/TLS/応答待ち)が分かるようにしておく。
    print $cf qq(write-out = "%{http_code} dns=%{time_namelookup}s connect=%{time_connect}s tls=%{time_appconnect}s wait=%{time_starttransfer}s total=%{time_total}s"\n);
    # 回線がつまっても永遠に待たないよう上限を設ける。超えたら curl が
    # エラー終了し、下で HTTP 000 として扱われる(固まらない)。
    print $cf qq(connect-timeout = 20\n);
    print $cf qq(max-time = 180\n);
    # IPv6のhappy-eyeballs(v6を試して失敗/タイムアウトしてからv4に
    # フォールバックする)は環境によって数十秒の遅延要因になりうる。
    # このAPIはIPv4でも問題なく届くので、最初からIPv4を使う。
    print $cf qq(ipv4\n);
    print $cf qq(silent\n);
    print $cf qq(show-error\n);
    close $cf;

    dbg("REQ $PROVIDER $MODEL -> $url  (" . length($body_json) . " bytes)");

    # 応答待ちのあいだ画面が固まって見えないよう一言出す。
    # カーソル制御のエスケープは一切使わない(古い Terminal.app が
    # 文字描画で落ちるため。消さずに1行残すだけにする)。
    emit_status(L('thinking_status'));
    my $curl_out = `@{[quote($CURL)]} -K @{[quote($tmp_config)]}`;
    $curl_out = '' unless defined $curl_out;
    dbg("curl timing: $curl_out");
    my ($http_code) = $curl_out =~ /^(\d*)/;
    $http_code = '' unless defined $http_code;
    emit_status("") if $GUI;
    unlink $tmp_req, $tmp_config;

    # レスポンスは生バイトで読んでからまとめてデコードする。
    # :encoding(UTF-8) 層でそのまま読むと、マルチバイト文字がバッファ境界で
    # 割れたときに "utf8 does not map to Unicode" で落ちることがある
    # (ppc_claude_cli で踏んだのと同じ罠。日本語を多く含む長い応答で出やすい)。
    my $resp_body = '';
    if (open(my $rf, '<:raw', $tmp_resp)) {
        local $/;
        my $bytes = <$rf>;
        close $rf;
        $resp_body = defined($bytes) ? decode('UTF-8', $bytes, FB_DEFAULT) : '';
    }
    unlink $tmp_resp;

    dbg("RESP HTTP=$http_code  (" . length($resp_body) . " chars)");
    dbg("BODY:\n$resp_body");

    if ($http_code !~ /^2/) {
        if ($http_code eq '' || $http_code eq '000') {
            die L('cannot_connect');
        }
        # 本文が長いと画面が流れてしまうので、頭だけ見せる。
        my $brief = $resp_body;
        $brief =~ s/\s+/ /g;
        $brief = substr($brief, 0, 300) . ' …' if length($brief) > 300;
        die L('api_error', $http_code, $brief);
    }

    my $data = eval { MiniJSON::decode($resp_body) };
    if ($@ || !defined $data) {
        die L('bad_response');
    }
    return $data;
}

sub quote {
    my ($s) = @_;
    $s =~ s/'/'\\''/g;
    return "'$s'";
}

# ------------------------------------------------------------------
# プロバイダごとのリクエスト構築・レスポンス解析
#
# 会話履歴(@messages)は常に Anthropic の content blocks 形式
# (role => user/assistant, content => 文字列 or [{type=>text/tool_use/
# tool_result, ...}]) を内部形式として持つ。Gemini 利用時は API を呼ぶ
# 直前だけ contents/parts 形式に変換し、応答が来たらすぐ内部形式へ戻す。
# こうすることで会話ループや run_tool はプロバイダを一切気にしなくてよい。
# ------------------------------------------------------------------
sub build_request {
    my ($messages, $tools, $system) = @_;
    return provider_spec($PROVIDER)->{build}->($messages, $tools, $system);
}

sub build_request_anthropic {
    my ($messages, $tools, $system) = @_;
    return {
        model      => $MODEL,
        max_tokens => $MAX_TOKENS,
        system     => $system,
        messages   => $messages,
        tools      => $tools,
    };
}

sub build_request_gemini {
    my ($messages, $tools, $system) = @_;

    my @contents;
    for my $msg (@$messages) {
        my $role = $msg->{role} eq 'assistant' ? 'model' : 'user';
        my @parts;
        if (!ref $msg->{content}) {
            push @parts, { text => $msg->{content} };
        }
        else {
            for my $block (@{ $msg->{content} }) {
                if ($block->{type} eq 'text') {
                    my $part = { text => $block->{text} };
                    $part->{thoughtSignature} = $block->{thought_signature} if defined $block->{thought_signature};
                    push @parts, $part;
                }
                elsif ($block->{type} eq 'tool_use') {
                    my $part = { functionCall => { name => $block->{name}, args => $block->{input} } };
                    # Gemini 3系は functionCall を送り返す時、受け取った時と同じ
                    # thoughtSignature を付け直さないと400になる。
                    $part->{thoughtSignature} = $block->{thought_signature} if defined $block->{thought_signature};
                    push @parts, $part;
                }
                elsif ($block->{type} eq 'tool_result') {
                    # Gemini は tool_use_id ではなく名前で結果を紐付ける
                    push @parts, {
                        functionResponse => {
                            name     => $block->{name},
                            response => { output => $block->{content} },
                        },
                    };
                }
            }
        }
        push @contents, { role => $role, parts => \@parts };
    }

    my @function_declarations = map {
        +{ name => $_->{name}, description => $_->{description}, parameters => $_->{input_schema} }
    } @$tools;

    return {
        contents          => \@contents,
        systemInstruction => { parts => [ { text => $system } ] },
        tools             => [ { functionDeclarations => \@function_declarations } ],
        generationConfig  => {
            maxOutputTokens => $MAX_TOKENS,
            thinkingConfig  => _gemini_thinking_config(),
        },
    };
}

# Gemini 3系は thinkingLevel 省略時の既定が "HIGH" で、単純な質問でも最初の
# 1文字まで数十秒かかることがある。非力なマシンでの対話用途では速さ優先で
# LOW を既定にし、CLAUDE_GEMINI_THINKING=high で元に戻せるようにする。
# Gemini 2.5系は thinkingBudget(0〜24576、-1で動的)なのでモデル名で分岐。
sub _gemini_thinking_config {
    my $want_high = lc($ENV{CLAUDE_GEMINI_THINKING} || 'low') eq 'high';
    if ($MODEL =~ /^gemini-3/) {
        return { thinkingLevel => $want_high ? 'HIGH' : 'LOW' };
    }
    return { thinkingBudget => $want_high ? -1 : 0 };
}

sub parse_response {
    my ($resp) = @_;
    return provider_spec($PROVIDER)->{parse}->($resp);
}

sub parse_response_anthropic {
    my ($resp) = @_;
    if ($resp->{type} && $resp->{type} eq 'error') {
        die L('api_error_short', MiniJSON::encode($resp)) . "\n";
    }
    return @{ $resp->{content} || [] };
}

my $gemini_call_seq = 0;

sub parse_response_gemini {
    my ($resp) = @_;
    if ($resp->{error}) {
        die L('api_error_short', MiniJSON::encode($resp->{error})) . "\n";
    }
    my $candidate = $resp->{candidates} && $resp->{candidates}[0];
    my @blocks;
    for my $part (@{ ($candidate && $candidate->{content}{parts}) || [] }) {
        if (defined $part->{text}) {
            my $block = { type => 'text', text => $part->{text} };
            $block->{thought_signature} = $part->{thoughtSignature} if defined $part->{thoughtSignature};
            # thinkingConfig を有効にしている(_gemini_thinking_config)ため、
            # partsには「考え中」のthought部分と実際の回答部分が別々に
            # 混ざって返ってくることがある。thought:trueの部分は表示せず
            # 会話履歴にだけ残す(thoughtSignatureの継続に必要)。ここで
            # 落とさず全部'text'として返していたのが原因で、GUI側で2本の
            # 流し込みが同時に走り、文字が交互に混ざって見えていた。
            $block->{thought} = 1 if $part->{thought};
            push @blocks, $block;
        }
        elsif ($part->{functionCall}) {
            $gemini_call_seq++;
            my $block = {
                type  => 'tool_use',
                id    => "gemini-call-$gemini_call_seq",   # Gemini の functionCall には id が無いので代用
                name  => $part->{functionCall}{name},
                input => $part->{functionCall}{args} || {},
            };
            $block->{thought_signature} = $part->{thoughtSignature} if defined $part->{thoughtSignature};
            push @blocks, $block;
        }
    }
    return @blocks;
}

# ------------------------------------------------------------------
# OpenAI 互換 API (OpenAI / DeepSeek / 通義千問 / Kimi / 智谱)
#
# 内部形式(Anthropic の content blocks)との違い:
#   · system はメッセージ配列の先頭に role=system で1件入れる
#   · tool_use は assistant.tool_calls[]、引数は JSON「文字列」
#   · tool_result は role=tool の独立メッセージで tool_call_id で紐付ける
#     (Anthropic のように user メッセージ配列へ入れ子にできない)
#   · tools は {type=>'function', function=>{...}} で1段包む
# ------------------------------------------------------------------
sub build_request_openai {
    my ($messages, $tools, $system) = @_;

    my @out;
    push @out, { role => 'system', content => $system }
        if defined $system && $system ne '';

    for my $msg (@$messages) {
        my $role = $msg->{role} || 'user';
        if (!ref $msg->{content}) {
            push @out, { role => $role, content => $msg->{content} };
            next;
        }

        my (@texts, @calls, @results);
        for my $block (@{ $msg->{content} }) {
            my $t = $block->{type} || '';
            if ($t eq 'text') {
                next if $block->{thought};   # 思考ログは送り返さない
                push @texts, $block->{text};
            }
            elsif ($t eq 'tool_use') {
                push @calls, {
                    id       => $block->{id},
                    type     => 'function',
                    function => {
                        name      => $block->{name},
                        arguments => MiniJSON::encode($block->{input} || {}),
                    },
                };
            }
            elsif ($t eq 'tool_result') {
                my $c = $block->{content};
                $c = MiniJSON::encode($c) if ref $c;   # 文字列以外はJSONにして渡す
                push @results, {
                    role         => 'tool',
                    tool_call_id => $block->{tool_use_id},
                    content      => defined $c ? $c : '',
                };
            }
        }

        push @out, @results;
        if (@calls) {
            my $m = { role => 'assistant', tool_calls => \@calls };
            $m->{content} = join("\n", @texts) if @texts;
            push @out, $m;
        }
        elsif (@texts) {
            push @out, { role => $role, content => join("\n", @texts) };
        }
    }

    my $req = { model => $MODEL, messages => \@out };
    $req->{max_tokens} = $MAX_TOKENS;
    if (!$NOTOOLS && $tools && @$tools) {
        $req->{tools} = [
            map {
                +{ type => 'function', function => {
                    name        => $_->{name},
                    description => $_->{description},
                    parameters  => $_->{input_schema},
                } }
            } @$tools
        ];
    }
    return $req;
}

my $openai_call_seq = 0;

sub parse_response_openai {
    my ($resp) = @_;

    if ($resp->{error}) {
        my $e   = $resp->{error};
        my $msg = ref $e eq 'HASH'
            ? (defined $e->{message} ? $e->{message} : MiniJSON::encode($e))
            : $e;
        die L('api_error_short', $msg) . "\n";
    }

    my $choice = ($resp->{choices} && $resp->{choices}[0]) || {};
    my $msg    = $choice->{message} || {};
    my @blocks;

    # reasoning_content(DeepSeek-R1 等の思考ログ)は履歴に入れない。
    # 送り返すと API 側が 400 を返す実装があるため、意図的に捨てる。
    my $content = $msg->{content};
    if (ref $content eq 'ARRAY') {
        # 一部ベンダーは content を parts 配列で返す
        my @t = map { $_->{text} }
                grep { ref $_ eq 'HASH' && defined $_->{text} } @$content;
        $content = join("\n", @t);
    }
    push @blocks, { type => 'text', text => $content }
        if defined $content && $content ne '';

    for my $tc (@{ $msg->{tool_calls} || [] }) {
        my $fn   = $tc->{function} || {};
        my $args = $fn->{arguments};
        my $input;
        if (defined $args && $args ne '') {
            $input = eval { MiniJSON::decode($args) };
            $input = { _raw => $args } if $@ || ref $input ne 'HASH';
        }
        else {
            $input = {};
        }
        push @blocks, {
            type  => 'tool_use',
            id    => (defined $tc->{id} && $tc->{id} ne '')
                        ? $tc->{id}
                        : 'openai-call-' . (++$openai_call_seq),
            name  => $fn->{name},
            input => $input,
        };
    }

    return @blocks;
}


# ------------------------------------------------------------------
# 会話履歴の暗号化保存
#
# High Sierra 標準の Perl には暗号機能がなく、CPAN依存も入れたくないので
# openssl コマンドにシェルアウトしてAES-256-CBCで暗号化する。パスフレーズは
# 環境変数 CLAUDE_HIST_PASS 経由で渡し、ps出力やargv、ディスクには出さない。
# High Sierra の LibreSSL は -pbkdf2 非対応のため鍵導出はやや弱め(MD5ベース)
# だが、平文でそのまま置くよりははるかにマシ、という位置づけ。-md md5 を
# 明示して、新しめのOpenSSLとの間でも同じ鍵導出になるようにしている。
# ------------------------------------------------------------------
sub _timestamp {
    my @t = localtime();
    return sprintf('%04d%02d%02d-%02d%02d%02d',
        $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
}

# 一時ファイルを 0600 で作って書き込む(平文がディスクに出るのはここだけ、
# 直後に必ず unlink する)
sub _write_private {
    my ($path, $data) = @_;
    open(my $fh, '>:encoding(UTF-8)', $path) or die L('cannot_make_tmp', $!);
    chmod 0600, $path;
    print $fh $data;
    close $fh;
}

# openssl のstderr(新しめのOpenSSLが出す "deprecated key derivation" 警告や
# パスフレーズ違いの "bad decrypt" など。いずれもこちらで戻り値を見て処理する)
# を飲み込んで実行する
sub _run_quiet {
    my @cmd = @_;
    open(my $olderr, '>&', \*STDERR) or return system(@cmd);
    open(STDERR, '>', '/dev/null') or do { return system(@cmd) };
    my $rc = system(@cmd);
    open(STDERR, '>&', $olderr);
    return $rc;
}

sub hist_encrypt {
    my ($plaintext, $out_path) = @_;
    my $tmp = "/tmp/claude-hist-$$-" . int(rand(1_000_000_000));
    _write_private($tmp, $plaintext);
    my $rc = _run_quiet($OPENSSL, 'enc', '-aes-256-cbc', '-md', 'md5', '-salt',
                    '-pass', 'env:CLAUDE_HIST_PASS',
                    '-in', $tmp, '-out', $out_path);
    unlink $tmp;
    return $rc == 0;
}

sub hist_decrypt {
    my ($in_path) = @_;
    my $tmp = "/tmp/claude-hist-$$-" . int(rand(1_000_000_000));
    my $rc = _run_quiet($OPENSSL, 'enc', '-d', '-aes-256-cbc', '-md', 'md5',
                    '-pass', 'env:CLAUDE_HIST_PASS',
                    '-in', $in_path, '-out', $tmp);
    if ($rc != 0) { unlink $tmp; return undef; }
    open(my $fh, '<:encoding(UTF-8)', $tmp) or do { unlink $tmp; return undef; };
    local $/;
    my $data = <$fh>;
    close $fh;
    unlink $tmp;
    return $data;
}

# パスフレーズを画面に表示せずに1行読む
{
    my $secret_hint_shown = 0;
    sub read_secret {
        my ($prompt) = @_;

        # GUI モード: パスフレーズ要求イベントを送り、返答を待つ。
        if ($GUI) {
            (my $label = $prompt) =~ s/[:：]\s*$//;
            $label =~ s/^\s+//;
            gui_send({ t => 'need_passphrase', prompt => $label });
            while (1) {
                my $r = gui_read();
                return undef unless defined $r;
                next unless $r->{t} && $r->{t} eq 'passphrase';
                return defined $r->{value} ? $r->{value} : '';
            }
        }

        # 「入力しても何も出ない」を知らないと固まったように見えるので、
        # このセッションで最初のパスフレーズ入力のときだけ一言添える。
        unless ($secret_hint_shown) {
            print L('hidden_input_hint');
            $secret_hint_shown = 1;
        }
        print $prompt;
        system('stty', '-echo');
        my $line = <STDIN>;
        system('stty', 'echo');
        print "\n";
        return undef unless defined $line;
        chomp $line;
        return decode('UTF-8', $line, FB_DEFAULT);
    }
}

# 秘密(パスフレーズ or 合言葉の答え)を指定して包む/開ける。
# CLAUDE_HIST_PASS を一時的に差し替えて hist_encrypt/hist_decrypt を呼ぶ。
sub _wrap_with {
    my ($secret, $plaintext, $out_path) = @_;
    local $ENV{CLAUDE_HIST_PASS} = $secret;
    return hist_encrypt($plaintext, $out_path);
}
sub _unwrap_with {
    my ($secret, $in_path) = @_;
    local $ENV{CLAUDE_HIST_PASS} = $secret;
    return hist_decrypt($in_path);
}

# ランダムなマスター鍵(64桁hex)を生成する
sub _gen_master {
    my $hex = `@{[quote($OPENSSL)]} rand -hex 32 2>/dev/null`;
    $hex = '' unless defined $hex;
    $hex =~ s/\s+//g;
    return ($hex =~ /^[0-9a-f]{64}$/) ? $hex : undef;
}

# 包まれたマスター鍵を秘密で開ける。取り出せたらhex文字列、ダメならundef。
sub _open_master {
    my ($secret, $wrap_path) = @_;
    my $got = _unwrap_with($secret, $wrap_path);
    return undef unless defined $got;
    return $1 if $got =~ /^MASTER:([0-9a-f]{64})/;
    return undef;
}

# マスター鍵を秘密で包んで保存する
sub _save_master {
    my ($secret, $master, $wrap_path) = @_;
    my $ok = _wrap_with($secret, "MASTER:$master\n", $wrap_path);
    chmod 0600, $wrap_path if $ok;
    return $ok;
}

# 合言葉の答えを正規化する(大文字小文字と前後・連続空白を無視。
# 「Toyota Corolla」と「 toyota  corolla 」を同じ扱いにする)
sub _norm_answer {
    my ($a) = @_;
    $a = lc $a;
    $a =~ s/^\s+//;
    $a =~ s/\s+$//;
    $a =~ s/\s+/ /g;
    return $a;
}

# 合言葉(復旧用の秘密の質問)を設定/再設定する。$master は既に手元にある前提。
sub set_recovery {
    my ($master) = @_;
    print L('ask_secret_question');
    my $q = <STDIN>;
    $q = defined($q) ? decode('UTF-8', $q, FB_DEFAULT) : '';
    chomp $q;
    if ($q eq '') { print L('secret_q_empty'); return 0; }
    my $a1 = read_secret(L('secret_answer_1'));
    my $a2 = read_secret(L('secret_answer_again'));
    unless (defined $a1 && $a1 ne '' && defined $a2 && $a1 eq $a2) {
        print L('secret_mismatch');
        return 0;
    }
    unless (_save_master(_norm_answer($a1), $master, $KEY_RECOVERY)) {
        print L('secret_save_failed');
        return 0;
    }
    _write_private($KEY_RECOVERY_Q, "$q\n");
    print L('secret_set_done');
    return 1;
}

# 新しいパスフレーズを2回入力させてマスター鍵を包み直す
sub reset_passphrase {
    my ($master) = @_;
    my $p1 = read_secret(L('new_passphrase_1'));
    my $p2 = read_secret(L('secret_answer_again'));
    unless (defined $p1 && $p1 ne '' && defined $p2 && $p1 eq $p2) {
        print L('passphrase_mismatch');
        return 0;
    }
    if (_save_master($p1, $master, $KEY_FILE)) { print L('changed_done'); return 1; }
    print L('change_failed');
    return 0;
}

# 合言葉で復旧する。成功したらマスター鍵hexを返す(ついでにパスフレーズの
# 再設定を促す)。中止/失敗の抜け道は「空Enter」。
sub recover_with_phrase {
    my $q = '';
    if (open(my $qf, '<:encoding(UTF-8)', $KEY_RECOVERY_Q)) {
        $q = <$qf>;
        close $qf;
        chomp $q if defined $q;
    }
    print L('secret_question_is', $q) if defined $q && $q ne '';
    while (1) {
        my $ans = read_secret(L('secret_answer_try'));
        return undef unless defined $ans && $ans ne '';
        my $master = _open_master(_norm_answer($ans), $KEY_RECOVERY);
        if (defined $master) {
            print L('recovered');
            print L('set_new_passphrase_q');
            my $yn = <STDIN>;
            reset_passphrase($master) if defined $yn && $yn =~ /^y/i;
            return $master;
        }
        print L('secret_wrong');
    }
}

# 旧形式(.check 直接暗号化 + 履歴ファイルもパスフレーズ直接暗号化)から
# マスター鍵方式へ移行する。成功したらマスター鍵hexを返す。
sub migrate_check_file {
    print L('hist_migrate_intro');
    while (1) {
        my $pass = read_secret(L('hist_passphrase_cancel'));
        return undef unless defined $pass && $pass ne '';
        my $got = _unwrap_with($pass, $HISTORY_CHECK);
        if (defined $got) {
            chomp $got;
            if ($got eq 'high_sierra_claude') {
                my $master = _gen_master();
                return undef unless defined $master;
                # 既存の履歴ファイルを パスフレーズ→マスター鍵 で再暗号化
                for my $f (history_files()) {
                    my $plain = _unwrap_with($pass, "$HISTORY_DIR/$f");
                    _wrap_with($master, $plain, "$HISTORY_DIR/$f") if defined $plain;
                }
                unless (_save_master($pass, $master, $KEY_FILE)) {
                    print L('migrate_failed');
                    return undef;
                }
                unlink $HISTORY_CHECK;
                print L('updated_done');
                return $master;
            }
        }
        print L('wrong_passphrase');
    }
}

# 履歴のロックを解除し、$ENV{CLAUDE_HIST_PASS} にマスター鍵をセットして
# 1 を返す。初回は新規設定、以降はパスフレーズ(または合言葉)で解錠する。
# 中止/失敗なら 0(履歴なしで続行)。
sub unlock_history {
    for my $d ("$ENV{HOME}/.claude-agent", $HISTORY_DIR) {
        mkdir($d, 0700) unless -d $d;
    }

    # GUI モード: パスフレーズは1回入力(確認欄なし)。代わりに「合言葉」を
    # 必須にして、忘れたときの復旧口を必ず用意する。旧形式移行は端末側で。
    if ($GUI) {
        return 0 if -f $HISTORY_CHECK && ! -f $KEY_FILE;

        my $has_recovery = (-f $KEY_RECOVERY && -f $KEY_RECOVERY_Q) ? 1 : 0;

        if (-f $KEY_FILE) {                                 # 解錠
            while (1) {
                gui_send({ t => 'need_passphrase', prompt => L('history_prompt'),
                           recover => ($has_recovery ? 1 : 0) });
                my $r = gui_read_typed('passphrase');
                return 0 unless defined $r;

                if ($has_recovery && $r->{recover}) {       # 合言葉で復旧
                    my $q = '';
                    if (open(my $qf, '<:encoding(UTF-8)', $KEY_RECOVERY_Q)) {
                        local $/; $q = <$qf>; close $qf;
                        $q = '' unless defined $q;
                        $q =~ s/\s+\z//;          # local $/ 中は chomp が効かない
                    }
                    gui_send({ t => 'need_recovery', mode => 'unlock', question => ($q // '') });
                    my $ra = gui_read_typed('recovery');
                    return 0 unless defined $ra;
                    my $ans = defined $ra->{answer} ? $ra->{answer} : '';
                    my $m = ($ans ne '') ? _open_master(_norm_answer($ans), $KEY_RECOVERY) : undef;
                    unless (defined $m) { emit_error(L('wrong_answer')); next; }
                    # 新しいパスフレーズに付け替える
                    gui_send({ t => 'need_passphrase',
                               prompt => L('new_history_prompt') });
                    my $np = gui_read_typed('passphrase');
                    my $npv = ($np && defined $np->{value}) ? $np->{value} : '';
                    _save_master($npv, $m, $KEY_FILE) if $npv ne '';
                    emit_note(L('recovered'));
                    $ENV{CLAUDE_HIST_PASS} = $m;
                    return 1;
                }

                my $pass = defined $r->{value} ? $r->{value} : '';
                return 0 if $pass eq '';                    # 空=履歴なしで起動
                my $master = _open_master($pass, $KEY_FILE);
                if (defined $master) { $ENV{CLAUDE_HIST_PASS} = $master; return 1; }
                emit_error(L('wrong_passphrase'));
            }
        }

        # 初回設定
        gui_send({ t => 'need_passphrase',
                   prompt => L('new_history_prompt') });
        my $r = gui_read_typed('passphrase');
        return 0 unless defined $r;
        my $p = defined $r->{value} ? $r->{value} : '';
        return 0 if $p eq '';
        my $master = _gen_master();
        return 0 unless defined $master;
        return 0 unless _save_master($p, $master, $KEY_FILE);

        # 合言葉(必須)。設定されなければ暗号化履歴は残さない
        # (パスフレーズを忘れたときに全損するのを避けるため)。
        gui_send({ t => 'need_recovery', mode => 'new' });
        my $rr = gui_read_typed('recovery');
        my $q = ($rr && defined $rr->{question}) ? $rr->{question} : '';
        my $a = ($rr && defined $rr->{answer})   ? $rr->{answer}   : '';
        if ($q ne '' && $a ne '' && _save_master(_norm_answer($a), $master, $KEY_RECOVERY)) {
            _write_private($KEY_RECOVERY_Q, "$q\n");
        } else {
            unlink $KEY_FILE;
            emit_error(L('no_recovery_set'));
            return 0;
        }
        $ENV{CLAUDE_HIST_PASS} = $master;
        return 1;
    }

    # 旧形式の移行
    if (-f $HISTORY_CHECK && ! -f $KEY_FILE) {
        my $master = migrate_check_file();
        if (defined $master) { $ENV{CLAUDE_HIST_PASS} = $master; return 1; }
        return 0;
    }

    # 2回目以降: パスフレーズ or 合言葉で解錠
    if (-f $KEY_FILE) {
        my $has_recovery = (-f $KEY_RECOVERY && -f $KEY_RECOVERY_Q) ? 1 : 0;
        # 回数制限なし。履歴なしで進めたいときは空Enterで抜ける。
        while (1) {
            my $prompt = $has_recovery
                ? L('hist_pass_no_recovery')
                : L('hist_pass_no_recovery2');
            my $pass = read_secret($prompt);
            unless (defined $pass && $pass ne '') {
                print L('starting_no_history');
                return 0;
            }
            if ($has_recovery && $pass eq 'r') {
                my $master = recover_with_phrase();
                if (defined $master) { $ENV{CLAUDE_HIST_PASS} = $master; return 1; }
                next;
            }
            my $master = _open_master($pass, $KEY_FILE);
            if (defined $master) { $ENV{CLAUDE_HIST_PASS} = $master; return 1; }
            print L('wrong_passphrase');
            print $has_recovery ? L('wrong_pass_recover_hint') : "\n";
        }
    }

    # 初回設定
    print L('hist_encrypt_intro', $HISTORY_DIR);
    print L('choose_passphrase');
    my $p1 = read_secret(L('new_passphrase_1'));
    my $p2 = read_secret(L('secret_answer_again'));
    unless (defined $p1 && $p1 ne '' && defined $p2 && $p1 eq $p2) {
        print L('passphrase_mismatch_continue');
        return 0;
    }
    my $master = _gen_master();
    unless (defined $master) {
        print L('key_gen_failed');
        return 0;
    }
    unless (_save_master($p1, $master, $KEY_FILE)) {
        print L('key_save_failed');
        return 0;
    }
    print L('set_done');

    print L('secret_optional_intro');
    print L('set_it_q');
    my $yn = <STDIN>;
    set_recovery($master) if defined $yn && $yn =~ /^y/i;

    $ENV{CLAUDE_HIST_PASS} = $master;
    return 1;
}

# 現在の会話を暗号化して $SESSION_FILE に保存する
sub save_history {
    my ($messages_ref) = @_;
    return unless $SESSION_FILE;
    my $json = MiniJSON::encode({
        model    => $MODEL,
        started  => $STARTED,
        messages => $messages_ref,
    });
    hist_encrypt($json, $SESSION_FILE);
    chmod 0600, $SESSION_FILE;
}

# 保存済みの会話ファイル(新しい順。ファイル名先頭がタイムスタンプ)
sub history_files {
    opendir(my $dh, $HISTORY_DIR) or return ();
    my @f = grep { /\.json\.enc$/ } readdir($dh);
    closedir $dh;
    return sort { $b cmp $a } @f;
}

# 会話データから最初のユーザー発言を1行取り出す(一覧表示用)
sub first_user_line {
    my ($data) = @_;
    for my $m (@{ $data->{messages} || [] }) {
        next unless $m->{role} && $m->{role} eq 'user';
        my $c = $m->{content};
        next if ref $c;   # tool_result などの構造化contentはスキップ
        $c =~ s/\s+/ /g;
        return length($c) > 60 ? substr($c, 0, 60) . '…' : $c;
    }
    return L('no_message');
}

# 内部形式の会話を GUI で再描画するための {role, text} 配列に平す。
#   role: you / ai / tool / toolresult
sub flatten_history {
    my ($msgs) = @_;
    my @out;
    for my $m (@$msgs) {
        my $role = $m->{role} || '';
        my $c = $m->{content};
        if (!ref $c) {
            push @out, { role => ($role eq 'assistant' ? 'ai' : 'you'), text => $c };
            next;
        }
        for my $b (@{ $c || [] }) {
            my $t = $b->{type} || '';
            if ($t eq 'text') {
                push @out, { role => 'ai', text => ($b->{text} // '') };
            }
            elsif ($t eq 'tool_use') {
                push @out, { role => 'tool',
                    text => ($b->{name} // 'tool') . '('
                          . MiniJSON::encode($b->{input} // {}) . ')' };
            }
            elsif ($t eq 'tool_result') {
                my $rc = $b->{content};
                $rc = MiniJSON::encode($rc) if ref $rc;
                push @out, { role => 'toolresult', text => ($rc // '') };
            }
        }
    }
    return \@out;
}

# ------------------------------------------------------------------
# ツール定義とツール実行
# ------------------------------------------------------------------
my @TOOLS = (
    {
        name => 'read_file',
        description => 'ファイルの内容を読み取る',
        input_schema => {
            type => 'object',
            properties => { path => { type => 'string', description => '読み取るファイルのパス' } },
            required => ['path'],
        },
    },
    {
        name => 'write_file',
        description => 'ファイルに内容を書き込む(上書き)',
        input_schema => {
            type => 'object',
            properties => {
                path    => { type => 'string', description => '書き込み先のパス' },
                content => { type => 'string', description => '書き込む内容' },
            },
            required => ['path', 'content'],
        },
    },
    {
        name => 'list_dir',
        description => 'ディレクトリの内容を一覧表示する',
        input_schema => {
            type => 'object',
            properties => { path => { type => 'string', description => '一覧表示するディレクトリ(省略時はカレント)' } },
            required => [],
        },
    },
    {
        name => 'run_shell',
        description => 'シェルコマンドを実行し、標準出力/標準エラーを返す',
        input_schema => {
            type => 'object',
            properties => { command => { type => 'string', description => '実行するシェルコマンド' } },
            required => ['command'],
        },
    },
);

# --tools= による絞り込み。ここは「減らす」方向にしか働かない —— 登録簿に無い
# 名前を渡されたら黙って無視せず死ぬ（設定ミスを静かに握り潰さない）。
if ($TOOLS_ALLOW ne '') {
    my %known = map { $_->{name} => 1 } @TOOLS;
    my %want;
    for my $n (split /,/, $TOOLS_ALLOW) {
        $n =~ s/^\s+//; $n =~ s/\s+$//;
        next if $n eq '';
        unless ($known{$n}) {
            die sprintf("--tools に未知のツール名 '%s' が指定されました（使えるのは: %s）\n",
                        $n, join(', ', sort keys %known));
        }
        $want{$n} = 1;
    }
    if (%want) {
        @TOOLS_ALLOWED = sort keys %want;
        @TOOLS = grep { $want{ $_->{name} } } @TOOLS;
    }
}

sub confirm {
    my ($msg, $opts) = @_;
    my $danger = ($opts && ref $opts eq 'HASH' && $opts->{danger}) ? 1 : 0;
    # strict: 「人が居なければ拒否」で閉じたい確認（危険コマンド、可写範囲外への
    # 書き込み）。danger は文言（★危険）のため、strict は待ち時間のため。
    my $strict = ($opts && ref $opts eq 'HASH' && $opts->{strict}) ? 1 : $danger;
    my $wait   = $strict ? confirm_timeout_secs() : 0;
    $CONFIRM_REASON = '';

    # GUI モード: 確認イベントを送って、返ってくる reply を待つ。
    # 危険な操作のときだけ待ち時間を切る（人が居ないまま固まらないように）。
    if ($GUI) {
        gui_send({ t => 'confirm', prompt => $msg, danger => $danger });
        my $value;
        my $got = 0;
        eval {
            local $SIG{ALRM} = sub { die "ALARM_CONFIRM\n" };
            alarm($wait) if $wait > 0;
            while (1) {
                my $r = gui_read();
                last unless defined $r;                  # GUIが閉じた
                next unless $r->{t} && $r->{t} eq 'reply';
                $value = $r->{value};
                $got = 1;
                last;
            }
            alarm(0);
        };
        alarm(0);
        if (!$got) {
            $CONFIRM_REASON = ($@ && $@ =~ /ALARM_CONFIRM/) ? 'timeout' : 'nochannel';
            return 0;
        }
        unless (defined $value && $value =~ /^(y|yes|1|true)$/i) {
            $CONFIRM_REASON = 'no';
            return 0;
        }
        return 1;
    }

    # 端末が無い（パイプ実行など）なら、危険な操作は聞かずに拒否する。
    # 聞く相手が居ないのに待つのは、固まるだけで何も安全にしない。
    if ($strict && !(-t STDIN)) {
        $CONFIRM_REASON = 'nochannel';
        return 0;
    }

    print "\n";
    print L('confirm_banner');
    print L('danger_banner') if $danger;
    print L('confirm_about_to');
    print "  $msg\n";
    print L('confirm_yn_hint');
    print L('confirm_not_instruct');
    print "─────────────────────\n";

    # y/n 以外(指示文を打ってしまった等)ではキャンセルせず、聞き直す。
    # 誤って打ち込んだ一言で書き込みが飛んでしまうのを防ぐ。
    my $answer;
    eval {
        local $SIG{ALRM} = sub { die "ALARM_CONFIRM\n" };
        alarm($wait) if $wait > 0;
        while (1) {
            print "y / n : ";
            my $ans = read_line_interactive('', 0);
            unless (defined $ans) { $answer = 0; last; }      # Ctrl-D
            my $a = $ans;
            $a =~ s/^\s+//; $a =~ s/\s+$//;
            if ($a =~ /^(y|yes|はい)$/i) { $answer = 1; last; }
            if ($a =~ /^(n|no|いいえ)$/i) { $answer = 0; last; }
            if ($a eq '') { $answer = 0; last; }               # 空Enter → 中止
            print L('confirm_yn_only');
        }
        alarm(0);
    };
    alarm(0);
    if (!defined $answer) {
        restore_tty();
        $CONFIRM_REASON = 'timeout';
        print L('danger_timeout_note', $wait) if $danger;
        return 0;
    }
    unless ($answer) { $CONFIRM_REASON = 'no'; return 0; }
    return 1;
}

# ------------------------------------------------------------------
# 行編集(矢印キー対応の簡易readline)
#
# 標準の <STDIN> はカーソル移動機能を持たないため、矢印キーを押すと
# ターミナルが送る生のエスケープシーケンス(ESC [ C など)がそのまま
# 文字として画面に出てしまう。これを避けるため、stty で端末をraw
# モードにし、1バイトずつ読みながら簡易的な行編集(←→移動、
# Backspace、↑↓での履歴呼び出し)を自前で実装する。
# 外部CPANモジュール(Term::ReadLineなど)には依存しない。
# ------------------------------------------------------------------
{
    my @HISTORY;

    # デバッグ用: $ENV{CLAUDE_DEBUG_INPUT}にファイルパスを設定すると、
    # read_line_interactiveが実際に受け取った生バイトを1行ずつ追記する。
    # 実機でIME入力時に何が届いているか調べるための一時的な仕組み。
    sub _debug_log {
        return unless $ENV{CLAUDE_DEBUG_INPUT};
        open(my $fh, '>>', $ENV{CLAUDE_DEBUG_INPUT}) or return;
        print $fh @_;
        close $fh;
    }

    # UTF-8の先頭バイトからその文字が何バイトかを返す
    sub _utf8_char_len {
        my ($byte) = @_;
        my $b = ord($byte);
        return 1 if $b < 0x80;
        return 2 if ($b & 0xE0) == 0xC0;
        return 3 if ($b & 0xF0) == 0xE0;
        return 4 if ($b & 0xF8) == 0xF0;
        return 1;  # 不正なバイト列は1バイトずつ進める
    }

    # デコード済みのPerl文字列を受け取り、ターミナル上での表示幅
    # (半角=1/全角=2)を返す
    sub _display_width_chars {
        my ($text) = @_;
        my $w = 0;
        for my $ch (split //, $text) {
            my $cp = ord($ch);
            $w += (
                ($cp >= 0x1100 && $cp <= 0x115F) ||
                ($cp >= 0x2E80 && $cp <= 0xA4CF) ||
                ($cp >= 0xAC00 && $cp <= 0xD7A3) ||
                ($cp >= 0xF900 && $cp <= 0xFAFF) ||
                ($cp >= 0xFF00 && $cp <= 0xFF60) ||
                ($cp >= 0xFFE0 && $cp <= 0xFFE6)
            ) ? 2 : 1;
        }
        return $w;
    }

    # 与えられたUTF-8バイト列の、ターミナル上での表示幅を返す
    sub _display_width {
        my ($bytes) = @_;
        return 0 if $bytes eq '';
        return _display_width_chars(decode('UTF-8', $bytes, FB_DEFAULT));
    }

    # ターミナルの桁数を返す(取得できなければ80にフォールバック)
    sub _term_width {
        my $wh = `stty size 2>/dev/null`;
        return $1 if $wh =~ /^\s*\d+\s+(\d+)\s*$/;
        return 80;
    }

    # 表示幅$w(セル数)ぶん文字を描画した直後にカーソルが位置する
    # (0始まりの行, 0始まりの列)を返す。ターミナルの折り返しは、行末に
    # 達しても次の文字が来るまで改行しない"遅延ラップ"仕様のため、
    # ちょうど桁数の倍数で折り返る場合はその行の最終列に留まる。
    sub _pos_rc {
        my ($w, $cols) = @_;
        return (0, 0) if $w <= 0 || $cols <= 0;
        my $row = int(($w - 1) / $cols);
        my $col = $w % $cols;
        $col = $cols - 1 if $col == 0;  # 遅延ラップ: ちょうど桁数の倍数のときは行末に留まる
        return ($row, $col);
    }

    # プロンプトを表示しつつ1行読み込む。
    #
    # 既定は「素の入力」: 端末を raw にせず <STDIN> で1行読むだけ。
    # 理由 — 矢印キー対応の自作行編集は、キー入力のたびに端末へ大量の
    # カーソル移動・全行再描画のエスケープシーケンスを送る。High Sierra の
    # Terminal.app 2.8.3 はこの負荷(特に日本語=CoreText グリフ描画)で
    # グリフ描画中に heap corruption を起こして abort することがある
    # (Terminal 側のバグ。crash report で確認済み)。実用上、行編集より
    # 「落ちないこと」を優先する。
    #
    # CLAUDE_FANCY_INPUT=1 で従来の行編集(←→移動・↑↓履歴)に戻せる。
    sub read_line_interactive {
        my ($prompt, $use_history) = @_;
        $use_history = 1 unless defined $use_history;

        unless ($ENV{CLAUDE_FANCY_INPUT}) {
            (my $p = $prompt) =~ s/^\n+//;
            print "\n" if $prompt =~ /^\n/;
            print $p;
            my $line = <STDIN>;
            return undef unless defined $line;   # EOF

            # 複数行を貼り付けると1行=1メッセージに割れてしまうのを防ぐ。
            # 最初の行を読んだ直後、まだ入力がバッファに残っていれば(=貼り付け)、
            # 続く行も同じメッセージとしてまとめる。人が1行ずつ考えて打つ場合は
            # 次の行まで間があくので、この待ち時間(50ms)には引っかからない。
            eval {
                my $rin = '';
                vec($rin, fileno(STDIN), 1) = 1;
                while (select(my $r = $rin, undef, undef, 0.05)) {
                    my $more = <STDIN>;
                    last unless defined $more;
                    $line .= $more;
                }
            };

            $line =~ s/\r?\n\z//;                 # 末尾の改行だけ落とす(中の改行は残す)
            return $line;                         # 生バイト(呼び出し側でデコード)
        }

        my $orig_stty = `stty -g`;
        chomp $orig_stty;
        my $term_cols = _term_width();
        # -opostが無いと、環境によっては出力後処理(特にocrnl)が有効なままで
        # 再描画に使う"\r"が改行として扱われ、行を上書きするはずが毎回新しい
        # 行を作ってしまう(結果、入力するたびにどんどん改行されていく)。
        system('stty', 'raw', '-echo', '-opost');

        my $buf = '';                    # 生バイト列
        my $pos = 0;                     # カーソル位置(バイト単位、常に文字境界)
        my $hist_idx = scalar(@HISTORY); # 履歴カーソル(配列末尾 = 新規入力中)
        my $saved_buf = '';              # 履歴を辿る前の入力を退避しておく

        # $promptの先頭改行(例: "\nご用件をどうぞ> ")は最初の表示でだけ使う。
        # 再描画のたびにこれをそのまま含めて出すと、キー入力するたびに
        # 改行が挿入され続けて新しい行がどんどん増えてしまう。
        (my $redraw_prompt = $prompt) =~ s/^\n+//;

        # redraw_promptだけを表示した状態(bufが空)で何行分の表示になるかを初期値とする。
        my $rows_used = (_pos_rc(_display_width_chars($redraw_prompt), $term_cols))[0] + 1;

        my $redraw = sub {
            # $bufは生バイトのUTF-8。STDOUTには:encoding(UTF-8)層が付いているので
            # 一度Perl文字列にデコードしてから渡さないと二重エンコードで文字化けする。
            my $text   = decode('UTF-8', $buf, FB_DEFAULT);
            my $before = decode('UTF-8', substr($buf, 0, $pos), FB_DEFAULT);
            my $full_text   = $redraw_prompt . $text;
            my $full_width  = _display_width_chars($full_text);
            my $cursor_width = _display_width_chars($redraw_prompt . $before);

            # 前回の再描画で使った行数ぶんカーソルを先頭行まで戻し、そこから
            # 画面末尾までを丸ごとクリアする。折り返した行が複数あっても、
            # 最終行だけをクリアする"\r\x1b[K"では前の行が消えずに残って
            # しまい、入力するたびに同じ文字列が積み重なって表示される
            # バグの原因になっていた。
            print "\x1b[" . ($rows_used - 1) . "A" if $rows_used > 1;
            print "\r\x1b[0J", $full_text;

            my $end_row = (_pos_rc($full_width, $term_cols))[0];
            $rows_used = $end_row + 1;

            if ($cursor_width < $full_width) {
                my ($cur_row, $cur_col) = _pos_rc($cursor_width, $term_cols);
                print "\x1b[" . ($end_row - $cur_row) . "A" if $end_row > $cur_row;
                print "\x1b[" . ($cur_col + 1) . "G";
            }
        };

        print $prompt;
        _debug_log("=== read_line_interactive start ===\n");

        # 誤って先読みしてしまったバイトを次のループへ戻すためのプッシュバック
        # キュー。マルチバイト文字の続きだと思って読んだバイトが実際には
        # continuationバイトの形式(10xxxxxx)でなかった場合に使う。
        my @pending;
        my $read_one_byte = sub {
            return shift @pending if @pending;
            my $ch;
            my $n = sysread(STDIN, $ch, 1);
            return (defined $n && $n > 0) ? $ch : undef;
        };
        # Mac OS X の Terminal.app は、IME(日本語入力など)で確定した
        # テキストを渡す際、各バイトの前に0x16(Ctrl-V。端末で伝統的に
        #「次の1文字をそのまま扱う(LNEXT)」の合図として使われるバイト)を
        # 付けて送ってくることがある。このプログラムはraw modeで自前で
        # 入力を処理しておりLNEXTの解釈をしていないため、何もしないと
        # この合図のバイト自体がゴミとして文字列に混入し、UTF-8が壊れて
        # 文字化けする。ここで0x16を読み飛ばし、次のバイトを本来のデータ
        # として扱う。
        my $read_byte = sub {
            my $ch = $read_one_byte->();
            if (defined $ch && $ch eq "\x16") {
                $ch = $read_one_byte->();
            }
            return $ch;
        };

        my $result;
        my $ctrld_seen = 0;   # 空行での Ctrl-D。1回目は警告、2回で終了。
        RAW_LOOP: while (1) {
            my $ch = $read_byte->();
            if (!defined $ch) {
                _debug_log("EOF\n");
                dbg("readline: real EOF on STDIN");
                $result = undef;  # 本物のEOF(標準入力が閉じた)
                last RAW_LOOP;
            }
            my $b = ord($ch);
            _debug_log(sprintf("byte: %02x (%s)\n", $b, ($b >= 0x20 && $b < 0x7f) ? chr($b) : ''));

            if ($b == 13 || $b == 10) {       # Enter
                _debug_log(sprintf("-> ENTER, buf hex=%s\n", unpack('H*', $buf)));
                print "\r\n";
                $result = $buf;
                last RAW_LOOP;
            }
            elsif ($b == 3) {                  # Ctrl-C: 行をキャンセルして空行扱い
                print "\r\n";
                $result = '';
                last RAW_LOOP;
            }
            elsif ($b == 4) {                  # Ctrl-D
                # 誤爆で1発終了しないよう、空行では2回連続で押されたときだけEOF。
                if ($buf eq '') {
                    $ctrld_seen++;
                    if ($ctrld_seen >= 2) {
                        dbg("readline: Ctrl-D x2 -> EOF");
                        $result = undef;
                        last RAW_LOOP;
                    }
                    print L('exit_hint');
                    print $redraw_prompt;
                    $rows_used = (_pos_rc(_display_width_chars($redraw_prompt), $term_cols))[0] + 1;
                }
            }
            elsif ($b == 127 || $b == 8) {      # Backspace
                if ($pos > 0) {
                    my $start = $pos - 1;
                    $start-- while $start > 0 && (ord(substr($buf, $start, 1)) & 0xC0) == 0x80;
                    substr($buf, $start, $pos - $start, '');
                    $pos = $start;
                    $redraw->();
                }
            }
            elsif ($b == 27) {                  # ESC: カーソルキーなど
                my $c2 = $read_byte->();
                next RAW_LOOP unless defined $c2;
                if ($c2 eq '[') {
                    my $c3 = $read_byte->();
                    next RAW_LOOP unless defined $c3;
                    if ($c3 eq 'C') {            # →
                        if ($pos < length($buf)) {
                            $pos += _utf8_char_len(substr($buf, $pos, 1));
                            $redraw->();
                        }
                    }
                    elsif ($c3 eq 'D') {         # ←
                        if ($pos > 0) {
                            my $start = $pos - 1;
                            $start-- while $start > 0 && (ord(substr($buf, $start, 1)) & 0xC0) == 0x80;
                            $pos = $start;
                            $redraw->();
                        }
                    }
                    elsif ($use_history && $c3 eq 'A') {  # ↑ 履歴を遡る
                        if ($hist_idx > 0) {
                            $saved_buf = $buf if $hist_idx == @HISTORY;
                            $hist_idx--;
                            $buf = $HISTORY[$hist_idx];
                            $pos = length($buf);
                            $redraw->();
                        }
                    }
                    elsif ($use_history && $c3 eq 'B') {  # ↓ 履歴を進める
                        if ($hist_idx < @HISTORY) {
                            $hist_idx++;
                            $buf = ($hist_idx == @HISTORY) ? $saved_buf : $HISTORY[$hist_idx];
                            $pos = length($buf);
                            $redraw->();
                        }
                    }
                    elsif ($c3 eq '3') {         # Delete キー (ESC [ 3 ~)
                        my $c4 = $read_byte->();
                        if (defined $c4 && $pos < length($buf)) {
                            substr($buf, $pos, _utf8_char_len(substr($buf, $pos, 1)), '');
                            $redraw->();
                        }
                    }
                }
            }
            else {                               # 通常の文字(UTF-8の生バイト)
                # マルチバイト文字の途中(バイトが揃っていない状態)でredrawすると
                # decode()が不完全な列を「�」に化けさせてしまうため、1文字分の
                # バイトが揃うまで読んでからバッファに追加・再描画する。
                # ただし、続くバイトが本当にUTF-8のcontinuationバイト(10xxxxxx)
                # でなければ、それは別の文字/キーの先頭バイトなので読み戻す
                # (でないと、本来の入力を誤って飲み込んでしまい、以降の入力が
                # 効かなくなってしまう)。
                my $need = _utf8_char_len($ch) - 1;
                my $char = $ch;
                while ($need > 0) {
                    my $cont = $read_byte->();
                    last unless defined $cont;
                    _debug_log(sprintf("  continuation byte: %02x\n", ord($cont)));
                    if ((ord($cont) & 0xC0) != 0x80) {
                        unshift @pending, $cont;
                        last;
                    }
                    $char .= $cont;
                    $need--;
                }
                substr($buf, $pos, 0) = $char;
                $pos += length($char);
                $redraw->();
            }
        }

        system('stty', $orig_stty) if defined $orig_stty && $orig_stty ne '';

        if ($use_history && defined $result && $result ne '') {
            push @HISTORY, $result;
        }
        return $result;
    }
}

# ------------------------------------------------------------------
# 模式・可写範囲・危険コマンド・シェル実行の共通部品
#
# ここは「安全側に倒す」ための判定だけを置く。判定に失敗したら危険側
# （＝許可）に倒さず、必ず確認か拒否に倒すこと。
# ------------------------------------------------------------------

# パスを実体に寄せる（~ 展開 + シンボリックリンク解決。未作成なら親で解決）。
sub resolve_path {
    my ($p) = @_;
    return '' unless defined $p;
    $p =~ s/^\s+//; $p =~ s/\s+$//;
    return '' if $p eq '';
    if ($p =~ m{^~(/|$)}) {
        my $h = $ENV{HOME} || '';
        $p =~ s{^~}{$h};
    }
    my $abs = Cwd::abs_path($p);
    return $abs if defined $abs && $abs ne '';
    my $parent = dirname($p);
    my $pabs = Cwd::abs_path($parent);
    if (defined $pabs && $pabs ne '') {
        (my $base = $p) =~ s{.*/}{};
        return "$pabs/$base";
    }
    return '';
}

# 可写の既定根: カレントディレクトリ + 一時ディレクトリ。
# 一時ディレクトリは TMPDIR があれば**それだけ**を使う（macOS は必ず設定される）。
# /tmp を常に足していた頃は、テストが「範囲外」を作ったつもりで /tmp 配下に
# 置いてしまい、環境によって可否が変わった —— 判定に環境依存を持ち込まない。
sub temp_root {
    my $t = defined $ENV{TMPDIR} && $ENV{TMPDIR} ne '' ? $ENV{TMPDIR} : '/tmp';
    return resolve_path($t);
}

sub write_roots_all {
    my @r = @WRITE_ROOTS;
    push @r, resolve_path(Cwd::getcwd());
    push @r, temp_root();
    my %seen;
    return grep { !$seen{$_}++ } grep { defined $_ && $_ ne '' } @r;
}

sub write_hard_denied {
    my ($abs) = @_;
    return 0 unless defined $abs && $abs ne '';
    for my $d (@WRITE_ROOTS_DENY) {
        next if $d eq '';
        return 1 if $abs eq $d || index($abs, "$d/") == 0;
    }
    return 0;
}

sub is_hard_denied_path {
    my ($path) = @_;
    my $abs = resolve_path($path);
    return 0 if $abs eq '';
    return write_hard_denied($abs) ? 1 : 0;
}

# 書き込みが許可範囲に入っているか（default モードでは判定に使わない）。
sub write_allowed {
    my ($path) = @_;
    my $abs = resolve_path($path);
    return 0 if $abs eq '';
    return 0 if write_hard_denied($abs);
    for my $r (write_roots_all()) {
        return 1 if $abs eq $r || index($abs, "$r/") == 0;
    }
    return 0;
}

# 危険コマンド。当たったら理由の identifier を返す（'' = 危険ではない）。
# 誤検知は「確認が 1 回増える」だけで済むが、見逃しは取り返せない。
# そのため少し広めに取る。
my @DANGER_RULES = (
    [ qr{\brm\s+(?:-[A-Za-z]+\s+)*(?:-[A-Za-z]*[rf][A-Za-z]*\s+)+['"]?(?:/|~|/\*|\$HOME|\$home)}, 'rm_root' ],
    [ qr{\bmkfs(?:\.|[\s&|;])}, 'mkfs' ],
    [ qr{\bdd\b[^\n]*\bof=/dev/}, 'dd_device' ],
    [ qr{>\s*/dev/(?:sd|disk|rdisk)}, 'redirect_device' ],
    [ qr{\b(?:shutdown|reboot|halt|poweroff)\b}, 'system_power' ],
    [ qr{\b(?:systemsetup|csrutil)\b}, 'system_setup' ],
    [ qr{\blaunchctl\s+unload\b}, 'launchctl' ],
    [ qr{\bsudo\b}, 'sudo' ],
    [ qr{(?:^|[|;&]\s*)su\s+-}, 'su' ],
    [ qr{\bchown\s+-R\s+\S+\s+root\b}, 'chown_root' ],
    [ qr{\b(?:curl|wget)\b[^\n|]*\|\s*(?:sudo\s+)?(?:sh|bash|zsh)\b}, 'pipe_to_shell' ],
    [ qr{\bchmod\s+-R\s+777\s+/}, 'chmod_root' ],
    [ qr{:\(\)\s*\{.*:\s*\|\s*:.*\}}, 'fork_bomb' ],
    [ qr{\bkill\s+-9\s+-1\b}, 'kill_all' ],
    [ qr{\bshred\b}, 'shred' ],
);
my @DANGER_INTERACTIVE = qw(vi vim nano emacs less more top htop man ssh telnet ftp sftp);

sub is_dangerous {
    my ($cmd) = @_;
    return '' unless defined $cmd && $cmd ne '';
    for my $rule (@DANGER_RULES) {
        return $rule->[1] if $cmd =~ $rule->[0];
    }
    # パイプや区切りの先頭トークンも見る（`cat x | less` は固まる）
    for my $seg (split(/\|\||&&|;|\|/, $cmd)) {
        $seg =~ s/^\s+//;
        next if $seg eq '';
        my ($first) = $seg =~ /^([A-Za-z_][A-Za-z0-9_.-]*)/;
        next unless defined $first;
        return "interactive_$first" if grep { $_ eq $first } @DANGER_INTERACTIVE;
    }
    return '';
}


# ------------------------------------------------------------------
# コマンド文字列の「書き込み先らしきもの」を拾う（保守的・best effort）
#
# shell の文法を完全に解析はしない。拾えるものだけ拾い、拾えなかったものは
# 従来どおり「危険コマンドの確認」に任せる。狙いは『write_file だけが範囲の
# 対象』という穴を塞ぐこと。cp/mv/rm/tee/リダイレクトくらいは実務上ほぼ全て。
# ------------------------------------------------------------------
sub _split_shell_words {
    my ($seg) = @_;
    my @w;
    my $cur = '';
    my $q   = '';
    for my $c (split(//, $seg)) {
        if ($q ne '') {
            if ($c eq $q) { $q = ''; next; }
            $cur .= $c;
            next;
        }
        if ($c eq '"' || $c eq "'") { $q = $c; next; }
        if ($c eq ' ' || $c eq "\t") { push @w, $cur if $cur ne ''; $cur = ''; next; }
        $cur .= $c;
    }
    push @w, $cur if $cur ne '';
    return @w;
}

sub shell_write_targets {
    my ($cmd) = @_;
    return () unless defined $cmd && $cmd ne '';
    my @targets;

    # 1) リダイレクト（> / >> / 2> / &>）
    while ($cmd =~ /(?:^|[^0-9&>])>>?\s*([^\s;|&>()]+)/g) {
        my $t = $1;
        $t =~ s/^['"]//;
        $t =~ s/['"]$//;
        push @targets, $t;
    }

    # 2) 代表的なコマンドの書き込み先
    for my $seg (split(/\|\||&&|;|\|/, $cmd)) {
        my @w = _split_shell_words($seg);
        next unless @w;
        my $c = $w[0];
        $c =~ s{.*/}{};
        my @args = grep { !m{^-} } @w[ 1 .. $#w ];
        if ($c eq 'tee') {
            push @targets, @args;
        }
        elsif ($c eq 'cp' || $c eq 'mv' || $c eq 'ln' || $c eq 'install') {
            push @targets, $args[-1] if @args;
        }
        elsif ($c eq 'rm' || $c eq 'touch' || $c eq 'mkdir') {
            push @targets, @args;
        }
    }

    my (@out, %seen);
    for my $t (@targets) {
        next if $t eq '' || $t eq '-';
        next if $t =~ m{^/dev/(?:null|stdout|stderr|tty|zero|fd/)};   # 無害
        next if $t =~ m{^&};
        next if $seen{$t}++;
        push @out, $t;
    }
    return @out;
}

# ('hard'|'scope', path) を返す。'' 相当（該当なし）なら空リスト。
sub shell_scope_violation {
    my ($cmd) = @_;
    for my $t (shell_write_targets($cmd)) {
        my $abs = resolve_path($t);
        next if $abs eq '';
        return ('hard', $t) if write_hard_denied($abs);
        unless (write_allowed($t)) { return ('scope', $t); }
    }
    return ();
}

sub shell_timeout_secs {
    my $v = defined $ENV{CLAUDE_SHELL_TIMEOUT} ? $ENV{CLAUDE_SHELL_TIMEOUT} : '';
    return 120 unless $v =~ /^\d+$/;
    return $v;
}

sub confirm_timeout_secs {
    my $v = defined $ENV{CLAUDE_CONFIRM_TIMEOUT} ? $ENV{CLAUDE_CONFIRM_TIMEOUT} : '';
    return 60 unless $v =~ /^\d+$/;
    return $v;
}

sub _tmp_path {
    my ($tag) = @_;
    my $dir = $ENV{TMPDIR} || '/tmp';
    $dir =~ s{/+$}{};
    return sprintf('%s/advisor-%s-%d-%d', $dir, $tag, $$, int(rand(1_000_000_000)));
}

sub _human_bytes {
    my ($n) = @_;
    return '0 B' unless defined $n && $n > 0;
    return sprintf('%d B', $n) if $n < 1024;
    return sprintf('%.1f KB', $n / 1024) if $n < 1024 * 1024;
    return sprintf('%.1f MB', $n / (1024 * 1024));
}

# run_shell の実行。タイムアウトと出力上限つき。
#   * 出力はファイルへ落としてから読む（メモリに溜めない）
#   * 子は独立したプロセスグループにする（npm などの孫まで確実に止める）
#   * 打ち切り時は TERM → 0.5 秒 → KILL
sub run_shell_capture {
    my ($command) = @_;
    my $limit = shell_timeout_secs();
    my $cap   = 64 * 1024;
    my $out   = _tmp_path('shell-out');

    my $pid = fork();
    unless (defined $pid) {
        return (L('shell_fork_failed'), 127);
    }
    if ($pid == 0) {
        eval { setpgrp(0, 0); };
        open(STDOUT, '>', $out) or exit 127;
        open(STDERR, '>&', STDOUT) or exit 127;
        exec('/bin/sh', '-c', $command);
        exit 127;
    }

    my $timed_out = 0;
    if ($limit > 0) {
        eval {
            local $SIG{ALRM} = sub { die "ALARM_SHELL_TIMEOUT\n" };
            alarm($limit);
            waitpid($pid, 0);
            alarm(0);
        };
        $timed_out = 1 if $@ && $@ =~ /ALARM_SHELL_TIMEOUT/;
    }
    else {
        waitpid($pid, 0);
    }
    my $status = $?;

    if ($timed_out) {
        alarm(0);
        my $k = kill('TERM', -$pid);
        kill('TERM', $pid) unless $k;
        select(undef, undef, undef, 0.5);
        $k = kill('KILL', -$pid);
        kill('KILL', $pid) unless $k;
        waitpid($pid, 0);
    }

    my $size = -s $out;
    $size = 0 unless defined $size && $size > 0;
    my $text = '';
    if (open(my $fh, '<', $out)) {
        binmode $fh;
        my $take = $size > $cap ? $cap : $size;
        if ($take > 0) { read($fh, $text, $take); }
        close $fh;
    }
    unlink($out);
    $text = '' unless defined $text;

    my $res = decode('UTF-8', $text, FB_DEFAULT);
    $res = '' unless defined $res;
    $res =~ s/\r\n/\n/g;

    $res .= L('shell_timed_out', $limit) if $timed_out;
    $res .= L('shell_truncated', int($cap / 1024), _human_bytes($size)) if $size > $cap;
    $res = L('no_output') if $res eq '';
    return ($res, (defined $status ? $status : 0));
}

# ------------------------------------------------------------------
# 自動承認の記録（~/.claude-agent/approvals.log）
#
# 遠隔用の audit.log とは別ファイルにする。片方は「外から誰が何を聞いたか」、
# こちらは「ローカルで勝手にやったこと」。混ぜるとどちらも読みにくくなる。
# ------------------------------------------------------------------
sub approvals_path { return ($ENV{HOME} || '.') . '/.claude-agent/approvals.log'; }

sub approvals_log {
    my ($tool, $target, $result) = @_;
    my $path = approvals_path();
    my $dir  = dirname($path);
    mkdir($dir, 0700) unless -d $dir;
    $target = '' unless defined $target;
    $target =~ s/\s+/ /g;
    $target = substr($target, 0, 300);
    if (open(my $fh, '>>:encoding(UTF-8)', $path)) {
        print $fh sprintf("%s\t%s\t%s\t%s\t%s\n", _timestamp(), $MODE, $tool, $result, $target);
        close $fh;
        chmod 0600, $path;
    }
}

sub approvals_tail {
    my ($n) = @_;
    my $path = approvals_path();
    return () unless -f $path;
    open(my $fh, '<:encoding(UTF-8)', $path) or return ();
    my @lines = <$fh>;
    close $fh;
    chomp @lines;
    @lines = @lines[-$n .. -1] if @lines > $n;
    return @lines;
}

sub emit_auto_approved {
    my ($tool, $target) = @_;
    $target = '' unless defined $target;
    $target =~ s/\s+/ /g;
    $target = substr($target, 0, 160);
    emit_note(L('mode_auto_approved', $tool, $target));
}

sub danger_reason_text {
    return L('danger_no_answer')  if $CONFIRM_REASON eq 'timeout';
    return L('danger_no_channel') if $CONFIRM_REASON eq 'nochannel';
    return L('danger_declined');
}

# 可写ディレクトリの表示。$TMPDIR は環境ごとに長い内部パス（macOS だと
# /var/folders/xx/.../T）で、そのまま出すと意味が伝わらないだけだった。
sub writable_display {
    my $tmp = temp_root();
    my @out;
    for my $r (write_roots_all()) {
        if ($tmp ne '' && $r eq $tmp) {
            push @out, L('temp_dir_label');
            next;
        }
        push @out, $r;
    }
    my %seen;
    return join(' / ', grep { !$seen{$_}++ } @out);
}

sub mode_summary {
    my $w = writable_display();
    return L('mode_now', $MODE) . L('mode_now_writable', $w);
}

sub apply_mode {
    my ($m) = @_;
    return unless $MODE_VALID{$m};
    $MODE = $m;
    persist_env('CLAUDE_MODE', $MODE);
    emit_note(L('mode_switched', $MODE));
    gui_send({ t => 'mode', mode => $MODE, writable => [ write_roots_all() ] }) if $GUI;
}

sub allow_write_command {
    my ($args) = @_;
    my $a = $args;
    $a =~ s/^\s+//; $a =~ s/\s+$//;
    if ($a =~ /^clear$/i) {
        @WRITE_ROOTS = ();
        persist_env('CLAUDE_ALLOW_WRITE', "''");
        approvals_log('allow-write', '(clear)', 'ok');
        emit_note(L('allow_write_cleared'));
        emit_note(L('mode_now_writable', writable_display()));
        return;
    }
    my (@added, @bad);
    for my $raw (split(/\s+/, $a)) {
        next if $raw eq '';
        my $abs = resolve_path($raw);
        if ($abs eq '') { push @bad, $raw; next; }
        if (write_hard_denied($abs)) { push @bad, $raw; next; }
        unless (grep { $_ eq $abs } @WRITE_ROOTS) { push @WRITE_ROOTS, $abs; }
        push @added, $abs;
    }
    if (@added) {
        # 記録は必ず残す。「いつ誰が可写範囲を広げたか」は後から効いてくる。
        approvals_log('allow-write', join(' ', @added), 'ok');
        persist_env('CLAUDE_ALLOW_WRITE', "'" . join(':', @WRITE_ROOTS) . "'");
        emit_note(L('allow_write_added', join(' ', @added)));
    }
    emit_note(L('allow_write_bad', join(' ', @bad))) if @bad;
    emit_note(L('mode_now_writable', writable_display()));
}

sub print_approvals {
    my @lines = approvals_tail(10);
    unless (@lines) { emit_note(L('approvals_none')); return; }
    emit_note(L('approvals_head', approvals_path()));
    for my $l (@lines) { emit_note("  $l\n"); }
}

sub run_tool {
    my ($name, $input) = @_;

    # --tools で絞られていれば、その外はここでも止める（@TOOLS から消してある
    # ので普通は来ないが、モデルが幻覚で存在しないツール名を返すことがある）。
    if (@TOOLS_ALLOWED) {
        my %ok = map { $_ => 1 } @TOOLS_ALLOWED;
        unless ($ok{$name}) {
            return L('tool_not_allowed', join(' / ', @TOOLS_ALLOWED), $name);
        }
    }

    if ($name eq 'read_file') {
        my $path = $input->{path};
        open(my $fh, '<:encoding(UTF-8)', $path) or return L('cannot_open_read', $path, $!);
        local $/;
        my $content = <$fh>;
        close $fh;
        return $content;
    }
    elsif ($name eq 'write_file') {
        my $path = $input->{path};
        # モードごとの扱い:
        #   default      : 毎回確認
        #   accept-edits : 可写範囲内だけ自動。範囲外は確認（拒否にしない）
        #   bypass       : 可写範囲内だけ自動。範囲外は拒否（人が居ない前提）
        my $auto = 0;
        if ($MODE ne 'default') {
            if (is_hard_denied_path($path)) {
                approvals_log('write_file', $path, 'denied_always');
                emit_note(L('write_always_denied', $path));
                return L('write_always_denied', $path);
            }
            if (write_allowed($path)) {
                $auto = 1;
            }
            elsif ($MODE eq 'bypass') {
                approvals_log('write_file', $path, 'refused_scope');
                emit_note(L('write_out_of_scope', $path));
                return L('write_out_of_scope', $path);
            }
        }
        unless ($auto || confirm(L('confirm_write_file', $path))) {
            return L('write_cancelled');
        }
        if ($auto) {
            approvals_log('write_file', $path, 'auto');
            emit_auto_approved('write_file', $path);
        }
        open(my $fh, '>:encoding(UTF-8)', $path) or return L('cannot_open_write', $path, $!);
        print $fh $input->{content};
        close $fh;
        return L('write_done', $path);
    }
    elsif ($name eq 'list_dir') {
        my $path = $input->{path} || '.';
        opendir(my $dh, $path) or return L('cannot_open_read', $path, $!);
        my @entries = sort grep { $_ ne '.' && $_ ne '..' } readdir($dh);
        closedir $dh;
        return join("\n", @entries);
    }
    elsif ($name eq 'run_shell') {
        my $command = $input->{command};
        my $danger  = is_dangerous($command);
        # コマンド経由の書き込みも可写範囲の対象にする（write_file だけが
        # 対象という穴を塞ぐ）。識別できたものだけ見る保守的な実装。
        my ($vkind, $vpath) = shell_scope_violation($command);
        $vkind = '' unless defined $vkind;
        $vpath = '' unless defined $vpath;

        # 永久禁止の場所への書き込みは、bypass では確認すらせず拒否する
        # （write_file 側と同じ扱い。聞いても「許可できない」のだから）。
        if ($MODE eq 'bypass' && $danger eq '' && $vkind eq 'hard') {
            approvals_log('run_shell', $command, 'refused_cmd_write_hard');
            emit_note(L('cmd_write_always_denied', $vpath));
            return L('cmd_write_always_denied', $vpath);
        }

        # 危険なコマンドはどのモードでも確認する（bypass でも例外にしない）。
        # モードが変えるのは「普通のコマンドを聞くかどうか」だけ。
        my $scope_ask = ($vkind eq 'scope') ? 1 : 0;
        my $need_confirm = ($MODE eq 'bypass' && $danger eq '' && !$scope_ask) ? 0 : 1;
        if ($need_confirm) {
            my $prompt = $danger ne ''
                ? L('confirm_run_shell_danger', $command)
                : $scope_ask
                    ? L('confirm_cmd_write_outside', $vpath, $command)
                    : L('confirm_run_shell', $command);
            my %opt = (danger => ($danger ne '' ? 1 : 0),
                       strict => (($danger ne '' || $scope_ask) ? 1 : 0));
            unless (confirm($prompt, \%opt)) {
                if ($danger ne '') {
                    approvals_log('run_shell', $command, 'refused_danger');
                    emit_note(L('danger_refused', danger_reason_text()));
                    return L('danger_refused', danger_reason_text());
                }
                if ($scope_ask) {
                    approvals_log('run_shell', $command, 'refused_cmd_write_scope');
                    emit_note(L('cmd_write_refused', $vpath, danger_reason_text()));
                    return L('cmd_write_refused', $vpath, danger_reason_text());
                }
                return L('run_cancelled');
            }
            approvals_log('run_shell', $command, 'confirmed_danger') if $danger ne '';
            approvals_log('run_shell', $command, 'confirmed_cmd_write_scope')
                if $scope_ask && $danger eq '';
        }
        else {
            approvals_log('run_shell', $command, 'auto');
            emit_auto_approved('run_shell', $command);
        }
        my ($output) = run_shell_capture($command);
        return $output;
    }
    else {
        return L('unknown_tool', $name);
    }
}

# ------------------------------------------------------------------
# 会話ループ
# ------------------------------------------------------------------
my @messages;

# --- 履歴: ロック解除 / 一覧表示 / 再開 ---
if ($HISTORY_ENABLED) {
    $HISTORY_ENABLED = unlock_history();
}

if ($CHANGE_PASS) {
    unless ($HISTORY_ENABLED) { print L('history_unavailable'); exit 1; }
    reset_passphrase($ENV{CLAUDE_HIST_PASS});   # unlock後、CLAUDE_HIST_PASSにはマスター鍵が入っている
    exit 0;
}

if ($SET_RECOVERY) {
    unless ($HISTORY_ENABLED) { print L('history_unavailable'); exit 1; }
    set_recovery($ENV{CLAUDE_HIST_PASS});
    exit 0;
}

if ($LIST_HISTORY) {
    unless ($HISTORY_ENABLED) { print L('history_unavailable'); exit 1; }
    my @files = history_files();
    unless (@files) { print L('no_saved_conv'); exit 0; }
    my $i = 1;
    for my $f (@files) {
        my $raw = hist_decrypt("$HISTORY_DIR/$f");
        my $line = L('cannot_decrypt');
        if (defined $raw) {
            my $d = eval { MiniJSON::decode($raw) };
            $line = $d ? (($d->{started} || $f) . '  ' . first_user_line($d)) : L('corrupted');
        }
        printf "  %2d) %s\n", $i++, $line;
    }
    exit 0;
}

if ($RESUME) {
    unless ($HISTORY_ENABLED) { print L('history_unavailable'); exit 1; }
    my @files = history_files();
    unless (@files) { print L('no_resumable_conv'); exit 0; }
    my @decoded;
    my $i = 1;
    for my $f (@files) {
        my $raw = hist_decrypt("$HISTORY_DIR/$f");
        my $d = defined($raw) ? eval { MiniJSON::decode($raw) } : undef;
        push @decoded, { file => $f, data => $d };
        printf "  %2d) %s\n", $i++,
            $d ? (($d->{started} || $f) . '  ' . first_user_line($d)) : L('unreadable_file', $f);
    }
    print L('resume_number');
    my $sel = <STDIN>;
    $sel = defined($sel) ? $sel + 0 : 1;
    $sel = 1 if $sel < 1 || $sel > scalar(@decoded);
    my $chosen = $decoded[$sel - 1];
    if ($chosen->{data} && $chosen->{data}{messages}) {
        @messages = @{ $chosen->{data}{messages} };
        $SESSION_FILE = "$HISTORY_DIR/" . $chosen->{file};   # 同じファイルに続けて保存
        print L('resuming_conv', scalar(@messages));
    } else {
        print L('could_not_load_new');
    }
}

# 新規会話のときの保存先
if ($HISTORY_ENABLED && !$SESSION_FILE) {
    $SESSION_FILE = "$HISTORY_DIR/$STARTED.json.enc";
}

# --- GUI モード: JSON でやり取りするループ(Python/tkinter から駆動) ---
if ($GUI) {
    gui_send({
        t         => 'ready',
        provider  => $PROVIDER,
        model     => $MODEL,
        history   => $HISTORY_ENABLED ? 1 : 0,
        models    => [ map { { id => $_->[0], label => $_->[1],
                                provider => $_->[2] } } @MODEL_CHOICES ],
        providers => [ map { my $pv = $_; { name  => $pv,
                               label => provider_label($pv),
                               has_key       => provider_has_key($pv) ? 1 : 0,
                               key_env       => provider_info($pv, 'key_env'),
                               key_url       => provider_info($pv, 'key_url'),
                               default_model => provider_info($pv, 'default_model'),
                               models => [ map { $_->[0] }
                                           grep { defined $_->[2] && $_->[2] eq $pv } @MODEL_CHOICES ] } }
                       @PROVIDER_ORDER ],
        messages  => scalar(@messages),
        mode      => $MODE,
        writable  => [ write_roots_all() ],
        mode_list => [ @MODE_ORDER ],
    });
    while (1) {
        my $req = gui_read();
        last unless defined $req;                       # GUI が閉じた = EOF
        my $type = $req->{t} || '';
        last if $type eq 'quit';
        if ($type eq 'cwd') {
            # GUI のコマンドパネルで cd した先を、AI のツールにも反映する。
            my $p = $req->{path};
            if (defined $p && $p ne '' && -d $p) { chdir($p); dbg("cwd -> $p"); }
            next;
        }
        if ($type eq 'set_mode') {
            my $m = defined $req->{mode} ? $req->{mode} : '';
            unless ($MODE_VALID{$m}) {
                emit_note(L('mode_bad', $m, join(' / ', @MODE_ORDER)));
                gui_send({ t => 'mode', mode => $MODE, writable => [ write_roots_all() ] });
                next;
            }
            if ($m eq 'bypass' && $MODE ne 'bypass') {
                # GUI でも 1 回だけ確認する。メニューの項目は取り消せないので、
                # 押し間違いで無確認実行に入るのを防ぐ。
                unless (confirm(L('mode_bypass_warn'))) {
                    emit_note(L('mode_bypass_cancelled'));
                    gui_send({ t => 'mode', mode => $MODE, writable => [ write_roots_all() ] });
                    next;
                }
            }
            apply_mode($m);
            next;
        }
        if ($type eq 'allow_write') {
            my $dirs = defined $req->{dirs} ? $req->{dirs} : '';
            allow_write_command($dirs);
            gui_send({ t => 'mode', mode => $MODE, writable => [ write_roots_all() ] });
            next;
        }
        if ($type eq 'list_history') {
            my @items;
            if ($HISTORY_ENABLED) {
                for my $f (history_files()) {
                    my $raw = hist_decrypt("$HISTORY_DIR/$f");
                    my $d = defined($raw) ? eval { MiniJSON::decode($raw) } : undef;
                    next unless $d;
                    push @items, { file => $f, started => ($d->{started} // $f),
                                   first => first_user_line($d) };
                }
            }
            gui_send({ t => 'history_list', items => \@items });
            next;
        }
        if ($type eq 'resume') {
            my $f = $req->{file} || '';
            my $path = "$HISTORY_DIR/$f";
            my $raw = ($HISTORY_ENABLED && -f $path) ? hist_decrypt($path) : undef;
            my $d = defined($raw) ? eval { MiniJSON::decode($raw) } : undef;
            if ($d && $d->{messages}) {
                @messages = @{ $d->{messages} };
                $SESSION_FILE = $path;                     # 同じファイルに続けて保存
                gui_send({ t => 'history_loaded',
                           count   => scalar(@messages),
                           entries => flatten_history(\@messages) });
            } else {
                emit_error(L('could_not_load_conv'));
            }
            next;
        }
        next unless $type eq 'user';
        my $text = defined $req->{text} ? $req->{text} : '';
        next if $text eq '';

        my $r = eval { handle_turn($text) };
        if ($@) {
            dbg("turn error(gui): $@");
            emit_error(L('turn_failed'));
            pop @messages if @messages
                && ($messages[-1]{role} eq 'assistant' || ref $messages[-1]{content});
        }
        eval { save_history(\@messages) if $HISTORY_ENABLED };
        gui_send({ t => 'turn_done' });
        last if defined $r && $r eq 'quit';
    }
    gui_send({ t => 'bye' });
    exit 0;
}

print "=== high_sierra Advisor ===\n";
print L('mode_banner', $MODE);
if ($MODE ne 'default') {
    print L('mode_now_writable', writable_display());
    print L('mode_now_log', approvals_path());
}
print $HISTORY_ENABLED ? L('hist_will_encrypt') : L('hist_will_not_save');
if (@MODEL_CHOICES) {
    show_model_menu();
} else {
    print "[$PROVIDER / $MODEL]\n";
}
print L('greeting');

# 1ターン分の処理。'quit' を返したら会話終了、それ以外は継続。
# ここで die しても、呼び出し側の eval が受け止めてプログラムは落ちない。
sub handle_turn {
    my ($input) = @_;
    dbg("turn start: msgs=" . scalar(@messages) . " input=" . substr($input, 0, 80));

    return 'quit' if $input eq 'exit';

    # bypass へ切り替える前の「yes と打ってもらう」待ち。
    # /mode bypass 1 回で即座に切り替わると、指が滑っただけで無確認実行が
    # 始まってしまう。ここだけは 2 回入力してもらう。
    if ($PENDING_MODE ne '') {
        my $want = $PENDING_MODE;
        $PENDING_MODE = '';
        my $a = $input;
        $a =~ s/^\s+//; $a =~ s/\s+$//;
        if ($a =~ /^(yes|はい|是)$/i) { apply_mode($want); }
        else { emit_note(L('mode_bypass_cancelled')); }
        return;
    }

    # /mode・/allow-write・/approvals はモデルに渡さず、ここで完結させる。
    if ($input =~ m{^/mode\s*$}) {
        emit_note(mode_summary());
        emit_note(L('mode_now_log', approvals_path())) if $MODE ne 'default';
        return;
    }
    if ($input =~ m{^/mode\s+(\S+)\s*$}) {
        my $want = $1;
        unless ($MODE_VALID{$want}) {
            emit_note(L('mode_bad', $want, join(' / ', @MODE_ORDER)));
            return;
        }
        if ($want eq $MODE) {
            emit_note(L('mode_switched', $MODE));
            return;
        }
        if ($want eq 'bypass') {
            $PENDING_MODE = 'bypass';
            emit_note(L('mode_bypass_warn'));
            return;
        }
        apply_mode($want);
        return;
    }
    if ($input =~ m{^/allow-write\s*$}) {
        emit_note(L('mode_now_writable', writable_display()));
        emit_note(L('allow_write_usage'));
        return;
    }
    if ($input =~ m{^/allow-write\s+(.+?)\s*$}) {
        allow_write_command($1);
        return;
    }
    if ($input =~ m{^/approvals\s*$}) {
        print_approvals();
        return;
    }

    # 一覧を出す(端末のみ。GUIは起動時に一覧を受け取っている)
    if ($input eq '/model' || $input eq '/models' || $input eq '/m' || $input eq '?') {
        show_model_menu() unless $GUI;
        return;
    }

    # 二段階メニューの途中なら、番号はその段階への回答として扱う。
    # 段階は「今この瞬間だけ」有効 —— 別の入力が来たら捨てる(古い段階が
    # 残って、次の数字が勝手にモデル切り替えになる事故を防ぐ)。
    my $menu_stage = $MENU_STAGE;
    $MENU_STAGE = '';
    if ($menu_stage ne '') {
        if ($input eq '') {
            print L('menu_cancelled');
            return;
        }
        if ($input =~ /^\s*(\d+)\s*$/) {
            my $n = $1;
            if ($menu_stage eq 'vendor') {
                my $p = $MENU_VENDORS{$n};
                if (!$p) { print L('menu_bad_number'); show_model_menu(); return; }
                show_vendor_models($p);
                return;
            }
            if ($menu_stage =~ /^model:(.+)$/) {
                my $stage_p = $1;
                my $id = $MENU_MODELS{$n};
                if (!$id) { print L('menu_bad_number'); show_vendor_models($stage_p); return; }
                ($id eq $MODEL)
                    ? emit_note(L('already_on', $PROVIDER, $MODEL))
                    : switch_to_model($id);
                return;
            }
        }
        # 数字以外が来た = メニューを離れて普通の操作
    }

    # 番号だけ打ったら、その番号のAIに切り替える(人間に一番やさしい操作)
    if ($input =~ /^\s*(\d+)\s*$/ && @MODEL_CHOICES) {
        my $n = $1;
        if ($n >= 1 && $n <= @MODEL_CHOICES) {
            my $id = $MODEL_CHOICES[$n - 1][0];
            ($id eq $MODEL)
                ? emit_note(L('already_on', $PROVIDER, $MODEL))
                : switch_to_model($id);
            return;
        }
        # 範囲外の数字はふつうの発言として扱う(下へ流れる)
    }

    # /model 3 や /model <ID> でも指定できる
    if ($input =~ m{^/models?\s+(\S.*?)\s*$}) {
        my $arg = $1;
        my $id = ($arg =~ /^\d+$/ && @MODEL_CHOICES && $arg >= 1 && $arg <= @MODEL_CHOICES)
            ? $MODEL_CHOICES[$arg - 1][0] : $arg;
        ($id eq $MODEL)
            ? emit_note(L('already_on', $PROVIDER, $MODEL))
            : switch_to_model($id);
        return;
    }

    # プロバイダだけ切り替える(/claude /gemini /openai /deepseek /qwen /kimi /glm ...)
    # 知らない名前(/foo など)はここで捕まえず、下のふつうの発言として流す。
    my $cmd_target = ($input =~ m{^/([a-z][a-z0-9_]*)$}) ? provider_from_command($1) : '';
    if ($cmd_target ne '') {
        if ($cmd_target eq $PROVIDER) {
            emit_note(L('already_on', $PROVIDER, $MODEL));
        }
        elsif (switch_provider($cmd_target)) {
            persist_env('CLAUDE_PROVIDER', $PROVIDER);
            persist_env('CLAUDE_MODEL', $MODEL);
            emit_note(L('switched_to_kept', $PROVIDER, $MODEL));
            gui_send({ t => 'model', provider => $PROVIDER, model => $MODEL }) if $GUI;
        }
        return;
    }

    push @messages, { role => 'user', content => $input };

    while (1) {
        dbg("build_request: msgs=" . scalar(@messages));
        my $body = build_request(\@messages, \@TOOLS, system_prompt());
        dbg("encode+call_api");
        my $resp = eval { call_api($API_URL, build_headers(), MiniJSON::encode($body)) };
        if ($@) {
            # 通信エラーなど。素のユーザー発言のターンなら取り消して戻る
            # (ツール応答の途中なら履歴を壊さないよう残す)。
            emit_error($@);
            pop @messages if @messages && !ref $messages[-1]{content};
            return;
        }

        my @content_blocks = eval { parse_response($resp) };
        if ($@) {
            emit_error($@);
            pop @messages if @messages && !ref $messages[-1]{content};
            return;
        }

        # 空の応答(安全フィルタ・トークン上限で本文なし 等)。空の assistant
        # ターンを履歴に入れると以後ずっと壊れるので、入れずに戻る。
        # thought(考え中)のtextしか無い場合も、ユーザーには何も表示され
        # ないまま黙って終わってしまうので同様に扱う。
        my $has_visible = grep {
            ($_->{type} eq 'text' && !$_->{thought}) || $_->{type} eq 'tool_use'
        } @content_blocks;
        unless (@content_blocks && $has_visible) {
            emit_error(L('empty_response'));
            pop @messages if @messages && !ref $messages[-1]{content};
            return;
        }

        push @messages, { role => 'assistant', content => \@content_blocks };

        my @tool_results;
        for my $block (@content_blocks) {
            my $t = $block->{type} || '';
            if ($t eq 'text') {
                emit_text($block->{text}) unless $block->{thought};
            }
            elsif ($t eq 'tool_use') {
                emit_tool($block->{name}, $block->{input});
                my $result = eval { run_tool($block->{name}, $block->{input}) };
                $result = L('tool_error', $@) if $@;
                push @tool_results, {
                    type        => 'tool_result',
                    tool_use_id => $block->{id},
                    name        => $block->{name},   # Gemini は名前で結果を紐付ける
                    content     => $result,
                };
            }
        }

        if (@tool_results) {
            push @messages, { role => 'user', content => \@tool_results };
            next; # ツール結果を送ってもう一度APIを呼ぶ
        }
        return; # tool_useが無ければこのターンは終了
    }
}

# --- メインループ ---
# 1ターンごとに eval で囲み、どこで die が起きてもプログラム全体は落とさず
# 入力プロンプトに戻す。端末設定も毎回念のため戻す。
while (1) {
    dbg("--- waiting for input (readline) ---");
    my $input = eval { read_line_interactive(L('your_turn_prompt')) };
    if ($@) {
        restore_tty();
        dbg("readline error: $@");
        print L('input_error');
        next;
    }
    dbg("readline returned: " . (defined $input ? "len=" . length($input) : "undef(EOF)"));
    last unless defined $input;

    $input = eval { decode('UTF-8', $input, FB_DEFAULT) };
    $input = '' unless defined $input;
    # 空行は基本「入力ミス」なので捨てる。ただしモデル選択メニューの途中だけは
    # 「Enter で取消」として届けたいので、段階が残っているときは通す。
    next if $input eq '' && $MENU_STAGE eq '';

    my $r = eval { handle_turn($input) };
    if ($@) {
        restore_tty();
        dbg("turn error: $@");
        print "\n────────\n";
        print L('turn_failed_cli');
        print L('debug_hint_1');
        print "  CLAUDE_DEBUG_LOG=\$HOME/advisor-debug.txt advisor\n";
        print L('debug_hint_2');
        print "────────\n";
        # 半端な履歴を1つ戻して、次の発言から再開できるようにする
        pop @messages if @messages
            && ($messages[-1]{role} eq 'assistant' || ref $messages[-1]{content});
        next;
    }
    last if defined $r && $r eq 'quit';

    eval { save_history(\@messages) if $HISTORY_ENABLED };
    dbg("save_history error: $@") if $@;
}

print L('farewell');
