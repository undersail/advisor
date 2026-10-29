#!/usr/bin/perl
# ============================================================================
# wecom-ws.pl — 企业微信「智能机器人 · API 模式 · 使用长连接」的客户端
#
#   手机 ──(企业微信长连接)──> wecom-ws.pl ──(复用 gateway.pl --stdin)──> agent
#
# 为什么需要它：平台端已有的入站方式是「自建应用 HTTP 回调」（platform.pl --serve），
# 它要求**公网可达的 HTTPS 域名**。而家里的 Mac 没有公网 IP，于是要么开域名、
# 要么用 Cloudflare 中继。智能机器人的「长连接」模式把方向反过来：**我方连出去**，
# 凭据只有 BotID + Secret，不需要公网、不需要域名、不需要加解密。
#
# 边界（与 platform.pl 完全一致，别在这里重写）：
#   白名单、审计、只读工具集、独立历史 **全部由 gateway.pl 负责**。
#   本文件只做「收帧 → 交给网关 → 把回复发回去」，一行判定都不自己写。
#
# 零 CPAN 约束：perl 核心没有 TLS（IO::Socket::SSL 是 CPAN），所以 wss 走
#   `openssl s_client` 子进程当 TLS 管道，WebSocket 帧在本文件里手写编解码。
#
# 用法：
#   perl remote/wecom-ws.pl --init     录入 BotID / Secret（隐藏输入，写 0600）
#   perl remote/wecom-ws.pl --check    连一次，验凭据能不能订阅成功
#   perl remote/wecom-ws.pl --serve    常驻：收消息 → 跑 agent → 回消息
#
# 配置：~/.claude-agent/wecom-ws.conf（0600）
#   BOT_ID=...           智能机器人的 Bot ID
#   BOT_SECRET=...       智能机器人的 Secret
#   WS_URL=wss://openws.work.weixin.qq.com
#   HEARTBEAT=30         心跳间隔（秒），官方建议 30
#   TEXT_LIMIT=1900      单条文本上限（字节），超了按字节分片
#   ACK_AFTER=15         超过这么多秒还没结果，先回一句「正在处理」
# ============================================================================
use strict;
use warnings;
use utf8;      # ★ 必写：本文件里的中文提示是源码里的字符，不写这个 encode() 会二次编码成乱码
use IO::Select;
use IO::Socket::INET;
use IPC::Open3;
use Symbol qw(gensym);
use POSIX qw(strftime);
use MIME::Base64 qw(encode_base64);
use Fcntl qw(O_WRONLY O_CREAT O_APPEND);
use File::Path qw(make_path);
use File::Basename qw(dirname);
use Encode qw(encode decode);

my $VERSION = '0.3.0';
my $SCRIPT_DIR = dirname(__FILE__);
my $AGENT_DIR  = ($ENV{HOME} || '') . '/.claude-agent';
my $CONF_PATH  = $ENV{WECOM_WS_CONF} || "$AGENT_DIR/wecom-ws.conf";
my $AUDIT_PATH = $ENV{AUDIT_LOG} || "$AGENT_DIR/audit.log";
my $DEFAULT_URL = 'wss://openws.work.weixin.qq.com';
my $GATEWAY = $ENV{GATEWAY_CMD} || "$^X $SCRIPT_DIR/gateway.pl";

# ★ 远程权限只在**启动时**定：命令行 > 配置文件（GUI 写的那份）。
#   起来之后远程端改不了 —— 消息里的 /mode 之类一律拒绝，见 gateway.pl。
my $REMOTE_MODE    = '';   # '' / default / accept-edits / bypass
my $REMOTE_ALLOW   = '';   # 逗号分隔的可写目录
my $CONFIRM_WAIT   = '';   # 远程确认等待秒数（空=用 gateway 默认）

$| = 1;
$SIG{PIPE} = 'IGNORE';   # 往已关闭的连接写 → 不能让进程被 SIGPIPE 杀掉（重连就永远跑不到）
# 带 use utf8 之后，中文是「字符」；不把这层标成 UTF-8，往终端打审计就会报
# 「Wide character in print」并且写出乱码。
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

# ------------------------------------------------------------------ 基础工具
sub audit {
    my ($ev, @kv) = @_;
    my $line = sprintf("%s ws %s %s\n", strftime('%Y-%m-%d %H:%M:%S', localtime), $ev, join(' ', @kv));
    print STDERR $line if $ENV{WECOM_WS_VERBOSE};
    make_path(dirname($AUDIT_PATH)) unless -d dirname($AUDIT_PATH);
    my $old = umask(077);
    my $ok = sysopen(my $af, $AUDIT_PATH, O_WRONLY | O_CREAT | O_APPEND, 0600);
    umask($old);
    return unless $ok;
    binmode($af, ':encoding(UTF-8)');
    print $af $line;
    close $af;
}

sub logmsg { print STDERR strftime('%H:%M:%S', localtime) . " $_[0]\n" }

sub load_conf {
    my %c;
    return \%c unless -e $CONF_PATH;
    open(my $fh, '<:encoding(UTF-8)', $CONF_PATH) or return \%c;
    while (my $l = <$fh>) {
        $l =~ s/\r?\n$//;
        next if $l =~ /^\s*(?:#|$)/;
        next unless $l =~ /^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$/;
        my ($k, $v) = ($1, $2);
        $v =~ s/^["']//; $v =~ s/["']$//;
        $c{$k} = $v;
    }
    close $fh;
    return \%c;
}

# 0600 从创建那一刻就成立：先 open 再 chmod 会有一瞬间是 0644
sub open_private {
    my ($path, $mode) = @_;
    $mode ||= O_WRONLY | O_CREAT;
    my $old = umask(077);
    my $ok = sysopen(my $fh, $path, $mode, 0600);
    umask($old);
    return $ok ? $fh : undef;
}

sub save_conf {
    my ($c) = @_;
    make_path($AGENT_DIR) unless -d $AGENT_DIR;
    my $fh = open_private($CONF_PATH) or die "无法写入 $CONF_PATH: $!\n";
    binmode($fh, ':encoding(UTF-8)');
    print $fh "# 企业微信智能机器人（长连接）凭据 —— 权限 0600，不要提交到任何仓库\n";
    print $fh "$_=$c->{$_}\n" for qw(BOT_ID BOT_SECRET WS_URL HEARTBEAT TEXT_LIMIT ACK_AFTER);
    close $fh;
    chmod 0600, $CONF_PATH;
    print "已保存：$CONF_PATH（0600）\n";
}

# ------------------------------------------------------------------ 迷你 JSON
# 不引 JSON::PP（虽然是核心模块，但目标是「能在老 perl 上跑」的极简离线工具）。
# 入站帧结构固定且很浅，一个 60 行的解码器足够，也免得正则抠嵌套字段抠错。
sub json_decode {
    my ($s) = @_;
    my $pos = 0;
    my $val = _jd_value(\$s, \$pos);
    return $val;
}

sub _jd_ws { my ($r, $p) = @_; $$p++ while $$p < length($$r) && substr($$r, $$p, 1) =~ /[ \t\r\n]/ }

sub _jd_value {
    my ($r, $p) = @_;
    _jd_ws($r, $p);
    return undef if $$p >= length($$r);
    my $c = substr($$r, $$p, 1);
    if ($c eq '{') { return _jd_obj($r, $p) }
    if ($c eq '[') { return _jd_arr($r, $p) }
    if ($c eq '"') { return _jd_str($r, $p) }
    if (substr($$r, $$p, 4) eq 'true')  { $$p += 4; return 1 }
    if (substr($$r, $$p, 5) eq 'false') { $$p += 5; return 0 }
    if (substr($$r, $$p, 4) eq 'null')  { $$p += 4; return undef }
    my $num = '';
    while ($$p < length($$r) && substr($$r, $$p, 1) =~ /[-+0-9.eE]/) { $num .= substr($$r, $$p, 1); $$p++ }
    return $num + 0;
}

sub _jd_str {
    my ($r, $p) = @_;
    $$p++;                                   # 跳过开引号
    my $out = '';
    while ($$p < length($$r)) {
        my $c = substr($$r, $$p, 1);
        if ($c eq '\\') {
            my $n = substr($$r, $$p + 1, 1);
            $$p += 2;
            if    ($n eq 'n') { $out .= "\n" }
            elsif ($n eq 't') { $out .= "\t" }
            elsif ($n eq 'r') { $out .= "\r" }
            elsif ($n eq 'b') { $out .= "\b" }
            elsif ($n eq 'f') { $out .= "\f" }
            elsif ($n eq 'u') {
                my $hex = substr($$r, $$p, 4);
                $$p += 4;
                my $code = hex($hex);
                if ($code >= 0xD800 && $code <= 0xDBFF) {          # 代理对
                    if (substr($$r, $$p, 2) eq '\\u') {
                        my $lo = hex(substr($$r, $$p + 2, 4));
                        $$p += 6;
                        $code = 0x10000 + (($code - 0xD800) << 10) + ($lo - 0xDC00);
                    }
                }
                $out .= chr($code);
            }
            else { $out .= $n }
            next;
        }
        last if $c eq '"';
        $out .= $c;
        $$p++;
    }
    $$p++;                                   # 跳过闭引号
    return $out;
}

sub _jd_arr {
    my ($r, $p) = @_;
    $$p++;
    my @out;
    _jd_ws($r, $p);
    if (substr($$r, $$p, 1) eq ']') { $$p++; return \@out }
    while ($$p < length($$r)) {
        push @out, _jd_value($r, $p);
        _jd_ws($r, $p);
        my $c = substr($$r, $$p, 1);
        $$p++;
        last if $c eq ']';
    }
    return \@out;
}

sub _jd_obj {
    my ($r, $p) = @_;
    $$p++;
    my %out;
    _jd_ws($r, $p);
    if (substr($$r, $$p, 1) eq '}') { $$p++; return \%out }
    while ($$p < length($$r)) {
        _jd_ws($r, $p);
        last unless substr($$r, $$p, 1) eq '"';
        my $k = _jd_str($r, $p);
        _jd_ws($r, $p);
        $$p++ if substr($$r, $$p, 1) eq ':';      # 跳过冒号
        $out{$k} = _jd_value($r, $p);
        _jd_ws($r, $p);
        my $c = substr($$r, $$p, 1);
        $$p++;
        last if $c eq '}';
    }
    return \%out;
}

sub json_esc {
    my ($s) = @_;
    $s = '' unless defined $s;
    $s =~ s/\\/\\\\/g;
    $s =~ s/"/\\"/g;
    $s =~ s/\n/\\n/g;
    $s =~ s/\r/\\r/g;
    $s =~ s/\t/\\t/g;
    $s =~ s/([\x00-\x1f])/sprintf('\\u%04x', ord($1))/ge;
    return '"' . $s . '"';
}

# ------------------------------------------------------------------ 文本分片
sub split_text {
    my ($text, $limit) = @_;
    $limit ||= 1900;
    my @parts;
    my $buf = '';
    for my $ch (split //, $text) {
        my $candidate = $buf . $ch;
        if (length(encode('UTF-8', $candidate)) > $limit) {
            push @parts, $buf if length $buf;
            $buf = $ch;
        } else {
            $buf = $candidate;
        }
    }
    push @parts, $buf if length $buf;
    push @parts, '' unless @parts;
    return @parts;
}

# ============================================================================
#  传输层：wss 走 openssl s_client 子进程，ws 走 IO::Socket::INET（测试用）
# ============================================================================
our ($TLS_PID, $SOCK);

sub transport_open {
    my ($url) = @_;
    my ($scheme, $host, $port, $path) = $url =~ m{^(wss?)://([^/:]+)(?::(\d+))?(/.*)?$}i
        or die "WS_URL 看不懂：$url\n";
    $port ||= ($scheme eq 'wss' ? 443 : 80);
    $path ||= '/';
    if ($scheme eq 'wss') {
        # -quiet：不打印会话信息；-servername：SNI（没有它服务端可能给错证书/直接断）
        my ($in, $out, $errh);
        my $pid = eval {
            open3($in, $out, $errh, 'openssl', 's_client', '-quiet', '-connect', "$host:$port",
                  '-servername', $host);
        };
        die "起不了 openssl s_client：$@\n" unless $pid;
        binmode($in);  binmode($out);
        select((select($in), $| = 1)[0]);
        $TLS_PID = $pid;
        return { in => $in, out => $out, errh => $errh, scheme => 'wss', host => $host,
                 port => $port, path => $path };
    }
    my $sock = IO::Socket::INET->new(PeerAddr => $host, PeerPort => $port, Proto => 'tcp', Timeout => 10)
        or die "连不上 $host:$port：$@\n";
    binmode($sock);
    select((select($sock), $| = 1)[0]);
    $SOCK = $sock;
    return { in => $sock, out => $sock, scheme => 'ws', host => $host, port => $port, path => $path };
}

sub transport_close {
    my ($t) = @_;
    eval { close $t->{in} } if $t->{in};
    eval { close $t->{out} } if $t->{out} && $t->{out} != $t->{in};
    eval { close $t->{errh} } if $t->{errh};
    if ($TLS_PID) { eval { waitpid($TLS_PID, 0) }; $TLS_PID = undef }
    $SOCK = undef;
}

# 缓冲读：$buf 里按字节累计
sub t_read {
    my ($t, $len, $timeout, $bufref) = @_;
    my $sel = IO::Select->new($t->{out});
    my $deadline = time() + ($timeout || 10);
    while (length($$bufref) < $len) {
        my $left = $deadline - time();
        return undef if $left <= 0;
        next unless $sel->can_read($left);
        my $chunk = '';
        my $n = sysread($t->{out}, $chunk, 65536);
        return 0 unless defined $n;               # 读错误也按断开处理
        return 0 if $n == 0;                      # EOF（对端关了）
        $$bufref .= $chunk;
    }
    return 1;
}

# ------------------------------------------------------------------ WebSocket
my $WS_BUF = '';

sub ws_handshake {
    my ($t) = @_;
    my @k = map { chr(int(rand(256))) } 1 .. 16;
    my $key = encode_base64(join('', @k), '');
    my $req = "GET $t->{path} HTTP/1.1\r\n"
        . "Host: $t->{host}:$t->{port}\r\n"
        . "Upgrade: websocket\r\n"
        . "Connection: Upgrade\r\n"
        . "Sec-WebSocket-Key: $key\r\n"
        . "Sec-WebSocket-Version: 13\r\n\r\n";
    my $sent = print { $t->{in} } $req;
    die "握手请求写入失败\n" unless $sent;
    my $buf = '';
    my $deadline = time() + 15;
    while (index($buf, "\r\n\r\n") < 0) {
        my $left = $deadline - time();
        die "握手超时（服务端没回 HTTP 头）\n" if $left <= 0;
        my $sel = IO::Select->new($t->{out});
        next unless $sel->can_read($left);
        my $chunk = '';
        my $n = sysread($t->{out}, $chunk, 4096);
        die "握手时连接被关闭\n" unless defined $n && $n > 0;
        $buf .= $chunk;
    }
    my ($hdr, $rest) = split /\r\n\r\n/, $buf, 2;
    $WS_BUF = defined $rest ? $rest : '';
    die "握手被拒：$hdr\n" unless $hdr =~ m{^HTTP/1\.1\s+101};
    return 1;
}

sub ws_send_frame {
    my ($t, $opcode, $payload) = @_;
    $payload = '' unless defined $payload;
    my $len = length($payload);
    my $hdr = chr(0x80 | $opcode);
    if ($len < 126) {
        $hdr .= chr(0x80 | $len);
    } elsif ($len < 65536) {
        $hdr .= chr(0x80 | 126) . pack('n', $len);
    } else {
        $hdr .= chr(0x80 | 127) . pack('Q>', $len);
    }
    my $mask = join('', map { chr(int(rand(256))) } 1 .. 4);
    my $masked = '';
    for (my $i = 0; $i < $len; $i++) {
        $masked .= chr(ord(substr($payload, $i, 1)) ^ ord(substr($mask, $i % 4, 1)));
    }
    my $ok = print { $t->{in} } $hdr . $mask . $masked;
    die "写入失败（连接已断）\n" unless $ok;
    return 1;
}

# 参数是一整段 JSON 文本（不是裸字符串）—— 所以只做 UTF-8 编码，绝不能再套一层引号。
# 踩过：enc_json 会把 {"cmd":...} 变成 "{\"cmd\":...}"，服务端当成字符串直接无视。
sub ws_send_text { return ws_send_frame($_[0], 0x1, encode('UTF-8', $_[1])) }

# 读满 n 字节：够了 1；超时 0（调用方当「这一轮没数据」）；对端关闭直接抛错。
# ★ EOF 必须和超时分开：混在一起的话，对端一关，主循环每圈都「读不到 → 继续」，
#   于是空转烧 CPU，而且看起来像「还在等消息」。
sub ws_need {
    my ($t, $n, $timeout) = @_;
    my $r = t_read($t, $n, $timeout, \$WS_BUF);
    die "连接被对端关闭\n" if defined $r && $r == 0;
    return defined $r ? 1 : 0;
}

sub ws_read_frame {
    my ($t, $timeout) = @_;
    my $h = '';
    return undef unless ws_need($t, 2, $timeout);
    $h = substr($WS_BUF, 0, 2);
    substr($WS_BUF, 0, 2) = '';
    my $b1 = ord(substr($h, 0, 1));
    my $b2 = ord(substr($h, 1, 1));
    my $fin    = ($b1 & 0x80) ? 1 : 0;
    my $opcode = $b1 & 0x0f;
    my $masked = ($b2 & 0x80) ? 1 : 0;
    my $len    = $b2 & 0x7f;
    if ($len == 126) {
        return undef unless ws_need($t, 2, $timeout);
        $len = unpack('n', substr($WS_BUF, 0, 2));
        substr($WS_BUF, 0, 2) = '';
    } elsif ($len == 127) {
        return undef unless ws_need($t, 8, $timeout);
        $len = unpack('Q>', substr($WS_BUF, 0, 8));
        substr($WS_BUF, 0, 8) = '';
    }
    my $mask;
    if ($masked) {                                 # 服务端不该 mask，但照规矩支持
        return undef unless ws_need($t, 4, $timeout);
        $mask = substr($WS_BUF, 0, 4);
        substr($WS_BUF, 0, 4) = '';
    }
    my $payload = '';
    if ($len > 0) {
        return undef unless ws_need($t, $len, $timeout);
        $payload = substr($WS_BUF, 0, $len);
        substr($WS_BUF, 0, $len) = '';
    }
    if ($masked) {
        my $out = '';
        for (my $i = 0; $i < length($payload); $i++) {
            $out .= chr(ord(substr($payload, $i, 1)) ^ ord(substr($mask, $i % 4, 1)));
        }
        $payload = $out;
    }
    return { fin => $fin, opcode => $opcode, payload => decode('UTF-8', $payload) };
}

# ============================================================================
#  协议层：订阅 / 心跳 / 收消息 / 回复
# ============================================================================
sub gen_req_id {
    my ($prefix) = @_;
    return sprintf('%s_%d%06d', $prefix, time(), int(rand(1_000_000)));
}

sub gw_spawn {
    my ($sender, $state) = @_;
    my $errh = gensym;
    my ($in, $out);
    my @cmd = split /\s+/, $GATEWAY;
    push @cmd, remote_extra_args($state);
    my $pid = eval { open3($in, $out, $errh, @cmd, '--stdin') };
    if (!$pid) { audit('gateway_spawn_fail', "from=$sender err=$@"); return undef }
    binmode($in,  ':encoding(UTF-8)');
    binmode($out, ':encoding(UTF-8)');
    select((select($in), $| = 1)[0]);
    $state->{gw}{$sender} = { in => $in, out => $out, errh => $errh, pid => $pid };
    audit('gateway_spawn', "from=$sender pid=$pid");
    return $state->{gw}{$sender};
}

# 启动时定下来的权限，转成 gateway 的参数
sub remote_extra_args {
    my ($state) = @_;
    my $mode  = $REMOTE_MODE;
    my $allow = $REMOTE_ALLOW;
    my $wait  = $CONFIRM_WAIT;
    if (ref $state eq 'HASH' && ref $state->{conf} eq 'HASH') {
        my $c = $state->{conf};
        $mode  = $c->{REMOTE_MODE}        if $mode  eq '' && defined $c->{REMOTE_MODE};
        $allow = $c->{REMOTE_ALLOW_WRITE} if $allow eq '' && defined $c->{REMOTE_ALLOW_WRITE};
    }
    my @a;
    push @a, '--mode=' . $mode if defined $mode && $mode ne '';
    push @a, '--allow-write=' . $allow if defined $allow && $allow ne '';
    push @a, '--confirm-wait=' . $wait if defined $wait && $wait ne '';
    return @a;
}

# 读一轮：要么读到最终回复（reply），要么读到「需要你确认」（ask）。
# 返回 { reply => '...' } 或 { ask => '...', danger => 0/1 } 或 undef（出异常）。
sub gw_read_turn {
    my ($sender, $s, $state) = @_;
    while (1) {
        my $line = readline($s->{out});
        return undef unless defined $line;
        $line =~ s/\r?\n$//;
        next if $line eq '';
        my $j = json_decode($line);
        return undef unless ref $j eq 'HASH';
        # 网关转发过来的「要不要允许」问题
        if (defined $j->{ask}) {
            audit('gateway_ask', "from=$sender danger=" . ($j->{danger} ? 1 : 0));
            return { ask => $j->{ask}, danger => ($j->{danger} ? 1 : 0) };
        }
        if (defined $j->{reply}) {
            audit('gateway_done', 'reply_len=' . length($j->{reply}));
            return { reply => $j->{reply} };
        }
        # 其它行（比如 ack）忽略，继续等
    }
}

sub gw_call {
    my ($sender, $text, $state, $on_slow, $depth, $on_ask) = @_;
    $depth ||= 0;
    my $s = $state->{gw}{$sender} || gw_spawn($sender, $state);
    return undef unless $s;
    print { $s->{in} } '{"from":' . json_esc($sender) . ',"text":' . json_esc($text) . "}\n";
    if (($state->{ack_after} || 0) > 0) {
        my $sel = IO::Select->new($s->{out});
        if (!$sel->can_read($state->{ack_after})) {
            $on_slow->() if $on_slow;
            audit('ack_sent', "from=$sender");
        }
    }
    my $r = gw_read_turn($sender, $s, $state);
    if (!defined $r) {
        audit('gateway_eof', "from=$sender retry=" . ($depth + 1));
        my $dead = delete $state->{gw}{$sender};
        if ($dead) {
            eval { close $dead->{in} };
            eval { close $dead->{out} };
            eval { close $dead->{errh} };
            eval { waitpid($dead->{pid}, 0) };
        }
        return undef if $depth >= 1;
        return gw_call($sender, $text, $state, $on_slow, $depth + 1, $on_ask);
    }
    if (defined $r->{ask}) {
        # 需要手机端确认：这一轮先挂起，问题已经发出去，等用户下一条消息当答案
        $state->{wait}{$sender} = 1;
        $on_ask->($r->{ask}, $r->{danger}) if $on_ask;
        return { pending => 1 };
    }
    return { reply => $r->{reply} // '' };
}

# 用户回了 y/n 之后，接着把这一轮读完（可能还要再确认一次）
sub gw_answer {
    my ($sender, $answer, $state, $on_ask) = @_;
    my $s = $state->{gw}{$sender} or return { reply => '' };
    print { $s->{in} } '{"answer":"' . ($answer eq 'y' ? 'y' : 'n') . '"}' . "\n";
    audit('gateway_answer', "from=$sender answer=" . ($answer eq 'y' ? 'y' : 'n'));
    my $r = gw_read_turn($sender, $s, $state);
    if ($r && $r->{ask} && $on_ask) {
        $state->{wait}{$sender} = 1;
        $on_ask->($r->{ask}, $r->{danger});
        return { pending => 1 };
    }
    delete $state->{wait}{$sender};
    return $r || { reply => '' };
}

sub subscribe_frame {
    my ($c) = @_;
    return sprintf('{"cmd":"aibot_subscribe","headers":{"req_id":%s},"body":{"bot_id":%s,"secret":%s}}',
        json_esc(gen_req_id('aibot_subscribe')), json_esc($c->{BOT_ID}), json_esc($c->{BOT_SECRET}));
}

sub ping_frame {
    return sprintf('{"cmd":"ping","headers":{"req_id":%s}}', json_esc(gen_req_id('ping')));
}

sub reply_frame {
    my ($req_id, $content) = @_;
    return sprintf('{"cmd":"aibot_respond_msg","headers":{"req_id":%s},"body":{"msgtype":"text","text":{"content":%s}}}',
        json_esc($req_id), json_esc($content));
}

sub welcome_frame {
    my ($req_id, $content) = @_;
    return sprintf('{"cmd":"aibot_respond_welcome_msg","headers":{"req_id":%s},"body":{"msgtype":"text","text":{"content":%s}}}',
        json_esc($req_id), json_esc($content));
}

# 等某类回执（心跳 ack / 回复 ack）：读到就返回，超时返回 undef。
# 期间收到的消息回调不会丢 —— 交给 $pending 回调处理。
sub wait_ack {
    my ($t, $prefix, $timeout, $state, $on_msg) = @_;
    my $deadline = time() + $timeout;
    while (1) {
        my $left = $deadline - time();
        return undef if $left <= 0;
        my $f = ws_read_frame($t, $left);
        return undef unless $f;
        if ($f->{opcode} == 0x9) { ws_send_frame($t, 0xA, $f->{payload}); next }   # ping → pong
        if ($f->{opcode} == 0x8) { return 'closed' }
        next unless $f->{opcode} == 0x1 || $f->{opcode} == 0x0;
        my $j = json_decode($f->{payload});
        next unless ref $j eq 'HASH';
        my $rid = $j->{headers}{req_id} // '';
        if ($rid =~ /^\Q$prefix\E/) {
            my $ec = $j->{errcode} // 0;
            $state->{last_errcode} = $ec;
            $state->{last_errmsg} = $j->{errmsg} // '';
            return $ec == 0 ? 1 : 0;
        }
        $on_msg->($t, $j, $state) if $on_msg;
    }
}

# 收到一条消息回调
sub handle_msg {
    my ($t, $j, $state) = @_;
    my $cmd = $j->{cmd} // '';
    my $req_id = $j->{headers}{req_id} // '';
    my $body = $j->{body} || {};

    if ($cmd eq 'aibot_event_callback') {
        my $ev = $body->{event}{eventtype} // $body->{eventtype} // '';
        audit('ws_event', "type=$ev");
        if ($ev eq 'enter_chat' && $req_id) {
            my $txt = $state->{welcome};
            ws_send_text($t, welcome_frame($req_id, $txt)) if length $txt;
        }
        return;
    }
    return unless $cmd eq 'aibot_msg_callback';

    my $sender  = $body->{from}{userid} // '';
    my $msgtype = $body->{msgtype} // '';
    my $text    = $body->{text}{content} // '';
    audit('ws_inbound', "from=$sender type=$msgtype len=" . length($text));

    my $limit = $state->{text_limit};
    # ★ 发完就走，不在这里等回执。旧写法「每发一片就 wait_ack 10 秒」有两个后果：
    #   ① 分片之间白等 ② 等回执期间到达的新消息会被丢掉。回执统一交给主循环（pending 表）。
    my $reply_to = sub {
        my ($content) = @_;
        my @parts = split_text($content, $limit - 60);
        my $i = 0;
        for my $p (@parts) {
            $i++;
            my $payload = @parts > 1 ? sprintf('（%d/%d）%s', $i, scalar(@parts), $p) : $p;
            ws_send_text($t, reply_frame($req_id, $payload));
            $state->{pending}{$req_id} = ($state->{pending}{$req_id} || 0) + 1;
            audit('ws_sent', "to=$sender part=$i/" . scalar(@parts) . ' len=' . length($p));
        }
    };

    if ($msgtype ne 'text') {
        # 最小可用范围只做文本；其它类型明确告诉对方，不静默吞掉
        $reply_to->('（暂只支持文本消息）');
        return;
    }
    if (!length $text) { return }

    my $on_slow = sub { $reply_to->('正在处理，请稍等…') };
    # 网关把 agent 的 y/n 问题转过来，这里原样交给用户；不回就超时按拒绝
    my $on_ask = sub {
        my ($prompt, $danger) = @_;
        my $head = $danger ? '⚠ 危险操作，需要你在手机上确认：' : '需要你确认：';
        $reply_to->($head . $prompt . "\n\n回复 y 允许 / n 拒绝（不回则超时按拒绝处理）");
    };

    # ★ 正在等确认：这条消息当答案处理；不是 y/n 就按拒绝收尾，再当新指令
    if ($state->{wait}{$sender}) {
        my $ans = $text =~ /^\s*(?:y|yes|1|true|是|允许|同意|确认|好)\s*$/i ? 'y'
                : $text =~ /^\s*(?:n|no|0|false|否|不|取消|拒绝)\s*$/i      ? 'n'
                : '';
        my $r = gw_answer($sender, ($ans eq '' ? 'n' : $ans), $state, $on_ask);
        if (ref $r eq 'HASH' && !$r->{pending}) {
            my $rep = $r->{reply} // '';
            $reply_to->($rep) if length $rep;
        }
        return if $ans ne '';      # 是 y/n：这一轮已经结束
        # 不是 y/n：已经按拒绝收尾，下面把这句话当新指令继续
    }

    my $r = gw_call($sender, $text, $state, $on_slow, 0, $on_ask);
    if (!defined $r) {
        audit('ws_gateway_undef', "from=$sender");
        $reply_to->('处理失败（网关异常），请稍后重试。');
        return;
    }
    return if $r->{pending};       # 问题已发给手机，等用户回 y/n
    my $reply = $r->{reply} // '';
    $reply_to->($reply) if length $reply;
}

# 一次连接的生命周期：握手 → 订阅 → 循环（心跳 + 收消息）
sub run_session {
    my ($c) = @_;
    my $url = $c->{WS_URL} || $DEFAULT_URL;
    my $t = transport_open($url);
    ws_handshake($t);
    ws_send_text($t, subscribe_frame($c));
    my %state = (
        text_limit => ($c->{TEXT_LIMIT} || 1900),
        ack_after  => ($c->{ACK_AFTER}  || 15),
        welcome    => ($c->{WELCOME}    || ''),
        conf       => $c,
        gw         => {},
    );
    my $ok = wait_ack($t, 'aibot_subscribe', 15, \%state, \&handle_msg);
    if (!defined $ok || $ok eq 'closed') {
        transport_close($t);
        die "订阅没有回执（连接被关闭？）\n";
    }
    if (!$ok) {
        my $ec = $state{last_errcode} // '?';
        my $em = $state{last_errmsg} // '';
        transport_close($t);
        die "订阅被拒：errcode=$ec errmsg=$em（多半是 BotID / Secret 不对）\n";
    }
    audit('ws_subscribe_ok', "url=$url");
    logmsg('已订阅，等待消息（Ctrl-C 结束）');

    my $hb = $c->{HEARTBEAT} || 30;
    my $next_ping = time() + $hb;
    my $missed = 0;
    my $replies_pending = 0;
    while (1) {
        my $now = time();
        if ($now >= $next_ping) {
            if ($missed >= 2) {
                audit('ws_dead', "missed=$missed");
                transport_close($t);
                die "连续 $missed 次心跳没有回执，判定连接已死\n";
            }
            ws_send_text($t, ping_frame());
            audit('ws_ping', "missed=$missed");
            $missed++;
            $next_ping = $now + $hb;
        }
        my $wait = $next_ping - time();
        $wait = 1 if $wait < 1;
        my $f = ws_read_frame($t, $wait);
        next unless $f;                                   # 超时：回到循环顶部看心跳
        if ($f->{opcode} == 0x8) {
            transport_close($t);
            die "服务端关闭了连接\n";
        }
        if ($f->{opcode} == 0x9) { ws_send_frame($t, 0xA, $f->{payload}); next }
        next unless $f->{opcode} == 0x1 || $f->{opcode} == 0x0;
        my $j = json_decode($f->{payload});
        next unless ref $j eq 'HASH';
        my $rid = $j->{headers}{req_id} // '';
        if ($rid =~ /^ping/) {                            # 心跳回执
            if (($j->{errcode} // 0) == 0) { $missed = 0 }
            else { audit('ws_ping_err', 'errcode=' . ($j->{errcode} // '?')) }
            next;
        }
        if (exists $state{pending}{$rid}) {                # 回复回执：只记结果，不重试
            my $ec = $j->{errcode} // 0;
            if ($ec != 0) {
                audit('ws_send_err', 'req=' . $rid . ' errcode=' . $ec
                      . ' errmsg=' . ($j->{errmsg} // ''));
            }
            if (--$state{pending}{$rid} <= 0) { delete $state{pending}{$rid} }
            next;
        }
        handle_msg($t, $j, \%state);
    }
}

# ------------------------------------------------------------------ 子命令
sub cmd_init {
    print "企业微信智能机器人（长连接）凭据录入\n";
    print "  在 企业微信 → 工作台 → 智能机器人 → 创建机器人 → API 模式 → 使用长连接 处获取\n";
    print "Bot ID: ";
    my $id = <STDIN>;
    chomp $id;
    die "Bot ID 不能为空\n" unless length $id;
    print "Secret（输入不会显示）: ";
    system('stty', '-echo');
    my $sec = <STDIN>;
    system('stty', 'echo');
    print "\n";
    chomp $sec;
    die "Secret 不能为空\n" unless length $sec;
    my $old = load_conf();
    save_conf({
        BOT_ID     => $id,
        BOT_SECRET => $sec,
        WS_URL     => ($old->{WS_URL} || $DEFAULT_URL),
        HEARTBEAT  => ($old->{HEARTBEAT}  || 30),
        TEXT_LIMIT => ($old->{TEXT_LIMIT} || 1900),
        ACK_AFTER  => ($old->{ACK_AFTER}  || 15),
    });
    print "下一步：perl remote/wecom-ws.pl --check   （验凭据）\n";
    return 0;
}

sub cmd_check {
    my ($c) = @_;
    die "还没有配置：$CONF_PATH（先跑 --init）\n" unless $c->{BOT_ID} && $c->{BOT_SECRET};
    my $url = $c->{WS_URL} || $DEFAULT_URL;
    print "连接 $url …\n";
    my $t = transport_open($url);
    ws_handshake($t);
    ws_send_text($t, subscribe_frame($c));
    my %state = (gw => {}, text_limit => 1900, ack_after => 0, conf => $c);
    my $ok = wait_ack($t, 'aibot_subscribe', 15, \%state, undef);
    transport_close($t);
    if (!defined $ok) { print "失败：订阅没有回执\n"; return 1 }
    if ($ok eq 'closed') { print "失败：连接被服务端关闭\n"; return 1 }
    if (!$ok) {
        printf "失败：errcode=%s errmsg=%s（检查 BotID / Secret）\n",
            $state{last_errcode} // '?', $state{last_errmsg} // '';
        return 1;
    }
    print "成功：订阅通过，凭据可用。\n";
    return 0;
}

sub cmd_serve {
    my ($c) = @_;
    die "还没有配置：$CONF_PATH（先跑 --init）\n" unless $c->{BOT_ID} && $c->{BOT_SECRET};
    my $attempt = 0;
    my $auth_fail = 0;
    while (1) {
        $attempt++;
        my $ok = eval { run_session($c); 1 };
        my $err = $@ || '';
        if (!$ok) {
            my $is_auth = ($err =~ /订阅被拒/);
            audit('ws_session_end', "attempt=$attempt err=" . ($err =~ s/\n/ /gr));
            logmsg("连接结束：$err");
            if ($is_auth) {
                $auth_fail++;
                if ($auth_fail >= 3) {
                    die "连续 $auth_fail 次订阅被拒 —— BotID / Secret 不对，停下来不再重试\n";
                }
            } else {
                $auth_fail = 0;
            }
        }
        my $delay = 1 << ($attempt > 5 ? 5 : ($attempt - 1));    # 1 2 4 8 16 32 上限
        $delay = 30 if $delay > 30;
        audit('ws_reconnect', "delay=${delay}s attempt=$attempt");
        logmsg("${delay}s 后重连（第 $attempt 次）");
        sleep $delay;
    }
}

sub usage {
    print <<"USAGE";
wecom-ws.pl $VERSION — 企业微信智能机器人长连接（API 模式 · 使用长连接）

  --init     录入 BotID / Secret（隐藏输入，写 $CONF_PATH 0600）
  --check    连一次，验证凭据能订阅成功
  --serve    常驻：收消息 → 复用 gateway.pl（白名单/权限/审计）→ 回复

远程权限（只在启动时定，手机端改不了）：
  --mode=default|accept-edits|bypass   默认 default=只读
  --allow-write=/路径,/另一个路径      可写目录（只对 accept-edits / bypass 有意义）
  --confirm-wait=120                   手机端确认最多等多久，超时按拒绝

配置：$CONF_PATH
白名单、审计、只读工具集都由 gateway.pl 负责（与本文件共用一份 remote.conf）。
USAGE
    return 0;
}

# ------------------------------------------------------------------ 主入口
my $cmd = $ARGV[0] // '';
for my $a (@ARGV) {
    if    ($a =~ /^--mode=(.*)$/)        { $REMOTE_MODE  = $1 }
    elsif ($a =~ /^--allow-write=(.*)$/) { $REMOTE_ALLOW = $1 }
    elsif ($a =~ /^--confirm-wait=(\d+)$/) { $CONFIRM_WAIT = $1 }
}
my $conf = load_conf();
if    ($cmd eq '--init')  { exit cmd_init() }
elsif ($cmd eq '--check') { exit cmd_check($conf) }
elsif ($cmd eq '--serve') { exit cmd_serve($conf) }
elsif ($cmd eq '--version') { print "wecom-ws $VERSION\n"; exit 0 }
else  { exit usage() }
