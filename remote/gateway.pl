#!/usr/bin/env perl
# -*- coding: utf-8 -*-
#
# remote/gateway.pl —— 远程网关
#
# 它是「平台 ↔ agent」之间唯一的一层。agent 本体完全不知道远程的存在：
# 网关只是用 --rpc（= --gui 的 JSON 行协议）+ --tools 收窄能力去驱动它。
# 删掉整个 remote/ 目录，本地功能一字不变。
#
# 用法：
#   perl remote/gateway.pl --stdin
#       从标准输入读 JSON 行，每条 {"from":"ID","text":"..."} 处理一条，
#       结果打印成 {"from":"ID","reply":"..."}。给测试和调试用。
#
#   perl remote/gateway.pl --once --from ID --text "..."
#       处理一条就退出。
#
# 配置 ~/.claude-agent/remote.conf（KEY = VALUE，# 注释）：
#   ALLOW = ou_xxx, userid_yyy     白名单。**不配就是谁也不许**（fail-closed）
#   NOTIFY = 1                     处理完把结果推到档①通知（默认 1）
#   HIST_PASS = ...                远程历史口令
#   HIST_RECOVERY = 问题|答案        远程历史的密保问题（两者都配才会真的写历史）
#   AGENT_ENV_FILE = /path         agent 的模型/密钥来源，默认 ~/.claude-agent-env
#   LANG = zh                      agent 的回复语言（zh/en/ja，默认 zh）
#
# ★ 安全上「写死、不可配置」的部分（这是刻意的，不做成开关）：
#     · 工具集固定为 read_file, list_dir —— 远程没有本地那个人按 y/n
#     · 历史目录固定 ~/.claude-agent/history-remote —— 与本地历史分开
#     · 审计日志 ~/.claude-agent/audit.log，只追加
#
# 零 CPAN：核心模块 + curl。
use strict;
use warnings;
use utf8;
use Encode qw(decode);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use IPC::Open3 qw(open3);
use Symbol qw(gensym);

binmode STDOUT, ':encoding(UTF-8)';
# ★ 逐行刷出：stdin 模式下我们靠「一行一问一答」跟调用方对话（长连接适配器、测试），
#   缓冲住就等于永远不回话 —— 尤其是确认问答（ask）必须立刻到手机。
$| = 1;
binmode STDERR, ':encoding(UTF-8)';

my $SCRIPT_DIR   = dirname(dirname(Cwd_abs($0)));
my $AGENT        = (defined $ENV{CLAUDE_AGENT} && $ENV{CLAUDE_AGENT} ne "")
    ? $ENV{CLAUDE_AGENT}                      # 仅测试用：换成假 agent
    : "$SCRIPT_DIR/agent/claude-agent.pl";
my $NOTIFY       = "$SCRIPT_DIR/remote/notify.pl";
my $CONF_PATH    = (defined $ENV{CLAUDE_REMOTE_CONF} && $ENV{CLAUDE_REMOTE_CONF} ne '')
    ? $ENV{CLAUDE_REMOTE_CONF}
    : "$ENV{HOME}/.claude-agent/remote.conf";
my $AUDIT_PATH   = "$ENV{HOME}/.claude-agent/audit.log";
my $REMOTE_HIST  = "$ENV{HOME}/.claude-agent/history-remote";

# ★ 远程权限：**只由启动参数决定**，远程端（手机）无法更改。
#   不传参数 → 只读（历史行为，默认）
#   --mode=accept-edits  → 可写范围内的 write_file 自动，run_shell 每次问
#   --mode=bypass        → 普通写与命令自动，危险命令仍问
#   --allow-write=<dir>  → 可写目录白名单（可重复或逗号分隔）
#   想加工具仍然要改这里的代码并 review；配置文件和聊天消息都不是入口。
my @REMOTE_TOOLS_READONLY = qw(read_file list_dir);
my @REMOTE_TOOLS_WRITABLE = qw(read_file list_dir write_file run_shell);
my $REMOTE_WRITE_MODE = '';            # '' = 未指定 → default（只读）
my @REMOTE_ROOTS;                      # --allow-write 的目录
my $CONFIRM_WAIT = 120;                # 远程确认最多等多久（秒），超时按拒绝
my $L_CONFIRM_PLAIN = '(需要确认的操作)';

sub write_mode_ok {
    my ($m) = @_;
    return ($m eq 'default' || $m eq 'accept-edits' || $m eq 'bypass') ? 1 : 0;
}

sub writable_mode {
    return ($REMOTE_WRITE_MODE eq 'accept-edits' || $REMOTE_WRITE_MODE eq 'bypass') ? 1 : 0;
}

sub effective_tools {
    return writable_mode() ? @REMOTE_TOOLS_WRITABLE : @REMOTE_TOOLS_READONLY;
}

sub Cwd_abs {
    my ($p) = @_;
    require Cwd;
    my $a = Cwd::abs_path($p);
    return defined $a ? $a : $p;
}

# ---------------------------------------------------------------- 审计
# 只追加。这里不提供删除/改写接口 —— 有删除能力的审计不叫审计。
sub audit {
    my ($kind, @rest) = @_;
    my @t = localtime;
    my $stamp = sprintf('%04d-%02d-%02d %02d:%02d:%02d',
                        $t[5] + 1900, $t[4] + 1, @t[3, 2, 1, 0]);
    my $body = join(' ', map { defined $_ ? $_ : '' } @rest);
    $body =~ s/\s+/ /g;
    $body = substr($body, 0, 300) . '...' if length($body) > 300;
    make_path(dirname($AUDIT_PATH)) unless -d dirname($AUDIT_PATH);
    my $fresh = !-e $AUDIT_PATH;
    if (open(my $af, '>>:encoding(UTF-8)', $AUDIT_PATH)) {
        print $af "[$stamp] $kind $body\n";
        close $af;
        chmod 0600, $AUDIT_PATH if $fresh;
    }
}

# ---------------------------------------------------------------- 配置
sub read_conf {
    my %c;
    if (open(my $fh, '<:encoding(UTF-8)', $CONF_PATH)) {
        while (my $l = <$fh>) {
            chomp $l;
            $l =~ s/\r$//;
            next if $l =~ /^\s*$/ || $l =~ /^\s*#/;
            next unless $l =~ /^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$/;
            my ($k, $v) = (uc $1, $2);
            $v =~ s/^["']//;
            $v =~ s/["']$//;
            $c{$k} = $v;
        }
        close $fh;
    }
    return \%c;
}

sub allow_set {
    my ($conf) = @_;
    my $raw = $ENV{CLAUDE_REMOTE_ALLOW};
    $raw = $conf->{ALLOW} unless defined $raw && $raw =~ /\S/;
    my %a;
    if (defined $raw) {
        for my $id (split /[,\s]+/, $raw) {
            next unless $id =~ /\S/;
            $a{$id} = 1;
        }
    }
    return \%a;
}

# ~/.claude-agent-env の export K=V を読む（agent に渡すモデル/キー）
sub read_agent_env {
    my ($path) = @_;
    my %e;
    open(my $fh, '<:encoding(UTF-8)', $path) or return \%e;
    while (my $l = <$fh>) {
        chomp $l;
        next unless $l =~ /^\s*export\s+([A-Za-z_][A-Za-z0-9_]*)=(.*)$/;
        my ($k, $v) = ($1, $2);
        $v =~ s/^["']//;
        $v =~ s/["']$//;
        $e{$k} = $v;
    }
    close $fh;
    return \%e;
}

# ---------------------------------------------------------------- JSON 行
sub json_escape {
    my ($s) = @_;
    return '' unless defined $s;
    $s =~ s/\\/\\\\/g;
    $s =~ s/"/\\"/g;
    $s =~ s/\n/\\n/g;
    $s =~ s/\r/\\r/g;
    $s =~ s/\t/\\t/g;
    $s =~ s/[\x00-\x1f]//g;
    return $s;
}

# 値が文字列だけの素朴な JSON を読む（この用途では入れ子不要）。
sub json_get {
    my ($line, $key) = @_;
    return undef unless defined $line;
    return $1 if $line =~ /"\Q$key\E"\s*:\s*"((?:[^"\\]|\\.)*)"/;
    return undef;
}

sub json_unescape {
    my ($s) = @_;
    return '' unless defined $s;
    $s =~ s/\\n/\n/g;
    $s =~ s/\\r/\r/g;
    $s =~ s/\\t/\t/g;
    $s =~ s/\\"/"/g;
    $s =~ s/\\\\/\\/g;
    return $s;
}

# ---------------------------------------------------------------- 会话
# 送信者ごとに agent プロセスを1本持つ（会話の文脈を保つため）。
# 落ちていたら作り直す。
my %SESS;

sub spawn_session {
    my ($from, $conf) = @_;
    my $envfile = $conf->{AGENT_ENV_FILE} || "$ENV{HOME}/.claude-agent-env";
    my $aenv = read_agent_env($envfile);

    my %env = (%ENV, %$aenv);
    $env{CLAUDE_HISTORY_DIR} = $REMOTE_HIST;
    # 远程过来的是中文平台（企微/飞书）。老 Mac 上的 Agent 会去看 AppleLocale，
    # 在日本语系统的机器上就会用日文回中文提问 —— 所以这里显式定语言。
    $env{CLAUDE_LANG} = (defined $conf->{LANG} && $conf->{LANG} =~ /^(zh|ja|en)/)
        ? lc($1) : 'zh';
    if (defined $conf->{HIST_PASS} && $conf->{HIST_PASS} =~ /\S/) {
        $env{CLAUDE_HIST_PASS} = $conf->{HIST_PASS};
    }
    else {
        # 远程历史口令没配就不写历史 —— 半吊子的加密不如没有。
        $env{CLAUDE_NO_HISTORY} = '1';
    }

    my $errh = gensym;
    my ($in, $out);
    local %ENV = %env;
    my $pid = eval {
        # --no-config：远程会话只对话。厂商/模型/模式/可写范围/密钥一律在本机配好，
        # 这里连命令入口都不给（密钥更不该经第三方聊天平台转一圈）。
        my @extra;
        push @extra, '--mode=' . $REMOTE_WRITE_MODE if $REMOTE_WRITE_MODE ne '';
        push @extra, ('--allow-write=' . $_) for @REMOTE_ROOTS;
        open3($in, $out, $errh, 'perl', $AGENT, '--rpc', '--no-config',
              '--tools=' . join(',', effective_tools()), @extra);
    };
    if (!$pid) {
        audit('session_spawn_failed', "from=$from", "err=$@");
        return undef;
    }
    # 子プロセスとのやり取りは UTF-8。層を付けないと、子が書いた UTF-8 バイトを
    # 「バイト列」として受け取り、STDOUT の :encoding(UTF-8) でもう一度符号化して
    # 二重変換（文字化け）になる。
    binmode($in,  ':encoding(UTF-8)');
    binmode($out, ':encoding(UTF-8)');

    # 起動直後のイベント（ready / need_passphrase）を読み切る
    my $ready = 0;
    while (my $l = <$out>) {
        $l =~ s/\r?\n$//;
        if ($l =~ /"t"\s*:\s*"need_passphrase"/) {
            my $pw = (defined $conf->{HIST_PASS}) ? $conf->{HIST_PASS} : '';
            print $in qq|{"t":"passphrase","value":"| . json_escape($pw) . qq|"}\n|;
            next;
        }
        if ($l =~ /"t"\s*:\s*"need_recovery"/) {
            # 初回の履歴作成ではパスフレーズに加えて合言葉(復旧用)が要る。
            # 応答しないと子は待ち続け、こちらは ready を待ち続けて固まる。
            # 未設定なら空で返す → 子は KEY_FILE を捨てて「履歴なし」で進む
            # （中途半端な暗号化履歴を残さないため。これは子側の既定動作）。
            my ($q, $a) = ('', '');
            if (defined $conf->{HIST_RECOVERY} && $conf->{HIST_RECOVERY} =~ /^(.*?)\|(.*)$/s) {
                $q = $1;
                $a = $2;
            }
            audit('recovery_answered', "from=$from", ($q ne '' ? 'set' : 'empty'));
            print $in qq|{"t":"recovery","question":"| . json_escape($q)
                     . qq|","answer":"| . json_escape($a) . qq|"}\n|;
            next;
        }
        if ($l =~ /"t"\s*:\s*"ready"/) { $ready = 1; last; }
    }
    unless ($ready) {
        audit('session_not_ready', "from=$from");
        close $in; close $out; waitpid($pid, 0);
        return undef;
    }
    # ★ 子プロセスの標準入力は自動フラッシュにする。これが無いと書き込んだ
    # 1行がバッファに残り、こちらは返事を待ち、あちらは指示を待つ —— 相互
    # ブロックで永久に止まる（実測で踏んだ）。
    my $prev = select($in);
    $| = 1;
    select($prev);

    $SESS{$from} = { pid => $pid, in => $in, out => $out, err => $errh, conf => $conf };
    audit('session_start', "from=$from", "pid=$pid", 'tools=' . join(',', effective_tools()),
          'mode=' . ($REMOTE_WRITE_MODE ne '' ? $REMOTE_WRITE_MODE : 'default'),
          'roots=' . (@REMOTE_ROOTS ? join(':', @REMOTE_ROOTS) : '-'),
          'no_config=1');
    return $SESS{$from};
}

sub ensure_session {
    my ($from, $conf) = @_;
    my $s = $SESS{$from};
    if ($s) {
        return $s if kill(0, $s->{pid});
        audit('session_dead', "from=$from", "pid=$s->{pid}");
        delete $SESS{$from};
    }
    return spawn_session($from, $conf);
}

# 远程确认：把 agent 的 y/n 问题转给手机，等这个人的下一条输入当答案。
# 通道仍是「一行一次」：先吐一行 ask，再读一行 answer。
# 超时按拒绝（与 agent 侧 fail-closed 一致），绝不放行。
sub ask_remote {
    my ($from, $prompt, $danger) = @_;
    print '{"from":"' . json_escape($from) . '","ask":"' . json_escape($prompt)
        . '","danger":' . ($danger ? 1 : 0) . "}\n";
    audit('confirm_asked', "from=$from", 'danger=' . $danger, 'wait=' . $CONFIRM_WAIT);
    my $ans = 'n';
    my $timed_out = 0;
    eval {
        local $SIG{ALRM} = sub { die "ask_timeout\n" };
        alarm $CONFIRM_WAIT if $CONFIRM_WAIT > 0;
        my $line = <STDIN>;
        if (defined $line) {
            my $v = json_get($line, 'answer') // '';
            $ans = 'y' if ($v =~ /^(y|yes|1|true)$/i);
        }
        alarm 0;
        1;
    } or do { alarm 0; $timed_out = 1 };
    audit('confirm_answered', "from=$from", 'answer=' . $ans,
          ($timed_out ? 'timeout=1' : ''));
    return $ans;
}

# 1件処理して、返信テキストを返す。失敗時は undef。
sub handle_message {
    my ($from, $text, $conf) = @_;
    my $s = ensure_session($from, $conf) or return undef;

    print { $s->{in} } qq|{"t":"user","text":"| . json_escape($text) . qq|"}\n|;

    my @texts;
    my $out = $s->{out};          # <{ ... }> は書式として通らないので一度受ける
    # 子プロセスが黙り込んだら永久に待たない（モデル側の無限ループ・ネットワーク
    # 停止など）。時間切れは子を落として次回作り直す。
    my $timed_out = 0;
    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm 180;
        while (my $l = <$out>) {
            $l =~ s/\r?\n$//;
            next if $l eq '';
            if ($l =~ /"t"\s*:\s*"tool"/) {
                my $name = json_get($l, 'name') // '?';
                audit('tool', "from=$from", "name=$name");
                next;
            }
            if ($l =~ /"t"\s*:\s*"text"/) {
                my $t = json_unescape(json_get($l, 'text') // '');
                push @texts, $t if $t =~ /\S/;
                next;
            }
            if ($l =~ /"t"\s*:\s*"confirm"/) {
                my $prompt = json_unescape(json_get($l, 'prompt') // $L_CONFIRM_PLAIN);
                my $danger = ($l =~ /"danger"\s*:\s*true/) ? 1 : 0;
                my $ans = 'n';
                if (writable_mode()) {
                    $ans = ask_remote($from, $prompt, $danger);
                }
                else {
                    # 只读模式本不该出现确认（写/命令没广告出去）；来了就拒，别打扰手机
                    audit('confirm_refused', "from=$from", 'readonly');
                }
                # ★ 回应键必须是 "reply"：agent 的 confirm() 只认这个。
                #   以前这里写的是 "confirm_answer"，等于没人回答 —— 只读模式下看不出来，
                #   一旦放开写就会一路等到超时（fail-closed 拒掉）。
                print { $s->{in} } qq|{"t":"reply","value":"$ans"}\n|;
                next;
            }
            if ($l =~ /"t"\s*:\s*"error"/) {
                my $t = json_unescape(json_get($l, 'text') // 'error');
                push @texts, $t;
                next;
            }
            last if $l =~ /"t"\s*:\s*"turn_done"/;
            last if $l =~ /"t"\s*:\s*"bye"/;
        }
        alarm 0;
        1;
    } or do {
        alarm 0;
        $timed_out = 1;
        audit('turn_timeout', "from=$from", "err=$@");
        kill 'KILL', $s->{pid};
        delete $SESS{$from};
    };
    return undef if $timed_out;

    my $reply = join("\n", @texts);
    audit('reply', "from=$from", 'len=' . length($reply));
    return $reply;
}

# ---------------------------------------------------------------- 通知
sub push_notify {
    my ($text) = @_;
    return unless defined $text && $text =~ /\S/;
    my $pid = open(my $ph, '-|');
    return unless defined $pid;
    if (!$pid) {
        exec('perl', $NOTIFY, $text) or exit 127;
    }
    while (my $l = <$ph>) { }   # 出力は使わないが読み切る（SIGPIPE 回避）
    close $ph;
}

# ---------------------------------------------------------------- 入口
my ($MODE, $ONCE_FROM, $ONCE_TEXT) = ('', '', '');
while (my $a = shift @ARGV) {
    if    ($a eq '--stdin')        { $MODE = 'stdin'; }
    elsif ($a eq '--once')         { $MODE = 'once'; }
    elsif ($a eq '--from')         { $ONCE_FROM = shift @ARGV; }
    elsif ($a eq '--text')         { $ONCE_TEXT = shift @ARGV; }
    elsif ($a =~ /^--mode=(.*)$/)  { $REMOTE_WRITE_MODE = lc $1; }
    elsif ($a eq '--mode')         { $REMOTE_WRITE_MODE = lc(shift @ARGV // ''); }
    elsif ($a =~ /^--allow-write=(.*)$/) { push @REMOTE_ROOTS, grep { length } split /,/, $1; }
    elsif ($a eq '--allow-write')  { push @REMOTE_ROOTS, grep { length } split /,/, (shift @ARGV // ''); }
    elsif ($a =~ /^--confirm-wait=(\d+)$/) { $CONFIRM_WAIT = $1; }
    elsif ($a eq '--help' || $a eq '-h') {
        print "用法: gateway.pl --stdin | --once --from ID --text \"...\"\n"
          . "      [--mode=default|accept-edits|bypass] [--allow-write=DIR[,DIR]] [--confirm-wait=秒]\n";
        exit 0;
    }
    else {
        print STDERR "未知の引数: $a\n";
        exit 2;
    }
}

my $conf  = read_conf();
my $allow = allow_set($conf);
my $notify_on = (exists $conf->{NOTIFY} && $conf->{NOTIFY} =~ /^0$/) ? 0 : 1;

audit('gateway_start', "mode=$MODE", 'allow=' . scalar(keys %$allow),
      'mode=' . ($REMOTE_WRITE_MODE ne '' ? $REMOTE_WRITE_MODE : 'default'),
      'tools=' . join(',', effective_tools()));
unless (keys %$allow) {
    audit('allowlist_empty', "conf=$CONF_PATH");
    print STDERR "白名单为空：所有消息都会被丢弃。请在 $CONF_PATH 里写 ALLOW = <id>,<id>\n";
}

# 送信者を確認する。許可外は「何も返さず」捨てる
# （「権限がありません」と返すとボットの存在に気づかれる）。
unless ($REMOTE_WRITE_MODE eq '' || write_mode_ok($REMOTE_WRITE_MODE)) {
    print STDERR "未知的 --mode：$REMOTE_WRITE_MODE（可选 default / accept-edits / bypass）\n";
    exit 2;
}
if (!writable_mode() && @REMOTE_ROOTS) {
    # 只读模式下给可写目录是自相矛盾的配置，直接说出来，别让它静默无效
    print STDERR "--allow-write 只在 --mode=accept-edits / bypass 下有意义；当前是只读模式\n";
    exit 2;
}

sub gate {
    my ($from, $text) = @_;
    unless (defined $from && $from =~ /\S/ && $allow->{$from}) {
        audit('drop_sender', 'from=' . (defined $from && $from ne '' ? $from : '(empty)'),
              'len=' . length($text // ''));
        return 0;
    }
    audit('inbound', "from=$from", 'len=' . length($text // ''));
    return 1;
}

if ($MODE eq 'once') {
    if (!gate($ONCE_FROM, $ONCE_TEXT)) {
        audit('gateway_end', 'mode=once result=dropped');
        exit 0;    # 落としたことは外から見えない。終了コードも 0。
    }
    my $reply = handle_message($ONCE_FROM, $ONCE_TEXT, $conf);
    push_notify($reply) if $notify_on && defined $reply;
    print defined $reply ? "$reply\n" : "(no reply)\n";
    audit('gateway_end', 'mode=once result=ok');
    exit 0;
}

if ($MODE eq 'stdin') {
    while (my $l = <STDIN>) {
        $l =~ s/\r?\n$//;
        next if $l =~ /^\s*$/;
        my $from = json_unescape(json_get($l, 'from') // '');
        my $text = json_unescape(json_get($l, 'text') // '');
        next unless gate($from, $text);
        my $reply = handle_message($from, $text, $conf);
        push_notify($reply) if $notify_on && defined $reply;
        print qq|{"from":"| . json_escape($from) . qq|","reply":"|
              . json_escape(defined $reply ? $reply : '') . qq|"}\n|;
    }
    audit('gateway_end', 'mode=stdin');
    exit 0;
}

print STDERR "模式未指定。用 --stdin / --once。\n";
exit 2;
