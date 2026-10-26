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
use Fcntl qw(O_WRONLY O_CREAT O_APPEND);
use File::Basename qw(dirname);
use IO::Select;

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
# 安全默认值（都可用环境变量/配置覆盖，但默认必须是安全的那一侧）
my $MAX_SKEW    = 300;            # 秒：时间戳超出即拒，防重放
my $MAX_BODY    = 262144;         # 字节：请求体上限，防内存打爆
my $MAX_QUEUE   = 32;             # 待处理消息上限（防刷），超出即丢
my $GW_IDLE     = 1800;           # 秒：常驻网关空闲这么久就回收
# 平台对单条文本有长度上限，超了会被平台直接拒（长时间思考的回答很容易超）。
# 注意单位是**字节**：企微 text 上限 2048 字节，中文一个字 3 字节，
# 按字符算会超（实测 2000 字符 ≈ 6000 字节，平台直接拒发）。
my %TEXT_LIMIT  = (wecom => 1900, feishu => 3800);
my $ACK_AFTER   = 3;              # 秒：超过这么久还没结果就先回一句"处理中"
my $ACK_TEXT    = '收到，正在处理…（完成后把结果发给你）';
# 中继模式：platform.pl 跑在公网服务器上、真正干活的 Mac 在 NAT 后面时用。
# 配了 RELAY_URL + RELAY_TOKEN 就不再本地起网关，改走中继队列。
my ($RELAY_URL, $RELAY_TOKEN) = ('', '');
my $RELAY_POLL  = 3;              # 秒：多久问一次中继有没有结果
my %RL_PENDING;                   # sender => 已投进中继但还没拿到结果的消息数
my $DEFAULT_BIND = '127.0.0.1';   # 默认只听本机：对外要靠穿透/反代，别把明文撒到局域网
my %GW;            # sender => { in, out, errh, pid, last }
our ($JOB_R, $JOB_W);   # 主进程 → 工作进程 的任务管道
my $QUEUE_N = 0;   # 已入队未回复的消息数
# 平台会在超时后重投同一条消息（企微/飞书都会）。没有去重就会出现
# 「一条指令被跑两遍」——对能改文件、能跑命令的 agent 来说这是真事故。
# 按平台侧 MessageId 去重；没有 MessageId 时退回用签名摘要。
my $DEDUP_TTL = 600;              # 秒
my %SEEN;                         # key => 过期时间

# ------------------------------------------------------------------ 日志 / 审计
sub audit {
    my ($ev, @kv) = @_;
    my $line = sprintf("%s platform %s %s\n", scalar(localtime()), $ev, join(' ', @kv));
    print STDERR $line if $ENV{PLATFORM_VERBOSE};
    make_path(dirname($AUDIT_PATH)) unless -d dirname($AUDIT_PATH);
    my $fresh = !-e $AUDIT_PATH;
    if (my $af = open_private($AUDIT_PATH, O_WRONLY | O_CREAT | O_APPEND)) {
        binmode($af, ':encoding(UTF-8)');
        print $af $line;
        close $af;
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

# 以 0600 创建：open 之后再 chmod 有一瞬间是 0644（umask 022 时），
# 那一瞬间别的进程能读到密钥。sysopen 带 mode 没有这个窗口。
sub open_private {
    my ($path, $mode) = @_;
    $mode ||= O_WRONLY | O_CREAT;
    my $old = umask(077);
    sysopen(my $fh, $path, $mode, 0600) or do { umask($old); return undef };
    umask($old);
    return $fh;
}

sub save_conf {
    my ($c) = @_;
    make_path($AGENT_DIR) unless -d $AGENT_DIR;
    my $fh = open_private($CONF_PATH) or die "无法写入 $CONF_PATH: $!";
    binmode($fh, ':encoding(UTF-8)');
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
    my $fh = open_private($in) or return undef;
    binmode($fh);
    print $fh $ct;
    close $fh;
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
    my $raw = decode_base64(encode('UTF-8', ($aes_key // '')) . '=');
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
    # 摘要只接受字节：配置里的值是字符，先编码再哈希（否则 wide character 会抛异常）
    return sha1_hex(encode('UTF-8', join('', sort { $a cmp $b }
        ($token // '', $ts // '', $nonce // '', $enc // ''))));
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
    my $plain = aes_decrypt(sha256(encode('UTF-8', $encrypt_key)), substr($raw, 0, 16), substr($raw, 16));
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

# 管道里传的是 JSON 字符串形态，取回来要反转义（只处理我们自己写进去的那几种）
sub json_unescape_str {
    my ($v) = @_;
    return '' unless defined $v;
    $v =~ s/^"//;
    $v =~ s/"$//;
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
    my $bf = open_private($tmp) or return (0, '', "临时文件写入失败: $!");
    binmode($bf, ':encoding(UTF-8)');
    print $bf $body;
    close $bf;

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

# 中继的 GET（/pull /outbox）。和 http_post 一样走 curl -K -，不让 token 出现在 ps 里。
sub http_get {
    my ($url, $auth) = @_;
    return (0, '', 'bad url') unless $url =~ m{^https?://};
    my $cfg = qq{url = "$url"\n};
    $cfg .= qq{header = "$auth"\n} if defined $auth && $auth ne '';
    $cfg .= qq{silent\nshow-error\nmax-time = "10"\n};
    my $errh = gensym;
    my ($in, $out);
    my $pid = eval { open3($in, $out, $errh, $CURL, '-K', '-') };
    return (0, '', "无法运行 curl: $@") unless $pid;
    binmode($out, ':encoding(UTF-8)');
    print {$in} $cfg;
    close $in;
    my $payload = do { local $/; <$out> // '' };
    close $out;
    close $errh;
    waitpid($pid, 0);
    return ($? == 0, $payload, '');
}

# 从 {"key":[{...},{...}]} 里取出每个元素的原文（要能扛住正文里的括号/引号，
# 所以老老实实扫字符串状态，不用正则硬切）。
sub json_list_items {
    my ($json, $key) = @_;
    return () unless defined $json && $json =~ /"\Q$key\E"\s*:\s*\[/;
    my $i = index($json, '[', pos($json) - 1);
    return () if $i < 0;
    my @items;
    my $depth = 0;
    my $in_str = 0;
    my $esc = 0;
    my $cur = '';
    my $end = -1;
    for (my $j = $i; $j < length($json); $j++) {
        my $ch = substr($json, $j, 1);
        if ($in_str) {
            $cur .= $ch if $depth >= 1;
            if ($esc) { $esc = 0 }
            elsif ($ch eq '\\') { $esc = 1 }
            elsif ($ch eq '"') { $in_str = 0 }
            next;
        }
        if ($ch eq '"') { $in_str = 1; $cur .= $ch if $depth >= 1; next }
        if ($ch eq '[' || $ch eq '{') { $depth++ }
        if ($depth >= 2) { $cur .= $ch if $depth == 2 || $ch !~ /[\[\{]/ }
        if ($ch eq ']' || $ch eq '}') {
            $depth--;
            if ($depth == 1 && $ch eq '}') { push @items, $cur; $cur = '' }
            if ($depth == 0) { $end = $j; last }
        }
    }
    return @items;
}

sub relay_on { return ($RELAY_URL ne '' && $RELAY_TOKEN ne '') ? 1 : 0 }

sub relay_push {
    my ($sender, $text) = @_;
    my ($ok, $payload, $err) = http_post($RELAY_URL . '/push',
        '{"from":' . json_esc($sender) . ',"text":' . json_esc($text) . '}',
        'authorization: Bearer ' . $RELAY_TOKEN);
    if (!$ok) { audit('relay_push_fail', 'err=' . $err); return 0 }
    audit('relay_push', "from=$sender");
    return 1;
}

# 取回结果并推给手机。返回取到的条数。
sub relay_drain {
    my ($c) = @_;
    my $n = 0;
    for my $sender (keys %RL_PENDING) {
        my ($ok, $payload, $err) = http_get(
            $RELAY_URL . '/outbox?to=' . urlenc($sender),
            'authorization: Bearer ' . $RELAY_TOKEN);
        next unless $ok;
        for my $r (json_list_items($payload, 'replies')) {
            my $reply = json_get($r, 'reply');
            next unless defined $reply && $reply =~ /\S/;
            send_text($c, $sender, $reply);
            $n++;
            $RL_PENDING{$sender}--;
            delete $RL_PENDING{$sender} if ($RL_PENDING{$sender} // 0) <= 0;
        }
        audit('relay_drain_fail', 'err=' . $err) unless $ok;
    }
    return $n;
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

# 按平台上限切分：企微 2048 字节、飞书 4000 字符，超了平台会拒发。
# 切点不能落在 UTF-8 字符中间，否则平台收到的是乱码。
sub split_text {
    my ($text, $limit) = @_;
    $limit ||= 2000;
    my @out;
    # 按**字节**切，但切点必须落在字符边界（否则平台收到半个汉字）。
    # 用二分找「最大的、编码后不超过 limit 的字符数」。
    my $bytes_of = sub { length(encode('UTF-8', $_[0])) };
    while (length($text) > 0) {
        if ($bytes_of->($text) <= $limit) { push @out, $text; last }
        my ($lo, $hi) = (1, length($text));
        while ($lo < $hi) {
            my $mid = int(($lo + $hi + 1) / 2);
            if ($bytes_of->(substr($text, 0, $mid)) <= $limit) { $lo = $mid }
            else { $hi = $mid - 1 }
        }
        push @out, substr($text, 0, $lo);
        $text = substr($text, $lo);
    }
    return @out;
}

sub send_text {
    my ($c, $to, $text) = @_;
    return 0 unless defined $text && $text =~ /\S/;
    my $plat  = $c->{PLATFORM} // '';
    my $limit = ($TEXT_LIMIT{$plat} || 1900) - 80;   # 80 字节留给「（1/3）」这类前缀
    my @parts = split_text($text, $limit);
    if (@parts > 1) {
        audit('send_split', "parts=" . scalar(@parts) . " limit=$limit");
    }
    my $ok = 1;
    my $i  = 0;
    for my $part (@parts) {
        $i++;
        my $prefix = @parts > 1 ? "（$i/" . scalar(@parts) . "）" : '';
        my $body   = $prefix . $part;
        my $r = $plat eq 'wecom'  ? wecom_send($c, $to, $body)
              : $plat eq 'feishu' ? feishu_send($c, $to, $body)
              : do { audit('send_skip', 'unknown platform'); 0 };
        $ok = 0 unless $r;
        last unless $r;                 # 有一段失败就别继续灌，避免半截消息
    }
    return $ok;
}

# ------------------------------------------------------------------ 交给网关（复用白名单/审计/只读）
sub gw_spawn {
    my ($sender) = @_;
    my $errh = gensym;
    my ($in, $out);
    my @cmd = split /\s+/, $GATEWAY;
    my $pid = eval { open3($in, $out, $errh, @cmd, '--stdin') };
    if (!$pid) { audit('gateway_spawn_fail', "cannot start: $@"); return undef }
    binmode($in,  ':encoding(UTF-8)');
    binmode($out, ':encoding(UTF-8)');
    select((select($in), $| = 1)[0]);          # 不刷新的话子进程收不到，双方互等
    $GW{$sender} = { in => $in, out => $out, errh => $errh, pid => $pid, last => time() };
    audit('gateway_spawn', "from=$sender pid=$pid");
    return $GW{$sender};
}

sub gw_reap {
    my ($sender) = @_;
    my $s = delete $GW{$sender} or return;
    close $s->{in};
    close $s->{out};
    close $s->{errh};
    waitpid($s->{pid}, 0);
    audit('gateway_reap', "from=$sender");
}

# 每个发送者一个常驻网关进程 —— 会话上下文才能接上（多轮对话）。
# stdin 一行一个请求，stdout 一行一个 {"from","reply"}，所以读一行就是这次的结果。
sub gw_call {
    my ($sender, $text, $depth, $on_slow) = @_;
    $depth ||= 0;
    my $s = $GW{$sender} || gw_spawn($sender);
    return undef unless $s;
    $s->{last} = time();
    print { $s->{in} } '{"from":' . json_esc($sender) . ',"text":' . json_esc($text) . "}\n";
    # 先等 ACK_AFTER 秒；还没结果就告诉对方"在处理"，然后继续等真正的结果。
    # 长任务（读一堆文件、跑命令）在手机上只看到"没反应"是很糟的体验。
    if ($ACK_AFTER > 0) {
        my $sel = IO::Select->new($s->{out});
        if (!$sel->can_read($ACK_AFTER)) {
            $on_slow->() if $on_slow;
            audit('ack_sent', "from=$sender");
        }
    }
    my $line = readline($s->{out});
    if (!defined $line) {
        # 网关没了（崩了/被回收）→ 清掉重开一次，别让这一条消息就此消失
        audit('gateway_eof', "from=$sender retry=" . ($depth + 1));
        gw_reap($sender);
        return undef if $depth >= 1;
        return gw_call($sender, $text, $depth + 1, $on_slow);
    }
    my $reply = json_get($line, 'reply');
    audit('gateway_done', 'reply_len=' . length($reply // ''));
    return $reply;
}

sub seen_before {
    my ($key) = @_;
    my $now = time;
    if (%SEEN && $now % 60 == 0) {
        for my $k (keys %SEEN) { delete $SEEN{$k} if $SEEN{$k} < $now }
    }
    return 1 if $SEEN{$key} && $SEEN{$key} >= $now;
    $SEEN{$key} = $now + $DEDUP_TTL;
    return 0;
}

sub dispatch {
    my ($c, $sender, $text, $msg_key) = @_;
    return 0 if !defined $text || $text !~ /\S/;
    my $key = (defined $msg_key && $msg_key =~ /\S/)
        ? "id:$msg_key"
        : 'sig:' . sha1_hex(encode('UTF-8', ($sender // '') . "\x00" . ($text // '')));
    if (seen_before($key)) {
        audit('duplicate_drop', "from=$sender key=$key");
        return 0;
    }
    audit('inbound', "from=$sender len=" . length($text));
    if ($QUEUE_N >= $MAX_QUEUE) {                 # 忙不过来就丢，别把机器拖垮
        audit('busy_drop', "queued=$QUEUE_N");
        return 0;
    }
    $QUEUE_N++;
    print { $JOB_W } json_esc($sender) . "\t" . json_esc($text) . "\n";
    select((select($JOB_W), $| = 1)[0]);
    return 1;
}

# 后台工作进程：串行处理消息，回复走平台 API。
# 串行是特意的：同一个发送者的多轮对话必须按顺序喂给同一个网关进程。
sub worker_loop {
    my ($c) = @_;
    binmode($JOB_R, ':encoding(UTF-8)');
    $SIG{CHLD} = 'DEFAULT';
    if (relay_on()) {
        # 中继模式：平台的回调打到这台机器，真正干活的 Mac 在 NAT 后面。
        # 这里只做「投递 + 取结果」，不碰网关。
        audit('relay_mode', 'queue=' . $RELAY_URL);
        my $sel = IO::Select->new($JOB_R);
        while (1) {
            if ($sel->can_read($RELAY_POLL)) {
                my $line = <$JOB_R>;
                last unless defined $line;
                chomp $line;
                my ($fs, $ts) = split(/\t/, $line, 2);
                my $sender = json_unescape_str($fs // '');
                my $text   = json_unescape_str($ts // '');
                next unless $sender =~ /\S/ && $text =~ /\S/;
                if (relay_push($sender, $text)) {
                    $RL_PENDING{$sender} = ($RL_PENDING{$sender} // 0) + 1;
                    $QUEUE_N--;
                }
                next;
            }
            relay_drain($c);                      # 没新任务就问问结果
        }
        return;
    }
    while (my $line = <$JOB_R>) {
        chomp $line;
        my ($fs, $ts) = split(/\t/, $line, 2);
        my $sender = json_unescape_str($fs // '');
        my $text   = json_unescape_str($ts // '');
        # 空闲太久就回收常驻网关，别一直占着内存
        my $now = time();
        for my $k (keys %GW) { gw_reap($k) if $now - ($GW{$k}{last} // 0) > $GW_IDLE }
        my $reply = gw_call($sender, $text, 0,
            sub { send_text($c, $sender, $ACK_TEXT) });
        send_text($c, $sender, $reply) if defined $reply && $reply =~ /\S/;
        $QUEUE_N--;
    }
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
    if ($len > $MAX_BODY) {
        # 上限之上要「丢弃式读完」再回 400：如果只读一半就关连接，客户端看到的是
        # TCP RST 而不是 400（macOS 上实测如此，Linux 上碰巧能先读到 400）。
        # 丢弃不累积，内存始终只有一块 64KB 的缓冲。
        my $hard = 8 * 1024 * 1024;
        if ($len <= $hard) {
            my $need = $len - length($rest);
            while ($need > 0) {
                my $n = sysread($sock, my $chunk, 65536);
                last unless defined $n && $n > 0;
                $need -= $n;
            }
        }
        return { too_big => 1, method => $method // 'GET', path => $path // '/', headers => \%h, body => '' };
    }
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

# 时间戳必须在 MAX_SKEW 秒内。签名本身覆盖 timestamp，但一份「旧的合法请求」
# 仍然可以原样重放 —— 只有校验新鲜度才能挡住（实测重放会把网关再跑一遍）。
sub fresh_ts {
    my ($ts) = @_;
    return 0 unless defined $ts && $ts =~ /^\d{1,12}$/;
    my $skew = abs(time() - $ts);
    return $skew <= $MAX_SKEW;
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

    unless (fresh_ts($ts)) {                           # 防重放：先看新鲜度
        audit('wecom_stale_ts', 'dropped');
        return respond($sock, 403, 'text/plain', '');
    }

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
    my ($msgid) = $plain =~ m{<MsgId>\s*(?:<!\[CDATA\[)?(\d+)(?:\]\]>)?\s*</MsgId>}s;
    respond($sock, 200, 'text/plain', 'success');      # 平台要求 5 秒内应答
    if ((defined $mtype && $mtype ne 'text') || !defined $from) {
        audit('wecom_skip', 'type=' . ($mtype // '?'));
        return 1;
    }
    dispatch($c, $from, $text, $msgid);
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
        unless (fresh_ts($ts)) {
            audit('feishu_stale_ts', 'dropped');
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
    my $msg_id  = json_get($body, 'message_id');
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

sub cleanup_tmp {
    my $dir = "$AGENT_DIR/tmp";
    return unless -d $dir;
    my $now = time;
    opendir(my $dh, $dir) or return;
    for my $f (readdir $dh) {
        next if $f =~ /^\.\.?$/;
        my $path = "$dir/$f";
        unlink $path if -f $path && $now - (stat($path))[9] > 3600;
    }
    closedir $dh;
}

sub serve {
    my ($c) = @_;
    my $port = $ENV{PORT} || $c->{PORT} || 8099;
    # 默认只听 127.0.0.1：回调正文是明文消息内容，绑 0.0.0.0 等于在同一网络里公开。
    # 要对外就用穿透/反代转发到本机，确实需要监听全部网卡时显式设 BIND。
    my $bind = $ENV{BIND} || $c->{BIND} || $DEFAULT_BIND;
    cleanup_tmp();
    pipe($JOB_R, $JOB_W) or die "无法建任务管道: $!\n";
    my $worker_pid = fork();
    if (!defined $worker_pid) { die "无法启动工作进程: $!\n" }
    if ($worker_pid == 0) {                        # 子进程：专职处理消息
        close $JOB_W;
        worker_loop($c);
        exit 0;
    }
    close $JOB_R;
    select((select($JOB_W), $| = 1)[0]);
    my $srv = IO::Socket::INET->new(
        LocalAddr => $bind, LocalPort => $port, Listen => 16,
        ReuseAddr => 1, Proto => 'tcp') or die "无法监听 $bind:$port: $!\n";
    print "监听 $bind:$port（platform=" . ($c->{PLATFORM} // '?') . "）\n";
    print "注意：默认只监听本机。要让平台回调进来，请用穿透/反向代理转发到 $bind:$port。\n"
        if $bind eq '127.0.0.1';
    if (relay_on()) {
        print "中继模式：消息投到 $RELAY_URL，每 $RELAY_POLL 秒取一次结果。\n";
        print "（本地网关不启动；真正处理消息的机器跑 gateway.pl --poll）\n";
    } else {
        print "每个发送者一个常驻网关进程：多轮对话连续。\n";
    }
    # 子进程退出会送 SIGCHLD，它会打断阻塞中的 accept()，让 accept 返回 undef —
    # 直接把服务退出掉（实测：第二条消息一到，服务就干净地 exit 0 了）。
    # 所以 accept 失败时先看是不是 EINTR，是就重试。
    # 只有工作进程一个子进程；它退出说明后台处理链断了，重开一个
    $SIG{CHLD} = sub {
        my $gone = waitpid(-1, 1);
        if (defined $gone && $gone == $worker_pid) {
            audit('worker_died', 'respawn');
            pipe($JOB_R, $JOB_W) or return;
            my $np = fork();
            if (defined $np && $np == 0) { close $JOB_W; worker_loop($c); exit 0 }
            if (defined $np) {
                close $JOB_R;
                select((select($JOB_W), $| = 1)[0]);
                $worker_pid = $np;
            }
        }
    };
    while (1) {
        my $cli = $srv->accept();
        if (!$cli) {
            next if $!{EINTR};
            last;
        }
        my $r = eval { read_request($cli) };
        if (!$r) { close $cli; next }
        if ($r->{too_big}) {                            # 不读进内存，直接拒
            audit('body_too_big', 'dropped');
            respond($cli, 400, 'text/plain', '');
            close $cli;
            next;
        }
        eval {
            my $p = $r->{path} // '';
            if    ($p =~ m{^/wecom})  { handle_wecom($c, $cli, $r) }
            elsif ($p =~ m{^/feishu}) { handle_feishu($c, $cli, $r) }
            else                      { respond($cli, 404, 'text/plain', '') }
        };
        audit('handler_error', substr($@, 0, 160)) if $@;
        close $cli;
        waitpid($worker_pid, 1);                       # 回收（工作进程正常时不会退出）
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
    # 允许在配置里调整（0 = 关掉"处理中"提示）
    $ACK_AFTER = $c->{ACK_AFTER} if ($c->{ACK_AFTER} // '') =~ /^\d+$/;
    $ACK_TEXT  = $c->{ACK_TEXT}  if defined $c->{ACK_TEXT} && $c->{ACK_TEXT} =~ /\S/;
    $RELAY_URL   = $c->{RELAY_URL}   if ($c->{RELAY_URL} // '')   =~ m{^https?://};
    $RELAY_TOKEN = $c->{RELAY_TOKEN} if defined $c->{RELAY_TOKEN};
    $RELAY_POLL  = $c->{RELAY_POLL}  if ($c->{RELAY_POLL} // '') =~ /^\d+$/ && $c->{RELAY_POLL} > 0;
    my @miss = missing_keys($c);
    if (@miss) { print STDERR "配置不完整，缺少：@miss（先 --init）\n"; exit 1 }
    serve($c);
    exit 0;
}

print STDERR "模式未指定，用 --init / --check / --serve / --test-push\n";
exit 2;
