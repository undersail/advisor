#!/usr/bin/env perl
# -*- coding: utf-8 -*-
#
# remote/notify.pl —— 档① 出站通知（企业微信群机器人 / 飞书自定义机器人）
#
# 也可以独立用：
#     perl remote/notify.pl "构建完成"
#     perl remote/notify.pl --test          # 只想确认凭据还对
#     echo "长任务结束" | perl remote/notify.pl -
#
# 配置（任一来源，环境变量优先）：
#     ~/.claude-agent/remote.conf     每行 KEY = VALUE，# 注释
#     CLAUDE_WECOM_WEBHOOK / CLAUDE_FEISHU_WEBHOOK
#
# ★ webhook URL 本身就是凭据（带 key / hook token）。所以：
#     · 绝不放进命令行参数（ps 里谁都能看见）
#     · 用 curl -K -，把配置从标准输入喂进去
#     · 日志和输出里只打目标名，不打 URL
#
# 零 CPAN：只用核心模块 + curl。
use strict;
use warnings;
use utf8;
use Encode qw(decode);
use File::Basename qw(dirname);
use IPC::Open3 qw(open3);
use Symbol qw(gensym);

binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

my $CONF_PATH = (defined $ENV{CLAUDE_REMOTE_CONF} && $ENV{CLAUDE_REMOTE_CONF} ne '')
    ? $ENV{CLAUDE_REMOTE_CONF}
    : "$ENV{HOME}/.claude-agent/remote.conf";
my $CURL   = $ENV{CLAUDE_CURL}   || 'curl';
my $CACERT = $ENV{CLAUDE_CACERT} || '';

# ---------------------------------------------------------------- 配置
# KEY = VALUE 形式（= 两侧空格随意）。行内 # 之后当注释，但如果 # 在引号里
# 就保留 —— webhook URL 里可能出现 # 吗？不会，所以简单处理即可。
sub read_conf {
    my %c;
    open(my $fh, '<:encoding(UTF-8)', $CONF_PATH) or return \%c;
    while (my $l = <$fh>) {
        chomp $l;
        $l =~ s/\r$//;
        next if $l =~ /^\s*$/;
        next if $l =~ /^\s*#/;
        next unless $l =~ /^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$/;
        my ($k, $v) = ($1, $2);
        $v =~ s/^["']//;
        $v =~ s/["']$//;
        $c{uc $k} = $v;
    }
    close $fh;
    return \%c;
}

sub targets {
    my $c = read_conf();
    my %t;
    for my $k (qw(WECOM_WEBHOOK FEISHU_WEBHOOK)) {
        my $v = $ENV{"CLAUDE_$k"};
        $v = $c->{$k} unless defined $v && $v =~ /\S/;
        next unless defined $v && $v =~ /\S/;
        $t{$k} = $v;
    }
    return \%t;
}

# ---------------------------------------------------------------- JSON（够用就好）
sub json_escape {
    my ($s) = @_;
    return '' unless defined $s;
    $s =~ s/\\/\\\\/g;
    $s =~ s/"/\\"/g;
    $s =~ s/\n/\\n/g;
    $s =~ s/\r/\\r/g;
    $s =~ s/\t/\\t/g;
    # 制御文字は落とす（JSON 的に不正にならないように）
    $s =~ s/[\x00-\x1f]//g;
    return $s;
}

sub payload_for {
    my ($kind, $text) = @_;
    if ($kind eq 'WECOM_WEBHOOK') {
        # 企業微信: markdown が使える。改行はそのまま入る。
        return sprintf('{"msgtype":"markdown","markdown":{"content":"%s"}}',
                       json_escape($text));
    }
    # 飛書: text が一番素直（markdown はバージョン差異あり）
    return sprintf('{"msg_type":"text","content":{"text":"%s"}}',
                   json_escape($text));
}

# ---------------------------------------------------------------- 送信
# 返り値: (ok, detail)
sub send_one {
    my ($kind, $url, $text) = @_;
    return (0, 'no url') unless defined $url && $url =~ /\S/;
    # 本物の webhook は必ず https。http を許すと平文で通知本文が流れる。
    # 例外はローカルテスト用に限る（127.0.0.1 / localhost / [::1]）。
    my $is_local = $url =~ m{^http://(?:127\.0\.0\.1|localhost|\[::1\])(?::\d+)?/};
    return (0, 'url must start with https') unless $url =~ m{^https://} || $is_local;

    my $body = payload_for($kind, $text);

    # 本文は秘密ではないが、0600 で一時ファイルに置いて --data-binary で渡す
    # （-d に直接書くとシェル経由のときに引用符で事故る）。
    my $tmp = sprintf('%s/.notify-body.%d.%d', dirname($CONF_PATH), $$, int(rand(100000)));
    mkdir dirname($CONF_PATH) unless -d dirname($CONF_PATH);
    open(my $bf, '>:encoding(UTF-8)', $tmp) or return (0, "temp write failed: $!");
    print $bf $body;
    close $bf;
    chmod 0600, $tmp;

    # ★ URL は設定(stdin)側にだけ書く。
    # 当初 open($ph,'-|') の子で STDIN を組み替える方式にしたが、その子では
    # fd 0 が使えず open(STDIN,'<',\$cfg) が "Bad file descriptor" で失敗し、
    # curl が一度も走らなかった（実測）。open3 で標準入力を自分で持つ。
    my $cfg = qq{url = "$url"\n};
    $cfg .= qq{header = "content-type: application/json"\n};
    $cfg .= qq{cacert = "$CACERT"\n} if $CACERT ne '';
    $cfg .= qq{silent\nmax-time = "20"\nshow-error\n};

    my $errh = gensym;
    my ($in, $out);
    my $pid = eval {
        open3($in, $out, $errh, $CURL, '-K', '-', '--data-binary', '@' . $tmp,
              '-w', "\n%{http_code}");
    };
    if (!$pid) {
        unlink $tmp;
        return (0, "cannot run curl: $@");
    }
    print $in $cfg;
    close $in;
    my $resp = do { local $/; <$out> };
    close $out;
    my $errs = do { local $/; <$errh> };
    close $errh;
    waitpid($pid, 0);
    unlink $tmp;
    $resp = '' unless defined $resp;
    $errs = '' unless defined $errs;

    my $code = '';
    my $payload = $resp;
    if ($resp =~ /^(.*)\n([0-9]{3})\s*$/s) {
        $payload = $1;
        $code = $2;
    }
    elsif ($resp =~ /^\s*([0-9]{3})\s*$/) {
        $payload = '';
        $code = $1;
    }
    if ($code eq '' && $errs =~ /\S/) {
        return (0, 'curl: ' . substr($errs, 0, 160));
    }
    return (0, 'HTTP ' . ($code eq '' ? '(none)' : $code) . ': ' . substr($payload, 0, 200))
        unless $code eq '200';

    # 企業微信は HTTP 200 でも errcode != 0 を返す（key 無効・IP 制限など）
    # 飛書は code != 0 / StatusCode != 0。
    my $ec;
    $ec = $1 if $payload =~ /"errcode"\s*:\s*(-?\d+)/;
    $ec = $1 if !defined $ec && $payload =~ /"(?:code|StatusCode)"\s*:\s*(-?\d+)/;
    if (defined $ec && $ec != 0) {
        return (0, "errcode $ec: " . substr($payload, 0, 200));
    }
    return (1, 'HTTP 200');
}

sub send_all {
    my ($text, $quiet) = @_;
    my $t = targets();
    my @kinds = grep { $t->{$_} } qw(WECOM_WEBHOOK FEISHU_WEBHOOK);
    unless (@kinds) {
        print STDERR "通知目标未配置：$CONF_PATH 里需要 WECOM_WEBHOOK= 或 FEISHU_WEBHOOK=\n"
            unless $quiet;
        return (0, 1);
    }
    my ($ok, $bad) = (0, 0);
    for my $k (@kinds) {
        my ($fine, $detail) = send_one($k, $t->{$k}, $text);
        if ($fine) {
            $ok++;
            print "通知已发送：$k\n" unless $quiet;
        }
        else {
            $bad++;
            print "通知发送失败：$k（$detail）\n" unless $quiet;
        }
    }
    return ($ok, $bad);
}

# ---------------------------------------------------------------- CLI
unless (caller) {
    my $mode = shift @ARGV;
    if (!defined $mode || $mode eq '') {
        print STDERR "用法: notify.pl \"<文本>\" | notify.pl --test | ... | notify.pl -\n";
        exit 2;
    }
    my $text;
    if ($mode eq '--test') {
        $text = 'advisor 通知连通性测试 —— 收到即成功。';
    }
    elsif ($mode eq '-') {
        my $raw = do { local $/; <STDIN> };
        $raw = '' unless defined $raw;
        $text = decode('UTF-8', $raw);
        $text =~ s/\s+$//;
    }
    else {
        $text = decode('UTF-8', $mode);
    }
    if (!defined $text || $text !~ /\S/) {
        print STDERR "没有可发送的文本。\n";
        exit 2;
    }
    my ($ok, $bad) = send_all($text, 0);
    exit($ok > 0 ? 0 : 1);
}

1;
