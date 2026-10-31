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
use Digest::MD5 qw(md5_hex);   # 内核自带（5.8+）。仅用于不把发送者原样留在历史里
use File::Basename qw(dirname);
use File::Path qw(make_path);
use IO::Select;
use IPC::Open3 qw(open3);
use Symbol qw(gensym);

binmode STDIN,  ':encoding(UTF-8)';   # ★ 少了这一行，手机发来的中文会变成「ä½ å¥½」
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
# remember / write_skill 也在这一档：它们写的是 ~/.claude-agent 下的
# 记忆文件与技能文件（那里的窄门），且**永远要人确认**（strict），
# 所以放进可写档不会变成「手机能偷偷改配置」。
my @REMOTE_TOOLS_WRITABLE = qw(read_file list_dir write_file run_shell remember write_skill);
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

# 读取 ~/.claude-agent-env 里的 export K=V（传给 agent 的模型/密钥）
# 读本机的 agent 环境文件（~/.claude-agent-env，形如 `export KEY=value`）。
#
# ★ 这里必须宽容：它本质是「shell 能 source 的片段」，而用户的手写习惯、不同版本的
#   写入方都会变点花样。原来只认 `^\s*export\s+NAME=value`（等号两边不能有空格），
#   于是 `export CLAUDE_PROVIDER = deepseek` / `CLAUDE_PROVIDER=deepseek`（没 export）
#   / `export CLAUDE_PROVIDER`（只有名字）这几种写法会被**整行丢掉**，
#   agent 那边就只能回退到 anthropic，然后报一句「请设置 ANTHROPIC_API_KEY」——
#   看起来像密钥没配，实际是厂商这一项被我们吃掉了（真机踩过）。
#
#   现在接受：export 可有可无、等号两边可有空格、值可有引号、行尾注释、CRLF。
our $ENV_FILE_ERR = '';      # 打不开的原因（供 config_sanity 说清楚）

sub read_agent_env {
    my ($path) = @_;
    my %e;
    $ENV_FILE_ERR = '';
    my $fh;
    if (!open($fh, '<:encoding(UTF-8)', $path)) {
        $ENV_FILE_ERR = $!;
        return \%e;
    }
    while (my $l = <$fh>) {
        $l =~ s/\r?\n$//;
        next if $l =~ /^\s*#/;                 # 整行注释
        next if $l !~ /\S/;                    # 空行
        $l =~ s/^\s*export\s+//;               # export 可有可无
        next unless $l =~ /^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/;
        my ($k, $v) = ($1, $2);
        $v =~ s/^\s+//;
        $v =~ s/\s+$//;
        # 先看有没有引号包裹（引号后的 ` #注释` 一律当注释丢掉）
        if ($v =~ /^"(.*?)"/s) {
            $v = $1;
        } elsif ($v =~ /^'(.*?)'/s) {
            $v = $1;
        } else {
            # 未加引号：去掉行尾 ` #注释`
            $v =~ s/\s+#.*$//;
            $v =~ s/\s+$//;
        }
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

# 读取只含字符串的朴素 JSON（本用途不需要嵌套）。
sub json_get {
    my ($line, $key) = @_;
    return undef unless defined $line;
    return $1 if $line =~ /"\Q$key\E"\s*:\s*"((?:[^"\\]|\\.)*)"/;
    return undef;
}

# JSON 反转义：**单趟**扫描，别拿一串 s/// 叠着做。
# 叠着做有两个坑：①`\\uXXXX` 要不要在 `\\` 收口前处理，顺序错了要么丢字要么把
# 代码里的字面 "\u4e2d" 变成汉字；②`\\uXXXX` 之前根本没处理 —— agent 若把中文
# 转义成 \uXXXX 发回来，手机上就会看到 "\u4f60\u597d" 这种字面量（真机踩过）。
sub json_unescape {
    my ($s) = @_;
    return '' unless defined $s;
    $s =~ s/\\(u[0-9a-fA-F]{4}|.)/json_esc_seq($1)/ge;
    # 代理对合成一个字符（emoji 等）
    $s =~ s/\\u([dD][89abAB][0-9a-fA-F]{2})\\u([dD][c-fC-F][0-9a-fA-F]{2})/
          chr(0x10000 + ((hex($1) - 0xD800) << 10) + (hex($2) - 0xDC00))/ge;
    return $s;
}

sub json_esc_seq {
    my ($e) = @_;
    return "\n" if $e eq 'n';
    return "\r" if $e eq 'r';
    return "\t" if $e eq 't';
    return '"'  if $e eq '"';
    return '\\' if $e eq '\\';
    return '/'  if $e eq '/';
    if ($e =~ /^u([0-9a-fA-F]{4})$/) {
        my $cp = hex($1);
        # 代理对（emoji 之类）：\uD83D\uDE00 这一趟只看到前半，先原样留着，
        # 由下面补一趟把它们合成一个字符。
        return chr($cp) unless $cp >= 0xD800 && $cp <= 0xDFFF;
        return "\\u$1";
    }
    return $e;    # 其它转义：原样（丢掉反斜杠更危险）
}

# ---------------------------------------------------------------- 会话
# 每个发送者各持一个 agent 进程（以保持对话上下文）。
# 已退出就重建。
my %SESS;

# 配置自检：远程会话能不能起来，取决 ~/.claude-agent-env 里有没有「厂商 + 该厂商的密钥」。
# 真机上踩过：文件里 CLAUDE_PROVIDER 在、但值是空的（或只有 ANTHROPIC_API_KEY），
# agent 于是回退到 anthropic 并报「请设置 ANTHROPIC_API_KEY」—— 看起来像密钥没配，
# 实际是厂商没定下来。这里在启动时就把话说清楚（只报有没有，绝不打印任何值）。
sub config_sanity {
    my ($conf) = @_;
    my $envfile = $conf->{AGENT_ENV_FILE} || "$ENV{HOME}/.claude-agent-env";
    my $e = read_agent_env($envfile);
    my @warn;
    if (!-e $envfile) {
        push @warn, "找不到 $envfile（远程会话起来时会没有可用密钥）";
    } elsif (!-r $envfile) {
        # ★ 真机现场：文件属主是 root（以前用 sudo 配过），普通用户读不到 → 所有键读成空，
        #   表现却是「没有有效的 CLAUDE_PROVIDER」，方向被带偏了。这里直接说清楚 + 给修法。
        push @warn, "$envfile 存在但当前用户读不到（" . ($ENV_FILE_ERR || '权限不足') . "）。"
                  . "常见原因：之前用 sudo 写过这个文件，属主变成了 root。修法："
                  . "sudo chown \$(whoami) $envfile && chmod 600 $envfile"
                  . "（顺带检查同目录：ls -l \$(dirname $envfile)）";
        for my $w (@warn) {
            audit('config_warn', $w);
            print STDERR "配置自检：$w\n";
        }
        return \@warn;
    }
    my $prov = $e->{CLAUDE_PROVIDER} // '';
    my %known;
    my $here = dirname(__FILE__);
    my $provfile = '';
    for my $cand ("$here/../providers.txt", "$here/providers.txt") {
        if (-r $cand) { $provfile = $cand; last }
    }
    if ($provfile ne '' && open(my $pf, '<:encoding(UTF-8)', $provfile)) {
        while (my $l = <$pf>) {
            next if $l =~ /^\s*#/ || $l !~ /\S/;
            my ($name) = split /\|/, $l;
            $name =~ s/\s+//g;
            $known{$name} = 1 if $name ne '';
        }
        close $pf;
    }
    if ($prov eq '') {
        push @warn, "$envfile 里没有有效的 CLAUDE_PROVIDER（这就解释了「请设置 ANTHROPIC_API_KEY」："
                  . "没定厂商就会回退到 Anthropic）";
    } elsif (%known && !$known{$prov}) {
        push @warn, "CLAUDE_PROVIDER 的值 '$prov' 不认识（可选："
                  . join(' / ', sort keys %known) . "）";
    }
    # 该厂商要的密钥变量有没有、是不是空的
    my %KEYOF = (
        anthropic => 'ANTHROPIC_API_KEY', gemini => 'GEMINI_API_KEY',
        openai => 'OPENAI_API_KEY', deepseek => 'DEEPSEEK_API_KEY',
        dashscope => 'DASHSCOPE_API_KEY', moonshot => 'MOONSHOT_API_KEY',
        zhipu => 'ZHIPU_API_KEY',
    );
    if ($prov ne '' && $KEYOF{$prov}) {
        my $k = $KEYOF{$prov};
        my $v = $e->{$k} // ($ENV{$k} // '');
        push @warn, "$envfile 里 $k 是空的（$prov 用这个变量）" if $v eq '';
    }
    for my $w (@warn) {
        audit('config_warn', $w);
        print STDERR "配置自检：$w\n";
    }
    return \@warn;
}

# 每个发送者「接着聊哪段会话」的键。
# 不想把发送者 ID 本身留在文件名或历史里，所以做哈希。
sub remote_session_key {
    my ($from) = @_;
    return substr(md5_hex(defined $from && length $from ? $from : 'unknown'), 0, 12);
}

sub spawn_session {
    my ($from, $conf) = @_;
    my $envfile = $conf->{AGENT_ENV_FILE} || "$ENV{HOME}/.claude-agent-env";
    my $aenv = read_agent_env($envfile);

    my %env = (%ENV, %$aenv);
    # ★ 挡住「父进程环境泄漏」：启动远程服务的那个 shell 里若 export 了历史开关，
    #   子 agent 会照单全收，表现就是「远程突然不存历史了」。
    #   档位/可写范围不在这里清 —— 见下面「一律显式传 --mode」那段：argv 永远压过
    #   环境变量，那才是唯一权威来源（解耦卡口也要求档位只走启动参数）。
    for my $leak (qw(CLAUDE_NO_HISTORY CLAUDE_ENCRYPT_HISTORY)) {
        delete $env{$leak};
    }
    $env{CLAUDE_HISTORY_DIR} = $REMOTE_HIST;
    # 远程过来的是中文平台（企微/飞书）。老 Mac 上的 Agent 会去看 AppleLocale，
    # 在日本语系统的机器上就会用日文回中文提问 —— 所以这里显式定语言。
    $env{CLAUDE_LANG} = (defined $conf->{LANG} && $conf->{LANG} =~ /^(zh|ja|en)/)
        ? lc($1) : 'zh';
    # 远程历史：**默认开**（与本机一致，明文 0600/0700）。配了 HIST_PASS 就
    # 用口令加密；没配也不再关掉历史 —— 关掉意味着「手机每条消息都是新对话、
    # 服务一重启就断片」，那才是真正不能用。
    if (defined $conf->{HIST_PASS} && $conf->{HIST_PASS} =~ /\S/) {
        $env{CLAUDE_HIST_PASS} = $conf->{HIST_PASS};
    }

    my $errh = gensym;
    my ($in, $out);
    local %ENV = %env;
    my $pid = eval {
        # --no-config：远程会话只对话。厂商/模型/模式/可写范围/密钥一律在本机配好，
        # 这里连命令入口都不给（密钥更不该经第三方聊天平台转一圈）。
        my @extra;
        # 一律显式传：不传的话，父 shell 里的环境变量就会顶上来（远程可能被
        # 悄悄变成可写）。argv 是唯一权威来源。
        push @extra, '--mode=' . ($REMOTE_WRITE_MODE ne '' ? $REMOTE_WRITE_MODE : 'default');
        push @extra, ('--allow-write=' . $_) for @REMOTE_ROOTS;
        # 每个发送者都从上次的续点开始。服务重启后同一个人的对话也不会中断
        # （相当于 Hermes 里的「每个通道回到同一个会话」）。
        # 没有名字时子进程会自己开新会话，所以这里不必检查存在性。
        # 无条件带上：没有历史文件时 agent 会自己开新会话（已测），
        # 有就接着上次 —— 服务重启、断线重连都靠这一行。
        my $key = 'remote:' . remote_session_key($from);
        push @extra, "--name=$key", "--continue=$key";
        audit('session_resume', "key=$key");
        open3($in, $out, $errh, 'perl', $AGENT, '--rpc', '--no-config',
              '--tools=' . join(',', effective_tools()), @extra);
    };
    if (!$pid) {
        audit('session_spawn_failed', "from=$from", "err=$@");
        return undef;
    }
    # 与子进程的交互统一用 UTF-8。不加这一层的话，子进程写出的 UTF-8 字节
    # 会被当作「字节串」接收，再经 STDOUT 的 :encoding(UTF-8) 编码一次，
    # 变成二次转换（乱码）。
    binmode($in,  ':encoding(UTF-8)');
    binmode($out, ':encoding(UTF-8)');

    # 读尽启动后立刻产生的事件（ready / need_passphrase）
    my $ready = 0;
    while (my $l = <$out>) {
        $l =~ s/\r?\n$//;
        if ($l =~ /"t"\s*:\s*"need_passphrase"/) {
            my $pw = (defined $conf->{HIST_PASS}) ? $conf->{HIST_PASS} : '';
            print $in qq|{"t":"passphrase","value":"| . json_escape($pw) . qq|"}\n|;
            next;
        }
        if ($l =~ /"t"\s*:\s*"need_recovery"/) {
            # 首次创建历史时，除口令还需要密保问题（用于恢复）。
            # 不应答的话子进程会一直等，这边也一直等 ready，双方卡死。
            # 未设置就回空 → 子进程丢弃 KEY_FILE，按「没有历史」继续
            # （避免留下半截加密历史。这是子进程侧的默认行为）。
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
        # ★ 原来这里只记一句 session_not_ready，子进程的 stderr 直接丢了 ——
        #   真机上表现成「手机发消息完全没反应」，而这行日志看不出任何原因。
        #   现在把 stderr 有界地读出来（最多 1 秒、400 字），写审计并打到终端。
        my $tail = '';
        if ($errh) {
            my $sel = IO::Select->new($errh);
            while ($sel->can_read(1)) {
                my $chunk = '';
                my $n = sysread($errh, $chunk, 4096);
                last unless $n;
                $tail .= decode('UTF-8', $chunk);
                last if length($tail) > 4000;
            }
        }
        close $in; close $out; waitpid($pid, 0);
        $tail =~ s/\r//g;
        $tail =~ s/\s+/ /g;
        $tail = substr($tail, 0, 400);
        audit('session_not_ready', "from=$from",
              ($tail ne '' ? "err=$tail" : 'err=-(子进程没输出任何东西)'));
        print STDERR "本机会话没起来（$from）：$tail\n" if $tail ne '';
        return undef;
    }
    # ★ 子进程的标准输入必须自动刷新。没有它，写入的
    # 一行会留在缓冲区，这边等回复、那边等指令 —— 互相
    # 阻塞，永久卡住（实测踩过）。
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

# 处理一条消息并返回回复文本。失败时返回 undef。
sub handle_message {
    my ($from, $text, $conf) = @_;
    my $s = ensure_session($from, $conf);
    unless ($s) {
        # 起不来也要回一句：否则用户只看到「发了没反应」，无从判断
        return '本机会话没起来，这次没有执行。原因已写在 Mac 的终端输出和审计日志里'
             . '（session_not_ready 那行）。常见原因：模型密钥失效 / 模型名不对 / '
             . '本机 ~/.claude-agent-env 没配好。';
    }

    print { $s->{in} } qq|{"t":"user","text":"| . json_escape($text) . qq|"}\n|;

    my @texts;
    my $out = $s->{out};          # <{ ... }> 当格式串过不了，先接一次
    # 子进程若沉默就别无限等下去（模型侧死循环、网络
    # 中断等）。超时就杀掉子进程，下次重建。
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
    while (my $l = <$ph>) { }   # 不用输出但读干净（避免 SIGPIPE）
    close $ph;
}

# ---------------------------------------------------------------- 入口
# argv 拿到的是原始字节（不会自动解码），涉及人看的文本时显式按 UTF-8 解一次。
# 用 eval 兜住非法序列：解不动就按原样用，别因为一个怪字符直接崩。
sub arg_text {
    my ($s) = @_;
    return '' unless defined $s;
    return $s if utf8::is_utf8($s);
    my $d = eval { decode('UTF-8', $s) };
    return defined $d ? $d : $s;
}

my ($MODE, $ONCE_FROM, $ONCE_TEXT) = ('', '', '');
while (my $a = shift @ARGV) {
    if    ($a eq '--stdin')        { $MODE = 'stdin'; }
    elsif ($a eq '--once')         { $MODE = 'once'; }
    elsif ($a eq '--from')         { $ONCE_FROM = arg_text(shift @ARGV); }
    elsif ($a eq '--text')         { $ONCE_TEXT = arg_text(shift @ARGV); }
    elsif ($a =~ /^--mode=(.*)$/)  { $REMOTE_WRITE_MODE = lc $1; }
    elsif ($a eq '--mode')         { $REMOTE_WRITE_MODE = lc(shift @ARGV // ''); }
    elsif ($a =~ /^--allow-write=(.*)$/) { push @REMOTE_ROOTS, grep { length } split /,/, arg_text($1); }
    elsif ($a eq '--allow-write')  { push @REMOTE_ROOTS, grep { length } split /,/, arg_text(shift @ARGV); }
    elsif ($a =~ /^--confirm-wait=(\d+)$/) { $CONFIRM_WAIT = $1; }
    elsif ($a eq '--help' || $a eq '-h') {
        print "用法: gateway.pl --stdin | --once --from ID --text \"...\"\n"
          . "      [--mode=default|accept-edits|bypass] [--allow-write=DIR[,DIR]] [--confirm-wait=秒]\n";
        exit 0;
    }
    else {
        print STDERR "未知的参数: $a\n";
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

# 确认发送者。不在白名单就「什么都不回」直接丢弃
# （回一句「无权限」会让对方察觉到机器人的存在）。
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

config_sanity($conf);

if ($MODE eq 'once') {
    if (!gate($ONCE_FROM, $ONCE_TEXT)) {
        audit('gateway_end', 'mode=once result=dropped');
        exit 0;    # 丢弃与否外部不可见。退出码也是 0。
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
