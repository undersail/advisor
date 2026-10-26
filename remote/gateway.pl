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
#   RELAY_URL = https://...        档② 中继地址（Worker）
#   RELAY_TOKEN = ...              中继令牌（Worker 那边用 secret put 配的同一个）
#   POLL_INTERVAL = 4              轮询间隔秒数（默认 4）
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
binmode STDERR, ':encoding(UTF-8)';

my $SCRIPT_DIR   = dirname(dirname(Cwd_abs($0)));
my $AGENT        = "$SCRIPT_DIR/agent/claude-agent.pl";
my $NOTIFY       = "$SCRIPT_DIR/remote/notify.pl";
my $CONF_PATH    = (defined $ENV{CLAUDE_REMOTE_CONF} && $ENV{CLAUDE_REMOTE_CONF} ne '')
    ? $ENV{CLAUDE_REMOTE_CONF}
    : "$ENV{HOME}/.claude-agent/remote.conf";
my $AUDIT_PATH   = "$ENV{HOME}/.claude-agent/audit.log";
my $REMOTE_HIST  = "$ENV{HOME}/.claude-agent/history-remote";

# ★ 远程允许的工具。想加就必须在这里改代码并 review —— 不接受配置覆盖。
my @REMOTE_TOOLS = qw(read_file list_dir);

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
        open3($in, $out, $errh, 'perl', $AGENT, '--rpc',
              '--tools=' . join(',', @REMOTE_TOOLS));
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
    audit('session_start', "from=$from", "pid=$pid", 'tools=' . join(',', @REMOTE_TOOLS));
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
                # y/n 待ちで双方が止まる。ここは常に「いいえ」。
                # 書込み系は --tools で広告していないので、来たら異常。
                audit('confirm_refused', "from=$from");
                print { $s->{in} } qq|{"t":"confirm_answer","value":"n"}\n|;
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

# ---------------------------------------------------------------- 中继（档②）
# token 同样是凭据：走 curl -K - 的 stdin，不进 argv、不进 ps、不进日志。
sub _relay_curl {
    my ($conf, $method, $path, $body) = @_;
    my $base = $conf->{RELAY_URL} || '';
    return (undef, 'RELAY_URL 未配置') unless $base =~ m{^https?://};
    my $token = $conf->{RELAY_TOKEN} || $ENV{CLAUDE_RELAY_TOKEN} || '';
    return (undef, 'RELAY_TOKEN 未配置') unless $token =~ /\S/;

    my $url = $base;
    $url =~ s{/+$}{};
    $url .= $path;

    my $cfg = qq{url = "$url"\n};
    $cfg .= qq{header = "authorization: Bearer $token"\n};
    $cfg .= qq{silent\nmax-time = "20"\nshow-error\n};

    my @extra;
    my $tmp;
    if (defined $body) {
        $tmp = sprintf('%s/.relay-body.%d.%d', dirname($CONF_PATH), $$, int(rand(100000)));
        open(my $bf, '>:encoding(UTF-8)', $tmp) or return (undef, "临时文件写入失败: $!");
        print $bf $body;
        close $bf;
        chmod 0600, $tmp;
        push @extra, '--data-binary', '@' . $tmp;
        push @extra, '-H', 'content-type: application/json';
    }
    push @extra, '-X', $method unless $method eq 'GET';

    my $errh = gensym;
    my ($in, $out);
    my $pid = eval {
        open3($in, $out, $errh, ($ENV{CLAUDE_CURL} || 'curl'),
              '-K', '-', @extra, '-w', "\n%{http_code}");
    };
    unless ($pid) {
        unlink $tmp if defined $tmp;
        return (undef, "无法执行 curl: $@");
    }
    print $in $cfg;
    close $in;
    my $resp = do { local $/; <$out> };
    close $out;
    my $errs = do { local $/; <$errh> };
    close $errh;
    waitpid($pid, 0);
    unlink $tmp if defined $tmp;
    $resp = '' unless defined $resp;
    $errs = '' unless defined $errs;
    $resp =~ s/\n([0-9]{3})\s*$//;
    my $code = defined $1 ? $1 : '';
    $code = '' unless defined $code;
    return (undef, 'curl: ' . substr($errs, 0, 160)) if $code eq '' && $errs =~ /\S/;
    return ($resp, "HTTP $code") unless $code eq '200';
    return ($resp, undef);
}

# 配列の中の平坦なオブジェクトを取り出す（この用途では入れ子が無い）
sub json_objects {
    my ($resp) = @_;
    my @objs;
    return \@objs unless defined $resp;
    while ($resp =~ /(\{[^{}]*\})/g) {
        my $o = $1;
        my %h;
        while ($o =~ /"([a-z_]+)"\s*:\s*"((?:[^"\\]|\\.)*)"/g) {
            $h{$1} = json_unescape($2);
        }
        push @objs, \%h if exists $h{id} || exists $h{text} || exists $h{reply};
    }
    return \@objs;
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
my ($MODE, $ONCE_FROM, $ONCE_TEXT, $MAX_MSGS) = ('', '', '', 0);
while (my $a = shift @ARGV) {
    if    ($a eq '--stdin')        { $MODE = 'stdin'; }
    elsif ($a eq '--once')         { $MODE = 'once'; }
    elsif ($a eq '--poll')         { $MODE = 'poll'; }
    elsif ($a eq '--max-msgs')     { $MAX_MSGS = shift @ARGV; }
    elsif ($a eq '--from')         { $ONCE_FROM = shift @ARGV; }
    elsif ($a eq '--text')         { $ONCE_TEXT = shift @ARGV; }
    elsif ($a eq '--help' || $a eq '-h') {
        print "用法: gateway.pl --stdin | --once --from ID --text \"...\" | --poll [--max-msgs N]\n";
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
      'tools=' . join(',', @REMOTE_TOOLS));
unless (keys %$allow) {
    audit('allowlist_empty', "conf=$CONF_PATH");
    print STDERR "白名单为空：所有消息都会被丢弃。请在 $CONF_PATH 里写 ALLOW = <id>,<id>\n";
}

# 送信者を確認する。許可外は「何も返さず」捨てる
# （「権限がありません」と返すとボットの存在に気づかれる）。
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

if ($MODE eq 'poll') {
    unless (($conf->{RELAY_URL} || '') =~ m{^https?://}) {
        print STDERR "RELAY_URL 未配置：$CONF_PATH 里需要 RELAY_URL = https://...\n";
        exit 2;
    }
    my $interval = ($conf->{POLL_INTERVAL} && $conf->{POLL_INTERVAL} =~ /^\d+$/)
        ? $conf->{POLL_INTERVAL} : 4;
    $interval = 1 if $interval < 1;
    # 中継は「宛先」で引く。誰の分を取りに行くかは ALLOW の並びを使う
    # （一人用なら ALLOW に自分の ID を一つ書けばよい）。
    my @boxes = sort keys %$allow;
    unless (@boxes) {
        print STDERR "白名单为空：没有可取的对象。\n";
        exit 2;
    }
    audit('poll_start', 'boxes=' . join(',', @boxes), "interval=$interval");
    my $processed = 0;
    while (1) {
        for my $box (@boxes) {
            my ($resp, $err) = _relay_curl($conf, 'GET', "/pull?to=$box&limit=10", undef);
            if (defined $err) {
                audit('poll_error', "box=$box", "err=$err");
                next;
            }
            my $objs = json_objects($resp);
            for my $o (@$objs) {
                my $from = $o->{from} // '';
                my $text = $o->{text} // '';
                next unless $text =~ /\S/;
                unless (gate($from, $text)) {
                    # 中継経由で来た場合も同じ規則：返さず捨てる
                    next;
                }
                my $reply = handle_message($from, $text, $conf);
                $reply = '(no reply)' unless defined $reply;
                my ($r, $perr) = _relay_curl($conf, 'POST', '/result',
                    sprintf('{"from":"%s","reply":"%s"}', json_escape($from), json_escape($reply)));
                audit('relay_result', "from=$from", (defined $perr ? "err=$perr" : 'ok'));
                push_notify($reply) if $notify_on;
                $processed++;
                if ($MAX_MSGS && $processed >= $MAX_MSGS) {
                    audit('poll_end', "processed=$processed");
                    exit 0;
                }
            }
        }
        sleep $interval;
    }
}

print STDERR "模式未指定。用 --stdin / --once / --poll。\n";
exit 2;
