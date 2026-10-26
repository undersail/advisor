#!/usr/bin/perl
# -*- coding: utf-8 -*-
#
# platform.pl ― 企业微信 / 飞书的回调服务（档② 平台端收发）
#
#   手机 ──(平台回调)──> platform.pl ──(复用 gateway.pl --stdin)──> agent
#          <──(平台发消息 API)──┘
#
# 边界（重要）：白名单、审计、只读工具集、独立历史**全部由 gateway.pl 负责**，
# 这里一行都不重写。本文件只做三件事：验签、解密、把回复发回平台。
#
# 凭据由使用者在本机录入（--init），存 ~/.claude-agent/platform.conf（0600）；
# 仓库里不含任何人的凭据。
#
# 用法：
#   perl remote/platform.pl --init                     交互式录入凭据
#   perl remote/platform.pl --check                    只校验配置是否齐全
#   perl remote/platform.pl --serve                    启动回调服务
#   perl remote/platform.pl --test-push "文本" --to ID  用当前凭据给自己发一条
#
# 零 CPAN：核心模块 + 系统 curl + 系统 openssl（macOS 自带）。
#
use strict;
use warnings;
# 本文件里的中文是 UTF-8 字面量：没有 use utf8 时它们是「字节」，
# 再经 binmode ':encoding(UTF-8)' 输出就会双重编码（实测中文变乱码）。
use utf8;
use IO::Socket::INET;
use IPC::Open3 qw(open3);
use Symbol qw(gensym);
use MIME::Base64 qw(decode_base64);
use Encode qw(decode encode);
use Digest::SHA qw(sha1_hex sha256 sha256_hex);
use File::Path qw(make_path);
use File::Basename qw(dirname);

binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

my $HOME       = $ENV{HOME} || '/tmp';
my $AGENT_DIR  = "$HOME/.claude-agent";
my $CONF_PATH  = $ENV{PLATFORM_CONF} || "$AGENT_DIR/platform.conf";
my $AUDIT_PATH = $ENV{AUDIT_PATH}    || "$AGENT_DIR/audit.log";
my $SCRIPT_DIR = dirname(__FILE__);
my $GATEWAY    = $ENV{GATEWAY_CMD} || "$^X $SCRIPT_DIR/gateway.pl";
my $CURL       = $ENV{CURL_BIN}    || 'curl';
my $OPENSSL    = $ENV{OPENSSL_BIN} || 'openssl';
# 仅测试用：把平台 API 指到本地假服务
my $API_BASE   = $ENV{PLATFORM_API_BASE} || '';

# ------------------------------------------------------------------ 日志 / 审计
sub audit {
    my ($ev, @kv) = @_;
    my $line = sprintf("%s platform %s %s\n", scalar(localtime()), $ev, join(' ', @kv));
    print STDERR $line if $ENV{PLATFORM_VERBOSE};
    make_path(dirname($AUDIT_PATH)) unless -d dirname($AUDIT_PATH);
    my $fresh = !-e $AUDIT_PATH;
    if (open(my $af, '>>:encoding(UTF-8)', $AUDIT_PATH)) {
        print $af $line;
        close $af;
        chmod 0600, $AUDIT_PATH if $fresh;
    }
}

# ------------------------------------------------------------------ 配置
sub load_conf {
    my %c;
    return \%c unless -e $CONF_PATH;
    open(my $fh, '<:encoding(UTF-8)', $CONF_PATH) or return \%c;
    while (my $l = <$fh>) {
        $l =~ s/\r?\n$//;
        next if $l =~ /^\s*(?:#|$)/;
        next unless $l =~ /^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$/;
        my ($k, $v) = ($1, $2);
        $v =~ s/^["']//;
        $v =~ s/["']$//;
        $c{$k} = $v;
    }
    close $fh;
    return \%c;
}

sub save_conf {
    my ($c) = @_;
    make_path($AGENT_DIR) unless -d $AGENT_DIR;
    open(my $fh, '>:encoding(UTF-8)', $CONF_PATH) or die "无法写入 $CONF_PATH: $!";
    print $fh "# 平台回调凭据（remote/platform.pl --init 生成）\n";
    print $fh "# 这是凭据文件：权限 0600，不要提交到任何仓库。\n";
    print $fh "$_ = $c->{$_}\n" for sort keys %$c;
    close $fh;
    chmod 0600, $CONF_PATH;
    print "已保存：$CONF_PATH（0600）\n";
}

sub required_keys {
    my ($c) = @_;
    my $p = $c->{PLATFORM} // '';
    return ('PLATFORM') unless $p ne '';
    return ('WECOM_CORP_ID', 'WECOM_AGENT_ID', 'WECOM_CORP_SECRET', 'WECOM_AES_KEY')
        if $p eq 'wecom';
    return ('FEISHU_APP_ID', 'FEISHU_APP_SECRET') if $p eq 'feishu';
    return ('PLATFORM');
}

sub missing_keys {
    my ($c) = @_;
    return grep { !defined $c->{$_} || $c->{$_} !~ /\S/ } required_keys($c);
}

# ------------------------------------------------------------------ 隐藏输入
sub read_secret {
    my ($prompt) = @_;
    print $prompt;
    my $stty = '';
    if (-t STDIN) {
        my $p = `command -v stty 2>/dev/null`;
        chomp $p;
        $stty = $p if $p ne '';
        system("$stty -echo") if $stty ne '';
    }
    my $v = <STDIN>;
    system("$stty echo") if $stty ne '';
    print "\n";
    return '' unless defined $v;
    $v =~ s/\r?\n$//;
    return $v;
}

# ------------------------------------------------------------------ AES（系统 openssl）
# 解密：密文写 0600 临时文件 → openssl -nopad → 读回 → 自己去填充。
sub aes_decrypt {
    my ($key, $iv, $ct) = @_;
    return undef if !defined $key || length($key) == 0;
    return undef if !defined $ct  || length($ct) == 0;
    make_path("$AGENT_DIR/tmp") unless -d "$AGENT_DIR/tmp";
    my $id = "$$." . int(rand(1e6));
    my $in  = "$AGENT_DIR/tmp/ct.$id";
    my $out = "$AGENT_DIR/tmp/pt.$id";
    open(my $fh, '>:raw', $in) or return undef;
    print $fh $ct;
    close $fh;
    chmod 0600, $in;
    my $errh = gensym;
    my ($in_h, $out_h);
    my $pid = eval {
        open3($in_h, $out_h, $errh, $OPENSSL, 'enc', '-d', '-aes-256-cbc',
              '-K', unpack('H*', $key), '-iv', unpack('H*', $iv),
              '-nopad', '-in', $in, '-out', $out);
    };
    my $errs = '';
    if ($pid) {
        close $in_h;
        close $out_h;
        $errs = do { local $/; <$errh> } // '';
        close $errh;
        waitpid($pid, 0);
    }
    my $plain;
    if ($pid && -e $out && open(my $rf, '<:raw', $out)) {
        local $/;
        $plain = <$rf>;
        close $rf;
    } else {
        audit('aes_fail', 'openssl=' . substr($errs, 0, 120));
    }
    unlink $in, $out;
    return $plain;
}

sub pkcs7_strip {
    my ($buf, $block) = @_;
    return $buf unless defined $buf && length($buf);
    $block ||= 32;
    my $pad = ord(substr($buf, -1));
    return $buf if $pad < 1 || $pad > $block || $pad > length($buf);
    return $buf unless substr($buf, length($buf) - $pad) eq chr($pad) x $pad;
    return substr($buf, 0, length($buf) - $pad);
}

sub wecom_cek {
    my ($aes_key) = @_;
    my $raw = decode_base64(($aes_key // '') . '=');
    return undef unless defined $raw && length($raw) == 32;
    return $raw;
}

# ReceiveId 必须等于本企业 CorpID（企微规范）。配置里没写 CorpID 时跳过。
sub receiveid_ok {
    my ($c, $rid) = @_;
    my $want = $c->{WECOM_CORP_ID} // '';
    return 1 if $want !~ /\S/;
    return 0 unless defined $rid;
    $rid =~ s/\x00+$//;
    return $rid eq $want;
}

sub wecom_sig {
    my ($token, $ts, $nonce, $enc) = @_;
    return sha1_hex(join('', sort { $a cmp $b } ($token // '', $ts // '', $nonce // '', $enc // '')));
}

# 企微明文结构：16 字节随机 + 4 字节大端长度 + 消息 + ReceiveId + 32 字节块填充
# 返回 { msg => ..., receiveid => ... }。ReceiveId 是本企业 CorpID：密文被改过时
# 它就对不上，这是官方规范里的完整性校验（只做 PKCS#7 判断是不够的）。
sub wecom_decrypt {
    my ($aes_key, $b64) = @_;
    my $key = wecom_cek($aes_key) or do { audit('aes_fail', 'bad EncodingAESKey'); return undef };
    my $ct = decode_base64($b64 // '');
    return undef unless defined $ct && length($ct);
    my $plain = aes_decrypt($key, substr($key, 0, 16), $ct);
    return undef unless defined $plain;
    $plain = pkcs7_strip($plain, 32);
    return undef if length($plain) < 20;
    my $len = unpack('N', substr($plain, 16, 4));
    return undef if $len <= 0 || 20 + $len > length($plain);
    return {
        msg       => substr($plain, 20, $len),
        receiveid => substr($plain, 20 + $len),
    };
}

# 飞书：key = sha256(EncryptKey)，密文 = base64(IV(16) + cipher)，16 字节块
sub feishu_decrypt {
    my ($encrypt_key, $b64) = @_;
    return undef unless defined $encrypt_key && $encrypt_key =~ /\S/;
    my $raw = decode_base64($b64 // '');
    return undef unless defined $raw && length($raw) > 16;
    my $plain = aes_decrypt(sha256($encrypt_key), substr($raw, 0, 16), substr($raw, 16));
    return undef unless defined $plain;
    return pkcs7_strip($plain, 16);
}

# ------------------------------------------------------------------ JSON（够用即可）
sub json_esc {
    my ($s) = @_;
    return '""' unless defined $s;
    $s =~ s/\\/\\\\/g;
    $s =~ s/"/\\"/g;
    $s =~ s/\n/\\n/g;
    $s =~ s/\r/\\r/g;
    $s =~ s/\t/\\t/g;
    $s =~ s/([\x00-\x1f])/sprintf('\\u%04x', ord($1))/ge;
    return '"' . $s . '"';
}

sub json_get {
    my ($s, $key) = @_;
    return undef unless defined $s;
    return undef unless $s =~ /"\Q$key\E"\s*:\s*"((?:[^"\\]|\\.)*)"/;
    my $v = $1;
    # 顺序很重要：先把 \\ 还原成 \，再把 \uXXXX 变成字符。
    # 反过来的话，JSON 里写了 \\u770b（转义的转义）会被解成「\看」这种垃圾。
    $v =~ s/\\\\/\\/g;
    $v =~ s/\\n/\n/g;
    $v =~ s/\\r/\r/g;
    $v =~ s/\\t/\t/g;
    $v =~ s/\\"/"/g;
    $v =~ s/\\u([0-9a-fA-F]{4})/chr(hex($1))/ge;
    return $v;
}

sub urlenc {
    my ($s) = @_;
    $s = '' unless defined $s;
    $s =~ s/([^A-Za-z0-9_.~-])/sprintf('%%%02X', ord($1))/ge;
    return $s;
}

# ------------------------------------------------------------------ HTTP 调用（curl -K -）
sub api_url {
    my ($url) = @_;
    return $url unless $API_BASE ne '';
    $url =~ s{^https://qyapi\.weixin\.qq\.com}{$API_BASE};
    $url =~ s{^https://open\.feishu\.cn}{$API_BASE};
    return $url;
}

# 秘密（token / secret）只写进 stdin 喂给 curl 的配置，不进 argv；
# 请求体写 0600 临时文件后立刻删。
sub http_post {
    my ($url, $body, $auth) = @_;
    $url = api_url($url);
    my $is_local = $url =~ m{^http://(?:127\.0\.0\.1|localhost|\[::1\])(?::\d+)?/};
    return (0, '', 'url 必须是 https（测试用的 127.0.0.1 除外）')
        unless $url =~ m{^https://} || $is_local;

    make_path("$AGENT_DIR/tmp") unless -d "$AGENT_DIR/tmp";
    my $tmp = "$AGENT_DIR/tmp/body.$$." . int(rand(1e6));
    open(my $bf, '>:encoding(UTF-8)', $tmp) or return (0, '', "临时文件写入失败: $!");
    print $bf $body;
    close $bf;
    chmod 0600, $tmp;

    my $cfg = qq{url = "$url"\n};
    $cfg .= qq{header = "content-type: application/json"\n};
    $cfg .= qq{header = "$auth"\n} if defined $auth && $auth ne '';
    $cfg .= qq{silent\nshow-error\nmax-time = "15"\n};

    my $errh = gensym;
    my ($in, $out);
    my $pid = eval {
        open3($in, $out, $errh, $CURL, '-K', '-', '--data-binary', '@' . $tmp,
              '-w', "\n%{http_code}");
    };
    if (!$pid) {
        unlink $tmp;
        return (0, '', "无法运行 curl: $@");
    }
    binmode($out, ':encoding(UTF-8)');
    print $in $cfg;
    close $in;
    my $resp = do { local $/; <$out> } // '';
    close $out;
    my $errs = do { local $/; <$errh> } // '';
    close $errh;
    waitpid($pid, 0);
    unlink $tmp;

    my $code = '';
    my $payload = $resp;
    if ($resp =~ /^(.*)\n([0-9]{3})\s*$/s) { $payload = $1; $code = $2 }
    elsif ($resp =~ /^\s*([0-9]{3})\s*$/) { $payload = ''; $code = $1 }
    if ($code eq '' && $errs =~ /\S/) {
        return (0, $payload, 'curl: ' . substr($errs, 0, 160));
    }
    return (0, $payload, "HTTP $code") unless $code eq '200';
    return (1, $payload, '');
}

# 错误码：企微 HTTP 200 但 errcode != 0；飞书 code != 0
sub api_error {
    my ($payload) = @_;
    return undef unless defined $payload;
    return $1 if $payload =~ /"errcode"\s*:\s*(-?\d+)/;
    return $1 if $payload =~ /"(?:code|StatusCode)"\s*:\s*(-?\d+)/;
    return undef;
}

# --- 企业微信 ---
my %TOKEN;   # { wecom|feishu => { val, exp } }

sub wecom_token {
    my ($c) = @_;
    my $now = time;
    return $TOKEN{wecom}{val} if $TOKEN{wecom}{val} && $TOKEN{wecom}{exp} > $now + 60;
    my ($ok, $payload, $err) = http_post(
        'https://qyapi.weixin.qq.com/cgi-bin/gettoken?corpid=' . urlenc($c->{WECOM_CORP_ID})
            . '&corpsecret=' . urlenc($c->{WECOM_CORP_SECRET}), '', undef);
    if (!$ok) { audit('wecom_token_fail', "err=$err"); return undef }
    my $tok = json_get($payload, 'access_token');
    my $ec  = api_error($payload);
    if (!defined $tok || (defined $ec && $ec ne '0')) {
        audit('wecom_token_fail', 'errcode=' . ($ec // '?'));
        return undef;
    }
    my $exp = json_get($payload, 'expires_in') // 7200;
    $TOKEN{wecom} = { val => $tok, exp => $now + $exp };
    return $tok;
}

sub wecom_send {
    my ($c, $to, $text) = @_;
    my $tok = wecom_token($c) or return 0;
    my $json = '{"touser":' . json_esc($to)
             . ',"msgtype":"text","agentid":' . ($c->{WECOM_AGENT_ID} // 0)
             . ',"text":{"content":' . json_esc($text) . '},"safe":0}';
    my ($ok, $payload, $err) = http_post(
        "https://qyapi.weixin.qq.com/cgi-bin/message/send?access_token=" . urlenc($tok),
        $json, undef);
    my $ec = api_error($payload);
    if (!$ok || (defined $ec && $ec ne '0')) {
        audit('wecom_send_fail', 'err=' . $err . ' errcode=' . ($ec // '?'));
        return 0;
    }
    audit('wecom_sent', "to=$to len=" . length($text));
    return 1;
}

# --- 飞书 ---
sub feishu_token {
    my ($c) = @_;
    my $now = time;
    return $TOKEN{feishu}{val} if $TOKEN{feishu}{val} && $TOKEN{feishu}{exp} > $now + 60;
    my $json = '{"app_id":' . json_esc($c->{FEISHU_APP_ID})
             . ',"app_secret":' . json_esc($c->{FEISHU_APP_SECRET}) . '}';
    my ($ok, $payload, $err) = http_post(
        'https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal',
        $json, undef);
    my $tok = json_get($payload, 'tenant_access_token');
    my $ec  = api_error($payload);
    if (!$ok || !defined $tok || (defined $ec && $ec ne '0')) {
        audit('feishu_token_fail', 'err=' . $err . ' code=' . ($ec // '?'));
        return undef;
    }
    my $exp = json_get($payload, 'expire') // 7200;
    $TOKEN{feishu} = { val => $tok, exp => $now + $exp };
    return $tok;
}

sub feishu_send {
    my ($c, $open_id, $text) = @_;
    my $tok = feishu_token($c) or return 0;
    my $content = '{"text":' . json_esc($text) . '}';
    my $json = '{"receive_id":' . json_esc($open_id)
             . ',"msg_type":"text","content":' . json_esc($content) . '}';
    my ($ok, $payload, $err) = http_post(
        'https://open.feishu.cn/open-apis/im/v1/messages?receive_id_type=open_id',
        $json, "authorization: Bearer $tok");
    my $ec = api_error($payload);
    if (!$ok || (defined $ec && $ec ne '0')) {
        audit('feishu_send_fail', 'err=' . $err . ' code=' . ($ec // '?'));
        return 0;
    }
    audit('feishu_sent', "to=$open_id len=" . length($text));
    return 1;
}

sub send_text {
    my ($c, $to, $text) = @_;
    return wecom_send($c, $to, $text)  if ($c->{PLATFORM} // '') eq 'wecom';
    return feishu_send($c, $to, $text) if ($c->{PLATFORM} // '') eq 'feishu';
    audit('send_skip', 'unknown platform');
    return 0;
}

# ------------------------------------------------------------------ 交给网关（复用白名单/审计/只读）
sub run_gateway {
    my ($sender, $text) = @_;
    my $json = '{"from":' . json_esc($sender) . ',"text":' . json_esc($text) . "}\n";
    my $errh = gensym;
    my ($in, $out);
    # 用 --stdin：消息内容不进 argv，ps 里看不到
    my @cmd = split /\s+/, $GATEWAY;
    my $pid = eval { open3($in, $out, $errh, @cmd, '--stdin') };
    if (!$pid) { audit('gateway_fail', "cannot start: $@"); return undef }
    binmode($in,  ':encoding(UTF-8)');
    binmode($out, ':encoding(UTF-8)');
    print $in $json;
    close $in;
    my $reply = do { local $/; <$out> } // '';
    close $out;
    my $errs = do { local $/; <$errh> } // '';
    close $errh;
    waitpid($pid, 0);
    audit('gateway_done', 'reply_len=' . length($reply)) if $errs !~ /\S/;
    $reply =~ s/\s+$//;
    return $reply;
}

sub dispatch {
    my ($c, $sender, $text) = @_;
    return 0 if !defined $text || $text !~ /\S/;
    audit('inbound', "from=$sender len=" . length($text));
    # 后台处理：平台要求 5 秒内应答，长任务必须先返回
    my $pid = fork();
    if (!defined $pid) {
        my $r = run_gateway($sender, $text);
        send_text($c, $sender, $r) if defined $r && $r =~ /\S/;
        return 0;
    }
    return 0 if $pid;
    # 子进程
    $SIG{CHLD} = 'DEFAULT';
    my $reply = run_gateway($sender, $text);
    send_text($c, $sender, $reply) if defined $reply && $reply =~ /\S/;
    exit 0;
}

# ------------------------------------------------------------------ HTTP 服务
sub read_request {
    my ($sock) = @_;
    my $buf = '';
    while ($buf !~ /\r?\n\r?\n/ && length($buf) < 65536) {
        my $n = sysread($sock, my $chunk, 8192);
        last unless defined $n && $n > 0;
        $buf .= $chunk;
    }
    return undef if $buf eq '';
    my ($head, $rest) = split(/\r?\n\r?\n/, $buf, 2);
    $rest = '' unless defined $rest;
    my @lines = split(/\r?\n/, $head);
    my $line = shift @lines // '';
    my ($method, $path) = $line =~ m{^(\S+)\s+(\S+)};
    my %h;
    for my $l (@lines) {
        next unless $l =~ /^([^:]+):\s*(.*)$/;
        $h{lc $1} = $2;
    }
    my $len = $h{'content-length'} // 0;
    while (length($rest) < $len) {
        my $n = sysread($sock, my $chunk, 8192);
        last unless defined $n && $n > 0;
        $rest .= $chunk;
    }
    return { method => $method // 'GET', path => $path // '/', headers => \%h, body => $rest };
}

sub respond {
    my ($sock, $code, $ctype, $body) = @_;
    my %reason = (200 => 'OK', 400 => 'Bad Request', 403 => 'Forbidden', 404 => 'Not Found');
    $body = '' unless defined $body;
    my $bytes = encode('UTF-8', $body);      # 内容是字符，socket 要字节
    my $out = "HTTP/1.1 $code " . ($reason{$code} // 'OK')
            . "\r\nContent-Type: $ctype\r\nContent-Length: " . length($bytes)
            . "\r\nConnection: close\r\n\r\n" . $bytes;
    syswrite($sock, $out);
}

sub qs {
    my ($q, $k) = @_;
    return undef unless defined $q;
    for my $kv (split(/&/, $q)) {
        my ($kk, $vv) = split(/=/, $kv, 2);
        next unless defined $kk && $kk eq $k;
        $vv = '' unless defined $vv;
        $vv =~ tr/+/ /;
        $vv =~ s/%([0-9a-fA-F]{2})/chr(hex($1))/ge;
        return $vv;
    }
    return undef;
}

sub handle_wecom {
    my ($c, $sock, $r) = @_;
    my ($path, $q) = split(/\?/, $r->{path} // '', 2);
    my $sig   = qs($q, 'msg_signature');
    my $ts    = qs($q, 'timestamp');
    my $nonce = qs($q, 'nonce');
    my $token = $c->{WECOM_CALLBACK_TOKEN} // '';

    if ($r->{method} eq 'GET') {                       # 配置回调 URL 时的验证
        my $echo = qs($q, 'echostr') // '';
        my $want = wecom_sig($token, $ts, $nonce, $echo);
        unless (defined $sig && $sig eq $want) {
            audit('wecom_verify_fail', 'sig mismatch');
            return respond($sock, 403, 'text/plain', '');
        }
        my $d = wecom_decrypt($c->{WECOM_AES_KEY}, $echo);
        unless (defined $d) { return respond($sock, 400, 'text/plain', '') }
        unless (receiveid_ok($c, $d->{receiveid})) {
            audit('wecom_receiveid_fail', 'URL 验证');
            return respond($sock, 400, 'text/plain', '');
        }
        audit('wecom_verify_ok', '');
        return respond($sock, 200, 'text/plain', decode('UTF-8', $d->{msg}));
    }

    my $body = $r->{body} // '';
    my ($enc) = $body =~ m{<Encrypt>\s*(?:<!\[CDATA\[)?(.*?)(?:\]\]>)?\s*</Encrypt>}s;
    unless (defined $enc) {
        audit('wecom_bad_body', 'no Encrypt');
        return respond($sock, 400, 'text/plain', '');
    }
    my $want = wecom_sig($token, $ts, $nonce, $enc);
    unless (defined $sig && $sig eq $want) {
        audit('wecom_sig_fail', 'dropped');            # 不回原因，避免暴露服务存在
        return respond($sock, 403, 'text/plain', '');
    }
    my $d = wecom_decrypt($c->{WECOM_AES_KEY}, $enc);
    unless (defined $d) {
        audit('wecom_decrypt_fail', '');
        return respond($sock, 400, 'text/plain', '');
    }
    unless (receiveid_ok($c, $d->{receiveid})) {
        audit('wecom_receiveid_fail', '密文被改或不是发给本企业的');
        return respond($sock, 400, 'text/plain', '');
    }
    my $plain = decode('UTF-8', $d->{msg});
    my ($from)  = $plain =~ m{<FromUserName>\s*(?:<!\[CDATA\[)?(.*?)(?:\]\]>)?\s*</FromUserName>}s;
    my ($text)  = $plain =~ m{<Content>\s*(?:<!\[CDATA\[)?(.*?)(?:\]\]>)?\s*</Content>}s;
    my ($mtype) = $plain =~ m{<MsgType>\s*(?:<!\[CDATA\[)?(.*?)(?:\]\]>)?\s*</MsgType>}s;
    respond($sock, 200, 'text/plain', 'success');      # 平台要求 5 秒内应答
    if ((defined $mtype && $mtype ne 'text') || !defined $from) {
        audit('wecom_skip', 'type=' . ($mtype // '?'));
        return 1;
    }
    dispatch($c, $from, $text);
    return 1;
}

sub handle_feishu {
    my ($c, $sock, $r) = @_;
    my $body = $r->{body} // '';
    my $ek = $c->{FEISHU_ENCRYPT_KEY} // '';

    if ($ek =~ /\S/) {                                 # 签名 = sha256(ts+nonce+key+body)
        my $ts   = $r->{headers}{'x-lark-request-timestamp'} // '';
        my $nc   = $r->{headers}{'x-lark-request-nonce'} // '';
        my $got  = $r->{headers}{'x-lark-signature'} // '';
        my $want = sha256_hex("$ts$nc$ek$body");
        unless ($got eq $want) {
            audit('feishu_sig_fail', 'dropped');
            return respond($sock, 403, 'application/json', '{}');
        }
    }

    if ($body =~ /"encrypt"\s*:\s*"([^"]+)"/) {        # 加密事件
        my $plain = feishu_decrypt($ek, $1);
        unless (defined $plain) {
            audit('feishu_decrypt_fail', '');
            return respond($sock, 400, 'application/json', '{}');
        }
        $body = decode('UTF-8', $plain);
    }

    if ($body =~ /"challenge"\s*:\s*"([^"]*)"/) {      # URL 验证
        audit('feishu_verify_ok', '');
        return respond($sock, 200, 'application/json', '{"challenge":"' . $1 . '"}');
    }

    my $vt = $c->{FEISHU_VERIFY_TOKEN} // '';
    if ($vt =~ /\S/ && (json_get($body, 'token') // '') ne $vt) {
        audit('feishu_token_fail', 'dropped');
        return respond($sock, 403, 'application/json', '{}');
    }

    my $etype = json_get($body, 'type') // '';
    if ($etype ne '' && $etype ne 'event_callback') {
        return respond($sock, 200, 'application/json', '{}');
    }

    my $open_id = json_get($body, 'open_id');
    my $content = json_get($body, 'content') // '';
    my $text = $content;
    $text = json_get($content, 'text') // '' if $content =~ /^\s*\{/;
    respond($sock, 200, 'application/json', '{}');
    if (!defined $open_id || $open_id !~ /\S/) {
        audit('feishu_skip', 'no open_id');
        return 1;
    }
    dispatch($c, $open_id, $text);
    return 1;
}

sub serve {
    my ($c) = @_;
    my $port = $ENV{PORT} || $c->{PORT} || 8099;
    my $srv = IO::Socket::INET->new(
        LocalAddr => '0.0.0.0', LocalPort => $port, Listen => 16,
        ReuseAddr => 1, Proto => 'tcp') or die "无法监听端口 $port: $!\n";
    print "监听 0.0.0.0:$port（platform=" . ($c->{PLATFORM} // '?') . "）\n";
    $SIG{CHLD} = 'DEFAULT';
    while (my $cli = $srv->accept()) {
        my $r = eval { read_request($cli) };
        if (!$r) { close $cli; next }
        eval {
            my $p = $r->{path} // '';
            if    ($p =~ m{^/wecom})  { handle_wecom($c, $cli, $r) }
            elsif ($p =~ m{^/feishu}) { handle_feishu($c, $cli, $r) }
            else                      { respond($cli, 404, 'text/plain', '') }
        };
        audit('handler_error', substr($@, 0, 160)) if $@;
        close $cli;
        while (waitpid(-1, 1) > 0) { }                 # 回收后台子进程
    }
}

# ------------------------------------------------------------------ 交互式录入
sub do_init {
    print "\n平台接入配置（凭据只写到本机 $CONF_PATH，权限 0600）\n\n";
    print "选择平台：1) 企业微信  2) 飞书  [1]: ";
    my $sel = <STDIN> // '';
    $sel =~ s/\r?\n$//;
    my %c;
    if ($sel eq '2') {
        $c{PLATFORM} = 'feishu';
        print "\n飞书：开发者后台 → 应用 → 凭证与基础信息。\n";
        print "App ID: "; my $id = <STDIN> // ''; $id =~ s/\r?\n$//; $c{FEISHU_APP_ID} = $id;
        $c{FEISHU_APP_SECRET} = read_secret('App Secret（输入不显示）: ');
        print "Encrypt Key（事件订阅加密用，可留空）: ";
        my $ek = <STDIN> // ''; $ek =~ s/\r?\n$//; $c{FEISHU_ENCRYPT_KEY} = $ek;
        print "Verification Token（可留空）: ";
        my $vt = <STDIN> // ''; $vt =~ s/\r?\n$//; $c{FEISHU_VERIFY_TOKEN} = $vt;
    } else {
        $c{PLATFORM} = 'wecom';
        print "\n企业微信：管理后台 → 应用 → 自建应用 → 接收消息（API 接收）。\n";
        print "企业 ID（CorpID）: "; my $cid = <STDIN> // ''; $cid =~ s/\r?\n$//; $c{WECOM_CORP_ID} = $cid;
        print "应用 AgentId（数字）: "; my $aid = <STDIN> // ''; $aid =~ s/\r?\n$//; $c{WECOM_AGENT_ID} = $aid;
        $c{WECOM_CORP_SECRET}    = read_secret('应用 Secret（输入不显示）: ');
        $c{WECOM_CALLBACK_TOKEN} = read_secret('回调 Token（输入不显示，建议填）: ');
        $c{WECOM_AES_KEY}        = read_secret('EncodingAESKey（43 位，输入不显示）: ');
    }
    print "\n回调监听端口 [8099]: ";
    my $port = <STDIN> // '';
    $port =~ s/\r?\n$//;
    $c{PORT} = ($port =~ /^\d+$/ ? $port : 8099);
    save_conf(\%c);
    print "\n下一步：\n";
    print "  1) 把平台的回调地址指向这台机器的 /wecom 或 /feishu（需公网可达）\n";
    print "  2) 在 ~/.claude-agent/remote.conf 里配 ALLOW = <你的平台 ID>（企微 UserID / 飞书 open_id）\n";
    print "  3) perl remote/platform.pl --serve\n\n";
    return 0;
}

# ------------------------------------------------------------------ main
my $MODE = '';
my $TEXT = '';
my $TO   = '';
while (my $a = @ARGV ? shift @ARGV : undef) {
    if    ($a eq '--init')      { $MODE = 'init' }
    elsif ($a eq '--check')     { $MODE = 'check' }
    elsif ($a eq '--serve')     { $MODE = 'serve' }
    elsif ($a eq '--test-push') { $MODE = 'test-push'; $TEXT = shift(@ARGV) // '来自 platform.pl 的测试消息' }
    elsif ($a eq '--to')        { $TO = shift(@ARGV) // '' }
    elsif ($a eq '--help' || $a eq '-h') {
        print "用法: platform.pl --init | --check | --serve | --test-push \"文本\" --to <ID>\n";
        exit 0;
    }
    else { print STDERR "未知参数: $a\n"; exit 2 }
}

if ($MODE eq '' || $MODE eq 'check') {
    my $c = load_conf();
    my @miss = missing_keys($c);
    if (@miss) {
        print "配置不完整，缺少：@miss\n路径: $CONF_PATH\n先跑 perl remote/platform.pl --init\n";
        exit 1;
    }
    print "配置齐全：platform=" . ($c->{PLATFORM} // '?') . " port=" . ($c->{PORT} // 8099) . "\n";
    print "白名单在 ~/.claude-agent/remote.conf 的 ALLOW（与网关共用一份）。\n";
    exit 0;
}

if ($MODE eq 'init') { exit do_init() }

if ($MODE eq 'test-push') {
    my $c = load_conf();
    my @miss = missing_keys($c);
    if (@miss) { print "配置不完整，缺少：@miss\n"; exit 1 }
    $TO = $c->{TEST_TO} // '' if $TO eq '';
    if ($TO eq '') { print "用 --to <ID> 指定收件人（企微 UserID / 飞书 open_id）\n"; exit 2 }
    my $ok = send_text($c, $TO, $TEXT);
    print $ok ? "发送成功\n" : "发送失败（看上面的错误）\n";
    exit($ok ? 0 : 1);
}

if ($MODE eq 'serve') {
    my $c = load_conf();
    my @miss = missing_keys($c);
    if (@miss) { print STDERR "配置不完整，缺少：@miss（先 --init）\n"; exit 1 }
    serve($c);
    exit 0;
}

print STDERR "模式未指定，用 --init / --check / --serve / --test-push\n";
exit 2;
