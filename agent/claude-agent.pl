#!/usr/bin/perl
# claude-agent.pl (advisor) — self-contained AI agent for old Intel Macs
# (Snow Leopard through High Sierra generation). No external CPAN modules.
# Supports both the Anthropic (Claude) and Google (Gemini) APIs.
#
# Mavericks (10.9)+ (Tier B) ships a curl that already speaks TLS 1.2, so it
# runs as-is with no extra build. On Snow Leopard through Mountain Lion
# (Tier A, 10.6-10.8), build OpenSSL/curl from source with the same steps as
# ppc_claude_cli and point CLAUDE_CURL / CLAUDE_CACERT at that location.
#
# Usage:
#   export ANTHROPIC_API_KEY=sk-ant-...      # or GEMINI_API_KEY=...
#   export CLAUDE_PROVIDER=anthropic          # or gemini
#   perl claude-agent.pl

use strict;
use warnings;
use utf8;  # 本文件里的中日文字面量按 UTF-8 解释
use Encode qw(decode FB_DEFAULT);
use File::Basename qw(dirname);
use Cwd ();

# 屏幕输出显式按 UTF-8 处理。
binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

# 命令行参数是以「字节串」传进来的。不先按 UTF-8 解释的话，
# 中文搜索词或名字会烂掉（实例：--search 报价 变成了 æ¥ä»·）。
for my $__a (@ARGV) { utf8::decode($__a) unless utf8::is_utf8($__a); }

# STDIN 故意保持生字节（不加 :encoding 层）。
# Perl 5.8.6 的 PerlIO :encoding(UTF-8) 在像真实键盘输入那样、
# 字节一点一点到达的交互式读取中，多字节字符会中途被
# 读取缓冲区切开，引发 "utf8 does not map to Unicode" 的
# 乱码错误（通过管道一次性输入时复现不出来）。
# 因此改成读完一整行、字节全部到齐之后再统一解码的方式
# （见下面的 while 循环）。

# 加上 :encoding 层会让 STDOUT 的自动 flush 失效，提示符的
# 显示可能拖到 API 响应之后才出现，所以每次都显式 flush。
$| = 1;

# 启动时先记下终端设置，无论以哪种方式退出都一定还原。
# read_line_interactive 会把终端切到 raw 模式，中途 die 的话
# 终端会坏着（看不到输入、不换行）。
# --- 两种日志 ---
# blog(): 常开的「面包屑」日志。不记录对话内容，只把动作节点和
#   结束原因写进 ~/.claude-agent/session.log（启动时清空）。
#   下次崩掉时，不用设任何环境变量也能看到最后的状况。
# dbg():  只有设了 CLAUDE_DEBUG_LOG=<path> 时才工作的详细日志。连 API 的
#   原始交互都写进去。
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
    blog(substr($line, 0, 200)) if $line !~ /^BODY:/;       # 非正文的部分也记进面包屑作为节点
    _logline($ENV{CLAUDE_DEBUG_LOG}, $line) if $ENV{CLAUDE_DEBUG_LOG};
}

# ------------------------------------------------------------------
# 界面语言（zh/en/ja）。七成下载来自海外用户，所以成了必需项。
# 和 GUI 侧（advisor_gui.py）一样，直接看 macOS 的系统语言设置
# （LANG 环境变量在 GUI 应用启动时可能是空的，靠不住）。
# 判断不出来时，沿用既有做法默认用中文（见 $LANGCODE 的初值）。
# ------------------------------------------------------------------
# 版本号只出自仓库根目录的 VERSION 文件（要和 tag 一致）。
# 分发出来的应用会一起带上 VERSION，所以也看脚本所在目录。
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

my $LANGCODE = 'zh';   # 默认中文（权重：以中文为主、英文为辅）
if (defined $ENV{CLAUDE_LANG} && $ENV{CLAUDE_LANG} =~ /^(en|ja|zh)/i) {
    # CLAUDE_LANG=en/ja/zh 最优先（用于不想改系统语言、
    # 只想确认显示语言的时候）。zh-Hans / zh_CN 这类写法也按 zh 处理。
    $LANGCODE = lc(substr($1, 0, 2));
}
else {
    my $out = `defaults read -g AppleLocale 2>/dev/null`;
    $out = '' unless defined $out;
    if ($out =~ /^ja/i) {
        $LANGCODE = 'ja';
    }
    elsif ($out =~ /^zh/i) {
        # zh-Hans / zh-Hant / zh_CN / zh_TW 等一律归为中文。
        # 繁体用户会看到简体字，但先保证「中文能读」。
        $LANGCODE = 'zh';
    }
    elsif ($out ne '') {
        $LANGCODE = 'en';
    }
    # 判断不了的环境（非 macOS 等）保持默认的中文。
}

# 显示语言候选列表（按优先级）。%S 里没有的语言按这个顺序往下退。
#   例：zh 没译 → en → ja。不会返回空串。
my @LANG_FALLBACK = (
    $LANGCODE,
    ($LANGCODE eq 'zh' ? ('en', 'ja') : ()),
    ($LANGCODE eq 'en' ? ('ja') : ()),
);
if ($LANGCODE ne 'ja' && $LANGCODE ne 'en' && $LANGCODE ne 'zh') {
    @LANG_FALLBACK = ('ja', 'en');
}

# key => 文案。有两种写法：
#   [ja, en]                     … 旧格式（中文回退到 en）
#   { ja => .., en => .., zh => .. } … 加了中文的格式
# %s 占位符由 sprintf 填充（L(key, arg1, arg2...)）。
# 参数顺序和个数在所有语言里必须一致（错位显示就坏了）。
# 长期记忆注入上限（字符）。超过就截断并在注入里说明 —— 别把 token 白烧掉。
my $MEMORY_MAX_CHARS = 2000;

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
    api_retrying         => {
        ja => "（接続できませんでした。%d 回目を %d 秒後に再試行します）\n",
        en => "(could not connect; retry %d in %ds)\n",
        zh => "（连不上，%d 秒后重试第 %d 次…）\n",
    },
    cannot_connect_api   => {
        ja => "サーバーに接続できません（%s · %s、%d 回試行）。確認すること: ① キーが有効か ② この端末から %s に到達できるか ③ プロキシが必要か\n",
        en => "Cannot reach the model service (%s · %s, tried %d times). Check: 1) is the key valid 2) can this machine reach %s 3) is a proxy needed\n",
        zh => "连不上模型服务（%s · %s，试了 %d 次）。按这个顺序查：① 密钥还有效吗 ② 这台机器能不能访问 %s ③ 是否需要代理\n",
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
    # ---- 面向终端（仅 CLI，无 --gui） ----
    interrupted          => {
        ja => "\n中断しました。\n",
        en => "\nInterrupted.\n",
        zh => "\n已中断。\n",
    },
    # 密钥只在安装时输入一次（setup.sh）。会话里既不索要、也不接收，
    # 只把"缺什么、去哪里配"说清楚 —— 在对话中途打断要密钥是这个项目
    # 真实出过事故的地方（看起来像 key 失效）。
    # 密钥的配置只有两条路：安装时（setup.sh），或会话中的专门命令 /key。
    # 切换模型的流程里**不夹带**密钥输入 —— 那会让人分不清"我要换模型"和"我的 key 坏了"。
    key_config_needed    => {
        ja => "\n%s のキーがまだ未設定です（%s）。\n"
            . "キーの設定は専用コマンドで行います: /key %s\n"
            . "（セッションを抜けて setup.sh か %s で設定してもかまいません）\n",
        en => "\n%s has no key yet (%s).\n"
            . "Keys are set with the dedicated command: /key %s\n"
            . "(or exit and set it via setup.sh / %s)\n",
        zh => "\n%s 还没有配置密钥（%s）。\n"
            . "密钥用专门的命令配置：/key %s\n"
            . "（也可以退出会话后用 setup.sh 或编辑 %s 配置）\n",
    },
    key_cmd_head         => {
        ja => "\nキー設定の専用コマンド: /key <ベンダー名>\n",
        en => "\nDedicated key command: /key <vendor>\n",
        zh => "\n密钥配置的专门命令：/key <厂商>\n",
    },
    key_cmd_have         => {
        ja => "設定済み",
        en => "configured",
        zh => "已配置",
    },
    key_cmd_missing      => {
        ja => "未設定",
        en => "not set",
        zh => "未配置",
    },
    key_cmd_usage        => {
        ja => "使い方: /key deepseek （または /key 4 のように番号でも可）\n",
        en => "Usage: /key deepseek (a menu number like /key 4 also works)\n",
        zh => "用法：/key deepseek（也可以 /key 4 这样用编号）\n",
    },
    key_cmd_unknown      => {
        ja => "不明なベンダー: %s\n",
        en => "Unknown vendor: %s\n",
        zh => "不认识的厂商：%s\n",
    },
    key_cmd_where        => {
        ja => "\n%s の API キーを入力してください。未取得なら: %s\n",
        en => "\nEnter the API key for %s. Get one here: %s\n",
        zh => "\n请输入 %s 的 API 密钥。还没有的话：%s\n",
    },
    key_cmd_prompt       => {
        ja => "貼り付けて Enter（画面には表示されません。空 Enter でキャンセル）: ",
        en => "Paste and press Enter (not echoed; empty Enter cancels): ",
        zh => "粘贴后按回车（不会显示在屏幕上；直接回车取消）：",
    },
    key_cmd_empty        => {
        ja => "キャンセルしました。\n",
        en => "Cancelled.\n",
        zh => "已取消。\n",
    },
    key_cmd_save_prompt  => {
        ja => "\n%s に保存しますか？ [y/N]: ",
        en => "\nSave it to %s? [y/N]: ",
        zh => "\n要保存到 %s 吗？[y/N]：",
    },
    key_cmd_saved        => {
        ja => "保存しました: %s（次回起動時も有効）\n",
        en => "Saved: %s (also used on next start)\n",
        zh => "已保存：%s（下次启动仍然有效）\n",
    },
    key_cmd_not_saved    => {
        ja => "保存していません（このセッション内だけ有効）。\n",
        en => "Not saved (only valid for this session).\n",
        zh => "未保存（只在本次会话内有效）。\n",
    },
    # 受限会话（远程/嵌入式）：只对话，不改配置。
    config_locked        => {
        ja => "\nこの会话では設定を変更できません（ベンダー・モデル・モード・書き込み範囲・キー）。\n"
            . "設定は advisor を動かしている端末側で行ってください。会話はそのまま続けられます。\n",
        en => "\nSettings cannot be changed from this session "
            . "(vendor / model / mode / writable roots / keys).\n"
            . "Configure them on the machine running advisor. Chat itself keeps working.\n",
        zh => "\n本次会话不能修改配置（厂商、模型、模式、可写范围、密钥）。\n"
            . "这些请在本机配置；对话本身照常可用。\n",
    },
    key_cmd_gui          => {
        ja => "GUI では開始画面（または設定）でキーを設定してください。ファイルを直接編集するなら %s\n",
        en => "In the GUI, set the key on the start screen (or Settings). Or edit %s directly.\n",
        zh => "GUI 里请在首启页（或设置）配置密钥；也可以直接编辑 %s\n",
    },
    key_invalid          => {
        ja => "\n%s のキーが拒否されました（HTTP %s）。\n"
            . "一度 exit で抜けて、%s を確認・設定してから起動し直してください。\n",
        en => "\nThe %s key was rejected (HTTP %s).\n"
            . "Exit once, check/set %s, then start again.\n",
        zh => "\n%s 的密钥被拒绝（HTTP %s）。\n"
            . "请先 exit 退出，检查或重新配置 %s 后再启动。\n",
    },
    # 列表里先标明「还没有密钥」。选完才发现的状态，
    # 和「按了没反应的按钮」一样，在用户看来就是故障。
    menu_no_key          => {
        ja => "  [キー未設定]",
        en => "  [no key yet]",
        zh => "  [未配置密钥]",
    },
    menu_vendor_no_key   => {
        ja => "  ※ %s はまだキー未設定です（%s）。設定するには /key %s\n",
        en => "  Note: %s has no key yet (%s). Set it with /key %s\n",
        zh => "  注：%s 还没有配置密钥（%s）。要配置请用 /key %s\n",
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
    model_switch_hint    => {
        ja => "（別のAIに切り替えるには /model と入力）\n",
        en => "(To switch AI, type /model)\n",
        zh => "（要换别的 AI 请输入 /model）\n",
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
    confirm_fs_op        => {
        ja => "ディレクトリ／ファイル操作（%s）です。実行しますか？ [y/N] ",
        en => "This is a file/directory operation (%s). Run it? [y/N] ",
        zh => "这是文件/目录操作（%s）。要执行吗？[y/N] ",
    },
    fs_op_refused        => {
        ja => "ディレクトリ／ファイル操作（%s）は承認されなかったため実行しません（%s）。",
        en => "The file/directory operation (%s) was not approved, so it was not run (%s).",
        zh => "文件/目录操作（%s）没被批准，没有执行（%s）。",
    },
    mode_bypass_warn     => {
        ja => "\nbypass モードにすると、書き込みもコマンド実行も確認なしで走ります。\n確認するのは「危険なコマンド」と「ディレクトリ／ファイル操作（rm・mv・cp 等）」だけです。\n書き込み可能な範囲の制限はこのモードでは効きません（あれは edit 用）。\n応答が無い場合は自動的に拒否します。\n切り替えるには yes と入力してください（やめるなら Enter）: ",
        en => "\nIn bypass mode, writes and commands run without asking. Only two things\nstill ask: dangerous commands, and file/directory operations (rm, mv, cp …).\nThe writable-roots whitelist does not apply in this mode (it is for edit mode).\nAn unanswered prompt is treated as refused. Type yes to switch (Enter cancels): ",
        zh => "\n切到 bypass 模式后，写文件和执行命令都不再询问。\n仍然会问的只有两类：危险命令，以及文件/目录操作（rm、mv、cp 等）。\n可写范围白名单在这个模式下不生效（那是 edit 模式用的）；\n没人应答时按拒绝处理。请输入 yes 切换（直接回车取消）：",
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
    turn_no_text         => {
        ja => "（この回は道具を %d 回使いましたが、まとめの文章が出ませんでした）\n",
        en => "(this turn ran %d tool call(s) but produced no summary text)\n",
        zh => "（这一轮跑了 %d 次工具调用，但没有产生总结文字）\n",
    },
    confirm_void_note    => {
        ja => "（前の確認への遅れた返事 %d 件を無視しました）\n",
        en => "(ignored %d late replies that belonged to an earlier confirmation)\n",
        zh => "（有 %d 条答复属于上一道确认，已忽略）\n",
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
    # ---- 长期记忆 / 技能（中文 + 英文；按项目语言政策不再新增日文，
    #      ja 缺 key 时由 LANG_FALLBACK 落到 en） ----
    memory_usage         => {
        en => "Usage: /remember <fact>   save one durable fact\n"
            . "       /memory            show what is remembered\n"
            . "       /memory rm <n>     delete line n\n"
            . "       /memory clear      delete everything\n",
        zh => "用法：/remember <事实>  记下一条长期有效的事实\n"
            . "      /memory          查看已记住的内容\n"
            . "      /memory rm <n>   删除第 n 行\n"
            . "      /memory clear    全部清空\n",
    },
    memory_empty         => {
        en => "Long-term memory is empty (%s).\n",
        zh => "长期记忆还是空的（%s）。\n",
    },
    memory_head          => {
        en => "Long-term memory: %s（%d lines, %d characters）\n",
        zh => "长期记忆：%s（%d 行，%d 字符）\n",
    },
    memory_cut           => {
        en => "(the file is longer than the %d characters that get sent; only the first %d are shown)\n",
        zh => "（文件超过注入上限 %d 字符，只送了前 %d 字符）\n",
    },
    memory_saved         => {
        en => "Remembered: %s\n",
        zh => "已记住：%s\n",
    },
    memory_full          => {
        en => "Long-term memory is full (%d characters). Trim %s and try again.\n",
        zh => "长期记忆已到上限（%d 字符）。请编辑 %s 删掉一些再试。\n",
    },
    memory_add_empty     => {
        en => "Nothing to remember (the fact was empty).\n",
        zh => "内容是空的，没有记下任何东西。\n",
    },
    memory_cannot_write  => {
        en => "Could not write long-term memory: %s (%s)\n",
        zh => "写不进长期记忆文件：%s（%s）\n",
    },
    memory_rm_usage      => {
        en => "Usage: /memory rm <line number>  (numbering comes from /memory)\n",
        zh => "用法：/memory rm <行号>（行号见 /memory）\n",
    },
    memory_rm_bad        => {
        en => "Long-term memory has no line %s.\n",
        zh => "长期记忆里没有第 %s 行。\n",
    },
    memory_rm_done       => {
        en => "Deleted line %s: %s\n",
        zh => "已删除第 %s 行：%s\n",
    },
    memory_cleared       => {
        en => "Long-term memory cleared.\n",
        zh => "长期记忆已清空。\n",
    },
    memory_clear_kept    => {
        en => "Left long-term memory as it was.\n",
        zh => "保留原样，没有清空。\n",
    },
    memory_clear_confirm => {
        en => "Delete ALL long-term memory?",
        zh => "确认清空全部长期记忆？",
    },
    confirm_remember     => {
        en => "The model wants to remember this about you:\n  %s\nSave it to long-term memory?",
        zh => "模型想记住关于你的一件事：\n  %s\n写进长期记忆？",
    },
    memory_save_cancelled => {
        en => "Not saved to long-term memory.\n",
        zh => "没有写进长期记忆。\n",
    },
    skills_head          => {
        en => "Skills in %s (%d):\n",
        zh => "技能目录 %s（共 %d 个）：\n",
    },
    name_usage           => {
        ja => "使い方: /name <名前>（現在の名前: %s）\n",
        en => "Usage: /name <name>  (current: %s)\n",
        zh => "用法：/name <名字>（现在的名字：%s）\n",
    },
    name_current_none    => {
        ja => "なし",
        en => "none",
        zh => "没有",
    },
    name_set             => {
        ja => "この会話の名前を「%s」にしました（--continue %s で続けられます）。\n",
        en => "Named this conversation \"%s\". Resume it with --continue %s.\n",
        zh => "这场对话的名字改成了「%s」（以后用 --continue %s 接着它）。\n",
    },
    search_usage         => {
        ja => "使い方: /search <語>（保存済みの会話を全文検索）\n",
        en => "Usage: /search <word>  (full-text search over saved conversations)\n",
        zh => "用法：/search <词>（在已保存的对话里全文搜索）\n",
    },
    history_hint_continue => {
        ja => "（続けるときは --continue、または --continue <名前>）\n",
        en => "(To pick up a conversation: --continue, or --continue <name>)\n",
        zh => "（要接着哪一场：--continue，或 --continue <名字>）\n",
    },
    continue_loaded      => {
        ja => "直前の会話（%s%d 件）を続けます。\n",
        en => "Continuing the previous conversation (%s%d messages).\n",
        zh => "接着上一场对话（%s%d 条消息）继续。\n",
    },
    continue_none        => {
        ja => "続けられる会話がないので、新しい会話として始めます%s。\n",
        en => "Nothing to continue, so this starts a new conversation%s.\n",
        zh => "没有可以接着的对话，这次当作新会话开始%s。\n",
    },
    search_header        => {
        ja => "「%s」で保存済みの会話を検索します:\n",
        en => "Searching saved conversations for \"%s\":\n",
        zh => "在已保存的对话里搜索「%s」：\n",
    },
    search_none          => {
        ja => "「%s」に一致する会話はありませんでした。\n",
        en => "No saved conversation matched \"%s\".\n",
        zh => "没有匹配「%s」的对话。\n",
    },
    search_skipped       => {
        ja => "（%d 件は復号できず読み飛ばしました。--encrypt-history で合言葉を入力すると読めます）\n",
        en => "(%d file(s) were skipped because they could not be decrypted; start with --encrypt-history and enter the passphrase.)\n",
        zh => "（有 %d 个文件解不开所以跳过了；用 --encrypt-history 启动并输入口令就能读）\n",
    },
    search_needs_word    => {
        ja => "--search には検索語が必要です（例: --search 見積）\n",
        en => "--search needs a word (e.g. --search invoice)\n",
        zh => "--search 需要一个词（例如 --search 报价）\n",
    },
    hist_skip_enc        => {
        en => "(%d encrypted conversation(s) could not be read: no key.enc here. Start with --encrypt-history and enter the passphrase to open them.)\n",
        zh => "（有 %d 个加密会话读不了：这个目录里没有 key.enc。要用口令打开它们，用 --encrypt-history 启动并输入口令。）\n",
    },
    plain_hist_nothing => {
        ja => "平文で保存する履歴しかありません（切り替える必要はありません）。\n",
        en => "History is already plain: nothing to convert.\n",
        zh => "历史已经是明文了，不需要转换。\n"},
    plain_hist_no_key => {
        ja => "復号できない %.0f 個の暗号化履歴があります（key.enc がありません）。\n",
        en => "There are %.0f encrypted conversations that cannot be opened: no key.enc here.\n",
        zh => "有 %.0f 个加密会话打不开：这个目录里没有 key.enc。\n"},
    plain_hist_pass_prompt => {
        ja => "現在のパスフレーズ: ", en => "Current passphrase: ",
        zh => "当前口令："},
    plain_hist_cancelled => {
        ja => "中止しました（何も変更していません）。\n",
        en => "Cancelled; nothing was changed.\n",
        zh => "已取消，什么都没有改动。\n"},
    plain_hist_bad_pass => {
        ja => "パスフレーズが違います（何も変更していません）。\n",
        en => "Wrong passphrase; nothing was changed.\n",
        zh => "口令不对，什么都没有改动。\n"},
    plain_hist_backup_failed => {
        ja => "バックアップを作れませんでした（%s）。中止します。\n",
        en => "Could not create a backup (%s). Aborted.\n",
        zh => "备份没能创建（%s），已中止。\n"},
    plain_hist_decrypt_failed => {
        ja => "%d 個の履歴を復号できませんでした（例: %s）。\n何も消していません。\n",
        en => "%d conversation(s) could not be decrypted (e.g. %s).\nNothing was deleted.\n",
        zh => "有 %d 个会话解不开（例如 %s），什么都没有删除。\n"},
    plain_hist_backup_kept => {
        ja => "バックアップは残してあります: %s\n",
        en => "The backup is kept at: %s\n",
        zh => "备份保留在：%s\n"},
    plain_hist_done => {
        ja => "%d 件を平文に変換しました（%s）。\nバックアップ: %s\n"
              . "次回からパスフレーズは訊きません。\n",
        en => "Converted %d conversation(s) in %s.\nBackup: %s\n"
              . "You will not be asked for a passphrase again.\n",
        zh => "已把 %d 个会话转成明文（%s）。\n备份：%s\n以后启动不再询问口令。\n"},
    confirm_write_skill  => {
        ja => "技能「%s」を書き込みます（%s）。\n次回からこの技能が一覧に出ます。よろしいですか？",
        en => "Write the skill \"%s\" to %s?\nIt will show up in the skill list from the next session.",
        zh => "要写入技能「%s」吗（%s）？\n下次启动起，它会出现在技能列表里。"},
    confirm_write_skill_over => {
        ja => "技能「%s」は既にあります（%s）。\n上書きしますか？",
        en => "The skill \"%s\" already exists (%s).\nOverwrite it?",
        zh => "技能「%s」已经存在（%s），要覆盖吗？"},
    skill_write_cancelled => {
        ja => "技能の書き込みを取りやめました（何も変更していません）。\n",
        en => "Skill not written; nothing was changed.\n",
        zh => "已取消写入技能，什么都没有改动。\n"},
    skill_name_bad => {
        ja => "技能名が不正です（1〜32 文字、/ と .. と制御文字は不可、先頭は . 以外）。\n",
        en => "Bad skill name: 1-32 chars, no slashes, no '..', no control chars, must not start with '.'.\n",
        zh => "技能名不合法（1~32 字，不能含 / 与 .. 与控制字符，不能以 . 开头）。\n"},
    skill_desc_bad => {
        ja => "説明が不正です（1〜80 文字）。\n",
        en => "Bad description: 1-80 chars.\n",
        zh => "描述不合法（1~80 字）。\n"},
    skill_body_bad => {
        ja => "本文が空です。\n", en => "Body is empty.\n", zh => "正文是空的。\n"},
    skill_body_too_big => {
        ja => "本文が大きすぎます（上限 %d バイト）。\n",
        en => "Body too large (limit %d bytes).\n",
        zh => "正文太大（上限 %d 字节）。\n"},
    skill_cannot_write => {
        ja => "技能を書き込めません（%s: %s）。\n",
        en => "Cannot write the skill (%s: %s).\n",
        zh => "技能写不进去（%s：%s）。\n"},
    skill_saved => {
        ja => "技能を保存しました: %s\n（次の起動から一覧に出ます）\n",
        en => "Skill saved: %s\n(It appears in the skill list from the next start.)\n",
        zh => "技能已保存：%s\n（下次启动起会出现在列表里）\n"},
    hist_plain_mode      => {
        en => "History is saved as plain text (mode 0600) in %s. Use --encrypt-history if you want it protected by a passphrase.\n",
        zh => "历史以明文保存在 %s（权限 0600）。想要口令加密，用 --encrypt-history 启动。\n",
    },
    hist_plain_no_pass   => {
        en => "This session saves history as plain text, so there is no passphrase to change.\nStart with --encrypt-history to switch to an encrypted history.\n",
        zh => "本次的历史是明文保存的，没有口令可改。\n想要加密，用 --encrypt-history 启动。\n",
    },
    hist_plain_no_recovery => {
        en => "This session saves history as plain text, so there is no recovery question.\nStart with --encrypt-history to use one.\n",
        zh => "本次的历史是明文保存的，没有密保问题。\n想要的话，用 --encrypt-history 启动。\n",
    },
    hist_encrypted_on    => {
        en => "History is encrypted with your passphrase.\n",
        zh => "历史已用口令加密。\n",
    },
    skills_none          => {
        en => "No skills yet. Drop one into %s（a directory containing SKILL.md, or a single .md file）。\n",
        zh => "还没有技能。放一个到 %s 即可（一个包含 SKILL.md 的目录，或单个 .md 文件）。\n",
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
        # 旧的 [ja, en]。中文还没译，就先退到英文（日/英行为不变）。
        $s = ($LANGCODE eq 'ja') ? $pair->[0] : $pair->[1];
    }
    $s = $pair->[0] unless defined $s && $s ne '';
    return @args ? sprintf($s, @args) : $s;
}

# perl 的警告（Deep recursion / Out of memory / uninitialized 等）也
# 留着。有时能提前看到死循环或内存耗尽的征兆。
$SIG{__WARN__} = sub { my $w = shift; blog("WARN: $w"); dbg("WARN: $w"); warn $w; };

blog("=== advisor start (pid $$) ===");

# 启动时先记下终端设置，无论以哪种方式退出都一定还原。
# read_line_interactive 会把终端切到 raw 模式，中途 die 的话
# 终端会坏着（看不到输入、不换行）。
our $ORIG_STTY = `stty -g 2>/dev/null`;
chomp $ORIG_STTY;
sub restore_tty { system('stty', $ORIG_STTY) if $ORIG_STTY ne ''; }
END { blog("END reached (exit=$?)"); restore_tty(); }
$SIG{INT}  = sub { blog("SIGINT");  restore_tty(); print L('interrupted'); exit 130; };
$SIG{TERM} = sub { blog("SIGTERM"); restore_tty(); exit 143; };
$SIG{HUP}  = sub { blog("SIGHUP (terminal closed?)"); restore_tty(); exit 129; };
$SIG{__DIE__} = sub { blog("DIE" . ($^S ? "(in eval)" : "(FATAL)") . ": " . substr($_[0],0,300)); return; };

# ------------------------------------------------------------------
# providers.txt — 密钥环境变量名、默认模型、取密钥 URL、显示名的唯一来源。
# 写在这里，GUI 的首次引导画面和菜单就会自动跟上。不要在代码里
# 重复维护 URL 或变量名。
# ------------------------------------------------------------------
my %PROVIDER_INFO;   # provider => { key_env, default_model, key_url, ja, en, zh }
my @PROVIDER_ORDER;  # providers.txt 里的顺序（菜单顺序用它）
{
    my @cand;
    push @cand, $ENV{CLAUDE_PROVIDERS_FILE} if $ENV{CLAUDE_PROVIDERS_FILE};
    my $here = dirname(Cwd::abs_path($0) // $0);
    push @cand, "$here/providers.txt", "$here/../providers.txt";
    my $path;
    for my $c (@cand) { if (defined $c && -f $c) { $path = $c; last } }
    if (!$path) {
        die "找不到 providers.txt。需要仓库自带的那个文件。\n";
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

# 取出 providers.txt 的一项。没有就立刻死（不带半吊子的默认值硬跑）。
sub provider_info {
    my ($name, $field) = @_;
    my $info = $PROVIDER_INFO{$name};
    die "providers.txt 里没有 '$name' 这一行。\n" unless $info;
    return $info->{$field};
}

# 按语言代码取显示名
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
    my $k = ($LANGCODE eq 'ja' || $LANGCODE eq 'zh' || $LANGCODE eq 'en') ? $LANGCODE : 'zh';
    my $v = $info->{$k};
    return (defined $v && $v ne '') ? $v : $name;
}

# ------------------------------------------------------------------
# 命令行参数（--help / --version 即使没有 API 密钥也要能用）
# 模型切换交给 ~/bin/claude（shell 包装脚本）侧的 -m/--select-model，
# 这里只读 CLAUDE_MODEL 环境变量，让本体保持简单。
# ------------------------------------------------------------------
# 历史记录的保存格式（v0.2.5 里把默认反过来了）：
#   --encrypt-history / CLAUDE_ENCRYPT_HISTORY=1 → 用口令加密
#   默认 → 明文保存（0600，目录 0700），不问口令
# 但如果已经存在加密历史（key.enc 或旧的 .check），不会擅自
# 掉回明文，而是照旧走解锁流程（见下面的 unlock_history）。
my $ENCRYPT_HISTORY = (defined $ENV{CLAUDE_ENCRYPT_HISTORY}
                       && $ENV{CLAUDE_ENCRYPT_HISTORY} ne '' && $ENV{CLAUDE_ENCRYPT_HISTORY} ne '0') ? 1 : 0;
my $HIST_PLAIN      = 0;   # 本场对话用明文保存（由 unlock_history 决定）

my $LIST_HISTORY   = 0;   # --list-history: 列出已保存的对话并退出
my $CONTINUE       = 0;   # --continue: 直接接着上一场对话（不显示选择菜单）
my $CONTINUE_NAME  = '';  # --continue <名字>: 按名字选一场接着继续
my $SESSION_NAME   = '';  # --name <名字>: 给这场对话起名字
my $SEARCH         = '';  # --search <词>: 在已保存的对话里全文搜索并退出
my $RESUME         = 0;   # --resume: 选一场已保存的对话接着继续
my $CHANGE_PASS    = 0;   # --change-passphrase: 修改历史口令后退出
my $SET_RECOVERY   = 0;   # --set-recovery: 设置密保问题（找回口令用）后退出
my $MAKE_PLAIN     = 0;   # --make-plain-history: 把已有的加密历史转成明文后退出
my $GUI            = 0;   # --gui: 不做终端显示，改成一行一条 JSON 的输入输出
# --tools=a,b : 收窄可用的工具（只能减，不能加）
# 远程使用时在这里传 read_file,list_dir —— 不过那个判断是
# 调用方根据自身情况做的。本体只知道「工具可以被收窄」这些。
my $TOOLS_ALLOW    = '';
my $NO_CONFIG = 0;   # --no-config: 拒绝会话内的配置修改（厂商/模型/模式/可写/密钥）
my @TOOLS_ALLOWED;   # 空 = 不限制

# ------------------------------------------------------------------
# 交互模式（--mode=default|accept-edits|bypass）
#
# 只切换「要不要弹确认」。能力（工具）归 --tools 管，
# 这两者互相正交 —— 模式不会变出新能力。
#
#   default      : write_file / run_shell 每次都确认（和以前一样）
#   accept-edits : 只有可写范围内的 write_file 自动放行，run_shell 仍每次确认
#   bypass       : 常规操作自动放行，只有危险命令才确认
#
# 危险命令的确认以「没有应答就拒绝」收尾（fail-closed）。
# 没人守的时候一直等既不更安全，只会把会话卡死。
# ------------------------------------------------------------------
my @MODE_ORDER = ('default', 'accept-edits', 'bypass');
my %MODE_VALID = map { $_ => 1 } @MODE_ORDER;
my $MODE = 'default';
my $MODE_ARG = '';
my @WRITE_ROOTS_RAW;      # --allow-write / CLAUDE_ALLOW_WRITE 的原始值
my @WRITE_ROOTS;          # 解析后的追加可写目录
my @WRITE_ROOTS_DENY;     # 明确加进来也不许写的位置
my $CONFIRM_REASON = '';  # 上一次 confirm() 拒绝的理由
my $CONFIRM_SEQ = 0;      # 每次确认一个 id（cid），迟到的答复一律不认
my $TURN_TEXTS = 0;       # 这一轮发出去多少条 text（网关只把 text/error 当回复）
my $TURN_TOOLS = 0;       # 这一轮跑了多少次工具
my $PENDING_MODE = '';    # /mode bypass 的「等 yes」状态
                          #        （由 Python/tkinter 的 GUI 在后台驱动）

# --tools 同时接受「--tools=a,b」和「--tools a,b」两种写法。
# 取值参数如果放在 for 循环里处理，值那一侧会被当成「未知参数」
# 默默丢掉 —— 实际就因为这样让能力限制整个失效（一行警告都没有）。
# 先做归一化。
for my $i (0 .. $#ARGV) {
    if ($ARGV[$i] eq '--tools' && defined $ARGV[$i + 1]) {
        $ARGV[$i] = "--tools=$ARGV[$i + 1]";
        splice(@ARGV, $i + 1, 1);
    }
}

# --mode / --allow-write 也接受「--mode x」的写法。值那一侧被当成
# 「未知参数」默默丢掉的话，以为设上了其实没生效（--tools 真出过这事）。
for my $i (0 .. $#ARGV) {
    for my $opt ('--mode', '--allow-write', '--continue', '--name', '--search') {
        next if $i > $#ARGV || !defined $ARGV[$i];
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
    if ($arg eq '--continue' || $arg eq '-c') { $CONTINUE = 1; }
    if ($arg =~ /^--continue=(.*)$/)   { $CONTINUE = 1; $CONTINUE_NAME = $1; }
    if ($arg =~ /^--name=(.*)$/)       { $SESSION_NAME = $1; }
    if ($arg eq '--search' || $arg eq '--search=') {
        print STDERR L('search_needs_word');
        exit 2;
    }
    if ($arg =~ /^--search=(.*)$/)     { $SEARCH = $1; }
    if ($arg eq '--resume')            { $RESUME = 1; }
    if ($arg eq '--change-passphrase') { $CHANGE_PASS = 1; }
    # 把已有的加密历史切成明文（单向操作，所以只在显式调用时做）。
    if ($arg eq '--make-plain-history') { $MAKE_PLAIN = 1; }
    if ($arg eq '--set-recovery')      { $SET_RECOVERY = 1; }
    if ($arg eq '--gui')               { $GUI = 1; }
    # --rpc 和 --gui 是完全相同的协议，只是按用途分了名字
    # （GUI 对面是界面，rpc 对面是程序）。
    if ($arg eq '--rpc')               { $GUI = 1; }
    if ($arg =~ /^--tools=(.*)$/)      { $TOOLS_ALLOW = $1; }
    # --no-config: 一律不接受修改配置的命令（收窄能力）。
    # 面向中转/嵌入场景，同时把密钥输入入口也堵上。
    if ($arg eq '--no-config')         { $NO_CONFIG = 1; }
    if ($arg eq '--encrypt-history')   { $ENCRYPT_HISTORY = 1; }
    if ($arg =~ /^--mode=(.*)$/)       { $MODE_ARG = $1; }
    if ($arg =~ /^--allow-write=(.*)$/) { push @WRITE_ROOTS_RAW, $1; }
}

# --- 确定模式与可写范围（参数 > 环境变量 > 默认） ------------------
{
    my $raw = $MODE_ARG;
    $raw = $ENV{CLAUDE_MODE} if $raw eq '' && defined $ENV{CLAUDE_MODE};
    $raw = '' unless defined $raw;
    $raw =~ s/^\s+//; $raw =~ s/\s+$//;
    $raw = 'default' if $raw eq '';
    unless ($MODE_VALID{$raw}) {
        # 不默默退回默认值。退了就会「本以为在 bypass，其实在 default」
        # （看着更安全，实际是无视用户意图偷偷改写）。
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

# --help 里那张「哪个环境变量放什么」的表。由 providers.txt 生成
# （不要在这里补厂商名或变量名）。
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
    # 中文分支。不支持的语言照旧落到日语（即下面的正文）。
    if ($LANGCODE eq 'zh') {
        my $h = <<'EOH';
用法: advisor [选项]

  -h, --help            显示本帮助
      --version         显示版本
      --list-history    列出已保存的对话并退出
      --continue, -c    接着最近一场对话继续（也可 --continue 名字）
      --name <名字>     给这场对话起名字，之后可用 --continue 名字 接着
      --search <词>     在已保存的对话里全文搜索并退出
      --resume          选择已保存的对话继续
      --change-passphrase 修改历史记录口令并退出
      --set-recovery    设置密保问题（找回口令用）并退出
      --encrypt-history 用口令加密保存历史（默认是明文保存，不询问口令）
      --tools=<a,b>     只用列出的工具（能力收窄；名字写错会报错退出）
      --no-config       本次会话不接受配置类命令（厂商/模型/模式/可写范围/密钥）
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
  CLAUDE_ENCRYPT_HISTORY 设为 1 则用口令加密保存历史（等同 --encrypt-history）
  CLAUDE_OPENSSL     openssl 命令路径（默认: openssl）
  CLAUDE_MODE        交互模式 default / accept-edits / bypass（等同 --mode）
  CLAUDE_ALLOW_WRITE 追加可写目录，冒号分隔（等同 --allow-write）
  CLAUDE_SHELL_TIMEOUT 命令超时秒数（默认 120，0=不限）
  CLAUDE_CONFIRM_TIMEOUT 危险操作确认等待秒数（默认 60，超时按拒绝处理）

对话中可用 /claude、/gemini 切换 AI（对话内容会保留）。
/mode 查看或切换交互模式；/allow-write 管理可写目录；/approvals 看最近自动批准。
/memory 查看长期记忆；/remember <事实> 记下一条；/skills 列出本机技能。
/name <名字> 给这场对话起名；/history 列出已保存的对话；/search <词> 在历史里全文搜索。
/key <厂商> 配置某家厂商的 API 密钥（会话中唯一的密钥入口；密钥只在安装时或这里输入）。
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
      --continue, -c    直前の会話を続ける（--continue 名前 も可）
      --name <名前>     この会話に名前を付ける
      --search <語>     保存済みの会話を全文検索して終了
      --resume          保存済みの会話を選んで続きから再開
      --change-passphrase 履歴パスフレーズを変更して終了
      --set-recovery    合言葉(復旧用の秘密の質問)を設定して終了
      --encrypt-history 履歴をパスフレーズで暗号化して保存する（既定は平文・合言葉を訊かない）
      --tools=<a,b>     指定したツールだけ使う (絞る方向のみ。名前を間違えると終了)
      --no-config       設定系コマンドを受け付けない (厂商/モデル/モード/書き込み範囲/キー)
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
  CLAUDE_ENCRYPT_HISTORY 1にすると履歴を暗号化保存（--encrypt-history と同じ）
  CLAUDE_OPENSSL     opensslコマンドのパス (既定: openssl)
  CLAUDE_MODE        対話モード default / accept-edits / bypass (--mode と同じ)
  CLAUDE_ALLOW_WRITE 書き込みを許すディレクトリを追加 (コロン区切り)
  CLAUDE_SHELL_TIMEOUT コマンドのタイムアウト秒 (既定 120、0=無制限)
  CLAUDE_CONFIRM_TIMEOUT 危険な操作の確認待ち秒 (既定 60、超過は拒否)

会話中に /claude・/gemini でAIを切り替えられる(会話は引き継がれる)。
/mode で対話モードの表示・切り替え、/allow-write で書き込み先の管理、/approvals で自動承認の履歴。
/memory で長期記憶の表示、/remember <事実> で 1 件追加、/skills で本機のスキル一覧。
/name <名前> でこの会話に名前、/history で保存済み会話の一覧、/search <語> で全文検索。
/key <ベンダー> でそのベンダーの API キーを設定(会話中にキーを入れる唯一の入口)。
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
# 不经过 setup.sh、在对话里用 /claude、/gemini 输入的密钥存到这里。
my $ENV_FILE_PATH = ($ENV{HOME} || '.') . '/.claude-agent-env';

# 厂商切换。CLAUDE_PROVIDER=gemini 用不需要绑卡的
# Gemini API 免费额度；默认（anthropic）用按量计费的 Claude。
# 对话里也可以用 /claude、/gemini 切换（见下面的对话循环）。
my ($PROVIDER, $API_KEY, $MODEL, $API_URL, $ANTHROPIC_VERSION);
my $NOTOOLS = 0;            # 1 则不发送 tools（不支持的模型）
my %MODEL_META;             # 模型 ID => { provider, base_url, notools }

# 按 $provider 设置（重置）$API_KEY / $MODEL / $API_URL 等。
# 启动时和对话中的 /claude、/gemini 都会调用。对应的
# 环境变量（ANTHROPIC_API_KEY / GEMINI_API_KEY）不存在时 die
# —— 启动时直接退出；切换时由调用方 eval 捕获，
# 保持当前厂商继续。
# ------------------------------------------------------------------
# 厂商注册表
#
# 把「密钥环境变量名 / 默认模型 / 请求地址 / 请求构造 / 响应解析」
# 集中到一处。以前这些信息散在 configure_provider、build_headers、
# build_request、parse_response 四个地方的 if/elsif 里，
# 要加一个厂商就得同时改四处
# （漏改一处就直接变成故障）。现在加一条记录就行。
#
# 各項目:
#   （key_env 和 default_model 在 providers.txt 侧。不要在代码里重复维护）
#   auth           头部风格：'goog' 以外都是 x-api-key 系（默认）
#   model_prefix   允许采用 CLAUDE_MODEL 的模型 ID 前缀

#   url            固定端点（没有 url_template 时使用）
#   url_template   把模型 ID 填进 %s 的端点
#   api_version    anthropic-version 头的值（只在需要时）
#   build / parse  与内部格式（Anthropic content blocks）的相互转换
# ------------------------------------------------------------------
# 厂商注册表
#
# 把「密钥环境变量名、默认模型、请求地址、请求构造、响应解析」
# 集中到一处。以前这些信息散在 configure_provider / build_headers /
# build_request / parse_response 四个地方的 if/elsif 里，
# 要加一个厂商就得同时改四处（漏改一处就直接变成故障）。
# 现在加一条记录就够。
#
# 每条记录的字段：
#   （key_env 和 default_model 在 providers.txt 侧。不要在代码里重复维护）
#   auth           头部风格：'x-api-key'（默认）/ 'goog' / 'bearer'
#   model_prefix   允许采用 CLAUDE_MODEL 的模型 ID 前缀

#   url            固定端点（anthropic）
#   url_template   把模型 ID 填进 %s 的端点（gemini）
#   base_url       OpenAI 兼容端点的基址（末尾补 /chat/completions）
#   api_version    anthropic-version 头的值（只在需要时）
#   build / parse  与内部格式（Anthropic content blocks）的转换函数
#
# OpenAI 系（openai / deepseek / dashscope / moonshot / zhipu）共用
# build/parse。各厂商不同的只有密钥环境变量名、默认模型和 base_url。
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

# 对话里输入的命令名当中，和厂商名不一致的那些。
# （/claude 是老用户肌肉记忆，保留）
my %PROVIDER_ALIAS = (
    claude => 'anthropic',
    qwen   => 'dashscope',
    tongyi => 'dashscope',
    kimi   => 'moonshot',
    glm    => 'zhipu',
);

# 命令名 → 厂商名。没有对应的返回空串。
sub provider_from_command {
    my ($cmd) = @_;
    return $cmd if $PROVIDERS{$cmd};
    my $t = $PROVIDER_ALIAS{$cmd};
    return ($t && $PROVIDERS{$t}) ? $t : '';
}

# 未登记的厂商名在这里拦掉（各函数不各自判断）。
sub provider_spec {
    my ($name) = @_;
    return $PROVIDERS{$name}
        || die L('unknown_provider', $name, join(' / ', sort keys %PROVIDERS));
}


# 由模型 ID 反查负责的厂商（第一个前缀匹配的）。
# 都不匹配就落到 anthropic —— 为了不改动既有的兜底。
# 由模型 ID 反查负责的厂商（第一个前缀匹配的）。
# 如果 models.txt 有厂商列，以那一列为准（见 switch_to_model）。
# 都不匹配就落到 anthropic —— 为了不改动既有的兜底。
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

    # CLAUDE_MODEL 跨厂商会不一致，所以只有在它以该厂商的
    # 前缀开头时才采用，否则用默认模型。
    my $env_model = $ENV{CLAUDE_MODEL} || '';
    my $pfx       = $spec->{model_prefix} || '';
    $MODEL = ($pfx ne '' && $env_model =~ /^\Q$pfx\E/)
        ? $env_model
        : provider_info($provider, 'default_model');

    # 请求地址的确定方式有三种：
    #   url           固定(anthropic)
    #   url_template  把模型 ID 填进去（gemini）
    #   base_url      OpenAI 兼容。models.txt 里有每个模型的 base_url
    #                 就用它，没有就用厂商默认值。
    #                 可用 CLAUDE_BASE_URL 整个替换（自建代理等）。
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

    # 不支持工具的模型不发 tools（有的实现发了就返回 400）。
    $NOTOOLS = ($MODEL_META{$MODEL} && $MODEL_META{$MODEL}{notools}) ? 1 : 0;

    $ANTHROPIC_VERSION = $spec->{api_version};
    $PROVIDER = $provider;
}

# 可选 AI 的列表（[id, 说明], ...）。包装脚本用 CLAUDE_MODELS_FILE 告知位置。
# models.txt 是 id|日文说明|English description 三列（向后兼容也接受两列）。
# 可选 AI 的列表（[id, 说明], ...）。包装脚本用 CLAUDE_MODELS_FILE 告知位置。
# models.txt 的列：id|日文说明|English|中文|provider|base_url|flags
#   向后兼容：说明文字列可以没有，provider 及之后也可以没有
#   flags 用空格/逗号分隔。目前只有 notools。
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

        # 按显示语言选说明文字列（空则按 ja → id 的顺序退）
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

# 替换 ~/.claude-agent-env 的一行（没有就追加）。让对话中的切换
# 也能带到下次启动。
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

# 对话中切换厂商（Claude/Gemini）。没有密钥就当场
# 让用户输入，可选保存。成功返回 1，中止/失败返回 0。
sub switch_provider {
    my ($target) = @_;
    eval { configure_provider($target) };
    return 1 unless $@;   # 密钥齐全，可以直接切换

    # 密钥变量名也从注册表取（以前这里写死了厂商名）
    my $spec = eval { provider_spec($target) };
    return 0 unless $spec;
    my $key_name = provider_info($target, 'key_env');

    # GUI 模式下，密钥获取页面引导、输入、连通性验证都交给
    # GUI 侧，这里接收验证过的密钥（{"t":"key","value":...}）
    # （和 need_passphrase 一样的「发出事件再等回复」模式）。
    if ($GUI) {
        # 首次启动的引导画面（密钥未设置时）由 GUI 侧的初始设置处理。
        # 这里是「想在对话中切到别的厂商」的情况，
        # 所以不索取输入，只告知设置方法。
        emit_error(L('key_config_needed', provider_label($target), $key_name,
                     $target, $ENV_FILE_PATH));
        return 0;
    }

    # 会话中不索要密钥（见上面 key_config_needed 的注释）。
    print L('key_config_needed', provider_label($target), $key_name, $target, $ENV_FILE_PATH);
    print L('switch_cancelled', $PROVIDER, $MODEL);
    return 0;
}

# 密钥类错误（401/403 或各家等价的报文）单独认出来，提示"退出后重配密钥"，
# 而不是丢一段原始 JSON 让人自己猜。
sub looks_like_key_error {
    my ($code, $body) = @_;
    return 1 if defined $code && ($code eq '401' || $code eq '403');
    return 0 unless defined $body;
    return 1 if $body =~ /authentication_error|invalid_api_key|incorrect api key|invalid x-api-key|API key not valid|invalid_request_error.*key|鑒权|鉴权失败/i;
    return 0;
}

# 模型选择分两步。第一步选厂商，第二步选该厂商的模型。
# 12 条排成一维会找不到想要的，所以按 providers.txt 的顺序分组。
my $MENU_STAGE = '';      # '' | 'vendor' | 'model:<provider>'
my %MENU_VENDORS;         # 番号 => provider
my %MENU_MODELS;          # 番号 => model_id

sub _models_of {
    my ($p) = @_;
    return grep { defined $_->[2] && $_->[2] eq $p } @MODEL_CHOICES;
}

# 第一步：厂商列表
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

# 第二步：该厂商的模型列表
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
        print L('menu_vendor_no_key', provider_label($p), provider_info($p, 'key_env'), $p);
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

# 切到指定的模型 ID。需要时连厂商一起切换，
# 并写进 ~/.claude-agent-env 以便下次启动沿用。
sub switch_to_model {
    my ($id) = @_;
    # models.txt 有 provider 列就以它为准。没有就从模型 ID 的
    # 前缀推测（不改动既有的兜底）。
    my $declared = ($MODEL_META{$id} && $MODEL_META{$id}{provider}) ? $MODEL_META{$id}{provider} : '';
    my $target_provider = $declared ne '' ? $declared : provider_for_model($id);

    my $prev_model = $ENV{CLAUDE_MODEL};
    $ENV{CLAUDE_MODEL} = $id;

    my $ok = 1;
    if ($target_provider ne $PROVIDER) {
        $ok = switch_provider($target_provider);
    }
    else {
        eval { configure_provider($PROVIDER) };  # 重新生成 $MODEL 和请求地址
        if ($@) { print $@; $ok = 0; }
    }

    unless ($ok) {
        # 切换失败。退回原来的模型。
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
# 输出抽象。终端模式下照旧 print，GUI 模式（$GUI）下
# 往 STDOUT 写一行一条 JSON。会话循环和 run_tool 都不需要
# 关心用的是哪种。GUI 侧（Python/tkinter）读这些 JSON 画界面。
# ------------------------------------------------------------------
sub gui_send {
    my ($obj) = @_;
    print MiniJSON::encode($obj), "\n";
}
# 从 GUI 读一行（JSON）并解码。EOF 返回 undef，其余一定返回哈希引用。
sub gui_read {
    my $line = <STDIN>;
    return undef unless defined $line;
    $line =~ s/\r?\n\z//;
    my $text = decode('UTF-8', $line, FB_DEFAULT);
    my $obj  = eval { MiniJSON::decode($text) };
    return (ref $obj eq 'HASH') ? $obj : {};
}
# 一直读到指定 t 的输入为止，跳过其它并返回。EOF 返回 undef。
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
    $TURN_TEXTS++ if defined $text && $text =~ /\S/;
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
    $TURN_TEXTS++ if defined $text && $text =~ /\S/;   # error 也算「带得走的回复」
    if ($GUI) { gui_send({ t => 'error', text => $text }); }
    else      { print "\n$text"; }
}
sub emit_note {   # 辅助提示（切换完成之类）
    my ($text) = @_;
    if ($GUI) { gui_send({ t => 'note', text => $text }); }
    else      { print "\n$text\n"; }
}

# --- 会话历史（加密后本地保存） ---
# 用随机主密钥加密历史文件，再把主密钥本身用
# 口令（以及可选的「密保问题」）包起来保存。任一种都能
# 取回主密钥，所以忘掉口令也能用密保问题恢复。
my $HISTORY_ENABLED = $ENV{CLAUDE_NO_HISTORY} ? 0 : 1;
# 历史目录可以用环境变量替换。目录变了，密钥
# 文件也就不同，结果就是「另一套口令保护的另一个历史」。
# 本体不知道是谁、为什么替换（本地多配置也好，
# 远程专用目录也好，同一套机制就够）。
my $HISTORY_DIR     = (defined $ENV{CLAUDE_HISTORY_DIR} && $ENV{CLAUDE_HISTORY_DIR} ne '')
                      ? $ENV{CLAUDE_HISTORY_DIR}
                      : "$ENV{HOME}/.claude-agent/history";
my $KEY_FILE        = "$HISTORY_DIR/key.enc";           # 用口令包起来的主密钥
my $KEY_RECOVERY    = "$HISTORY_DIR/key.recovery.enc";  # 同一个主密钥用密保答案包起来的版本（可选）
my $KEY_RECOVERY_Q  = "$HISTORY_DIR/key.recovery.q";    # 密保问题（明文）
my $HISTORY_CHECK   = "$HISTORY_DIR/.check";            # 旧格式。存在就迁移到主密钥方式
my $OPENSSL         = $ENV{CLAUDE_OPENSSL} || 'openssl';
my $STARTED         = _timestamp();
my $SESSION_FILE;                                       # 本场对话的保存位置（unlock 之后决定）

my $SYSTEM_PROMPT = <<'EOS';
You are a lightweight coding assistant running in the terminal of an
older Intel Mac (High Sierra era) that's being kept useful instead of
thrown away. Many users here are not programmers; they want you to build
small personal tools for them. You have four tools: read_file,
write_file, list_dir, and run_shell. Use them to read/write files and
run commands in the user's working directory. Keep replies concise.

Language rule (strict): write every word the user can see in the same
language the user wrote in — that includes the reply, one-line progress
notes, status lines, and any sentence you write before or after a tool
call. Tool descriptions and tool errors are English for compactness;
they must NOT change your output language. If the user writes Chinese,
every sentence you produce is Chinese, never Japanese.

__MODE_CONFIRM_NOTE__

Before a multi-step build, tell the user in one or two lines what files
you'll create and what you'll run, so the confirmation prompts make sense.

Environment: `python3` is Python 3.10 (in the user's PATH via
~/.bash_profile; from run_shell use `python3` and it resolves). tkinter
is available. For extra libraries use `python3 -m pip install --user
<pkg>`. Prefer the standard library when it's enough.
EOS

# 确认说明随模式而变。bypass 下如果写着「每次都会问」，
# 模型会先道一句「我先问一下」白耽误时间、进展不下去。
my %MODE_NOTE = (
    'default' => <<'EON',
write_file and run_shell each ask the user for a y/n confirmation before
running. If a call comes back cancelled, it only means the user declined
THAT ONE action right then (often they were still typing a thought, or
want a change first) - it does NOT mean the environment blocks tools.
Never conclude that file writes or commands are disabled. Instead, stop,
say plainly what you were about to do, ask what they want to adjust, and
try again once they're ready. Do not silently retry the same write.
When a tool call fails, never paste the raw error text back as your whole answer and never tell
the user to "resend"/"重发": say what failed, why, and the one next step you will take or they
should take. If the same class of error happens twice, stop retrying and report what is missing.
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
In the current mode (bypass) writes and commands are approved
automatically - do not ask beforehand and do not wait for a confirmation
that will not come. Two kinds of call still stop and ask the user: (1)
dangerous commands (recursive deletes, sudo, permission changes,
power/system actions, download-and-run, interactive programs); (2)
file/directory operations in the shell - rm, rmdir, mv, cp, ln, mkdir,
chmod, chown, dd, truncate, rsync, tar, zip/unzip, gzip, install,
find -delete, git clean. The writable-roots whitelist does NOT apply in
this mode (it only controls what is auto-approved in edit mode), so you
are not restricted to those roots; however ~/.ssh, ~/.claude-agent, /etc
and /usr stay refused outright. Before a multi-step job, state in one or
two lines what you are about to create and run; if a call is refused,
explain the reason to the user rather than retrying the same thing.
EON
);

sub system_prompt {
    my $note = $MODE_NOTE{$MODE};
    $note = $MODE_NOTE{'default'} unless defined $note;
    my $p = $SYSTEM_PROMPT;
    $p =~ s/__MODE_CONFIRM_NOTE__/$note/;

    # 长期记忆（纯本地文件。内容是用户的东西，不是指令）
    my ($mem, $mem_total, $mem_cut) = read_memory();
    if ($mem ne '') {
        $p .= "\n# Long-term memory about this user\n"
            . "The user keeps this file themselves (" . memory_path() . "). Treat it as\n"
            . "context about them - preferences, facts, preferences they stated. Follow it,\n"
            . "but the request in the CURRENT conversation always wins over it. Never quote\n"
            . "it back unprompted. If something in it looks out of date, say so instead of\n"
            . "silently trusting it.\n";
        if ($mem_cut) {
            $p .= "(only the first $MEMORY_MAX_CHARS characters are shown here; the file has $mem_total -\n"
                . "tell the user it is getting long if that matters)\n";
        }
        $p .= "---\n$mem\n---\n";
    }

    # 写技能的硬要求与「有没有技能」无关，始终说起来 —— 没有技能的时候
    # 恰恰是最该照这个规范新建一个的时候。
    $p .= "\n# Writing a skill (always applies)\n"
        . "If a skill calls a script, reference the script by ABSOLUTE path (when the\n"
        . "remote service starts the agent, PATH usually does NOT include ~/bin), spell out\n"
        . "the exact argument format, and include one self-check command (a --help or\n"
        . "--dry-run that can be run before the real run).\n";

    # 技能只放「名字 + 一行说明」。全文需要时再让它用 read_file 读
    # （别把 prompt 撑胖 = 老 Mac 上也便宜又快）。
    my @sk = skills_list();
    if (@sk) {
        $p .= "\n# Skills available on this machine\n"
            . "Reusable procedures saved as plain files. Only names and one-line\n"
            . "descriptions are listed here; when a task matches one, read the file with\n"
            . "read_file first and then follow it. Do not list them to the user unless asked.\n";
        for my $sk (@sk) {
            $p .= "- " . $sk->{name} . ": " . $sk->{desc}
                . (($sk->{desc} ne '') ? ' ' : '')
                . "(read: " . $sk->{path} . ")\n";
        }
    }
    return $p;
}

# ------------------------------------------------------------------
# 最小 JSON 编码器/解码器（零依赖，覆盖 Claude API 消息
# 结构所需范围的递归下降解析器）
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

# decode: 字符串 -> Perl 数据结构。一边推进 pos 一边解析。
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
# curl 调用
# ------------------------------------------------------------------
# 各厂商的 HTTP 头。API 密钥在这里组装，传给 call_api 的
# 是头字符串数组（call_api 本身不知道是哪家 AI）。
sub build_headers {
    my $spec = provider_spec($PROVIDER);
    my $auth = $spec->{auth} || 'x-api-key';

    # API 密钥在这里组装，传给 call_api 的是头字符串数组
    # （call_api 本身不知道是哪家 AI）。
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

sub call_api_once {
    my ($url, $headers, $body_json) = @_;

    my $tmp_req    = "/tmp/claude-agent-req-$$.json";
    my $tmp_resp   = "/tmp/claude-agent-resp-$$.json";
    my $tmp_config = "/tmp/claude-agent-curlcfg-$$.txt";

    open(my $fh, '>:encoding(UTF-8)', $tmp_req) or die "cannot write $tmp_req: $!\n";
    print $fh $body_json;
    close $fh;

    # 为了不把 API 密钥暴露在 ps 输出里，不走命令行参数，
    # 而是通过 curl 的配置文件（-K）传头
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
    # 除了 http_code，各阶段耗时也记进日志。有报告说「响应特别
    # 慢」（2026-09-25），但用 curl 直接打同样的请求
    # 1〜3 秒就回来了，复现不了（GUI、curl 调用方式
    # 两边都没找到原因）。怀疑是 IPv6 happy-eyeballs 延迟之类、
    # 偶发的网络侧因素，所以下次再出现时能立刻
    # 看出卡在哪个阶段（域名解析/连接/TLS/等响应）。
    print $cf qq(write-out = "%{http_code} dns=%{time_namelookup}s connect=%{time_connect}s tls=%{time_appconnect}s wait=%{time_starttransfer}s total=%{time_total}s"\n);
    # 设上限，免得线路拥堵时无限等。超时后 curl
    # 报错退出，下面就按 HTTP 000 处理（不会卡死）。
    print $cf qq(connect-timeout = 20\n);
    print $cf qq(max-time = 180\n);
    # IPv6 的 happy-eyeballs（先试 v6，失败/超时再
    # 回退到 v4）在某些环境下会造成几十秒延迟。
    # 这个 API 走 IPv4 也没问题，所以直接用 IPv4。
    print $cf qq(ipv4\n);
    print $cf qq(silent\n);
    print $cf qq(show-error\n);
    close $cf;

    dbg("REQ $PROVIDER $MODEL -> $url  (" . length($body_json) . " bytes)");

    # 等响应期间别让人觉得屏幕卡死，先给一句话。
    # 完全不用光标控制的转义序列（老 Terminal.app
    # 会在字符绘制时崩。只留一行，不做清除）。
    emit_status(L('thinking_status'));
    my $curl_out = `@{[quote($CURL)]} -K @{[quote($tmp_config)]}`;
    $curl_out = '' unless defined $curl_out;
    dbg("curl timing: $curl_out");
    my ($http_code) = $curl_out =~ /^(\d*)/;
    $http_code = '' unless defined $http_code;
    emit_status("") if $GUI;
    unlink $tmp_req, $tmp_config;

    # 响应按生字节读进来再统一解码。
    # 直接用 :encoding(UTF-8) 层读的话，多字节字符在缓冲区边界被
    # 切开时会以 "utf8 does not map to Unicode" 挂掉
    # （和 ppc_claude_cli 踩的同一个坑。含大量日文的长响应里容易出现）。
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
            die "CONNECT_FAIL\t" . L('cannot_connect');
        }
        if (looks_like_key_error($http_code, $resp_body)) {
            die L('key_invalid', provider_label($PROVIDER),
                  $http_code, provider_info($PROVIDER, 'key_env'));
        }
        # 正文太长会把屏幕刷走，只显示开头。
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

# 重试策略：只重试「连接没建立」和 429 / 5xx 这类临时性失败，
# 业务错误（400/401/402/404…）一律不重试 —— 重试它们只会浪费时间和钱。
my $HTTP_RETRY_MAX = (defined $ENV{CLAUDE_HTTP_RETRY} && $ENV{CLAUDE_HTTP_RETRY} =~ /^\d+$/)
    ? $ENV{CLAUDE_HTTP_RETRY} : 2;

sub api_host_of {
    my ($url) = @_;
    my $h = $url || '';
    $h =~ s{^[a-z]+://}{}i;
    $h =~ s{/.*$}{};
    return $h ne '' ? $h : '(未知地址)';
}

sub call_api {
    my ($url, $headers, $body_json) = @_;
    my $max = 1 + $HTTP_RETRY_MAX;
    my $tries = 0;
    my $err = '';
    while ($tries < $max) {
        $tries++;
        my $data = eval { call_api_once($url, $headers, $body_json) };
        return $data unless $@;
        $err = $@;
        my $retryable = ($err =~ /CONNECT_FAIL/ || $err =~ /HTTP\s*(?:429|5\d\d)/) ? 1 : 0;
        last unless $retryable && $tries < $max;
        my $sleep = $tries == 1 ? 2 : 5;
        dbg("call_api 第 $tries 次失败（可重试）：$err");
        emit_status(L('api_retrying', $tries, $sleep));
        sleep $sleep;
    }
    # 到这里说明真的连不上/一直 5xx。把排查方向直接写进回复里，
    # 别只说「请检查网络」—— 用户拿手机根本无从判断是哪一段断了。
    my $is_connect = ($err =~ s/^CONNECT_FAIL\t//) ? 1 : 0;
    if ($is_connect) {
        # 连接类失败：旧文案（无法连接…请检查网络）本身就是我们要换掉的东西，不能拼回去。
        die L('cannot_connect_api', provider_label($PROVIDER),
              api_host_of($url), $tries, api_host_of($url));
    }
    # ★ 其余（400/401/422/…）**不能**贴成「连不上模型服务」——
    #   连得上，是它拒了这个请求。贴错标签会把排障方向直接带偏。
    die $err;
}

sub quote {
    my ($s) = @_;
    $s =~ s/'/'\\''/g;
    return "'$s'";
}

# ------------------------------------------------------------------
# 各厂商的请求构造与响应解析
#
# 会话历史（@messages）始终以 Anthropic 的 content blocks 形式
# (role => user/assistant, content => 文字列 or [{type=>text/tool_use/
# tool_result, ...}]) 作为内部格式。用 Gemini 时只在调用 API
# 之前转换成 contents/parts 形式，响应一到就马上转回内部格式。
# 这样会话循环和 run_tool 完全不用管是哪家厂商。
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
                    # Gemini 3 系回传 functionCall 时，必须带上和收到时
                    # 相同的 thoughtSignature，否则返回 400。
                    $part->{thoughtSignature} = $block->{thought_signature} if defined $block->{thought_signature};
                    push @parts, $part;
                }
                elsif ($block->{type} eq 'tool_result') {
                    # Gemini 不用 tool_use_id，而是按名字对应结果
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

# Gemini 3 系省略 thinkingLevel 时默认是 "HIGH"，连简单的问题也要
# 几十秒才出第一个字。在性能有限的机器上做对话，优先速度，
# 所以默认 LOW，可用 CLAUDE_GEMINI_THINKING=high 改回来。
# Gemini 2.5 系用的是 thinkingBudget（0〜24576，-1 表示动态），所以按模型名分支。
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
            # 因为启用了 thinkingConfig（_gemini_thinking_config），
            # parts 里「思考中」的 thought 部分和真正的回答部分会
            # 混在一起返回。thought:true 的部分不显示，
            # 只留在会话历史里（thoughtSignature 的延续需要它）。这里
            # 没丢掉、全按 'text' 返回，导致 GUI 侧两路流式
            # 同时跑，文字交错着显示。
            $block->{thought} = 1 if $part->{thought};
            push @blocks, $block;
        }
        elsif ($part->{functionCall}) {
            $gemini_call_seq++;
            my $block = {
                type  => 'tool_use',
                id    => "gemini-call-$gemini_call_seq",   # Gemini 的 functionCall 没有 id，用这个代替
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
# 与内部格式（Anthropic 的 content blocks）的差异：
#   · system 作为 role=system 放在消息数组开头，一条
#   · tool_use 是 assistant.tool_calls[]，参数是 JSON「字符串」
#   · tool_result 是 role=tool 的独立消息，用 tool_call_id 关联
#     （不能像 Anthropic 那样嵌进 user 消息数组里）
#   · tools 用 {type=>'function', function=>{...}} 多包一层
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
                next if $block->{thought};   # 思考日志不回传
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
                $c = MiniJSON::encode($c) if ref $c;   # 字符串以外先 JSON 化再传
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
            # ★ content 必须是字符串：只有工具调用、没有文本时也要给 ''，
            #   不能留 undef（MiniJSON 会编成 null，DeepSeek 这类服务直接
            #   422 invalid_request_error「content should be a string or a list」）。
            $m->{content} = @texts ? join("\n", @texts) : '';
            push @out, $m;
        }
        elsif (@texts) {
            push @out, { role => $role, content => join("\n", @texts) };
        }
    }

    # 发出去之前统一兜一层：content 必须有值且是字符串/数组。
    # 老会话文件、手工改过的历史、第三方导入都可能留下 content:null。
    my (@bad_idx, $bad_kind);
    for my $i (0 .. $#out) {
        my $m = $out[$i];
        next unless ref $m eq 'HASH';
        my $c = $m->{content};
        if (!defined $c) {
            $out[$i]{content} = '';
            push @bad_idx, $i; $bad_kind = 'null';
        }
        elsif (ref $c eq 'HASH') {
            # 单个块（{type=>'text',text=>…}）漏转成数组时会出现：
            # 编出去就是个 JSON 对象，厂商同样报 content should be a string or a list。
            $out[$i]{content} = (defined $c->{text} && !ref $c->{text}) ? $c->{text}
                                                                       : MiniJSON::encode($c);
            push @bad_idx, $i; $bad_kind = 'object';
        }
    }
    if (@bad_idx && ($ENV{CLAUDE_DEBUG} || '') ne '') {
        warn "::notice::content 兜底：$bad_kind 修了 " . scalar(@bad_idx)
            . " 条（下标 " . join(',', @bad_idx[0 .. ($#bad_idx > 9 ? 9 : $#bad_idx)]) . "）\n";
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

    # reasoning_content（DeepSeek-R1 等的思考日志）不进历史。
    # 有的实现回传后会返回 400，所以故意丢掉。
    my $content = $msg->{content};
    if (ref $content eq 'ARRAY') {
        # 有些厂商把 content 放在 parts 数组里返回
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
# 会话历史的加密保存
#
# High Sierra 自带的 Perl 没有加密功能，也不想引入 CPAN 依赖，
# 所以调 openssl 命令做 AES-256-CBC 加密。口令通过
# 环境变量 CLAUDE_HIST_PASS 传，不出现在 ps 输出、argv 和磁盘上。
# High Sierra 的 LibreSSL 不支持 -pbkdf2，密钥派生偏弱（基于 MD5），
# 但比明文放着好得多 —— 就是这个定位。显式指定 -md md5，
# 让新一些的 OpenSSL 也用同样的密钥派生。
# ------------------------------------------------------------------
sub _timestamp {
    my @t = localtime();
    return sprintf('%04d%02d%02d-%02d%02d%02d',
        $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
}

# 用 0600 建临时文件再写（明文落盘只在这里，
# 写完立刻 unlink）
sub _write_private {
    my ($path, $data) = @_;
    open(my $fh, '>:encoding(UTF-8)', $path) or die L('cannot_make_tmp', $!);
    chmod 0600, $path;
    print $fh $data;
    close $fh;
}

# 把 openssl 的 stderr（新版 OpenSSL 的 "deprecated key derivation" 警告、
# 口令不对时的 "bad decrypt" 等。都靠这边的返回值判断处理）
# 吞掉再执行
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

sub hist_plain_encrypted {   # 这个文件是否已加密
    my ($path) = @_;
    # ★ 以前只看 /\.json\.enc$/，于是**被包起来的主密钥**
    #   （key.enc / key.recovery.enc）和旧格式 .check 被判定为「明文」，
    #   不经过 openssl 就当 UTF-8 文本读了。结果口令再正确
    #   也必定失败，而且整个文件被当成乱码字符串读进来，
    #   刷出一堆「does not map to Unicode」警告。
    #   扩展名 .enc 和旧的 .check 一律当密文处理。
    return 1 if $path =~ /\.enc$/;
    return 1 if $path =~ m{/\.check$};
    return 0;
}

sub hist_decrypt {
    my ($in_path) = @_;
    # 明文历史直接读（不需要口令）
    unless (hist_plain_encrypted($in_path)) {
        open(my $fh, '<:encoding(UTF-8)', $in_path) or return undef;
        local $/;
        my $raw = <$fh>;
        close $fh;
        return $raw;
    }
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

# 不显示在屏幕上读一行口令
{
    my $secret_hint_shown = 0;
    sub read_secret {
        my ($prompt) = @_;

        # GUI 模式：发出口令请求事件，等回复。
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

        # 不知道「输入了也什么都不显示」就会以为卡死，所以
        # 只在本场会话第一次输口令时加一句说明。
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

# 用指定的秘密（口令或密保答案）包起来/打开。
# 临时替换 CLAUDE_HIST_PASS 后调用 hist_encrypt/hist_decrypt。
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

# 生成随机主密钥（64 位 hex）
sub _gen_master {
    my $hex = `@{[quote($OPENSSL)]} rand -hex 32 2>/dev/null`;
    $hex = '' unless defined $hex;
    $hex =~ s/\s+//g;
    return ($hex =~ /^[0-9a-f]{64}$/) ? $hex : undef;
}

# 用秘密打开包好的主密钥。成功返回 hex 串，失败返回 undef。
sub _open_master {
    my ($secret, $wrap_path) = @_;
    my $got = _unwrap_with($secret, $wrap_path);
    return undef unless defined $got;
    return $1 if $got =~ /^MASTER:([0-9a-f]{64})/;
    return undef;
}

# 用秘密把主密钥包起来保存
sub _save_master {
    my ($secret, $master, $wrap_path) = @_;
    my $ok = _wrap_with($secret, "MASTER:$master\n", $wrap_path);
    chmod 0600, $wrap_path if $ok;
    return $ok;
}

# 规范化密保答案（忽略大小写、前后与连续空白。
# 「Toyota Corolla」和「 toyota  corolla 」视为相同）
sub _norm_answer {
    my ($a) = @_;
    $a = lc $a;
    $a =~ s/^\s+//;
    $a =~ s/\s+$//;
    $a =~ s/\s+/ /g;
    return $a;
}

# 设置/重设密保问题（找回口令用）。前提是 $master 已在手上。
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

# 让用户输两遍新口令，重新包一遍主密钥
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

# 用密保问题恢复。成功返回主密钥 hex（顺便提示
# 重设口令）。中止/失败的出口是「空 Enter」。
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

# 从旧格式（直接加密 .check + 历史文件也直接用口令加密）迁移
# 到主密钥方式。成功返回主密钥 hex。
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
                # 把已有的历史文件从 口令→主密钥 重新加密
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

# 解锁历史，把主密钥设进 $ENV{CLAUDE_HIST_PASS} 并
# 返回 1。首次是新建设置，之后用口令（或密保答案）解锁。
# 中止/失败返回 0（不带历史继续）。
# 把已有的加密历史切成明文。
# 只收一次口令（或 CLAUDE_HIST_PASS），全部解密之后再
# 删 key.enc —— 中途失败**什么都不删**（不造读不了的历史）。
# 事前一定先备份（cp -R。macOS 自带）。
sub make_plain_history {
    my @enc = grep { /\.json\.enc$/ } history_files();
    my $key_path = -f $KEY_FILE ? $KEY_FILE : (-f $HISTORY_CHECK ? $HISTORY_CHECK : '');
    unless ($key_path ne '' || @enc) {
        print L('plain_hist_nothing');
        return 0;
    }
    unless ($key_path ne '') {
        print L('plain_hist_no_key', scalar @enc);
        return 1;
    }

    my $secret = $ENV{CLAUDE_HIST_PASS};
    if (!defined $secret || $secret eq '') {
        $secret = read_secret(L('plain_hist_pass_prompt'));
        unless (defined $secret && $secret ne '') {
            print L('plain_hist_cancelled');
            return 1;
        }
    }
    my $master = _open_master($secret, $key_path);
    unless (defined $master) {
        print L('plain_hist_bad_pass');
        return 1;
    }

    # 备份（把解密前的状态原样留下）
    require File::Basename;
    my $parent = File::Basename::dirname($HISTORY_DIR);
    my $base   = File::Basename::basename($HISTORY_DIR);
    my $backup = "$parent/$base-backup-" . _timestamp();
    my $rc = system('cp', '-R', $HISTORY_DIR, $backup);
    if ($rc != 0 || !-d $backup) {
        print L('plain_hist_backup_failed', $backup);
        return 1;
    }
    chmod 0700, $backup;

    # 解密并写出 *.json。有一个失败就中断（不删）。
    my (@ok, @ng);
    for my $f (@enc) {
        my $plain = _unwrap_with($master, "$HISTORY_DIR/$f");
        if (!defined $plain) { push @ng, $f; next; }
        (my $out = $f) =~ s/\.enc$//;
        eval { _write_private("$HISTORY_DIR/$out", $plain); 1 } or do { push @ng, $f; next; };
        push @ok, $out;
    }
    if (@ng) {
        print L('plain_hist_decrypt_failed', scalar @ng, join(', ', @ng[0 .. ($#ng > 2 ? 2 : $#ng)]));
        print L('plain_hist_backup_kept', $backup);
        return 1;
    }

    # 到这里才开始删。已经有解好的 *.json，数据不会丢。
    for my $f (@enc) { unlink "$HISTORY_DIR/$f"; }
    for my $k ($KEY_FILE, $HISTORY_CHECK, $KEY_RECOVERY, $KEY_RECOVERY_Q) {
        unlink $k if -f $k;
    }
    $HIST_PLAIN = 1;
    print L('plain_hist_done', scalar @ok, $HISTORY_DIR, $backup);
    return 0;
}

sub unlock_history {
    for my $d ("$ENV{HOME}/.claude-agent", $HISTORY_DIR) {
        mkdir($d, 0700) unless -d $d;
    }

    # ★ 明文模式（默认）。但「已经存在加密历史」就不转明文
    #   —— 用户加密保护着的东西，偷偷改成明文就是事故。
    unless ($ENCRYPT_HISTORY) {
        # 「有没有加密历史」按**主密钥的痕迹**判断（key.enc / 旧的 .check）。
        # 只有 *.json.enc 而没有 key.enc 的是解不开的孤儿文件，
        # 拿它当理由去问口令，会让已经切到明文的人
        # 莫名其妙被要求输密钥（测试里真踩过）。
        my $legacy = (-f $KEY_FILE || -f $HISTORY_CHECK) ? 1 : 0;
        unless ($legacy) {
            $HIST_PLAIN = 1;
            print L('hist_plain_mode', $HISTORY_DIR) unless $GUI;
            return 1;
        }
    }

    # GUI 模式：口令只输一次（没有确认栏）。改用「密保问题」
    # 必填，保证忘掉时一定有恢复口。旧格式迁移在终端侧做。
    if ($GUI) {
        return 0 if -f $HISTORY_CHECK && ! -f $KEY_FILE;

        my $has_recovery = (-f $KEY_RECOVERY && -f $KEY_RECOVERY_Q) ? 1 : 0;

        if (-f $KEY_FILE) {                                 # 解錠
            while (1) {
                gui_send({ t => 'need_passphrase', prompt => L('history_prompt'),
                           recover => ($has_recovery ? 1 : 0) });
                my $r = gui_read_typed('passphrase');
                return 0 unless defined $r;

                if ($has_recovery && $r->{recover}) {       # 用密保问题恢复
                    my $q = '';
                    if (open(my $qf, '<:encoding(UTF-8)', $KEY_RECOVERY_Q)) {
                        local $/; $q = <$qf>; close $qf;
                        $q = '' unless defined $q;
                        $q =~ s/\s+\z//;          # local $/ 之下 chomp 不起作用
                    }
                    gui_send({ t => 'need_recovery', mode => 'unlock', question => ($q // '') });
                    my $ra = gui_read_typed('recovery');
                    return 0 unless defined $ra;
                    my $ans = defined $ra->{answer} ? $ra->{answer} : '';
                    my $m = ($ans ne '') ? _open_master(_norm_answer($ans), $KEY_RECOVERY) : undef;
                    unless (defined $m) { emit_error(L('wrong_answer')); next; }
                    # 换成新口令
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
                return 0 if $pass eq '';                    # 空=不带历史启动
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

        # 密保问题（必填）。没设置就不留加密历史
        # （免得忘了口令时全损）。
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

    # 旧格式迁移
    if (-f $HISTORY_CHECK && ! -f $KEY_FILE) {
        my $master = migrate_check_file();
        if (defined $master) { $ENV{CLAUDE_HIST_PASS} = $master; return 1; }
        return 0;
    }

    # 第二次以后：用口令 或 密保答案解锁
    if (-f $KEY_FILE) {
        my $has_recovery = (-f $KEY_RECOVERY && -f $KEY_RECOVERY_Q) ? 1 : 0;
        # 不限次数。不想带历史继续就空 Enter 退出。
        while (1) {
            my $prompt = $has_recovery
                ? L('hist_pass_no_recovery')
                : L('hist_pass_no_recovery2');
            # 如果传了 CLAUDE_HIST_PASS，就拿它当口令试
            # （自动化、远程、--make-plain-history 走同一条路）。
            # 不对就照旧交互重问，所以失败也不会卡住。
            my $from_env = (defined $ENV{CLAUDE_HIST_PASS} && $ENV{CLAUDE_HIST_PASS} ne '')
                ? $ENV{CLAUDE_HIST_PASS} : undef;
            my $pass = defined $from_env ? $from_env : read_secret($prompt);
            if (defined $from_env) {
                my $m0 = _open_master($from_env, $KEY_FILE);
                if (defined $m0) { $ENV{CLAUDE_HIST_PASS} = $m0; return 1; }
                # 环境变量不对 → 丢掉变量，切回交互
                delete $ENV{CLAUDE_HIST_PASS};
                print L('wrong_passphrase');
                $pass = read_secret($prompt);
            }
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

# 把当前会话加密保存到 $SESSION_FILE
sub save_history {
    my ($messages_ref) = @_;
    return unless $SESSION_FILE;
    my %rec = (
        model    => $MODEL,
        started  => $STARTED,
        messages => $messages_ref,
    );
    $rec{name} = $SESSION_NAME if defined $SESSION_NAME && $SESSION_NAME ne '';
    my $json = MiniJSON::encode(\%rec);
    if ($HIST_PLAIN) {
        # 明文也是 0600。目录 0700（unlock_history 里建）。
        _write_private($SESSION_FILE, $json);
        chmod 0600, $SESSION_FILE;
        return;
    }
    hist_encrypt($json, $SESSION_FILE);
    chmod 0600, $SESSION_FILE;
}

# 逐行组装已保存的会话（--list-history 和 /history 共用）。
# 返回值：(行的数组, 解不开的条数)
sub history_lines {
    my @lines;
    my $undecryptable = 0;
    my $i = 1;
    for my $f (history_files()) {
        my $raw = hist_decrypt("$HISTORY_DIR/$f");
        my $line = L('cannot_decrypt');
        $undecryptable++ unless defined $raw;
        if (defined $raw) {
            my $d = eval { MiniJSON::decode($raw) };
            if ($d) {
                my $nm = (defined $d->{name} && $d->{name} ne '')
                    ? '[' . $d->{name} . '] ' : '';
                $line = $nm . ($d->{started} || $f) . '  ' . first_user_line($d);
            }
            else { $line = L('corrupted'); }
        }
        push @lines, sprintf("  %2d) %s", $i++, $line);
    }
    return (\@lines, $undecryptable);
}

# 在已保存的会话里全文搜索（--search 和 /search 共用）。
# 返回值：(显示行数组, 命中会话数, 解不开的条数)
sub search_history_lines {
    my ($word) = @_;
    my @out;
    my $hits = 0;
    my $skipped = 0;
    my $needle = lc $word;
    for my $f (history_files()) {
        my $raw = hist_decrypt("$HISTORY_DIR/$f");
        if (!defined $raw) { $skipped++; next; }
        my $d = eval { MiniJSON::decode($raw) };
        next unless $d;
        my @lines;
        for my $m (@{ $d->{messages} || [] }) {
            my $c = ref($m->{content}) ? '' : ($m->{content} // '');
            next if $c eq '';
            my $pos = index(lc $c, $needle);
            next if $pos < 0;
            # 按字符切出命中位置前后（按字节切会切坏中文）
            my $from = $pos - 40 > 0 ? $pos - 40 : 0;
            my $frag = substr($c, $from, length($word) + 80);
            $frag = '…' . $frag if $from > 0;
            $frag .= '…' if $from + length($word) + 80 < length($c);
            $frag =~ s/\s+/ /g;
            push @lines, sprintf("      %s: %s", ($m->{role} || '?'), $frag);
        }
        next unless @lines;
        $hits++;
        my $nm = (defined $d->{name} && $d->{name} ne '') ? '[' . $d->{name} . '] ' : '';
        push @out, sprintf("  %s%s  %s", $nm, ($d->{started} || $f), first_user_line($d));
        push @out, @lines;
        last if $hits >= 20;
    }
    return (\@out, $hits, $skipped);
}

# 已保存的会话文件（新的在前。文件名开头是时间戳）
sub history_files {
    opendir(my $dh, $HISTORY_DIR) or return ();
    # 明文（*.json）和加密（*.json.enc）可能混在一起（刚切换格式之后）。
    # 文件名开头是时间戳，所以降序排序就是新的在前。
    my @f = grep { /\.json(\.enc)?$/ } readdir($dh);
    closedir $dh;
    return sort { $b cmp $a } @f;
}

# 从会话数据里取出第一条用户发言（列表显示用）
sub first_user_line {
    my ($data) = @_;
    for my $m (@{ $data->{messages} || [] }) {
        next unless $m->{role} && $m->{role} eq 'user';
        my $c = $m->{content};
        next if ref $c;   # tool_result 之类结构化 content 跳过
        $c =~ s/\s+/ /g;
        return length($c) > 60 ? substr($c, 0, 60) . '…' : $c;
    }
    return L('no_message');
}

# 把内部格式的会话摊平成 {role, text} 数组，供 GUI 重绘。
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
# 工具定义与工具执行
# ------------------------------------------------------------------
my @TOOLS = (
    {
        name => 'read_file',
        description => 'Read the contents of a file.',
        input_schema => {
            type => 'object',
            properties => { path => { type => 'string', description => 'Path of the file to read' } },
            required => ['path'],
        },
    },
    {
        name => 'write_file',
        description => 'Write content to a file (overwrites existing content).',
        input_schema => {
            type => 'object',
            properties => {
                path    => { type => 'string', description => 'Path to write to' },
                content => { type => 'string', description => 'Content to write' },
            },
            required => ['path', 'content'],
        },
    },
    {
        name => 'list_dir',
        description => 'List the contents of a directory.',
        input_schema => {
            type => 'object',
            properties => { path => { type => 'string', description => 'Directory to list (defaults to the current directory)' } },
            required => [],
        },
    },
    {
        name => 'run_shell',
        description => 'Run a shell command and return its stdout/stderr.',
        input_schema => {
            type => 'object',
            properties => { command => { type => 'string', description => 'Shell command to run' } },
            required => ['command'],
        },
    },
    {
        name => 'write_skill',
        description => 'Save (or overwrite) one reusable procedure as a skill, so it can be '
                     . 'reloaded in later sessions. The user is asked to confirm before writing.',
        input_schema => {
            type => 'object',
            properties => {
                name        => { type => 'string', description => 'short skill name (<= 32 chars, no slashes)' },
                description => { type => 'string', description => 'one line (<= 80 chars): when to use it' },
                body        => { type => 'string', description => 'the procedure itself, markdown (<= 20000 bytes)' },
            },
            required => ['name', 'description', 'body'],
        },
    },
    {
        name => 'remember',
        description => 'Save one durable fact about the user into their long-term memory '
                     . '(the user is asked to confirm before anything is written)',
        input_schema => {
            type => 'object',
            properties => {
                fact => { type => 'string',
                          description => 'one sentence worth remembering across sessions' },
            },
            required => ['fact'],
        },
    },
);

# --tools= 的收窄。这里只往「减少」的方向生效 —— 注册表里没有的
# 名字不会默默忽略，而是直接死（不把配置错误悄悄吞掉）。
if ($TOOLS_ALLOW ne '') {
    my %known = map { $_->{name} => 1 } @TOOLS;
    my %want;
    for my $n (split /,/, $TOOLS_ALLOW) {
        $n =~ s/^\s+//; $n =~ s/\s+$//;
        next if $n eq '';
        unless ($known{$n}) {
            die sprintf("--tools 指定了未知的工具名 '%s'（可用的是: %s）\n",
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
    # strict：「没人守着就拒绝」时要闭合的确认（危险命令、可写范围外
    # 的写入）。danger 是为了措辞（★危险），strict 是为了等待时长。
    my $strict = ($opts && ref $opts eq 'HASH' && $opts->{strict}) ? 1 : $danger;
    my $wait   = $strict ? confirm_timeout_secs() : 0;
    $CONFIRM_REASON = '';

    # GUI 模式：发出确认事件，等返回的 reply。
    # 只有危险操作才缩短等待（免得没人守着时卡死）。
    if ($GUI) {
        my $cid = sprintf('%d-%d', $$, ++$CONFIRM_SEQ);
        gui_send({ t => 'confirm', cid => $cid, prompt => $msg,
                   danger => $danger, timeout => $wait });
        my $value;
        my $got = 0;
        my $stale = 0;
        eval {
            local $SIG{ALRM} = sub { die "ALARM_CONFIRM\n" };
            alarm($wait) if $wait > 0;
            while (1) {
                my $r = gui_read();
                last unless defined $r;                  # GUI 已关闭
                next unless $r->{t} && $r->{t} eq 'reply';
                # ★ 只认这一回的 cid。没有 cid 或对不上 = 上一条问题迟到的答复，
                #   丢掉 —— 否则「我明明没同意」的那次操作会被人后面点的一下放过去。
                my $rc = defined $r->{cid} ? $r->{cid} : '';
                if ($rc ne $cid) { $stale++; next; }
                $value = $r->{value};
                $got = 1;
                last;
            }
            alarm(0);
        };
        alarm(0);
        if (!$got) {
            # 让界面把「这道题已经作废」的弹窗关掉，别留着让人点
            gui_send({ t => 'confirm_cancel', cid => $cid });
            $CONFIRM_REASON = ($@ && $@ =~ /ALARM_CONFIRM/) ? 'timeout' : 'nochannel';
            emit_note(L('confirm_void_note', $stale)) if $stale;
            return 0;
        }
        unless (defined $value && $value =~ /^(y|yes|1|true)$/i) {
            $CONFIRM_REASON = 'no';
            return 0;
        }
        return 1;
    }

    # 没有终端（管道执行等）时，危险操作不问直接拒绝。
    # 没人可问还等着，只会卡死，一点安全性都换不来。
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

    # y/n 以外（打成了指令等）不当作取消，重新问。
    # 防止误打的一句话把写入发出去。
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
# 行编辑（支持方向键的简易 readline）
#
# 标准 <STDIN> 没有光标移动功能，按方向键时
# 终端发出的原始转义序列（ESC [ C 等）会直接
# 当字符显示在屏幕上。为避免这点，用 stty 把终端切到 raw
# 模式，一个字节一个字节读，自己做简易行编辑（←→移动、
# Backspace、↑↓调历史）。
# 不依赖外部 CPAN 模块（Term::ReadLine 等）。
# ------------------------------------------------------------------
{
    my @HISTORY;

    # 调试用：设 $ENV{CLAUDE_DEBUG_INPUT} 为文件路径后，
    # read_line_interactive 会把实际收到的生字节逐行追加进去。
    # 这是查真机上 IME 输入时到底收到什么的临时手段。
    sub _debug_log {
        return unless $ENV{CLAUDE_DEBUG_INPUT};
        open(my $fh, '>>', $ENV{CLAUDE_DEBUG_INPUT}) or return;
        print $fh @_;
        close $fh;
    }

    # 从 UTF-8 首字节返回该字符占几字节
    sub _utf8_char_len {
        my ($byte) = @_;
        my $b = ord($byte);
        return 1 if $b < 0x80;
        return 2 if ($b & 0xE0) == 0xC0;
        return 3 if ($b & 0xF0) == 0xE0;
        return 4 if ($b & 0xF8) == 0xF0;
        return 1;  # 非法字节序列就一个字节一个字节往前推
    }

    # 接收已解码的 Perl 字符串，返回在终端上的显示宽度
    # （半角=1/全角=2）
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

    # 返回给定 UTF-8 字节串在终端上的显示宽度
    sub _display_width {
        my ($bytes) = @_;
        return 0 if $bytes eq '';
        return _display_width_chars(decode('UTF-8', $bytes, FB_DEFAULT));
    }

    # 返回终端列数（取不到就回退 80）
    sub _term_width {
        my $wh = `stty size 2>/dev/null`;
        return $1 if $wh =~ /^\s*\d+\s+(\d+)\s*$/;
        return 80;
    }

    # 返回画完宽度 $w（单元格数）之后光标所在位置
    # （0 起始的行, 0 起始的列）。终端的折行是「延后换行」
    # 规格：到行末也不会换行，直到下一个字符到来，
    # 所以正好在列数整数倍处折行时，光标留在该行最后一列。
    sub _pos_rc {
        my ($w, $cols) = @_;
        return (0, 0) if $w <= 0 || $cols <= 0;
        my $row = int(($w - 1) / $cols);
        my $col = $w % $cols;
        $col = $cols - 1 if $col == 0;  # 延后换行：正好是列数整数倍时留在行末
        return ($row, $col);
    }

    # 显示提示符并读一行。
    #
    # 默认是「朴素输入」：不把终端切 raw，只用 <STDIN> 读一行。
    # 理由 —— 自己做的方向键行编辑，每次按键都要往终端发大量
    # 光标移动、整行重绘的转义序列。High Sierra 的
    # Terminal.app 2.8.3 在这种负载下（尤其是日文=CoreText 字形绘制）
    # 画字形时会出现 heap corruption 然后 abort
    # （Terminal 侧的 bug。crash report 里确认过）。实用上，比起行编辑
    # 优先「不崩」。
    #
    # CLAUDE_FANCY_INPUT=1 可以回到原来的行编辑（←→移动、↑↓历史）。
    sub read_line_interactive {
        my ($prompt, $use_history) = @_;
        $use_history = 1 unless defined $use_history;

        unless ($ENV{CLAUDE_FANCY_INPUT}) {
            (my $p = $prompt) =~ s/^\n+//;
            print "\n" if $prompt =~ /^\n/;
            print $p;
            my $line = <STDIN>;
            return undef unless defined $line;   # EOF

            # 防止粘贴多行时被拆成一行一条消息。
            # 读完第一行之后，如果输入还留在缓冲区里（=粘贴），
            # 就把后续行也并进同一条消息。人一行一行想着打的时候
            # 到下一行会有间隔，不会被这个等待时间（50ms）误判。
            eval {
                my $rin = '';
                vec($rin, fileno(STDIN), 1) = 1;
                while (select(my $r = $rin, undef, undef, 0.05)) {
                    my $more = <STDIN>;
                    last unless defined $more;
                    $line .= $more;
                }
            };

            $line =~ s/\r?\n\z//;                 # 只去掉末尾换行（中间的换行保留）
            return $line;                         # 生字节（由调用方解码）
        }

        my $orig_stty = `stty -g`;
        chomp $orig_stty;
        my $term_cols = _term_width();
        # 没有 -opost 时，某些环境下输出后处理（尤其 ocrnl）仍然开着，
        # 重绘用的 "\r" 被当成换行，本该覆盖一行却每次新建一行
        # （结果就是每输入一次就多换一行）。
        system('stty', 'raw', '-echo', '-opost');

        my $buf = '';                    # 生字节串
        my $pos = 0;                     # 光标位置（字节单位，始终在字符边界）
        my $hist_idx = scalar(@HISTORY); # 历史光标（数组末尾 = 正在新输入）
        my $saved_buf = '';              # 翻历史之前先存一下当前输入

        # $prompt 开头的换行（如中文提示符里的 "\n…> "）只在首次显示时用。
        # 每次重绘都原样带上它的话，每按一次键就会
        # 不断插入换行，新行越来越多。
        (my $redraw_prompt = $prompt) =~ s/^\n+//;

        # 以只显示 redraw_prompt（buf 为空）时占几行作为初值。
        my $rows_used = (_pos_rc(_display_width_chars($redraw_prompt), $term_cols))[0] + 1;

        my $redraw = sub {
            # $buf 是 UTF-8 生字节。STDOUT 加着 :encoding(UTF-8) 层，
            # 不先解码成 Perl 字符串再写就会双重编码乱码。
            my $text   = decode('UTF-8', $buf, FB_DEFAULT);
            my $before = decode('UTF-8', substr($buf, 0, $pos), FB_DEFAULT);
            my $full_text   = $redraw_prompt . $text;
            my $full_width  = _display_width_chars($full_text);
            my $cursor_width = _display_width_chars($redraw_prompt . $before);

            # 按上次重绘用掉的行数把光标退回首行，然后从那里
            # 清到屏幕末尾。即使折成多行，只清最后一行的
            # "\r\x1b[K" 也清不掉前面的行，
            # 于是每输入一次就叠一层同样的字符串，
            # 这就是那个显示 bug 的原因。
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

        # 把误读进来的字节退回下一轮循环的 pushback
        # 队列。用于：当成多字节字符后续读进来的字节，其实并不是
        # continuation 字节格式（10xxxxxx）的情况。
        my @pending;
        my $read_one_byte = sub {
            return shift @pending if @pending;
            my $ch;
            my $n = sysread(STDIN, $ch, 1);
            return (defined $n && $n > 0) ? $ch : undef;
        };
        # Mac OS X 的 Terminal.app 在用 IME（日文输入等）确定
        # 文本时，会在每个字节前加 0x16（Ctrl-V。终端里传统上
        # 表示「下一个字符原样处理（LNEXT）」的字节）
        # 一起送过来。本程序在 raw mode 下自己处理输入，
        # 不解释 LNEXT，所以什么都不做的话
        # 这个标记字节本身会混进字符串里，UTF-8 就坏了、
        # 变成乱码。这里跳过 0x16，把下一个字节
        # 当真正的数据处理。
        my $read_byte = sub {
            my $ch = $read_one_byte->();
            if (defined $ch && $ch eq "\x16") {
                $ch = $read_one_byte->();
            }
            return $ch;
        };

        my $result;
        my $ctrld_seen = 0;   # 空行处的 Ctrl-D。第一次警告，两次就退出。
        RAW_LOOP: while (1) {
            my $ch = $read_byte->();
            if (!defined $ch) {
                _debug_log("EOF\n");
                dbg("readline: real EOF on STDIN");
                $result = undef;  # 真正的 EOF（标准输入被关闭）
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
            elsif ($b == 3) {                  # Ctrl-C: 取消本行，按空行处理
                print "\r\n";
                $result = '';
                last RAW_LOOP;
            }
            elsif ($b == 4) {                  # Ctrl-D
                # 防止误触一次就退出，空行里只有连按两次才算 EOF。
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
            elsif ($b == 27) {                  # ESC: 方向键等
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
                    elsif ($use_history && $c3 eq 'A') {  # ↑ 往历史里回退
                        if ($hist_idx > 0) {
                            $saved_buf = $buf if $hist_idx == @HISTORY;
                            $hist_idx--;
                            $buf = $HISTORY[$hist_idx];
                            $pos = length($buf);
                            $redraw->();
                        }
                    }
                    elsif ($use_history && $c3 eq 'B') {  # ↓ 往历史里前进
                        if ($hist_idx < @HISTORY) {
                            $hist_idx++;
                            $buf = ($hist_idx == @HISTORY) ? $saved_buf : $HISTORY[$hist_idx];
                            $pos = length($buf);
                            $redraw->();
                        }
                    }
                    elsif ($c3 eq '3') {         # Delete 键 (ESC [ 3 ~)
                        my $c4 = $read_byte->();
                        if (defined $c4 && $pos < length($buf)) {
                            substr($buf, $pos, _utf8_char_len(substr($buf, $pos, 1)), '');
                            $redraw->();
                        }
                    }
                }
            }
            else {                               # 普通字符（UTF-8 生字节）
                # 多字节字符中途（字节还不全）就重绘的话，
                # decode() 会把不完整的序列变成「�」，所以
                # 等一个字符的字节齐了再加进缓冲、重绘。
                # 但如果后续字节不是 UTF-8 的 continuation 字节
                # （10xxxxxx），那就是别的字符/按键的首字节，要读回去
                # （否则会误吞掉本来的输入，之后打什么都
                # 没反应）。
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
# 模式、可写范围、危险命令、shell 执行的公共部件
#
# 这里只放「往安全侧倒」的判定。判定失败时不能倒向危险侧
# （＝放行），一定要落到确认或拒绝。
# ------------------------------------------------------------------

# 把路径解析到实体（~ 展开 + 符号链接解析。还没创建就在父目录上解析）。
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

# 可写的默认根：当前目录 + 临时目录。
# 临时目录只要有 TMPDIR 就**只用它**（macOS 一定会设）。
# 以前总是把 /tmp 也算进去，测试以为造了「范围外」，
# 实际放在 /tmp 下面，能不能写就看环境 —— 判定不能带环境依赖。
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

# 写入是否在许可范围内（default 模式下不用它判定）。
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

# 危险命令。命中就返回理由标识（'' = 不危险）。
# 误报只是「多一次确认」，漏报却收不回来。
# 所以范围取宽一点。
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

# ---------------------------------------------------------------- 目录/文件操作
# bypass 模式下也要确认的「目录/文件操作」。
# 只放带破坏或移动的那些（touch、sed -i 这类「只写内容」的
# 不放 —— 那和 write_file 同等对待，bypass 下不确认）。
my %FS_MUTATION = map { $_ => 1 } qw(
    rm rmdir mv cp ln mkdir chmod chown chgrp dd truncate rsync
    tar zip unzip gzip gunzip install
);

# 返回值：命中的命令名（没有则 ''）。
# 按管道、&&、; 切分，只看每段开头的 token（跳过 sudo/env/xargs 这些
# 前缀和 -option 之后）。避免「echo rm」这种误报。
sub is_fs_mutation {
    my ($cmd) = @_;
    return '' unless defined $cmd && length $cmd;
    return 'find -delete' if $cmd =~ /\bfind\b[^\n|;]*\s-delete\b/;
    return 'git clean'    if $cmd =~ /\bgit\b[^\n|;]*\bclean\b/;
    for my $seg (split /\|\||&&|[;|\n]/, $cmd) {
        my @w = split /\s+/, $seg;
        shift @w while @w && $w[0] =~ /^[A-Za-z_][A-Za-z0-9_]*=/;
        my $i = 0;
        while ($i < @w) {
            my $t = $w[$i];
            $t =~ s{.*/}{};
            if ($t =~ /^(?:sudo|doas|env|nohup|xargs|command|time|nice|timeout|stdbuf|sh|bash|zsh|-c)$/) {
                $i++;
                next;
            }
            last unless $t =~ /^-/;
            $i++;
        }
        next if $i >= @w;
        my $name = $w[$i];
        $name =~ s{.*/}{};
        return $name if $FS_MUTATION{$name};
    }
    return '';
}

sub is_dangerous {
    my ($cmd) = @_;
    return '' unless defined $cmd && $cmd ne '';
    for my $rule (@DANGER_RULES) {
        return $rule->[1] if $cmd =~ $rule->[0];
    }
    # 管道和分隔符后面的开头 token 也看（`cat x | less` 会卡住）
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
# 从命令字符串里捡出「看起来是写入目标」的东西（保守·best effort）
#
# 不做完整的 shell 语法解析。能捡的捡，捡不到的
# 照旧交给「危险命令确认」。目的是堵住「只有 write_file 才受范围
# 约束」这个洞。cp/mv/rm/tee/重定向在实务上基本覆盖全了。
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

    # 1) 重定向（> / >> / 2> / &>）
    while ($cmd =~ /(?:^|[^0-9&>])>>?\s*([^\s;|&>()]+)/g) {
        my $t = $1;
        $t =~ s/^['"]//;
        $t =~ s/['"]$//;
        push @targets, $t;
    }

    # 2) 代表性命令的写入目标
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

# 返回 ('hard'|'scope', path)。相当于 ''（没有命中）时返回空列表。
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

# 执行 run_shell。带超时和输出上限。
#   * 输出先落到文件再读（不在内存里堆）
#   * 子进程放进独立进程组（npm 之类派生的孙进程也能确实停掉）
#   * 掐断时按 TERM → 0.5 秒 → KILL
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
# 自动批准的记录（~/.claude-agent/approvals.log）
#
# 和远程用的 audit.log 分成不同文件。一个是「外面谁问了什么」，
# 这个是「本地擅自做了什么」。混在一起两边都难读。
# ------------------------------------------------------------------
sub approvals_path { return ($ENV{HOME} || '.') . '/.claude-agent/approvals.log'; }

# ------------------------------------------------------------------
# 长期记忆与技能
#   两者都是 ~/.claude-agent/ 下的纯文本。不加密 ——
#   memory 每轮都要进 system prompt，每次启动都问密保
#   不划算。改为限制在 0600、位置在 ~/.claude-agent 下
#   （已 gitignore），并在 README 和手册里写明「以明文存放」。
# ------------------------------------------------------------------
# 上限取开头的 $MEMORY_MAX_CHARS（让 system_prompt 也能看到）

sub memory_path {
    my $e = $ENV{CLAUDE_MEMORY_FILE};
    return $e if defined $e && $e ne '';
    return ($ENV{HOME} || '.') . '/.claude-agent/memory.md';
}

sub skills_dir {
    my $e = $ENV{CLAUDE_SKILLS_DIR};
    return $e if defined $e && $e ne '';
    return ($ENV{HOME} || '.') . '/.claude-agent/skills';
}

# 返回值：(注入的正文, 全长, 是否截断)
sub read_memory {
    my $path = memory_path();
    return ('', 0, 0) unless -f $path;
    open(my $fh, '<:encoding(UTF-8)', $path) or return ('', 0, 0);
    local $/;
    my $raw = <$fh>;
    close $fh;
    $raw = '' unless defined $raw;
    $raw =~ s/\r\n/\n/g;
    $raw =~ s/\s+$//;
    my $total = length($raw);
    return ('', 0, 0) if $total == 0;
    if ($total > $MEMORY_MAX_CHARS) {
        my $cut = substr($raw, 0, $MEMORY_MAX_CHARS);
        $cut =~ s/\n[^\n]*$//;    # 不在行中间切
        $cut = $raw =~ /\n/ ? $cut : substr($raw, 0, $MEMORY_MAX_CHARS);
        return ($cut, $total, 1);
    }
    return ($raw, $total, 0);
}

# 纯正文（注入用时不做截断）。按行操作走这边。
sub read_memory_raw {
    my $path = memory_path();
    return '' unless -f $path;
    open(my $fh, '<:encoding(UTF-8)', $path) or return '';
    local $/;
    my $raw = <$fh>;
    close $fh;
    $raw = '' unless defined $raw;
    $raw =~ s/\r\n/\n/g;
    return $raw;
}

sub today_stamp {
    my @t = localtime;
    return sprintf('%04d-%02d-%02d', $t[5] + 1900, $t[4] + 1, $t[3]);
}

# 加一行。返回值：(是否成功, 显示给用户的文案)
sub memory_add {
    my ($fact) = @_;
    $fact = '' unless defined $fact;
    $fact =~ s/\s+/ /g;
    $fact =~ s/^\s+//; $fact =~ s/\s+$//;
    $fact =~ s/^[-*]\s*//;
    return (0, L('memory_add_empty')) if $fact eq '';

    my $path = memory_path();
    my $dir  = $path;
    $dir =~ s{/[^/]+$}{};
    if ($dir ne '' && !-d $dir) {
        mkdir $dir or return (0, L('memory_cannot_write', $dir, $!));
        chmod 0700, $dir;
    }

    my $raw = read_memory_raw();
    my $line = '- ' . $fact . '（' . today_stamp() . "）\n";
    my $base = $raw;
    $base =~ s/\s+$//;
    my $new = ($base eq '') ? $line : $base . "\n" . $line;
    if (length($new) > $MEMORY_MAX_CHARS) {
        return (0, L('memory_full', $MEMORY_MAX_CHARS, $path));
    }
    open(my $out, '>:encoding(UTF-8)', $path) or return (0, L('memory_cannot_write', $path, $!));
    print $out $new;
    close $out;
    chmod 0600, $path;
    return (1, L('memory_saved', $fact));
}

sub memory_clear {
    my $path = memory_path();
    open(my $out, '>:encoding(UTF-8)', $path) or return L('memory_cannot_write', $path, $!);
    close $out;
    chmod 0600, $path;
    return L('memory_cleared');
}

sub memory_remove_line {
    my ($n) = @_;
    my $raw = read_memory_raw();
    my @lines = split(/\n/, $raw, -1);
    pop @lines while @lines && $lines[-1] eq '';
    if ($n < 1 || $n > scalar(@lines)) {
        return L('memory_rm_bad', $n);
    }
    my $gone = $lines[$n - 1];
    splice(@lines, $n - 1, 1);
    my $path = memory_path();
    my $body = @lines ? join("\n", @lines) . "\n" : '';
    open(my $out, '>:encoding(UTF-8)', $path) or return L('memory_cannot_write', $path, $!);
    print $out $body;
    close $out;
    chmod 0600, $path;
    return L('memory_rm_done', $n, $gone);
}

sub print_memory {
    my $path = memory_path();
    my $raw  = read_memory_raw();
    my @lines = grep { length } split(/\n/, $raw);
    if (!@lines) {
        emit_note(L('memory_empty', $path));
        emit_note(L('memory_usage'));
        return;
    }
    emit_note(L('memory_head', $path, scalar(@lines), length($raw)));
    my $i = 0;
    for my $l (@lines) {
        $i++;
        emit_note(sprintf("%2d. %s\n", $i, $l));
    }
    if (length($raw) > $MEMORY_MAX_CHARS) {
        emit_note(L('memory_cut', $MEMORY_MAX_CHARS, $MEMORY_MAX_CHARS));
    }
}

# 把一条技能转成 {name, desc, path}。说明取 frontmatter 的 description，
# 没有就取第一个标题，再没有就取第一行非空行。
sub skill_entry {
    my ($name, $path) = @_;
    my $desc = '';
    if (open(my $fh, '<:encoding(UTF-8)', $path)) {
        my @lines;
        while (my $l = <$fh>) {
            $l =~ s/\r?\n$//;
            push @lines, $l;
        }
        close $fh;
        my $in_fm = 0;
        for my $i (0 .. $#lines) {
            my $l = $lines[$i];
            if ($i == 0 && $l =~ /^---\s*$/) { $in_fm = 1; next; }
            if ($in_fm) {
                last if $l =~ /^---\s*$/;
                if ($l =~ /^description\s*:\s*(.+?)\s*$/) { $desc = $1; last; }
                next;
            }
        }
        if ($desc eq '') {
            for my $l (@lines) {
                next if $l =~ /^\s*$/;
                next if $l =~ /^---\s*$/;
                if ($l =~ /^#+\s*(.+?)\s*$/) { $desc = $1; last; }
                $desc = $l if $desc eq '';
            }
        }
    }
    $desc =~ s/^["']//;
    $desc =~ s/["']$//;
    $desc =~ s/\s+/ /g;
    $desc =~ s/^\s+//; $desc =~ s/\s+$//;
    $desc = substr($desc, 0, 80) . '…' if length($desc) > 80;
    return { name => $name, desc => $desc, path => $path };
}

# 遍历 skills/。`<名字>/SKILL.md` 和 `<名字>.md` 都接受。
# 技能写入的校验（不落盘）：返回 (错误文案, 路径, 内容)。
# 先把「不能写」的情况全部判掉，再让调用方去问人 —— 不能问完才发现不合法。
sub skill_prepare {
    my ($name, $desc, $body) = @_;
    $name = '' unless defined $name;
    $desc = '' unless defined $desc;
    $body = '' unless defined $body;

    $name =~ s/^\s+//; $name =~ s/\s+$//;
    $desc =~ s/\s+/ /g; $desc =~ s/^\s+//; $desc =~ s/\s+$//;

    return (L('skill_name_bad'), undef, undef)
        if $name eq '' || length($name) > 32 || $name =~ m{[/\\]} || $name =~ /\.\./
           || $name =~ /^[.\s]/ || $name =~ /[\x00-\x1f]/;
    return (L('skill_desc_bad'), undef, undef) if $desc eq '' || length($desc) > 80;
    return (L('skill_body_bad'), undef, undef) if $body =~ /^\s*$/;
    return (L('skill_body_too_big', 20000), undef, undef) if length($body) > 20000;

    # 正文里若自带 frontmatter 就用它的，否则由我们补一份（技能列表只读 description）
    my $text = $body;
    unless ($text =~ /^---\s*\r?\n/) {
        $text = "---\nname: $name\ndescription: $desc\n---\n\n" . $body;
        $text .= "\n" unless $text =~ /\n$/;
    }
    my $dir  = skills_dir();
    my $path = "$dir/$name/SKILL.md";
    return ('', $path, $text);
}

sub skill_commit {
    my ($path, $text) = @_;
    my $dir = $path;
    $dir =~ s{/[^/]+$}{};
    unless (-d $dir) {
        my $top = skills_dir();
        mkdir $top or return (0, L('skill_cannot_write', $top, $!)) unless -d $top;
        chmod 0700, $top;
        mkdir $dir or return (0, L('skill_cannot_write', $dir, $!)) unless -d $dir;
        chmod 0700, $dir;
    }
    open(my $fh, '>:encoding(UTF-8)', $path) or return (0, L('skill_cannot_write', $path, $!));
    print $fh $text;
    close $fh;
    chmod 0600, $path;
    return (1, L('skill_saved', $path));
}

sub skills_list {
    my $dir = skills_dir();
    my @out;
    opendir(my $dh, $dir) or return @out;
    my @entries = sort grep { $_ ne '.' && $_ ne '..' } readdir($dh);
    closedir $dh;
    for my $e (@entries) {
        if (-d "$dir/$e") {
            my $p = "$dir/$e/SKILL.md";
            push @out, skill_entry($e, $p) if -f $p;
        }
        elsif ($e =~ /\.md$/i && -f "$dir/$e") {
            (my $name = $e) =~ s/\.md$//i;
            push @out, skill_entry($name, "$dir/$e");
        }
    }
    return @out;
}

sub print_skills {
    my $dir = skills_dir();
    my @sk = skills_list();
    unless (@sk) {
        emit_note(L('skills_none', $dir));
        return;
    }
    emit_note(L('skills_head', $dir, scalar(@sk)));
    for my $sk (@sk) {
        emit_note('- ' . $sk->{name} . ($sk->{desc} ne '' ? '：' . $sk->{desc} : '')
                  . "\n  " . $sk->{path} . "\n");
    }
}

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

# 可写目录的显示。$TMPDIR 各环境都是很长的内部路径（macOS 上是
# /var/folders/xx/.../T），原样打出来只是让人看不懂。
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
        # 记录一定要留。「谁在什么时候扩大了可写范围」后面会派上用场。
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

    # --tools 收窄过的话，范围外的这里也拦（已经从 @TOOLS 里删掉了
    # 所以通常到不了，但模型可能幻觉出不存在的工具名）。
    if (@TOOLS_ALLOWED) {
        my %ok = map { $_ => 1 } @TOOLS_ALLOWED;
        unless ($ok{$name}) {
            return L('tool_not_allowed', join(' / ', @TOOLS_ALLOWED), $name);
        }
    }

    if ($name eq 'write_skill') {
        # 技能一旦写下去，以后每一轮都会被注入名字+描述，等于长期改变行为，
        # 所以和记性一样：**任何模式都要人确认**（bypass 也不例外）。
        my $sk_name = (ref $input eq 'HASH' && defined $input->{name}) ? $input->{name} : '';
        my $sk_desc = (ref $input eq 'HASH' && defined $input->{description}) ? $input->{description} : '';
        my $sk_body = (ref $input eq 'HASH' && defined $input->{body}) ? $input->{body} : '';
        my ($bad, $sk_path, $sk_text) = skill_prepare($sk_name, $sk_desc, $sk_body);
        return $bad if defined $bad && $bad ne '';
        my $exists = (-f $sk_path) ? 1 : 0;
        my $prompt = $exists
            ? L('confirm_write_skill_over', $sk_name, $sk_path)
            : L('confirm_write_skill', $sk_name, $sk_path);
        unless (confirm($prompt, { strict => 1 })) {
            approvals_log('write_skill', $sk_name, 'refused');
            return L('skill_write_cancelled');
        }
        my ($ok2, $msg2) = skill_commit($sk_path, $sk_text);
        approvals_log('write_skill', $sk_name, $ok2 ? 'saved' : 'refused');
        return $msg2;
    }
    if ($name eq 'remember') {
        # 长期记忆在任何模式下都一定问人（bypass 也不例外）。
        # 记忆写下去之后一直生效，跳过确认会留下长期事故。
        my $fact = (ref $input eq 'HASH' && defined $input->{fact}) ? $input->{fact} : '';
        unless (confirm(L('confirm_remember', substr($fact, 0, 200)), { strict => 1 })) {
            approvals_log('remember', substr($fact, 0, 60), 'refused');
            return L('memory_save_cancelled');
        }
        my ($ok, $msg) = memory_add($fact);
        approvals_log('remember', substr($fact, 0, 60), $ok ? 'saved' : 'refused');
        return $msg;
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
        # 各模式下的处理：
        #   default      : 毎回確認
        #   accept-edits : 可写范围内自动，范围外确认（不直接拒绝）
        #   bypass       : 不确认。可写范围（白名单）**不生效**
        #                  —— 那个列表是给 accept-edits 决定「可以自动到
        #                  哪」用的。例外只有永久禁止的位置。
        my $auto = 0;
        if ($MODE ne 'default') {
            if (is_hard_denied_path($path)) {
                approvals_log('write_file', $path, 'denied_always');
                emit_note(L('write_always_denied', $path));
                return L('write_always_denied', $path);
            }
            if ($MODE eq 'bypass') {
                $auto = 1;
            }
            elsif (write_allowed($path)) {
                $auto = 1;
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
        # 经命令的写入也纳入可写范围管制（堵住只有 write_file 才
        # 受管的洞）。只处理能识别出来的，保守实现。
        my ($vkind, $vpath) = shell_scope_violation($command);
        $vkind = '' unless defined $vkind;
        $vpath = '' unless defined $vpath;

        # 往永久禁止位置的写入，bypass 下连问都不问直接拒绝
        # （和 write_file 侧同样处理。问了也是「不能允许」）。
        if ($MODE eq 'bypass' && $danger eq '' && $vkind eq 'hard') {
            approvals_log('run_shell', $command, 'refused_cmd_write_hard');
            emit_note(L('cmd_write_always_denied', $vpath));
            return L('cmd_write_always_denied', $vpath);
        }

        # 危险命令在任何模式都确认（bypass 也不例外）。
        # bypass 下还额外确认「目录/文件操作」（rm / mv / cp / chmod /
        # tar / unzip / find -delete 等）。反过来，可写范围（白
        # 名单）在 bypass 下不参与判定 —— 那是给 accept-edits 用的。
        my $fsop = is_fs_mutation($command);
        my $scope_ask = ($MODE eq 'bypass') ? 0 : (($vkind eq 'scope') ? 1 : 0);
        my $need_confirm;
        if ($MODE eq 'bypass') {
            $need_confirm = ($danger ne '' || $fsop ne '') ? 1 : 0;
        }
        else {
            $need_confirm = 1;
        }
        if ($need_confirm) {
            my $prompt = $danger ne ''
                ? L('confirm_run_shell_danger', $command)
                : $scope_ask
                    ? L('confirm_cmd_write_outside', $vpath, $command)
                    : $fsop ne ''
                        ? L('confirm_fs_op', $fsop, $command)
                        : L('confirm_run_shell', $command);
            my %opt = (danger => ($danger ne '' ? 1 : 0),
                       strict => (($danger ne '' || $scope_ask) ? 1 : 0));
            unless (confirm($prompt, \%opt)) {
                if ($danger ne '') {
                    approvals_log('run_shell', $command, 'refused_danger');
                    emit_note(L('danger_refused', danger_reason_text()));
                    return L('danger_refused', danger_reason_text());
                }
                if ($fsop ne '') {
                    approvals_log('run_shell', $command, 'refused_fs_op');
                    emit_note(L('fs_op_refused', $fsop, danger_reason_text()));
                    return L('fs_op_refused', $fsop, danger_reason_text());
                }
                if ($scope_ask) {
                    approvals_log('run_shell', $command, 'refused_cmd_write_scope');
                    emit_note(L('cmd_write_refused', $vpath, danger_reason_text()));
                    return L('cmd_write_refused', $vpath, danger_reason_text());
                }
                return L('run_cancelled');
            }
            approvals_log('run_shell', $command, 'confirmed_danger') if $danger ne '';
            approvals_log('run_shell', $command, 'confirmed_fs_op')
                if $fsop ne '' && $danger eq '';
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
# 会话循环
# ------------------------------------------------------------------
my @messages;

# --- 历史：加密 → 明文的切换（只在显式调用时做） ---
if ($MAKE_PLAIN) {
    exit make_plain_history();
}

# --- 历史：解锁 / 列表 / 继续 ---
if ($HISTORY_ENABLED) {
    $HISTORY_ENABLED = unlock_history();
}

if ($CHANGE_PASS) {
    unless ($HISTORY_ENABLED) { print L('history_unavailable'); exit 1; }
    if ($HIST_PLAIN) { print L('hist_plain_no_pass'); exit 0; }
    reset_passphrase($ENV{CLAUDE_HIST_PASS});   # unlock 之后 CLAUDE_HIST_PASS 里放的是主密钥
    exit 0;
}

if ($SET_RECOVERY) {
    unless ($HISTORY_ENABLED) { print L('history_unavailable'); exit 1; }
    if ($HIST_PLAIN) { print L('hist_plain_no_recovery'); exit 0; }
    set_recovery($ENV{CLAUDE_HIST_PASS});
    exit 0;
}

if ($LIST_HISTORY) {
    unless ($HISTORY_ENABLED) { print L('history_unavailable'); exit 1; }
    my @files = history_files();
    unless (@files) { print L('no_saved_conv'); exit 0; }
    my ($lines, $undecryptable) = history_lines();
    print "$_\n" for @$lines;
    # 明文运行却还留着加密历史时，补一行说明怎么打开
    print L('hist_skip_enc', $undecryptable) if $HIST_PLAIN && $undecryptable > 0;
    exit 0;
}

# --- --continue: 不显示菜单直接继续（指定名字就接那场） ---
if ($CONTINUE && !$RESUME) {
    unless ($HISTORY_ENABLED) { emit_error(L('history_unavailable')); exit 1; }
    my ($pick, $pick_data);
    for my $f (history_files()) {
        my $raw = hist_decrypt("$HISTORY_DIR/$f");
        next unless defined $raw;
        my $d = eval { MiniJSON::decode($raw) };
        next unless $d && $d->{messages} && @{ $d->{messages} };
        if ($CONTINUE_NAME ne '') {
            next unless defined $d->{name} && $d->{name} eq $CONTINUE_NAME;
        }
        $pick      = $f;
        $pick_data = $d;
        last;    # history_files 是新的在前
    }
    if ($pick) {
        @messages = @{ $pick_data->{messages} };
        $SESSION_FILE = "$HISTORY_DIR/$pick";
        $SESSION_NAME = $pick_data->{name}
            if $SESSION_NAME eq '' && defined $pick_data->{name};
        emit_note(L('continue_loaded',
                (defined $pick_data->{name} ? '[' . $pick_data->{name} . '] ' : ''),
                scalar(@messages)));
    }
    else {
        emit_note(L('continue_none',
                ($CONTINUE_NAME ne '' ? "（$CONTINUE_NAME）" : '')));
    }
}

# --- --search: 在已保存的对话里全文搜索并退出 ---
if ($SEARCH ne '') {
    unless ($HISTORY_ENABLED) { print L('history_unavailable'); exit 1; }
    print L('search_header', $SEARCH);
    my ($lines, $hits, $skipped) = search_history_lines($SEARCH);
    print "$_\n" for @$lines;
    print L('search_none', $SEARCH) if $hits == 0;
    print L('search_skipped', $skipped) if $skipped > 0;
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
        my $nm = ($d && defined $d->{name} && $d->{name} ne '') ? '[' . $d->{name} . '] ' : '';
        printf "  %2d) %s%s  %s\n", $i++, $nm,
            ($d ? ($d->{started} || $f) : $f),
            $d ? first_user_line($d) : L('unreadable_file', $f);
    }
    print L('resume_number');
    my $sel = <STDIN>;
    $sel = defined($sel) ? $sel + 0 : 1;
    $sel = 1 if $sel < 1 || $sel > scalar(@decoded);
    my $chosen = $decoded[$sel - 1];
    if ($chosen->{data} && $chosen->{data}{messages}) {
        @messages = @{ $chosen->{data}{messages} };
        $SESSION_FILE = "$HISTORY_DIR/" . $chosen->{file};   # 继续写进同一个文件
        print L('resuming_conv', scalar(@messages));
    } else {
        print L('could_not_load_new');
    }
}

# 新对话时的保存位置
if ($HISTORY_ENABLED && !$SESSION_FILE) {
    $SESSION_FILE = $HIST_PLAIN ? "$HISTORY_DIR/$STARTED.json"
                                : "$HISTORY_DIR/$STARTED.json.enc";
}

# --- GUI 模式：用 JSON 交互的循环（由 Python/tkinter 驱动） ---
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
        last unless defined $req;                       # GUI 已关闭 = EOF
        my $type = $req->{t} || '';
        last if $type eq 'quit';
        if ($type eq 'cwd') {
            # GUI 命令面板里 cd 到的目录，也反映到 AI 的工具上。
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
                # GUI 里也只确认一次。菜单项不能撤销，
                # 防止按错就进了无确认执行。
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
                $SESSION_FILE = $path;                     # 继续写进同一个文件
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

        $TURN_TEXTS = 0;
        $TURN_TOOLS = 0;
        my $r = eval { handle_turn($text) };
        if ($@) {
            dbg("turn error(gui): $@");
            emit_error(L('turn_failed'));
            pop @messages if @messages
                && ($messages[-1]{role} eq 'assistant' || ref $messages[-1]{content});
        }
        # ★ 一轮跑完却一条 text 都没有 → 网关会把它当成「没回复」（手机端啥也看不到）。
        #   补一条，把这一轮到底做了什么说清楚。
        if (!$TURN_TEXTS) {
            emit_text(L('turn_no_text', $TURN_TOOLS));
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
if (@MODEL_CHOICES && !$RESUME) {
    show_model_menu();
} else {
    # --resume 选完对话就弹厂商列表的话，用户会以为要输「继续的编号」
    # 而误按，接着就进到等密钥输入（真的发生过）。恢复时只显示
    # 当前组合，想切换的人提示用 /model。
    print "[$PROVIDER / $MODEL]\n";
    print L('model_switch_hint') if $RESUME && @MODEL_CHOICES;
}
print L('greeting');

# 处理一轮。返回 'quit' 就结束对话，其余继续。
# 这里 die 了，调用方的 eval 会接住，程序不会崩。
sub handle_turn {
    my ($input) = @_;
    dbg("turn start: msgs=" . scalar(@messages) . " input=" . substr($input, 0, 80));

    return 'quit' if $input eq 'exit';

    # 受限会话不接受配置类命令（对话照常放行）。
    if ($NO_CONFIG) {
        my $pcmd = ($input =~ m{^/([a-z][a-z0-9_]*)\s*$}) ? provider_from_command($1) : '';
        if ($pcmd ne ''
            || $input =~ m{^/(?:model|models|mode|allow-write|key|memory|remember|skills|name|history|search)\b}) {
            # 受限会话（远程/嵌入式）里这是一句"给对面看的回答"，不是本地提示，
            # 所以走 text 事件：网关与平台只把 text / error 当回复带走。
            if ($GUI) { gui_send({ t => 'text', text => L('config_locked') }); }
            else      { print L('config_locked'); }
            return;
        }
    }

    # 切到 bypass 之前「让人打 yes」的等待。
    # /mode bypass 一次就立刻切换的话，手指一滑就进了无确认执行，
    # 所以这里要输两次。
    if ($PENDING_MODE ne '') {
        my $want = $PENDING_MODE;
        $PENDING_MODE = '';
        my $a = $input;
        $a =~ s/^\s+//; $a =~ s/\s+$//;
        if ($a =~ /^(yes|はい|是)$/i) { apply_mode($want); }
        else { emit_note(L('mode_bypass_cancelled')); }
        return;
    }

    # /memory、/remember、/skills 也一样在这里处理完（不交给模型）。
    if ($input =~ m{^/memory\s*$}) {
        print_memory();
        return;
    }
    if ($input =~ m{^/memory\s+clear\s*$}) {
        if (confirm(L('memory_clear_confirm'), { strict => 1 })) {
            emit_note(memory_clear());
        } else {
            emit_note(L('memory_clear_kept'));
        }
        return;
    }
    if ($input =~ m{^/memory\s+rm\s+(\d+)\s*$}) {
        emit_note(memory_remove_line($1));
        return;
    }
    if ($input =~ m{^/memory\s+(.+?)\s*$}) {
        emit_note(L('memory_usage'));
        return;
    }
    if ($input =~ m{^/remember\s+(.+?)\s*$}) {
        my ($ok, $msg) = memory_add($1);
        emit_note($msg);
        approvals_log('remember', substr($1, 0, 60), $ok ? 'saved' : 'refused');
        return;
    }
    if ($input =~ m{^/remember\s*$}) {
        emit_note(L('memory_usage'));
        return;
    }
    if ($input =~ m{^/skills\s*$}) {
        print_skills();
        return;
    }

    # /name、/history、/search 也一样在这里处理完（不交给模型）。
    if ($input =~ m{^/name\s*$}) {
        emit_note(L('name_usage',
                    ($SESSION_NAME ne '' ? $SESSION_NAME : L('name_current_none'))));
        return;
    }
    if ($input =~ m{^/name\s+(.+?)\s*$}) {
        my $nm = $1;
        # 不用于文件名，所以只轻度整理会进历史 JSON 的字符
        $nm =~ s/[\r\n\t]+/ /g;
        unless ($HISTORY_ENABLED) { emit_note(L('history_unavailable')); return; }
        $SESSION_NAME = $nm;
        save_history(\@messages) if @messages;   # 已有文件也立即反映（没有就等下次保存）
        approvals_log('name', substr($nm, 0, 60), 'set');
        emit_note(L('name_set', $nm));
        return;
    }
    if ($input =~ m{^/history\s*$}) {
        unless ($HISTORY_ENABLED) { emit_note(L('history_unavailable')); return; }
        my ($lines, $undecryptable) = history_lines();
        if (!@$lines) { emit_note(L('no_saved_conv')); return; }
        emit_note($_) for @$lines;
        emit_note(L('hist_skip_enc', $undecryptable)) if $undecryptable > 0;
        emit_note(L('history_hint_continue'));
        return;
    }
    if ($input =~ m{^/search\s*$}) {
        emit_note(L('search_usage'));
        return;
    }
    if ($input =~ m{^/search\s+(.+?)\s*$}) {
        unless ($HISTORY_ENABLED) { emit_note(L('history_unavailable')); return; }
        my $word = $1;
        my ($lines, $hits, $skipped) = search_history_lines($word);
        emit_note(L('search_header', $word));
        if ($hits == 0) { emit_note(L('search_none', $word)); }
        else { emit_note($_) for @$lines; }
        emit_note(L('search_skipped', $skipped)) if $skipped > 0;
        return;
    }

    # /mode、/allow-write、/approvals 不交给模型，在这里处理完。
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

    # 列出列表（仅终端。GUI 启动时已收到列表）
    if ($input eq '/model' || $input eq '/models' || $input eq '/m' || $input eq '?') {
        show_model_menu() unless $GUI;
        return;
    }

    # 处在两步菜单途中时，数字当作对当前这一步的回答。
    # 这一步只在「当下这一瞬间」有效 —— 来了别的输入就丢掉（防止旧的
    # 步骤残留，下一个数字莫名其妙变成切换模型）。
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
        # 来的不是数字 = 离开菜单，走普通操作
    }

    # 只打数字就切到那个编号的 AI（对人最友好的操作）
    if ($input =~ /^\s*(\d+)\s*$/ && @MODEL_CHOICES) {
        my $n = $1;
        if ($n >= 1 && $n <= @MODEL_CHOICES) {
            my $id = $MODEL_CHOICES[$n - 1][0];
            ($id eq $MODEL)
                ? emit_note(L('already_on', $PROVIDER, $MODEL))
                : switch_to_model($id);
            return;
        }
        # 范围外的数字当作普通发言（往下走）
    }

    # /model 3 或 /model <ID> 也能指定
    # ---- /key：密钥配置的唯一会话内入口（切换模型不夹带密钥输入）----
    if ($input =~ m{^/key(?:\s+(.+?))?\s*$}) {
        my $arg = defined $1 ? $1 : '';
        if ($arg eq '') {
            print L('key_cmd_head');
            my $i = 0;
            for my $p (@PROVIDER_ORDER) {
                $i++;
                printf("  %2d  %-24s %s\n", $i, provider_label($p),
                       provider_has_key($p) ? L('key_cmd_have') : L('key_cmd_missing'));
            }
            print L('key_cmd_usage');
            return;
        }
        # 厂商名或菜单编号都认
        my $target = $arg;
        if ($arg =~ /^\d+$/ && $arg >= 1 && $arg <= @PROVIDER_ORDER) {
            $target = $PROVIDER_ORDER[$arg - 1];
        }
        elsif (provider_from_command(lc $arg) ne '') {
            $target = provider_from_command(lc $arg);
        }
        unless (grep { $_ eq $target } @PROVIDER_ORDER) {
            print L('key_cmd_unknown', $arg);
            print L('key_cmd_usage');
            return;
        }
        if ($GUI) {
            emit_error(L('key_cmd_gui', $ENV_FILE_PATH));
            return;
        }
        my $kenv = provider_info($target, 'key_env');
        my $kurl = provider_info($target, 'key_url');
        print L('key_cmd_where', provider_label($target), $kurl) if $kurl ne '';
        my $key = read_secret(L('key_cmd_prompt'));
        if (!defined $key || $key eq '') {
            print L('key_cmd_empty');
            return;
        }
        my $old = $ENV{$kenv};
        $ENV{$kenv} = $key;
        if ($target eq $PROVIDER) {
            eval { configure_provider($PROVIDER) };   # 立即对当前会话生效
        }
        print L('key_cmd_save_prompt', $ENV_FILE_PATH);
        my $yn = <STDIN>;
        if (defined $yn && $yn =~ /^y/i) {
            persist_env($kenv, $key);
            print L('key_cmd_saved', $ENV_FILE_PATH);
        }
        else {
            print L('key_cmd_not_saved');
        }
        return;
    }

    if ($input =~ m{^/models?\s+(\S.*?)\s*$}) {
        my $arg = $1;
        my $id = ($arg =~ /^\d+$/ && @MODEL_CHOICES && $arg >= 1 && $arg <= @MODEL_CHOICES)
            ? $MODEL_CHOICES[$arg - 1][0] : $arg;
        ($id eq $MODEL)
            ? emit_note(L('already_on', $PROVIDER, $MODEL))
            : switch_to_model($id);
        return;
    }

    # 只切换厂商（/claude /gemini /openai /deepseek /qwen /kimi /glm ...）
    # 不认识的名字（/foo 等）不在这里拦，往下当普通发言放走。
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
        my $json_body = MiniJSON::encode($body);
        my $resp = eval { call_api($API_URL, build_headers(), $json_body) };
        if ($@) {
            # ★ 先把错误存下来：下面为了取诊断信息还会 eval，$@ 会被冲掉
            #   （踩过：报错文案变成空的，什么都看不到）。
            my $err = $@;
            # ★ 厂商报「messages[N].content 不合规」时，把第 N 条到底长什么样记下来：
            #   历史动辄几百条，没有这条线索就只能靠猜（真发生过两次）。
            if ($err =~ /messages\[(\d+)\]/) {
                my $idx = $1;
                my $parsed = eval { MiniJSON::decode($json_body) };
                my $m = (defined $parsed && ref $parsed eq 'HASH')
                    ? $parsed->{messages}[$idx] : undef;
                if (ref $m eq 'HASH') {
                    my $c = $m->{content};
                    my $kind = !defined $c ? 'null'
                             : ref $c   ? ref($c)
                             : 'string(' . length($c) . ')';
                    emit_note("（厂商指认的第 $idx 条消息：role="
                        . (defined $m->{role} ? $m->{role} : '?')
                        . " content=$kind"
                        . (ref $m->{tool_calls} eq 'ARRAY' ? ' 带 ' . scalar(@{ $m->{tool_calls} }) . ' 个工具调用' : '')
                        . "）");
                }
            }
            # 通信错误等。是纯用户发言的那一轮就撤销并返回
            # （在工具应答途中就保留，别弄坏历史）。
            emit_error($err);
            pop @messages if @messages && !ref $messages[-1]{content};
            return;
        }

        my @content_blocks = eval { parse_response($resp) };
        if ($@) {
            emit_error($@);
            pop @messages if @messages && !ref $messages[-1]{content};
            return;
        }

        # 空响应（安全过滤、token 上限导致没有正文等）。空 assistant
        # 轮进了历史之后会一直坏，所以不写进去直接返回。
        # 只有 thought（思考中）的 text 时，用户什么也看不到
        # 就默默结束了，同样处理。
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
                $TURN_TOOLS++;
                my $result = eval { run_tool($block->{name}, $block->{input}) };
                $result = L('tool_error', $@) if $@;
                push @tool_results, {
                    type        => 'tool_result',
                    tool_use_id => $block->{id},
                    name        => $block->{name},   # Gemini 按名字对应结果
                    content     => $result,
                };
            }
        }

        if (@tool_results) {
            push @messages, { role => 'user', content => \@tool_results };
            next; # 把工具结果发回去再调一次 API
        }
        return; # 没有 tool_use 这一轮就结束
    }
}

# --- 主循环 ---
# 每轮都用 eval 包住，不管在哪里 die 都不让整个程序崩，
# 回到输入提示符。终端设置也每次保险起见还原一遍。
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
    # 空行基本是「输入失误」，丢掉。但模型选择菜单途中
    # 要当「Enter 取消」送进去，所以还有未完成步骤时放行。
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
        # 退回一条不完整的历史，好从下一句继续。
        pop @messages if @messages
            && ($messages[-1]{role} eq 'assistant' || ref $messages[-1]{content});
        next;
    }
    last if defined $r && $r eq 'quit';

    eval { save_history(\@messages) if $HISTORY_ENABLED };
    dbg("save_history error: $@") if $@;
}

print L('farewell');
