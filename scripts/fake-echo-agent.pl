#!/usr/bin/env perl
# 测试夹具：一个「原样回显用户文本」的假 agent。
#
# 用途：验中文的字节链路有没有被双重编码。真机上踩过——手机发中文，agent 收到的是
# 「ä½ å¥½」（UTF-8 字节被当成 latin-1 读进来又编了一次）。这种问题用 ASCII 测不出来，
# 必须真的走一遍中文。
#
# 协议与真 agent 的最小交集：启动吐 ready，收 user 行，回 text 行，再吐 turn_done。
#
# ★ 这里用 JSON::PP 真解 / 真编（core 模块，Perl 5.14+ 自带）：网关会把非 ASCII 转成
#   \uXXXX，手写正则还原很容易再踩一层转义 —— 用标准库最稳。
use strict;
use warnings;
use utf8;
use JSON::PP ();

binmode(STDIN,  ':encoding(UTF-8)');
binmode(STDOUT, ':encoding(UTF-8)');
$| = 1;

# utf8(0)：进出都用「字符」，编码交给 STDIN/STDOUT 的层，避免二次编码
my $json = JSON::PP->new->utf8(0)->allow_nonref(1);

print $json->encode({ t => 'ready' }), "\n";

while (my $l = <STDIN>) {
    last if $l =~ /"t"\s*:\s*"bye"/;
    next unless $l =~ /"t"\s*:\s*"user"/;
    my $msg = eval { $json->decode($l) } || {};
    my $txt = defined $msg->{text} ? $msg->{text} : '';
    print $json->encode({ t => 'text', text => '回显:' . $txt }), "\n";
    print $json->encode({ t => 'turn_done' }), "\n";
}
