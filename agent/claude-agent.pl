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
        ja => "不明なプロバイダ: '%s' (anthropic か gemini)\n",
        en => "Unknown provider: '%s' (anthropic or gemini)\n",
        zh => "未知的提供商：'%s'（可选 anthropic 或 gemini）\n",
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
        ja => "\n%s が未設定です。貼り付けてEnter(空Enterでキャンセル): ",
        en => "\n%s is not set. Paste it and press Enter (empty to cancel): ",
        zh => "\n%s 尚未设置。粘贴后按回车（直接回车取消）：",
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
    model_menu_hint      => {
        ja => "番号を入力すると切り替わります。そのまま質問してもOK。\n",
        en => "Type a number to switch. Or just type your question as usual.\n",
        zh => "输入编号即可切换。也可以直接提问。\n",
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
# コマンドライン引数 (--help / --version はAPIキー無しでも動作させる)
# モデル切り替えは ~/bin/claude (シェルラッパー) 側の -m/--select-model で
# 行い、ここではCLAUDE_MODEL環境変数を読むだけにして本体は単純に保つ。
# ------------------------------------------------------------------
my $LIST_HISTORY   = 0;   # --list-history: 保存済みの会話を一覧表示して終了
my $RESUME         = 0;   # --resume: 保存済みの会話を選んで続きから再開
my $CHANGE_PASS    = 0;   # --change-passphrase: 履歴パスフレーズを変更して終了
my $SET_RECOVERY   = 0;   # --set-recovery: 合言葉(復旧用の秘密の質問)を設定して終了
my $GUI            = 0;   # --gui: 端末用の表示をやめ、1行1件のJSONで入出力する
                          #        (Python/tkinter のGUIから裏で駆動するため)

for my $arg (@ARGV) {
    if ($arg eq '--help' || $arg eq '-h') {
        print_help();
        exit 0;
    }
    if ($arg eq '--version') {
        print "advisor (high_sierra_claude) 0.1\n";
        exit 0;
    }
    if ($arg eq '--list-history')      { $LIST_HISTORY = 1; }
    if ($arg eq '--resume')            { $RESUME = 1; }
    if ($arg eq '--change-passphrase') { $CHANGE_PASS = 1; }
    if ($arg eq '--set-recovery')      { $SET_RECOVERY = 1; }
    if ($arg eq '--gui')               { $GUI = 1; }
}

sub print_help {
    print <<'EOH';
使い方: advisor [オプション]

  -h, --help            このヘルプを表示
      --version         バージョンを表示
      --list-history    保存済みの会話を一覧表示して終了
      --resume          保存済みの会話を選んで続きから再開
      --change-passphrase 履歴パスフレーズを変更して終了
      --set-recovery    合言葉(復旧用の秘密の質問)を設定して終了

環境変数:
  CLAUDE_PROVIDER    使うAI: anthropic (既定) または gemini
  ANTHROPIC_API_KEY  Anthropic APIキー (CLAUDE_PROVIDER=anthropic のとき必須)
  GEMINI_API_KEY     Gemini APIキー   (CLAUDE_PROVIDER=gemini のとき必須)
  CLAUDE_MODEL       使用するモデル (既定: claude-sonnet-5 / gemini-3.5-flash-lite)
  CLAUDE_GEMINI_THINKING  high にすると Gemini の思考を深くする (既定 low=速い)
  CLAUDE_CURL        curlコマンドのパス (既定: curl。PATH上のものを使用)
  CLAUDE_CACERT      CA証明書ファイル (既定: 未指定。システムcurlの信頼ストアを使用)
  CLAUDE_NO_HISTORY  1にすると会話を保存しない(パスフレーズも尋ねない)
  CLAUDE_OPENSSL     opensslコマンドのパス (既定: openssl)

会話中に /claude・/gemini でAIを切り替えられる(会話は引き継がれる)。
モデルの選択は `advisor --select-model` / `advisor -m <ID>` (シェルラッパー側)。
EOH
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
#   key_env        APIキーを読む環境変数名
#   auth           ヘッダの流儀: 'goog' 以外は x-api-key 系(既定)
#   model_prefix   CLAUDE_MODEL を採用してよいモデルIDの接頭辞
#   default_model  既定モデル
#   url            固定エンドポイント(url_template が無いとき使う)
#   url_template   %s にモデルIDを埋めるエンドポイント
#   api_version    anthropic-version ヘッダの値(必要なときだけ)
#   build / parse  内部形式(Anthropic content blocks)との相互変換
# ------------------------------------------------------------------
my %PROVIDERS = (
    anthropic => {
        key_env       => 'ANTHROPIC_API_KEY',
        auth          => 'x-api-key',
        model_prefix  => 'claude',
        default_model => 'claude-sonnet-5',
        url           => 'https://api.anthropic.com/v1/messages',
        api_version   => '2023-06-01',
        build         => \&build_request_anthropic,
        parse         => \&parse_response_anthropic,
    },
    gemini => {
        key_env       => 'GEMINI_API_KEY',
        auth          => 'goog',
        model_prefix  => 'gemini',
        default_model => 'gemini-3.5-flash-lite',
        url_template  => 'https://generativelanguage.googleapis.com/v1beta/models/%s:generateContent',
        build         => \&build_request_gemini,
        parse         => \&parse_response_gemini,
    },
);

# 未登録のプロバイダ名はここで弾く(各関数が個別に判定しない)。
sub provider_spec {
    my ($name) = @_;
    return $PROVIDERS{$name} || die L('unknown_provider', $name);
}

# モデルIDから担当プロバイダを引く(接頭辞が一致する最初のもの)。
# どれにも一致しなければ anthropic に倒す — 既存の受け皿を変えないため。
sub provider_for_model {
    my ($id) = @_;
    for my $name (sort keys %PROVIDERS) {
        my $pfx = $PROVIDERS{$name}{model_prefix} || next;
        return $name if $id =~ /^\Q$pfx\E/;
    }
    return 'anthropic';
}


sub configure_provider {
    my ($provider) = @_;
    my $spec = provider_spec($provider);

    my $env_key = $spec->{key_env};
    $ENV{$env_key} or die L('need_key', $env_key);
    $API_KEY = $ENV{$env_key};

    # CLAUDE_MODEL はプロバイダをまたぐと食い違うので、その provider の
    # 接頭辞で始まるときだけ採用し、そうでなければ既定モデルにする。
    my $env_model = $ENV{CLAUDE_MODEL} || '';
    my $pfx       = $spec->{model_prefix} || '';
    $MODEL = ($pfx ne '' && $env_model =~ /^\Q$pfx\E/)
        ? $env_model
        : $spec->{default_model};

    $API_URL = defined $spec->{url}
        ? $spec->{url}
        : sprintf($spec->{url_template}, $MODEL);
    $ANTHROPIC_VERSION = $spec->{api_version};

    $PROVIDER = $provider;
}

# 選べるAIの一覧 ([id, 説明], ...)。ラッパーが CLAUDE_MODELS_FILE で場所を教える。
# models.txt は id|日本語の説明|English description の3列(後方互換で2列でも可)。
my @MODEL_CHOICES;
if ($ENV{CLAUDE_MODELS_FILE} && open(my $mf, '<:encoding(UTF-8)', $ENV{CLAUDE_MODELS_FILE})) {
    while (my $l = <$mf>) {
        chomp $l;
        next unless $l =~ /\S/;
        my ($id, $desc_ja, $desc_en) = split /\|/, $l, 3;
        my $desc = ($LANGCODE eq 'en' && defined $desc_en && $desc_en ne '')
            ? $desc_en
            : ((defined $desc_ja && $desc_ja ne '') ? $desc_ja : $id);
        push @MODEL_CHOICES, [ $id, $desc ];
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
    my $key_name = $spec->{key_env};

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

# 選べるAIの一覧を番号付きで表示する
sub show_model_menu {
    unless (@MODEL_CHOICES) {
        print L('model_list_unavail');
        return;
    }
    print "\n";
    my $i = 1;
    for my $c (@MODEL_CHOICES) {
        my $mark = ($c->[0] eq $MODEL) ? L('currently_using_cli') : '';
        printf "  %d) %s%s\n", $i++, $c->[1], $mark;
    }
    print L('model_menu_hint');
}

# 指定したモデルIDに切り替える。必要ならプロバイダも一緒に切り替え、
# 次回起動に引き継ぐため ~/.claude-agent-env にも書く。
sub switch_to_model {
    my ($id) = @_;
    my $target_provider = provider_for_model($id);
    my $prev_model = $ENV{CLAUDE_MODEL};
    $ENV{CLAUDE_MODEL} = $id;

    my $ok = 1;
    if ($target_provider ne $PROVIDER) {
        $ok = switch_provider($target_provider);
    }
    else {
        eval { configure_provider($PROVIDER) };  # $MODEL と(Geminiの)$API_URL を作り直す
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
my $HISTORY_DIR     = "$ENV{HOME}/.claude-agent/history";
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

write_file and run_shell each ask the user for a y/n confirmation before
running. If a call comes back cancelled, it only means the user declined
THAT ONE action right then (often they were still typing a thought, or
want a change first) — it does NOT mean the environment blocks tools.
Never conclude that file writes or commands are disabled. Instead, stop,
say plainly what you were about to do, ask what they want to adjust, and
try again once they're ready. Do not silently retry the same write.

Before a multi-step build, tell the user in one or two lines what files
you'll create and what you'll run, so the confirmation prompts make sense.

Environment: `python3` is Python 3.10 (in the user's PATH via
~/.bash_profile; from run_shell use `python3` and it resolves). tkinter
is available. For extra libraries use `python3 -m pip install --user
<pkg>`. Prefer the standard library when it's enough.
EOS

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
    # APIキーはここで組み立て、call_api にはヘッダ文字列の配列として渡す
    # (call_api 自体はどっちのAIか知らない)。
    if (($spec->{auth} || '') eq 'goog') {
        return [ "x-goog-api-key: $API_KEY", "content-type: application/json" ];
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

sub confirm {
    my ($msg) = @_;

    # GUI モード: 確認イベントを送って、返ってくる reply を待つ。
    if ($GUI) {
        gui_send({ t => 'confirm', prompt => $msg });
        while (1) {
            my $r = gui_read();
            return 0 unless defined $r;                  # GUIが閉じた
            next unless $r->{t} && $r->{t} eq 'reply';
            return ($r->{value} && $r->{value} =~ /^(y|yes|1|true)$/i) ? 1 : 0;
        }
    }

    print "\n";
    print L('confirm_banner');
    print L('confirm_about_to');
    print "  $msg\n";
    print L('confirm_yn_hint');
    print L('confirm_not_instruct');
    print "─────────────────────\n";
    # y/n 以外(指示文を打ってしまった等)ではキャンセルせず、聞き直す。
    # 誤って打ち込んだ一言で書き込みが飛んでしまうのを防ぐ。
    while (1) {
        print "y / n : ";
        my $ans = read_line_interactive('', 0);
        return 0 unless defined $ans;                       # Ctrl-D
        my $a = $ans;
        $a =~ s/^\s+//; $a =~ s/\s+$//;
        return 1 if $a =~ /^(y|yes|はい)$/i;
        return 0 if $a =~ /^(n|no|いいえ)$/i;
        return 0 if $a eq '';                               # Ctrl-C / 空Enter → 中止
        print L('confirm_yn_only');
    }
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

sub run_tool {
    my ($name, $input) = @_;

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
        unless (confirm(L('confirm_write_file', $path))) {
            return L('write_cancelled');
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
        unless (confirm(L('confirm_run_shell', $command))) {
            return L('run_cancelled');
        }
        my $output = `$command 2>&1`;
        return $output eq '' ? L('no_output') : $output;
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
        models    => [ map { { id => $_->[0], label => $_->[1] } } @MODEL_CHOICES ],
        messages  => scalar(@messages),
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

    # 一覧を出す(端末のみ。GUIは起動時に一覧を受け取っている)
    if ($input eq '/model' || $input eq '/models' || $input eq '/m' || $input eq '?') {
        show_model_menu() unless $GUI;
        return;
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

    # プロバイダ(Claude/Gemini)だけ切り替える
    if ($input eq '/claude' || $input eq '/gemini') {
        my $target = $input eq '/claude' ? 'anthropic' : 'gemini';
        if ($target eq $PROVIDER) {
            emit_note(L('already_on', $PROVIDER, $MODEL));
        }
        elsif (switch_provider($target)) {
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
        my $body = build_request(\@messages, \@TOOLS, $SYSTEM_PROMPT);
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
    next if $input eq '';

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
