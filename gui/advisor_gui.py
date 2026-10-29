#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
advisor_gui.py  ―  advisor の1画面GUIフロントエンド

裏で `advisor gui`(= perl claude-agent.pl --gui)を起動し、1行1件のJSONで
やり取りする。入力はノート下部の書き込み欄(OSの日本語入力がそのまま
普通に使える。Terminal.app の2バイト文字バグを回避できる)、質問と回答は
1枚のノートに交互に追記されていく(枠付きの入力ボックスは無い)。

見た目は2つ:
  - ノート : 生成りの紙に書いていく感じ。相手の返答は2文字ぶん字下げ。
  - ハッカー: 黒地に緑文字。

必要なもの: Python 3.x + tkinter(標準同梱)のみ。外部ライブラリ不要。
"""

import json
import os
import queue
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import tkinter as tk
import webbrowser
from tkinter import font as tkfont
from tkinter import messagebox
from tkinter import ttk

# 本文の左インセット(px)。ノート左の赤い縦罫(大学ノートの余白線)の
# すぐ右から書き始める、という要望に合わせた小さめの値。
EDGE = 10

# ---------- 言語 ----------
# ダウンロードの7割が海外ユーザーとのことで日英対応が必須になった。
# LANG環境変数はGUIアプリをダブルクリック起動した時に空になることが
# あり(ログインシェルを経由しないため)あてにできない。macOS自体の
# 言語設定を直接読む。判定できなければ、この項目の既存ユーザーに
# 合わせて日本語を既定にする。ボタン文字は _S/L() で切り替えるだけで
# レイアウト(padx等)自体は変えていないので、英語の方が長い/短い場合は
# 別途ヘッダーの余白調整が要るかもしれない。
def _detect_lang():
    # CLAUDE_LANG=en/ja/zh があれば最優先(システム言語を変えずに表示言語を
    # 確認したいとき用)。zh-Hans / zh_CN のような書き方も zh として扱う。
    override = os.environ.get("CLAUDE_LANG", "").strip().lower()
    if override[:2] in ("en", "ja", "zh"):
        return override[:2]
    try:
        out = subprocess.check_output(
            ["defaults", "read", "-g", "AppleLocale"],
            stderr=subprocess.DEVNULL, timeout=2,
        ).decode("utf-8", "replace").strip().lower()
        if out.startswith("ja"):
            return "ja"
        if out.startswith("zh"):
            # zh-Hans / zh-Hant / zh_CN / zh_TW をまとめて中国語にする。
            # 繁体字を簡体字で出す問題はあるが、まず「中国語で読める」を優先。
            return "zh"
        if out:
            return "en"
    except Exception:
        pass
    # 判定できない環境(非macOS など)は従来通り日本語のまま。
    return "ja"


# 表示言語の優先順。未訳の言語はこの順で落とす(zh 未訳 -> en -> ja)。
# 空文字を返さないための保険。
_LANG_FALLBACK = {
    "ja": ("ja", "en"),
    "en": ("en", "ja"),
    "zh": ("zh", "en", "ja"),
}


LANG = _detect_lang()

# key: (日本語, English)。フォーマット文字列は L(key, **kwargs) で埋める。
_S = {
    "tab_chat": {
        "ja": "会話",
        "en": "Chat",
        "zh": "对话",
    },
    "tab_cmd": {
        "ja": "コマンド",
        "en": "Cmd",
        "zh": "命令",
    },
    "hist_btn": {
        "ja": "続きから",
        "en": "Resume",
        "zh": "继续上次",
    },
    "mode_btn": {
        "ja": "モード ▾",
        "en": "Mode ▾",
        "zh": "模式 ▾",
    },
    "mode_default": {
        "ja": "通常（毎回確認）",
        "en": "Default (asks every time)",
        "zh": "默认（每次确认）",
    },
    "mode_default_short": {
        "ja": "通常",
        "en": "Default",
        "zh": "默认",
    },
    "mode_accept_edits": {
        "ja": "書込みだけ自動",
        "en": "Accept edits",
        "zh": "写文件免确认",
    },
    "mode_accept_edits_short": {
        "ja": "書込自動",
        "en": "Edits",
        "zh": "写免确认",
    },
    "mode_bypass": {
        "ja": "bypass（危険な操作だけ確認）",
        "en": "Bypass (only dangerous ops ask)",
        "zh": "Bypass（只有危险操作确认）",
    },
    "mode_bypass_short": {
        "ja": "bypass",
        "en": "Bypass",
        "zh": "Bypass",
    },
    "switch_btn": {
        "ja": "AIを切替 ▾",
        "en": "Switch AI ▾",
        "zh": "切换 AI ▾",
    },
    "stop_btn": {
        "ja": "中止",
        "en": "Stop",
        "zh": "中止",
    },
    "write_mark": {
        "ja": "▶ ここに書いてください（Enterで送信）",
        "en": "▶ Type here (Enter to send)",
        "zh": "▶ 在此输入（回车发送）",
    },
    "busy_running": {
        "ja": "(実行中です。中止 ボタンか Ctrl-C で止めてください)\n",
        "en": "(Already running. Use Stop or Ctrl-C.)\n",
        "zh": "（正在运行。请用「中止」按钮或 Ctrl-C 停止）\n",
    },
    "no_such_folder": {
        "ja": "cd: そのフォルダはありません: {path}\n",
        "en": "cd: no such folder: {path}\n",
        "zh": "cd: 没有该文件夹：{path}\n",
    },
    "cannot_run": {
        "ja": "実行できません: {err}\n",
        "en": "Could not run: {err}\n",
        "zh": "无法执行：{err}\n",
    },
    "history_encrypted": {
        "ja": "暗号化保存",
        "en": "encrypted",
        "zh": "加密保存",
    },
    "history_off": {
        "ja": "保存しない",
        "en": "off",
        "zh": "不保存",
    },
    "ready_status": {
        "ja": "準備完了（履歴: {hist}）",
        "en": "Ready (history: {hist})",
        "zh": "就绪（历史：{hist}）",
    },
    "using_tool": {
        "ja": "— {name} を使います —",
        "en": "— using {name} —",
        "zh": "— 正在使用 {name} —",
    },
    "confirm_title": {
        "ja": "確認",
        "en": "Confirm",
        "zh": "确认",
    },
    "confirm_body": {
        "ja": "AIが次のことをしようとしています:\n\n{prompt}\n\n許可しますか？",
        "en": "The AI wants to do the following:\n\n{prompt}\n\nAllow it?",
        "zh": "AI 即将执行以下操作：\n\n{prompt}\n\n允许吗？",
    },
    "passphrase_default": {
        "ja": "パスフレーズ",
        "en": "Passphrase",
        "zh": "口令",
    },
    "turn_end": {
        "ja": "[終了 {code}]\n",
        "en": "[exit {code}]\n",
        "zh": "[退出 {code}]\n",
    },
    "bye_status": {
        "ja": "advisor を終了しました",
        "en": "advisor has exited",
        "zh": "advisor 已退出",
    },
    "querying_status": {
        "ja": "問い合わせ中…",
        "en": "Thinking…",
        "zh": "思考中…",
    },
    "starting_status": {
        "ja": "起動中…",
        "en": "Starting…",
        "zh": "启动中…",
    },
    "currently_using": {
        "ja": "  ← 使用中",
        "en": "  ← current",
        "zh": "  ← 使用中",
    },
    "menu_no_key": {
        "ja": "  [キー未設定]",
        "en": "  [no key yet]",
        "zh": "  [未配置密钥]",
    },
    "passphrase_title": {
        "ja": "パスフレーズ",
        "en": "Passphrase",
        "zh": "口令",
    },
    "ok": {
        "ja": "OK",
        "en": "OK",
        "zh": "确定",
    },
    "recover_with_answer": {
        "ja": "合言葉で復旧",
        "en": "Recover with answer",
        "zh": "用密保恢复",
    },
    "secret_title": {
        "ja": "合言葉",
        "en": "Recovery answer",
        "zh": "密保",
    },
    "secret_new_body": {
        "ja": "パスフレーズを忘れたときの復旧用です(必須)。\n"
                         "あなたにしか答えられない質問にしてください。\n"
                         "例: 初めて買った車の名前は？",
        "en": "Used to recover if you forget your passphrase "
                         "(required).\nPick a question only you can answer.\n"
                         "Example: What was your first car?",
        "zh": "用于忘记口令时恢复（必填）。\n请设置只有你能回答的问题。\n例：第一辆车的名字？",
    },
    "question_label": {
        "ja": "質問",
        "en": "Question",
        "zh": "问题",
    },
    "secret_unlock_body": {
        "ja": "合言葉で履歴を復旧します。",
        "en": "Recover history with your answer.",
        "zh": "用密保问题恢复历史记录。",
    },
    "question_prefix": {
        "ja": "質問: {q}",
        "en": "Question: {q}",
        "zh": "问题：{q}",
    },
    "answer_label": {
        "ja": "答え",
        "en": "Answer",
        "zh": "答案",
    },
    "resume_title": {
        "ja": "続きから",
        "en": "Resume",
        "zh": "继续上次",
    },
    "no_saved_history": {
        "ja": "保存された会話がありません。",
        "en": "No saved conversations.",
        "zh": "没有已保存的对话。",
    },
    "resume_pick": {
        "ja": "続きから始める会話を選んでください",
        "en": "Choose a conversation to resume",
        "zh": "请选择要继续的对话",
    },
    "open": {
        "ja": "開く",
        "en": "Open",
        "zh": "打开",
    },
    "cancel": {
        "ja": "やめる",
        "en": "Cancel",
        "zh": "取消",
    },
    "resume_page": {
        "ja": "（{page}ページ目 / 全{total}ページ）",
        "en": "(page {page} of {total})",
        "zh": "（第 {page} 页 / 共 {total} 页）",
    },
    "resume_loaded": {
        "ja": "（ここまで読み込みました。続きをどうぞ）",
        "en": "(loaded up to here — continue below)",
        "zh": "（已加载到这里。请继续）",
    },
    "cannot_start_title": {
        "ja": "起動できません",
        "en": "Could not start",
        "zh": "无法启动",
    },
    "backend_exit_title": {
        "ja": "バックエンドが終了しました。この画面からは送信できません。",
        "en": "The backend has exited — you can no longer send from this window.",
        "zh": "后端进程已退出 —— 这个窗口已经发不出消息了。",
    },
    "backend_exit_hint": {
        "ja": "上の理由を確認してください（キー未設定・モデル名・設定ファイルの権限など）。\n"
              "直し方: このウィンドウを閉じて開き直す / ターミナルで `advisor` を実行すると同じエラーがそのまま出ます。",
        "en": "See the reason above (missing key, unknown model id, config file permission, ...).\n"
              "To fix: close and reopen this window, or run `advisor` in Terminal — it prints the same error.",
        "zh": "先看上面的原因（未配置密钥、模型名不认识、配置文件权限等）。\n"
              "处理办法：关掉这个窗口重新打开，或在终端直接运行 `advisor`，同样的错误会原样打出来。",
    },
    "key_save_denied": {
        "ja": "設定ファイルに書き込めません:\n  {path}\n"
              "（所有者 {owner} / 権限 {mode}）\n"
              "別のユーザーが作ったファイルかもしれません（sudo で setup.sh を実行した等）。\n"
              "ターミナルで次を実行してから、もう一度お試しください:\n  sudo rm {path}",
        "en": "Cannot write the settings file:\n  {path}\n"
              "(owner {owner} / mode {mode})\n"
              "It may have been created by another user (e.g. running setup.sh with sudo).\n"
              "Run this in Terminal, then try again:\n  sudo rm {path}",
        "zh": "无法写入配置文件：\n  {path}\n"
              "（属主 {owner} / 权限 {mode}）\n"
              "这个文件可能是别的用户创建的（例如用 sudo 跑过 setup.sh）。\n"
              "在终端执行下面的命令后再试一次：\n  sudo rm {path}",
    },
    "cannot_start_body": {
        "ja": "advisor を起動できませんでした:\n{err}",
        "en": "Could not start advisor:\n{err}",
        "zh": "无法启动 advisor：\n{err}",
    },
    "internal_error": {
        "ja": "(内部エラー: {err})",
        "en": "(internal error: {err})",
        "zh": "（内部错误：{err}）",
    },
    # macOS メニューバー(画面最上部のOSメニュー。アプリ内ヘッダーとは別物)
    "menu_edit": {
        "ja": "編集",
        "en": "Edit",
        "zh": "编辑",
    },
    "menu_cut": {
        "ja": "切り取り",
        "en": "Cut",
        "zh": "剪切",
    },
    "menu_copy": {
        "ja": "コピー",
        "en": "Copy",
        "zh": "复制",
    },
    "menu_paste": {
        "ja": "貼り付け",
        "en": "Paste",
        "zh": "粘贴",
    },
    "menu_select_all": {
        "ja": "すべてを選択",
        "en": "Select All",
        "zh": "全选",
    },
    "menu_window": {
        "ja": "ウインドウ",
        "en": "Window",
        "zh": "窗口",
    },
    "menu_minimize": {
        "ja": "しまう",
        "en": "Minimize",
        "zh": "最小化",
    },
    # 初回起動時、APIキー未登録のときに出す案内画面
    "onboard_intro": {
        "ja": "はじめまして。AdvisorはAIとやり取りするためのアプリです。使うには"
        "「APIキー」というあなた専用の利用許可コード(パスワードのような"
        "もの)が必要です。下のGeminiなら無料で今すぐ発行できます。",
        "en": "Welcome. Advisor is an app for talking with AI. To use it, you'll "
        "need an \"API key\" — a personal permission code (think of it like "
        "a password). Gemini below lets you get one free, right now.",
        "zh": "你好。Advisor 是一个与 AI 对话的应用。使用时需要一个「API 密钥」——你专属的使用许可代码（类似密码）。下面的 Gemini 可以免费、马上申请。",
    },
    "onboard_key_get_here": {
        "ja": "① まずAPIキー(利用許可コード)を取得してください:",
        "en": "① First, get your API key (permission code):",
        "zh": "① 先获取 API 密钥（使用许可代码）：",
    },
    "onboard_open_key_page": {
        "ja": "🔑 APIキーを取得するページを開く",
        "en": "🔑 Open the API key page",
        "zh": "🔑 打开获取 API 密钥的页面",
    },
    "onboard_key_label": {
        "ja": "② 取得したAPIキーをここに貼り付け:",
        "en": "② Paste your API key here:",
        "zh": "② 把拿到的 API 密钥粘贴到这里：",
    },
    "onboard_start": {
        "ja": "はじめる",
        "en": "Get Started",
        "zh": "开始",
    },
    "onboard_checking": {
        "ja": "確認しています…",
        "en": "Checking…",
        "zh": "正在校验…",
    },
    "onboard_err_empty": {
        "ja": "APIキーを入力してください。",
        "en": "Please enter an API key.",
        "zh": "请输入 API 密钥。",
    },
    "onboard_err_api": {
        "ja": "APIキーを確認できませんでした(HTTP {code})。キーが正しいかご確認ください。",
        "en": "Couldn't verify the API key (HTTP {code}). Please check that it's correct.",
        "zh": "无法校验 API 密钥（HTTP {code}）。请确认密钥是否正确。",
    },
    # 会話中に、まだキーを登録していないAIへ切り替えようとしたときの案内
    "switch_key_title": {
        "ja": "APIキーの登録",
        "en": "Register API Key",
        "zh": "登记 API 密钥",
    },
    "switch_key_intro": {
        "ja": "{provider}にはまだAPIキーが登録されていません。取得して貼り付ければ、"
        "そのまま切り替えます。",
        "en": "There's no API key registered for {provider} yet. Get one and paste "
        "it in, and we'll switch right over.",
        "zh": "{provider} 还没有登记 API 密钥。获取后粘贴进去，就会直接切换。",
    },
    # ---- 远程接入（企业微信 長接続 / 长连接）----
    "menu_tools": {"ja": "ツール", "en": "Tools", "zh": "工具"},
    "remote_menu": {"ja": "リモート接続…", "en": "Remote Access…", "zh": "远程接入…"},
    "remote_title": {"ja": "リモート接続（企業微信・長接続）",
                     "en": "Remote Access (WeCom · long connection)",
                     "zh": "远程接入（企业微信 · 长连接）"},
    "remote_intro": {
        "ja": "スマホからこのMacに仕事を頼めるようにします。企業微信の「スマートボット」"
        "→ APIモード → 長接続 で発行される BotID と Secret を入れてください。"
        "公開URLもクラウド資源も要りません。",
        "en": "Let your phone hand work to this Mac. Enter the BotID and Secret issued by "
        "WeCom → smart bot → API mode → long connection. No public URL or cloud "
        "resource is needed.",
        "zh": "让手机能给这台 Mac 派活。填企业微信「智能机器人」→ API 模式 → 使用长连接 里"
        "给你的 BotID 和 Secret。不需要公网地址，也不需要任何云资源。",
    },
    "remote_botid": {"ja": "BotID", "en": "BotID", "zh": "BotID"},
    "remote_secret": {"ja": "Secret", "en": "Secret", "zh": "Secret"},
    "remote_secret_kept": {"ja": "（保存済み。空欄のままなら変更しません）",
                           "en": "(already saved; leave blank to keep it)",
                           "zh": "（已保存，留空则不修改）"},
    "remote_allow": {"ja": "許可するユーザーID（カンマ区切り）",
                     "en": "Allowed user IDs (comma separated)",
                     "zh": "允许的用户 ID（逗号分隔）"},
    "remote_mode": {
        "zh": "远程权限",
        "en": "Remote permission",
        "ja": "リモート権限",
    },
    "remote_mode_hint": {
        "zh": "跟本机三档一致：只读 / 可编辑（可写目录内自动，跑命令仍要确认）/ 放开（危险命令仍要确认）。"
              "在这里选定后**必须在 Mac 上重启远程服务才生效**，手机端无法更改。",
        "en": "Same three levels as local: read-only / accept-edits (writes inside the allowed dirs are automatic, "
              "shell still asks) / bypass (dangerous commands still ask). Changing it here takes effect only after "
              "you restart the remote service on the Mac — the phone can never change it.",
        "ja": "ローカルと同じ3段階：読み取り専用／編集可（許可ディレクトリ内は自動、コマンドは毎回確認）／"
              "制限なし（危険なコマンドは確認）。ここで変えても Mac 側でリモートサービスを再起動するまで"
              "反映されず、スマホ側からは変更できません。",
    },
    "remote_write_roots": {
        "zh": "可写目录",
        "en": "Writable dirs",
        "ja": "書き込み可能ディレクトリ",
    },
    "remote_write_roots_hint": {
        "zh": "逗号分隔；只对「可编辑 / 放开」两档有意义，只读档写了不生效（保存时会拦下）。",
        "en": "Comma separated. Only meaningful for accept-edits / bypass; ignored-and-refused in read-only.",
        "ja": "カンマ区切り。「編集可 / 制限なし」でのみ有効。読み取り専用では保存時に弾きます。",
    },
    "remote_allow_hint": {
        "ja": "ここに無い相手には返事をしません（「権限なし」とも返しません）。",
        "en": "Anyone not listed gets no reply at all (not even 'no permission').",
        "zh": "不在名单里的人不会收到任何回复（也不回「无权限」）。",
    },
    "remote_save": {"ja": "保存", "en": "Save", "zh": "保存"},
    "remote_test": {"ja": "接続テスト", "en": "Test connection", "zh": "测试连接"},
    "remote_close": {"ja": "閉じる", "en": "Close", "zh": "关闭"},
    "remote_need_mode": {
        "zh": "可写目录只在「可编辑 / 放开」两档下有意义，先选权限档位。",
        "en": "Writable dirs only apply to accept-edits / bypass — pick a permission level first.",
        "ja": "書き込み可能ディレクトリは「編集可 / 制限なし」でのみ有効です。先に権限を選んでください。",
    },
    "remote_readonly_label": {
        "zh": "只读",
        "en": "Read-only",
        "ja": "読み取り専用",
    },
    "remote_accept_label": {
        "zh": "可编辑",
        "en": "Accept edits",
        "ja": "編集可",
    },
    "remote_bypass_label": {
        "zh": "放开（危险命令仍要确认）",
        "en": "Bypass (dangerous commands still ask)",
        "ja": "制限なし（危険なコマンドは確認）",
    },
    "remote_status_none": {"ja": "未設定：まだ接続情報がありません。",
                           "en": "Not configured: no connection settings yet.",
                           "zh": "未配置：还没有连接信息。"},
    "remote_status_ready": {"ja": "設定済み（最終活動 {when}）",
                            "en": "Configured (last activity {when})",
                            "zh": "已配置（最近一次活动 {when}）"},
    "remote_status_never": {"ja": "設定済み（まだ活動記録なし）",
                            "en": "Configured (no activity recorded yet)",
                            "zh": "已配置（还没有活动记录）"},
    "remote_saved": {"ja": "保存しました：{path}（0600）",
                     "en": "Saved: {path} (0600)", "zh": "已保存：{path}（0600）"},
    "remote_need_botid": {"ja": "BotID を入れてください。",
                          "en": "Please enter the BotID.", "zh": "请填写 BotID。"},
    "remote_need_secret": {"ja": "Secret を入れてください（初回のみ）。",
                           "en": "Please enter the Secret (first time only).",
                           "zh": "请填写 Secret（只需第一次）。"},
    "remote_testing": {"ja": "接続を確認しています…", "en": "Checking connection…",
                       "zh": "正在检查连接…"},
    "remote_no_script": {
        "ja": "remote/wecom-ws.pl が見つかりません（この環境にはリモート部品がありません）。",
        "en": "remote/wecom-ws.pl was not found (remote components are not installed here).",
        "zh": "找不到 remote/wecom-ws.pl（这个环境里没有安装远程组件）。",
    },
    "remote_ok_hint": {
        "ja": "パソコン側は `perl remote/wecom-ws.pl --serve` で常駐させます。",
        "en": "On the Mac, keep it running with `perl remote/wecom-ws.pl --serve`.",
        "zh": "在 Mac 上常驻用 `perl remote/wecom-ws.pl --serve`。",
    },
}


def L(key, **kw):
    """文言を引く。

    条目は 2 通り書ける:
        ("日本語", "English")                      … 従来形式(中国語は英語に落ちる)
        {"ja": ..., "en": ..., "zh": ...}          … 中国語を足した形式
    未訳の言語は _LANG_FALLBACK の順で回退し、空文字は返さない。
    """
    entry = _S[key]
    s = None
    if isinstance(entry, dict):
        for lang in _LANG_FALLBACK.get(LANG, ("ja",)):
            v = entry.get(lang)
            if v:
                s = v
                break
    else:
        ja, en = entry
        s = ja if LANG == "ja" else en
    if not s:
        s = entry["ja"] if isinstance(entry, dict) else entry[0]
    return s.format(**kw) if kw else s


def theme_label(spec):
    # 主题名也要跟随语言(没有 label_zh 时落回日文原名)
    if LANG == "zh":
        return spec.get("label_zh", spec["label"])
    return spec.get("label_en", spec["label"]) if LANG == "en" else spec["label"]


# 書き込み欄が空のときに出す案内。クリックすると全体が消えて先頭から
# 書ける(_write_click_clear)。点滅する縦線のカーソルの代わりに、
# 点滅だけ止めて(insertofftime=0)この矢印で書き始めの位置を示す。
WRITE_MARK = L("write_mark")

CFG_PATH = os.path.expanduser("~/.claude-agent/gui.json")

# ```lang ... ``` のコードブロック検出
FENCE_RE = re.compile(r"```[ \t]*([\w+.\-]*)[ \t]*\n(.*?)```", re.DOTALL)
# ざっくりした汎用ハイライト(python/js/sh/json あたりを想定)。
# 並び順が優先度: 文字列 → コメント → 数値 → キーワード。
CODE_RE = re.compile(r"""
    (?P<str>"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|`(?:[^`\\]|\\.)*`)
  | (?P<com>\#[^\n]*|//[^\n]*|/\*.*?\*/)
  | (?P<num>\b\d+(?:\.\d+)?\b)
  | (?P<kw>\b(?:def|class|return|if|elif|else|for|while|import|from|as|try|
        except|finally|raise|with|lambda|pass|break|continue|yield|True|False|
        None|and|or|not|in|is|async|await|function|const|let|var|new|typeof|
        export|default|extends|super|this|null|undefined|echo|then|fi|do|done|
        case|esac|local|self|print)\b)
""", re.VERBOSE | re.DOTALL)
HL_TAG = {"str": "code_str", "com": "code_com", "num": "code_num", "kw": "code_kw"}

# テーマ定義。レイアウトは全モード共通(読みやすさ優先):
#   自分の発言 = 右寄せ、ブロックの左は 1/3 空ける
#   相手の返答 = 左寄せ、ブロックの右は 1/3 空ける
#   発言の間に薄い区切り線。色・書体・穴だけモードで変える。
#   prompt_prefix = 自分の発言に色付き「watermark> 」を付ける(端末系)
#   handwriting   = 手書き風フォントが入っていれば使う(環境依存)
#   holes         = 左にルーズリーフの穴
THEMES = {
    "paper": {
        "label": "ノート", "label_en": "Note", "label_zh": "笔记", "handwriting": True, "holes": True,
        # 背景を少し明るく、文字(質問・回答とも)は逆にもう少し濃くして
        # はっきりさせた(明るくした分そのままだとコントラストが落ちる
        # ため。実際にはコントラスト比は上がっている: fg 9.57→12.5,
        # ai 7.74→10.8)。
        "bg": "#faf4e6", "fg": "#1a2c54", "ai": "#463420",   # 青黒インク / 茶
        "dim": "#9a8f78", "err": "#a5341f", "rule": "#d7b7ab", "code_bg": "#efe6cf",
        "line": "#c96b63",                                    # 昔のルーズリーフの赤い罫
        "hline": "#9fb0c9",     # 横罫線(紺グレー)。PhotoImageでの埋め込みは
                                # このマシンで描画されなかったため、既に
                                # 描けている縦罫(Canvas.create_line)と同じ
                                # 実部品(tk.Frame)を使う方式に変更した
        "vline": "#c96b63",                                   # 左の縦罫(赤)。書き始めの目印
        "input_bg": "#faf4e6", "input_fg": "#1a2c54",
        "hl": {"kw": "#7a3b8f", "str": "#8a5a2b", "com": "#9a8f78", "num": "#3a5a3a"},
        "font": ("Hiragino Maru Gothic ProN", 12),  # 少し小さめにして行数を稼ぐ
    },
    "coding": {
        "label": "コーディング", "label_en": "Code", "label_zh": "编程", "prompt_prefix": True,
        "bg": "#1e1e1e", "fg": "#d4d4d4", "ai": "#cfcfcf", "prompt": "#c586c0",
        "dim": "#7a7a7a", "err": "#f48771", "rule": "#3a3a3a", "code_bg": "#252526",
        "line": "#3a3a3a", "input_bg": "#1e1e1e", "input_fg": "#d4d4d4",
        "hl": {"kw": "#569cd6", "str": "#ce9178", "com": "#6a9955", "num": "#b5cea8"},
        "font": ("Menlo", 13),
    },
    "hacker": {
        "label": "ハッカー", "label_en": "Hacker", "label_zh": "黑客", "prompt_prefix": True,
        # エラー/終了コード(err)以外は全部緑にする、との要望。以前は
        # promptとhl.kw/numがシアン系だったので緑に寄せた。
        "bg": "#000000", "fg": "#39ff5a", "ai": "#33dd88", "prompt": "#00ff66",
        "dim": "#2e7d4f", "err": "#ff5555", "rule": "#2e9d55", "code_bg": "#041004",
        "line": "#2e9d55", "input_bg": "#000000", "input_fg": "#39ff5a",
        "hl": {"kw": "#00ff66", "str": "#9dff9d", "com": "#2e7d4f", "num": "#a8ffcb"},
        "font": ("Menlo", 13),
    },
}


def pick_font(family, size):
    """指定 family が無ければ順に代替。手書き風は入っていれば拾う。"""
    try:
        import tkinter.font as tkfont
        have = set(tkfont.families())
    except Exception:
        return (family, size)
    cands = [family,
             "Hiragino Maru Gothic ProN", "YuKyokasho", "Klee",
             "Chalkboard SE", "Hiragino Sans", "ヒラギノ角ゴシック"]
    for c in cands:
        if c in have:
            return (c, size)
    return (family, size)


ENV_FILE_PATH = os.path.expanduser("~/.claude-agent-env")

# 远程接入的配置文件：与命令行 wecom-ws.pl --init / gateway.pl 用的是**同一个**
WECOM_WS_CONF_PATH = os.path.expanduser("~/.claude-agent/wecom-ws.conf")
REMOTE_CONF_PATH = os.path.expanduser("~/.claude-agent/remote.conf")
AUDIT_LOG_PATH = os.path.expanduser("~/.claude-agent/audit.log")


def read_kv_conf(path):
    """读 KEY=VALUE 形式（# 开头是注释）。文件不存在返回 {}。"""
    out = {}
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, _, v = line.partition("=")
                out[k.strip()] = v.strip()
    except Exception:
        pass
    return out


def write_kv_conf_atomic(path, updates):
    """只改 updates 里那几个键，其余行（注释、别人的配置）原样保留。

    这是「不要覆盖用户已有配置」的落点：远程文件里除了 BotID/Secret，
    还可能有 WS_URL / HEARTBEAT，remote.conf 里可能有 NOTIFY / LANG / HIST_PASS。
    同目录临时文件 + os.replace，失败会抛异常（不静默），权限 0600。
    """
    d = os.path.dirname(path)
    if d:
        os.makedirs(d, exist_ok=True)
    lines = []
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.readlines()
    except Exception:
        lines = []
    seen = set()
    out = []
    for line in lines:
        stripped = line.strip()
        if stripped and not stripped.startswith("#") and "=" in stripped:
            k = stripped.partition("=")[0].strip()
            if k in updates:
                out.append("%s=%s\n" % (k, updates[k]))
                seen.add(k)
                continue
        out.append(line if line.endswith("\n") else line + "\n")
    for k, v in updates.items():
        if k not in seen:
            out.append("%s=%s\n" % (k, v))
    tmp = path + ".tmp.%d" % os.getpid()
    old_umask = os.umask(0o077)
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            f.writelines(out)
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    finally:
        os.umask(old_umask)
    return path


def remote_status():
    """状态只从文件与审计日志读，不自己造。"""
    conf = read_kv_conf(WECOM_WS_CONF_PATH)
    has_cred = bool(conf.get("BOT_ID")) and bool(conf.get("BOT_SECRET"))
    when = ""
    if os.path.exists(AUDIT_LOG_PATH):
        try:
            with open(AUDIT_LOG_PATH, encoding="utf-8", errors="replace") as f:
                for line in f.readlines()[-400:]:
                    parts = line.split()
                    if len(parts) >= 4 and parts[2] == "ws":
                        when = "%s %s" % (parts[0], parts[1])
        except Exception:
            pass
    return {"configured": has_cred, "last_activity": when,
            "allow": read_kv_conf(REMOTE_CONF_PATH).get("ALLOW", "")}


def find_wecom_ws_script():
    """找 remote/wecom-ws.pl：仓库布局与构建目录布局都试一遍，都找不到就返回 ''。"""
    here = os.path.dirname(os.path.abspath(__file__))
    cands = [
        os.path.join(here, "..", "remote", "wecom-ws.pl"),
        os.path.join(here, "remote", "wecom-ws.pl"),
        os.path.join(os.path.expanduser("~/claude-build"), "remote", "wecom-ws.pl"),
    ]
    rd = _bundled_resource_dir()
    if rd:
        cands.insert(0, os.path.join(rd, "remote", "wecom-ws.pl"))
        cands.insert(0, os.path.join(rd, "wecom-ws.pl"))
    for c in cands:
        c = os.path.normpath(c)
        if os.path.isfile(c):
            return c
    return ""


def run_wecom_check(script, timeout=30):
    """跑一次 --check，把**真实输出**原样交回来（成功/errcode 都由它决定）。"""
    try:
        p = subprocess.run(["perl", script, "--check"], capture_output=True,
                           timeout=timeout, stdin=subprocess.DEVNULL)
        out = (p.stdout or b"").decode("utf-8", "replace") + \
              (p.stderr or b"").decode("utf-8", "replace")
        return p.returncode == 0, out.strip()
    except Exception as e:
        return False, "%s" % e


def _pointing_cursor():
    """macOS は pointinghand、それ以外(X11)は hand2。

    ここを直書きすると Linux で Tk が bad cursor spec で落ちる。
    macOS の見た目・挙動はそのまま（darwin では従来どおり pointinghand）。
    """
    return "pointinghand" if sys.platform == "darwin" else "hand2"


def _providers_path():
    """providers.txt の場所。同梱(Resources) → リポジトリ直下 → ~/claude-build の順。"""
    cands = []
    here = _bundled_resource_dir()
    if here:
        cands.append(os.path.join(here, "providers.txt"))
    cands.append(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                              os.pardir, "providers.txt"))
    cands.append(os.path.expanduser("~/claude-build/providers.txt"))
    for c in cands:
        if os.path.isfile(c):
            return os.path.abspath(c)
    return None


def read_providers():
    """providers.txt を読む。

    返り値: [(name, {key_env, default_model, key_url, ja, en, zh}), ...]（ファイル順）
    ここが唯一の出所。GUI 側にキー名やURLを書き足さない。
    """
    out = []
    path = _providers_path()
    if not path:
        return out
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.rstrip("\n")
                if not line.strip() or line.lstrip().startswith("#"):
                    continue
                parts = [p.strip() for p in line.split("|")]
                if len(parts) < 4 or not parts[0]:
                    continue
                name, kenv, dmodel, kurl = parts[0], parts[1], parts[2], parts[3]
                labels = parts[4:] + ["", "", ""]
                out.append((name, {
                    "key_env": kenv,
                    "default_model": dmodel,
                    "key_url": kurl,
                    "ja": labels[0] or name,
                    "en": labels[1] or name,
                    "zh": labels[2] or name,
                }))
    except Exception:
        return []
    return out


def provider_label(info):
    if not info:
        return ""
    for k in (LANG, "zh", "en", "ja"):
        v = info.get(k)
        if v:
            return v
    return ""


def read_models():
    """models.txt を読む: [{id, ja, en, zh, provider, base_url}, ...]"""
    path = None
    for c in (os.path.expanduser("~/claude-build/models.txt"),
              os.path.join(os.path.dirname(os.path.abspath(__file__)),
                           os.pardir, "models.txt")):
        if os.path.isfile(c):
            path = c
            break
    if not path:
        here = _bundled_resource_dir()
        if here and os.path.isfile(os.path.join(here, "models.txt")):
            path = os.path.join(here, "models.txt")
    if not path:
        return []
    out = []
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.rstrip("\n")
                if not line.strip() or line.lstrip().startswith("#"):
                    continue
                p = [x.strip() for x in line.split("|")]
                if not p or not p[0]:
                    continue
                p += [""] * (7 - len(p))
                out.append({"id": p[0], "ja": p[1] or p[0], "en": p[2] or p[0],
                            "zh": p[3] or p[0], "provider": p[4], "base_url": p[5]})
    except Exception:
        return []
    return out


def read_env_file():
    # ~/.claude-agent-env の "export VAR=値" 形式を辞書にして返す。
    result = {}
    try:
        with open(ENV_FILE_PATH, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line.startswith("export "):
                    continue
                k, sep, v = line[len("export "):].partition("=")
                if sep:
                    result[k.strip()] = v.strip()
    except Exception:
        pass
    return result


def has_valid_api_key():
    # どのベンダーでも「そのベンダーのキーがあるか」で判定する。
    # キー名は providers.txt から引く(ここに GEMINI/ANTHROPIC を書き足さない)。
    env = read_env_file()
    provider = env.get("CLAUDE_PROVIDER", "")
    if not provider:
        return False
    for name, info in read_providers():
        if name == provider:
            return bool(env.get(info["key_env"]))
    return False


def _bundled_resource_dir():
    # setup.shでビルドした場合は自分自身(advisor_gui.py)と同じフォルダに
    # claude-agent.pl / models.txt が既にある(~/claude-build/)。
    # ダブルクリックだけで動く単体アプリ(py2appの標準ビルド)の場合は、
    # アプリ本体の Contents/Resources/ に同梱されているはずなのでそちらを探す。
    here = os.path.dirname(os.path.abspath(__file__))
    if os.path.isfile(os.path.join(here, "claude-agent.pl")):
        return here
    try:
        exe_dir = os.path.dirname(os.path.abspath(sys.executable))
        resources = os.path.normpath(os.path.join(exe_dir, "..", "Resources"))
        if os.path.isfile(os.path.join(resources, "claude-agent.pl")):
            return resources
    except Exception:
        pass
    return None


def ensure_backend_files():
    # setup.shを一度も実行していない(=~/claude-buildが無い)環境でも、
    # アプリに同梱したエージェント本体を~/claude-buildへ配置して動くようにする。
    build_dir = os.path.expanduser("~/claude-build")
    target_agent = os.path.join(build_dir, "claude-agent.pl")
    target_models = os.path.join(build_dir, "models.txt")
    target_providers = os.path.join(build_dir, "providers.txt")
    if (os.path.isfile(target_agent) and os.path.isfile(target_models)
            and os.path.isfile(target_providers)):
        return True
    src = _bundled_resource_dir()
    if src is None:
        return False
    try:
        os.makedirs(build_dir, exist_ok=True)
        if not os.path.isfile(target_agent):
            shutil.copy(os.path.join(src, "claude-agent.pl"), target_agent)
        if not os.path.isfile(target_models):
            shutil.copy(os.path.join(src, "models.txt"), target_models)
        if not os.path.isfile(target_providers):
            src_providers = os.path.join(src, "providers.txt")
            if os.path.isfile(src_providers):
                shutil.copy(src_providers, target_providers)
        return True
    except Exception:
        return False


def build_backend_command_and_env():
    # ~/bin/advisor(setup.shが生成するラッパー)があればそれを使う。
    # 無ければ(=setup.shを実行していない)、同梱したエージェントを直接起動する。
    wrapper = os.path.expanduser("~/bin/advisor")
    if os.path.isfile(wrapper) and os.access(wrapper, os.X_OK):
        return [wrapper, "gui"], None
    if not ensure_backend_files():
        return None, None
    env = dict(os.environ)
    env.update(read_env_file())
    env.setdefault("CLAUDE_CURL", "curl")
    env["CLAUDE_MODELS_FILE"] = os.path.expanduser("~/claude-build/models.txt")
    agent = os.path.expanduser("~/claude-build/claude-agent.pl")
    return ["perl", agent, "--gui"], env


def validate_api_key(provider, api_key, base_url="", model=""):
    """キーが本当に通るかをその場で確かめる（種別ごとに叩き方が違う）。

    gemini     : x-goog-api-key ヘッダ + generateContent
    anthropic  : x-api-key + anthropic-version ヘッダ + /v1/messages
    OpenAI互換 : Authorization: Bearer + <base_url>/chat/completions
    """
    if provider == "gemini":
        url = ("https://generativelanguage.googleapis.com/v1beta/models/"
               "%s:generateContent" % (model or "gemini-3.5-flash-lite"))
        headers = ["-H", "x-goog-api-key: %s" % api_key,
                   "-H", "content-type: application/json"]
        data = '{"contents":[{"parts":[{"text":"hi"}]}],"generationConfig":{"maxOutputTokens":8}}'
    elif provider == "anthropic":
        url = "https://api.anthropic.com/v1/messages"
        headers = ["-H", "x-api-key: %s" % api_key,
                   "-H", "anthropic-version: 2023-06-01",
                   "-H", "content-type: application/json"]
        data = ('{"model":"%s","max_tokens":10,"messages":[{"role":"user","content":"hi"}]}'
                % (model or "claude-sonnet-5"))
    else:
        base = (base_url or "").rstrip("/")
        if not base:
            return False, ""
        url = base + "/chat/completions"
        headers = ["-H", "Authorization: Bearer %s" % api_key,
                   "-H", "content-type: application/json"]
        data = ('{"model":"%s","max_tokens":10,"messages":[{"role":"user","content":"hi"}]}'
                % (model or "gpt-4o"))
    try:
        out = subprocess.run(
            ["curl", "-s", url] + headers + ["-d", data, "-w", "\n%{http_code}"],
            capture_output=True, text=True, timeout=20,
        )
    except Exception:
        return False, ""
    text = out.stdout
    _, _, code = text.rpartition("\n")
    return code.strip() == "200", code.strip()


def env_file_diag(path):
    """配置文件的属主与权限（报错时用，绝不读取文件内容）。"""
    owner, mode = "?", "?"
    try:
        st = os.stat(path)
        mode = oct(st.st_mode & 0o777)
        try:
            import pwd
            owner = pwd.getpwuid(st.st_uid).pw_name
        except Exception:
            owner = str(st.st_uid)
    except OSError:
        pass
    return owner, mode


def write_env_atomic(lines):
    """同目录临时文件 + os.replace。

    只要求**目录**可写，不要求目标文件可写 —— 与 setup.sh 的 mv 语义一致。
    直接 open(path,'w') 在「文件属于别人 / 只读」时会失败（GUI 曾报
    「没权限」，而命令行 setup 却能正常写，就是这个差别）。
    """
    d = os.path.dirname(ENV_FILE_PATH) or "."
    try:
        fd, tmp = tempfile.mkstemp(prefix=".claude-agent-env.", dir=d)
    except OSError:
        owner, mode = env_file_diag(ENV_FILE_PATH)
        raise RuntimeError(L("key_save_denied", path=ENV_FILE_PATH,
                             owner=owner, mode=mode))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.writelines(lines)
        os.chmod(tmp, 0o600)
        os.replace(tmp, ENV_FILE_PATH)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        owner, mode = env_file_diag(ENV_FILE_PATH)
        raise RuntimeError(L("key_save_denied", path=ENV_FILE_PATH,
                             owner=owner, mode=mode))


def save_onboard_env(provider, api_key):
    """選んだベンダーのキーだけを書き換える。

    他ベンダーのキーは消さない —— 一度登録したキーを、別のベンダーを試した
    だけで失うのは事故なので。既存行の並びも保つ。
    """
    info = {}
    for name, i in read_providers():
        if name == provider:
            info = i
            break
    keyvar = info.get("key_env", "")
    if not keyvar:
        raise RuntimeError("providers.txt に %s の定義がありません" % provider)
    default_model = info.get("default_model", "")
    try:
        with open(ENV_FILE_PATH, encoding="utf-8") as f:
            lines = f.readlines()
    except Exception:
        lines = []
    drop = {"CLAUDE_PROVIDER", "CLAUDE_MODEL", keyvar}
    keep = []
    for l in lines:
        m = re.match(r"export ([A-Za-z0-9_]+)=", l)
        if m and m.group(1) in drop:
            continue
        keep.append(l)
    keep.append("export CLAUDE_PROVIDER=%s\n" % provider)
    keep.append("export %s=%s\n" % (keyvar, api_key))
    if default_model:
        keep.append("export CLAUDE_MODEL=%s\n" % default_model)
    write_env_atomic(keep)


def load_cfg():
    try:
        with open(CFG_PATH, encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {}


def save_cfg(cfg):
    try:
        os.makedirs(os.path.dirname(CFG_PATH), exist_ok=True)
        with open(CFG_PATH, "w", encoding="utf-8") as f:
            json.dump(cfg, f)
    except Exception:
        pass


class AdvisorGUI:
    def __init__(self, root):
        self.root = root
        self.root.title("Advisor")
        self.root.geometry("560x800")          # A5 大学ノートの比率(縦長)
        # Dock/ウィンドウのアイコン(できれば)。tkinter だけだと Dock は
        # Python の絵のままのことがあるが、少なくとも試みる。
        try:
            png = os.path.expanduser("~/claude-build/advisor.png")
            if os.path.isfile(png):
                self._icon_img = tk.PhotoImage(file=png)
                self.root.iconphoto(True, self._icon_img)
        except Exception:
            pass

        self.events = queue.Queue()
        self.proc = None
        self.busy = False
        self.pane = "chat"                      # "chat" / "cmd"
        self.cwd = os.path.expanduser("~")      # コマンドパネルの現在地
        self.cmd_proc = None
        self._providers = read_providers()
        self.model_label_var = tk.StringVar(value="…")
        self.status_var = tk.StringVar(value=L("starting_status"))
        self.cmd_prompt_var = tk.StringVar(value="")
        self.theme_name = load_cfg().get("theme", "paper")
        if self.theme_name not in THEMES:
            self.theme_name = "paper"

        self._build_menubar()
        self.root.after(50, self._localize_native_app_menu)
        self.root.protocol("WM_DELETE_WINDOW", self._on_close)

        if has_valid_api_key():
            self._start_main_ui()
        else:
            self._build_onboarding()

    def _start_main_ui(self):
        self._build_ui()
        self._apply_theme(self.theme_name)
        self._write_show_marker()
        # 起動直後に書き込み欄へフォーカスを渡す。渡さないと「ウィンドウは
        # 出ているのに何を打っても入らない」になる（実機で踏んだ）。
        self._focus_write_zone()
        self._start_backend()
        self.root.bind("<FocusIn>", self._on_window_focus, add="+")
        self.root.after(80, self._pump)

    def _on_window_focus(self, _event=None):
        try:
            if self.root.focus_get() is None:
                self._focus_write_zone()
        except Exception:
            pass

    def _focus_write_zone(self):
        try:
            if str(self.write_zone.cget("state")) not in ("disabled", "1"):
                self.write_zone.focus_set()
        except Exception:
            pass

    # ---------- 初回起動時、APIキー未登録なら出す案内画面 ----------
    def _build_onboarding(self):
        bg = "#fdf6e3"
        self._providers = read_providers()
        _first = self._providers[0][0] if self._providers else ""
        frame = tk.Frame(self.root, bg=bg)
        frame.pack(fill=tk.BOTH, expand=True)
        self._onboard_frame = frame

        tk.Label(frame, text="Advisor", font=("Helvetica", 28, "bold"),
                 bg=bg, fg="#2b2b2b").pack(pady=(48, 6))
        tk.Label(frame, text=L("onboard_intro"), font=("Helvetica", 13),
                 bg=bg, fg="#2b2b2b", wraplength=440, justify=tk.LEFT).pack(
            pady=(0, 20), padx=40)

        # 7ベンダーをラジオで並べると横に溢れるので、プルダウン1つにする。
        # 表示名は providers.txt から引く(ここにベンダー名を直書きしない)。
        provider_row = tk.Frame(frame, bg=bg)
        provider_row.pack(pady=(0, 10))
        self._provider_labels = {}
        names = []
        for name, info in self._providers:
            lbl = provider_label(info)
            self._provider_labels[lbl] = name
            names.append(lbl)
        self._onboard_label = tk.StringVar(value=names[0] if names else "")
        self._onboard_menu = tk.OptionMenu(provider_row, self._onboard_label, *names)
        self._onboard_menu.config(font=("Helvetica", 12), width=26)
        self._onboard_menu.pack(side=tk.LEFT, padx=8)
        self._onboard_label.trace_add("write", lambda *a: self._onboard_update_link())

        tk.Label(frame, text=L("onboard_key_get_here"), font=("Helvetica", 13, "bold"),
                 bg=bg, fg="#2b2b2b").pack(pady=(4, 8))

        # 非技術者にも「押せるボタン」だと一目で分かるよう、生のURLではなく
        # 色付き・大きめのボタン風ラベルにする(小さい下線リンクだと
        # 見落とされやすいとのフィードバックを受けて)。
        self._onboard_link = tk.Label(frame, text="", fg="#ffffff", bg="#1a5fb4",
                                       cursor=_pointing_cursor(),
                                       font=("Helvetica", 16, "bold"),
                                       padx=18, pady=10)
        self._onboard_link.pack(pady=(0, 22))
        self._onboard_link.bind("<Button-1>", lambda e: webbrowser.open(self._onboard_url))
        self._onboard_update_link()

        key_row = tk.Frame(frame, bg=bg)
        key_row.pack(pady=(0, 10))
        tk.Label(key_row, text=L("onboard_key_label"), bg=bg,
                 font=("Helvetica", 12)).pack(side=tk.TOP, anchor="w", pady=(0, 4))
        self._onboard_key_entry = tk.Entry(key_row, width=40, show="•",
                                            font=("Helvetica", 13))
        self._onboard_key_entry.pack(side=tk.TOP)
        self._onboard_key_entry.bind("<Return>", lambda e: self._onboard_start())
        self._onboard_key_entry.focus_set()

        self._onboard_btn = tk.Label(frame, text=L("onboard_start"),
                                      cursor=_pointing_cursor(),
                                      font=("Helvetica", 13, "bold"), bg=bg,
                                      fg="#2b2b2b", padx=14, pady=4,
                                      highlightthickness=1,
                                      highlightbackground="#2b2b2b")
        self._onboard_btn.pack(pady=(6, 10))
        self._onboard_btn.bind("<Button-1>", lambda e: self._onboard_start())

        self._onboard_status = tk.Label(frame, text="", bg=bg, fg="#a33",
                                         font=("Helvetica", 11), wraplength=440)
        self._onboard_status.pack(pady=(4, 20))

    def _onboard_selected(self):
        """下拉で選ばれているベンダー名と、その定義を返す。"""
        lbl = getattr(self, "_onboard_label", None)
        name = self._provider_labels.get(lbl.get(), "") if lbl else ""
        for n, info in getattr(self, "_providers", []):
            if n == name:
                return n, info
        return name, {}

    def _onboard_update_link(self):
        _name, info = self._onboard_selected()
        self._onboard_url = info.get("key_url", "")
        self._onboard_link.config(text=L("onboard_open_key_page"))

    def _onboard_start(self):
        key = self._onboard_key_entry.get().strip()
        if not key:
            self._onboard_status.config(fg="#a33", text=L("onboard_err_empty"))
            return
        provider, info = self._onboard_selected()
        self._onboard_btn.config(state=tk.DISABLED)
        self._onboard_status.config(fg="#2b2b2b", text=L("onboard_checking"))
        threading.Thread(target=self._onboard_validate_thread,
                          args=(provider, key, info), daemon=True).start()

    def _onboard_validate_thread(self, provider, key, info=None):
        info = info or {}
        model = info.get("default_model", "")
        base = ""
        for m in read_models():
            if m["id"] == model:
                base = m.get("base_url", "")
                break
        ok, code = validate_api_key(provider, key, base, model)
        self.root.after(0, lambda: self._onboard_validate_done(ok, code, provider, key))

    def _onboard_validate_done(self, ok, code, provider, key):
        self._onboard_btn.config(state=tk.NORMAL)
        if not ok:
            self._onboard_status.config(fg="#a33", text=L("onboard_err_api", code=code))
            return
        try:
            save_onboard_env(provider, key)
        except Exception as e:
            self._onboard_status.config(fg="#a33", text=L("internal_error", err=e))
            return
        self._onboard_frame.destroy()
        self._start_main_ui()

    # ---------- macOSメニューバー(画面最上部のOSメニュー。アプリ内
    # ヘッダーの[ 会話 ][ コマンド ]等とは別物) ----------
    def _build_menubar(self):
        menubar = tk.Menu(self.root)
        self.root.config(menu=menubar)

        # 先頭のアプリケーションメニュー(About/隠す/サービス/終了)はTk自身が
        # バンドル名から自動で用意してくれるが、中身の文言はTk本体に
        # コンパイル済みで埋め込まれた固定の英語で、OS言語設定にもここでの
        # 翻訳にも反応しない(setAppleMenu:というCocoaの古いAPIでTkが自分で
        # 登録してしまうため)。自前で"apple"という名前のメニューを追加しても
        # マージされず、空の別メニューが並ぶだけだったので作らない。日本語化は
        # _localize_native_app_menu() でOSネイティブメニューを直接書き換えて
        # 行う。「終了」を選んだ時にきちんと後片付け(_on_close)されるように
        # だけここでフックする。
        self.root.createcommand("tk::mac::Quit", self._on_close)

        edit_menu = tk.Menu(menubar, tearoff=0)
        menubar.add_cascade(label=L("menu_edit"), menu=edit_menu)
        edit_menu.add_command(label=L("menu_cut"), accelerator="Cmd-X",
                               command=lambda: self._menu_gen_event("<<Cut>>"))
        edit_menu.add_command(label=L("menu_copy"), accelerator="Cmd-C",
                               command=lambda: self._menu_gen_event("<<Copy>>"))
        edit_menu.add_command(label=L("menu_paste"), accelerator="Cmd-V",
                               command=lambda: self._menu_gen_event("<<Paste>>"))
        edit_menu.add_separator()
        edit_menu.add_command(label=L("menu_select_all"), accelerator="Cmd-A",
                               command=self._menu_select_all)

        # ツール：リモート接続の設定（キーの登録と同じく、GUIから完結させる）
        tools_menu = tk.Menu(menubar, tearoff=0)
        menubar.add_cascade(label=L("menu_tools"), menu=tools_menu)
        tools_menu.add_command(label=L("remote_menu"),
                               command=self._open_remote_dialog)

        # name="window" にするとTkが項目を自動生成してくれるが、その中身
        # (Minimize/Zoom等)は英語固定で翻訳できない。自前の項目にする。
        window_menu = tk.Menu(menubar, tearoff=0)
        menubar.add_cascade(label=L("menu_window"), menu=window_menu)
        window_menu.add_command(label=L("menu_minimize"), accelerator="Cmd-M",
                                 command=self.root.iconify)

        self.root.createcommand("tk::mac::ReopenApplication", lambda: self.root.deiconify())

    def _menu_gen_event(self, virtual):
        w = self.root.focus_get()
        if w is None:
            return
        try:
            w.event_generate(virtual)
        except Exception:
            pass

    def _menu_select_all(self):
        w = self.root.focus_get()
        if w is None:
            return
        try:
            if isinstance(w, tk.Text):
                w.tag_add("sel", "1.0", "end-1c")
            elif isinstance(w, tk.Entry):
                w.select_range(0, tk.END)
        except Exception:
            pass

    def _localize_native_app_menu(self):
        # Tkが自動生成するアプリケーションメニュー(About/隠す/サービス/終了)
        # の中身は英語固定でTkからは書き換えられない(_build_menubar内の説明
        # 参照)。pyobjc(py2appビルド時のみ同梱)が使える場合だけ、OSの
        # ネイティブメニューを直接書き換えて日本語化する。無い環境では何も
        # せず英語のまま(壊れはしない)。
        if LANG != "ja":
            return
        try:
            from AppKit import NSApplication
        except Exception:
            return
        try:
            main_menu = NSApplication.sharedApplication().mainMenu()
            app_menu = main_menu.itemAtIndex_(0).submenu() if main_menu else None
            if app_menu is None:
                return
            for item in app_menu.itemArray():
                title = str(item.title())
                if title.startswith("About "):
                    item.setTitle_("%s について" % title[len("About "):])
                elif title.startswith("Hide Others"):
                    item.setTitle_("ほかを隠す")
                elif title.startswith("Hide "):
                    item.setTitle_("%s を隠す" % title[len("Hide "):])
                elif title == "Show All":
                    item.setTitle_("すべてを表示")
                elif title == "Services":
                    item.setTitle_("サービス")
                elif title.startswith("Preferences"):
                    item.setTitle_("環境設定…")
                elif title.startswith("Quit "):
                    item.setTitle_("%s を終了" % title[len("Quit "):])
        except Exception:
            pass

    # ---------- 画面 ----------
    def _build_ui(self):
        self.bar = tk.Frame(self.root)
        self.bar.pack(fill=tk.X)

        # ヘッダーのボタン類は tk.Button/Menubutton だと macOS が独自の
        # 見た目(枠付きの部品)を勝手に描いてしまい、relief や色を変えても
        # 反映されない。tk.Label + クリックの組み合わせにすると、Tk自身が
        # 描画するので好きな見た目(会話タブと同じ手書き風)にできる。
        self.tab_chat = tk.Label(self.bar, text=L("tab_chat"), cursor=_pointing_cursor(), padx=3)
        self.tab_chat.bind("<Button-1>", lambda e: self._show_pane("chat"))
        # 左端の余白を赤線の始まり(padx=56)に合わせる(右端のボタン群を
        # 揃えたのと同じ考え方)。
        self.tab_chat.pack(side=tk.LEFT, padx=(56, 1), pady=2)
        self.tab_cmd = tk.Label(self.bar, text=L("tab_cmd"), cursor=_pointing_cursor(), padx=3)
        self.tab_cmd.bind("<Button-1>", lambda e: self._show_pane("cmd"))
        self.tab_cmd.pack(side=tk.LEFT, padx=1, pady=2)

        self.model_lbl = tk.Label(self.bar, textvariable=self.model_label_var)
        self.model_lbl.pack(side=tk.LEFT, padx=10, pady=6)

        # 見た目・AI切替・続きから、の3つも同じ理由で tk.Label + クリックに
        self.theme_btn = tk.Label(self.bar, cursor=_pointing_cursor(), padx=8, pady=2)
        self.theme_menu = tk.Menu(self.theme_btn, tearoff=0)
        self.theme_btn.bind("<Button-1>", lambda e: self._popup_menu(self.theme_menu, self.theme_btn))
        self._theme_choice = tk.StringVar(value=self.theme_name)
        for key, spec in THEMES.items():
            self.theme_menu.add_radiobutton(
                label=theme_label(spec), value=key, variable=self._theme_choice,
                command=lambda k=key: self._choose_theme(k))
        # 右端の余白を赤線の終わり(padx=56)に合わせる。ここが一番右端の
        # ボタンなので、右側だけ追加で余白を足す。
        self.theme_btn.pack(side=tk.RIGHT, padx=(6, 56), pady=3)

        # 幅は固定せず文字なりに(固定幅にすると文字が欠けて矢印と重なるため)
        self.switch_btn = tk.Label(self.bar, text=L("switch_btn"), cursor=_pointing_cursor(),
                                   padx=8, pady=2)
        self.switch_menu = tk.Menu(self.switch_btn, tearoff=0)
        self.switch_btn.bind("<Button-1>", lambda e: self._popup_menu(self.switch_menu, self.switch_btn))
        self.switch_btn.pack(side=tk.RIGHT, padx=6, pady=3)

        self.hist_btn = tk.Label(self.bar, text=L("hist_btn"), cursor=_pointing_cursor(),
                                 padx=8, pady=2)
        self.hist_btn.bind("<Button-1>", lambda e: self._write({"t": "list_history"}))
        self.hist_btn.pack(side=tk.RIGHT, padx=6, pady=3)

        # 交互モードの切替。いま何モードかが常に見えていないと、
        # 「勝手に確認なしで走った」と受け取られる（黙って挙動が変わるのが一番悪い）。
        self.mode_btn = tk.Label(self.bar, text=L("mode_btn"), cursor=_pointing_cursor(),
                                 padx=8, pady=2)
        self.mode_menu = tk.Menu(self.mode_btn, tearoff=0)
        self._mode_choice = tk.StringVar(value="default")
        for key in ("default", "accept-edits", "bypass"):
            self.mode_menu.add_radiobutton(
                label=L("mode_" + key.replace("-", "_")), value=key,
                variable=self._mode_choice,
                command=lambda k=key: self._write({"t": "set_mode", "mode": k}))
        self.mode_btn.bind("<Button-1>", lambda e: self._popup_menu(self.mode_menu, self.mode_btn))
        self.mode_btn.pack(side=tk.RIGHT, padx=6, pady=3)

        # 常設のバッジ（bypass のときは色を変える）。
        self.mode_badge = tk.Label(self.bar, text="", cursor=_pointing_cursor(), padx=6, pady=2)
        self.mode_badge.pack(side=tk.RIGHT, padx=(6, 0), pady=3)
        self._mode_key = "default"
        self._mode_writable = []

        # ヘッダー下の細い罫線(共通)。
        self.hdr_rule = tk.Frame(self.root, height=1)
        self.hdr_rule.pack(side=tk.TOP, fill=tk.X, padx=56)

        # 会話ペインとコマンドペインは同じ場所に重ねて置き、切り替えは
        # pack_forget/pack でなく tkraise で行う。pack_forget は中の
        # 罫線・穴のFrameを含めて全部いったんアンマップするようで、
        # 古いMacだと切り替えに何秒もかかっていた(tkraiseなら重ねた
        # まま前後を入れ替えるだけで済む)。
        self.pane_host = tk.Frame(self.root)
        self.pane_host.pack(side=tk.TOP, fill=tk.BOTH, expand=True)

        # ================= 会話ペイン =================
        self.chat_pane = tk.Frame(self.pane_host)
        self.chat_pane.place(relx=0, rely=0, relwidth=1, relheight=1)

        # ステータスバー。最下段、常に2行ぶんの高さを確保する
        # (pack_propagate(False)で中身の量に関わらず高さを保つ)。
        self.status_frame = tk.Frame(self.chat_pane)
        self.status_frame.pack(side=tk.BOTTOM, fill=tk.X)
        self.status_frame.pack_propagate(False)
        self.status_lbl = tk.Label(self.status_frame, textvariable=self.status_var,
                                   anchor=tk.NW, justify=tk.LEFT)
        # 左端を赤線(上のin_ruleと同じpadx=56)の始まりに合わせる。
        self.status_lbl.pack(fill=tk.BOTH, expand=True, padx=(56, 0))

        self.in_rule = tk.Frame(self.chat_pane, height=1)
        self.in_rule.pack(side=tk.BOTTOM, fill=tk.X, padx=56)

        # 書き込み欄。以前のような枠付きの箱+送信ボタンではなく、ノートの
        # 続きに見える4行ぶんの領域(罫線・穴もノート本文と共通)。
        # Enterで送信、Shift+Enterで改行。
        self.write_row = tk.Frame(self.chat_pane)
        self.write_row.pack(side=tk.BOTTOM, fill=tk.X)
        self.write_holes = tk.Canvas(self.write_row, width=36, highlightthickness=0)
        self.write_holes.pack(side=tk.LEFT, fill=tk.Y)
        self.write_holes.bind("<Configure>", lambda e: self._request_draw_holes())
        # 右端の手前(4文字ぶん)で折り返すための余白。固定サイズなので、
        # write_zone(expand=True)より先にpackして場所を確保しておく
        # (send_btnの件と同じ理由。順番を逆にすると場所が残らない)。
        self.write_pad_right = tk.Frame(self.write_row, width=1)
        self.write_pad_right.pack(side=tk.RIGHT, fill=tk.Y)
        self.write_zone = tk.Text(self.write_row, height=4, wrap=tk.CHAR,
                                  relief=tk.FLAT, highlightthickness=0, bd=0,
                                  padx=18, pady=0)
        self.write_zone.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        self.write_zone.bind("<Return>", self._on_return)
        # プレースホルダー(矢印)は <<Modified>> (中身が実際に変わった後の
        # 通知)で消す。<Key> で消すとIMEの変換前の生入力に割り込み、
        # 1文字目だけ英字のまま入ってしまう不具合が過去にあったため。
        self.write_zone.bind("<<Modified>>", self._write_on_modified)
        self.write_zone.bind("<Button-1>", self._write_click_clear)
        self.write_zone.bind("<FocusOut>", self._write_focus_out)
        self.write_zone.bind(
            "<Configure>", lambda e: self._request_draw_grid(self.write_zone, "_grid_write"))
        self._write_ph = False

        mid = tk.Frame(self.chat_pane)
        mid.pack(side=tk.TOP, fill=tk.BOTH, expand=True)
        self.holes = tk.Canvas(mid, width=34, highlightthickness=0)
        self.holes.pack(side=tk.LEFT, fill=tk.Y)
        self.holes.bind("<Configure>", lambda e: self._request_draw_holes())
        self.note = tk.Text(mid, wrap=tk.CHAR, state=tk.DISABLED, height=1,
                            padx=18, pady=14, relief=tk.FLAT,
                            highlightthickness=0, spacing2=2)
        sb = tk.Scrollbar(mid, command=self.note.yview)
        self.note.config(yscrollcommand=sb.set)
        sb.pack(side=tk.RIGHT, fill=tk.Y)
        self.note.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        self.note.bind(
            "<Configure>",
            lambda e: (self._relayout(e), self._request_draw_grid(self.note, "_grid_note")))
        # トラックパッドの既定のスクロールは半端なpxで止まるため、罫線と
        # 文字がその瞬間だけズレて見える。1行(=pitch)単位でしか止まら
        # ないようにする。
        self.note.bind("<MouseWheel>", self._on_note_wheel)

        # ================= コマンドペイン =================
        # 背景は黒地(端末風)でテーマに関係なく固定。文字色だけ
        # _style_cmd_pane() でテーマに合わせて変える(ハッカーなら緑、
        # それ以外は既定の配色)。ここでは初期値としてCBだけ使う。
        self.CB = CB = "#0f1115"
        CF = CIN = CERR = CDIM = CSUCCESS = "#d6d6d6"  # 後で _style_cmd_pane が上書きする
        self.cmd_pane = tk.Frame(self.pane_host, bg=CB)
        self.cmd_pane.place(relx=0, rely=0, relwidth=1, relheight=1)
        # フォルダパスが深くなると長くなり、同じ行だと入力欄を圧迫して
        # いたため、パス表示は独立した1行(上)にして、入力欄(下)は常に
        # フル幅を使えるようにする。
        self.cmd_row = tk.Frame(self.cmd_pane, bg=CB)
        self.cmd_row.pack(side=tk.BOTTOM, fill=tk.X)
        self.cmd_prompt = tk.Label(self.cmd_pane, textvariable=self.cmd_prompt_var,
                                   anchor=tk.W, bg=CB, fg=CIN)
        self.cmd_prompt.pack(side=tk.BOTTOM, fill=tk.X, padx=(10, 8), pady=(0, 2))
        self.cmd_stop_btn = tk.Button(self.cmd_row, text=L("stop_btn"), width=5,
                                      state=tk.DISABLED, command=self._cmd_stop)
        self.cmd_stop_btn.pack(side=tk.RIGHT, padx=(2, 8), pady=6)
        # パス込みの長いコマンドが窮屈で見づらいとの指摘で、2行→3行に
        # (あくまで1コマンドの表示領域で、複数行のスクリプトを書く欄
        # ではないため、Returnは改行ではなく送信、Up/Downはカーソル移動
        # ではなく履歴呼び出しのまま)。
        self.cmd_entry = tk.Text(self.cmd_row, height=3, wrap=tk.CHAR, relief=tk.FLAT,
                                 bg="#1a1d22", fg=CF, insertbackground=CF,
                                 highlightthickness=0, padx=4, pady=2)
        self.cmd_entry.pack(side=tk.LEFT, fill=tk.X, expand=True, padx=(8, 4), pady=6)
        self.cmd_entry.bind("<Return>", lambda e: (self._cmd_submit(), "break")[1])
        self.cmd_entry.bind("<Up>", self._cmd_hist_prev)
        self.cmd_entry.bind("<Down>", self._cmd_hist_next)
        self.cmd_entry.bind("<Control-c>", lambda e: (self._cmd_stop(), "break")[1])
        self.cmd_hist = []          # コマンド履歴(このセッション限り)
        self.cmd_hist_idx = None
        self.cmid = cmid = tk.Frame(self.cmd_pane, bg=CB)
        cmid.pack(side=tk.TOP, fill=tk.BOTH, expand=True)
        self.cmd_out = tk.Text(cmid, wrap=tk.CHAR, state=tk.DISABLED, bg=CB, fg=CF,
                               padx=10, pady=8, relief=tk.FLAT, highlightthickness=0)
        self.cmd_out.tag_config("cin", foreground=CIN)
        self.cmd_out.tag_config("cerr", foreground=CERR)
        self.cmd_out.tag_config("cdim", foreground=CDIM)
        self.cmd_out.tag_config("csuccess", foreground=CSUCCESS)
        csb = tk.Scrollbar(cmid, command=self.cmd_out.yview)
        self.cmd_out.config(yscrollcommand=csb.set)
        csb.pack(side=tk.RIGHT, fill=tk.Y)
        self.cmd_out.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        self._cmd_refresh_prompt()

        self.pane = "chat"
        self.chat_pane.tkraise()   # 起動直後は会話ペインを前面に

    def _show_pane(self, name):
        self.pane = name
        if name == "cmd":
            self.cmd_pane.tkraise()
            self._cmd_refresh_prompt()
            self.cmd_entry.focus_set()
        else:
            self.chat_pane.tkraise()
        self._style_tabs()

    def _style_tabs(self):
        """ヘッダーのボタン全部(会話/コマンド のタブ + 見た目/AI切替/
        続きから)を同じ調子にする。ノートモードは手書き風＋下線、
        コーディング/ハッカーは枠を使わず「[ 項目 ]」の無骨な見た目に
        統一する(以前の押しボタン風の枠は、ノートだけ枠が無いのが
        不揃いだと指摘された)。タブだけ選択中を太字にする。
        (全部 tk.Label なので activebackground 等 Button専用オプションは使えない)"""
        t = THEMES[self.theme_name]
        paper = self.theme_name == "paper"
        active = getattr(self, "pane", "chat")
        tabs = (("chat", self.tab_chat, L("tab_chat")), ("cmd", self.tab_cmd, L("tab_cmd")))
        utils = ((self.hist_btn, L("hist_btn")), (self.switch_btn, L("switch_btn")),
                 (self.mode_btn, L("mode_btn")),
                 (self.theme_btn, theme_label(t) + " ▾"))
        # 左右端を赤線に揃えたのはノート(縦線・罫線がある)向けの調整。
        # コーディング/ハッカーは全面黒で赤線が無く、[ ]で幅も食うため、
        # 同じ余白だと「続きから」が完全に隠れるほど窮屈だった。
        # ノートのレイアウトは変えず、それ以外だけ余白を詰める。
        self.tab_chat.pack_configure(padx=(56 if paper else 4, 1))
        self.theme_btn.pack_configure(padx=(6, 56 if paper else 4))
        # ボタン間の隙間・ボタン自身の内側余白も、コーディング/ハッカーは
        # 詰める(フォントも1段階小さくする)。ノートは変えない。
        gap = 6 if paper else 2
        self.model_lbl.pack_configure(padx=(10 if paper else 4))
        self.tab_cmd.pack_configure(padx=(1 if paper else gap))
        self.switch_btn.pack_configure(padx=gap)
        self.hist_btn.pack_configure(padx=gap)
        # 非選択タブの色。dimは背景とのコントラストが低すぎて
        # (テーマにより約2.8〜4.2:1)背景に溶け込み、選択中と区別しづらい
        # との指摘があった。aiは各テーマで元々コントラストが高く
        # (7.7〜11.8:1)、選択中(fg)ともきちんと色が違うので、これに変える。
        off_color = t["ai"]

        def deco(label):
            return label if paper else "[ %s ]" % label

        for name, btn, label in tabs:
            on = (name == active) or (name == "chat" and active not in ("chat", "cmd"))
            if paper:
                f = self.font
                fs = max(9, f[1] - 1)   # 少し小さめにして幅を詰める
                fnt = (f[0], fs, "bold", "underline") if on \
                    else (f[0], fs, "underline")
                btn.config(text=deco(label), relief=tk.FLAT, bd=0, highlightthickness=0,
                           font=fnt, fg=(t["fg"] if on else off_color), bg=t["bg"])
            else:
                tf = t["font"]
                btn.config(text=deco(label), relief=tk.FLAT, bd=0, highlightthickness=0,
                           font=(tf[0], tf[1] - 2), fg=(t["fg"] if on else off_color),
                           bg=t["bg"], padx=1)
        for btn, label in utils:
            if paper:
                f = self.font
                fs = max(10, f[1])   # 手書き風は小さいと潰れるので本文サイズのまま
                btn.config(text=deco(label), relief=tk.FLAT, bd=0, highlightthickness=0,
                           font=(f[0], fs, "underline"), fg=t["dim"], bg=t["bg"])
            else:
                # 常時使うボタンなのでdimではなくfgにする(理由は上のtabsと同じ)。
                btn.config(text=deco(label), relief=tk.FLAT, bd=0, highlightthickness=0,
                           font=("Hiragino Sans", 10), fg=t["fg"], bg=t["bg"], padx=2)

    # ---------- コマンドパネル ----------
    def _cmd_env(self):
        env = dict(os.environ)
        env["PATH"] = (os.path.expanduser("~/bin") +
                       ":/usr/local/bin:/usr/local/sbin:/opt/homebrew/bin"
                       ":/opt/homebrew/sbin"
                       ":/Library/Frameworks/Python.framework/Versions/3.10/bin"
                       ":/usr/bin:/bin:/usr/sbin:/sbin")
        env["TERM"] = "dumb"
        return env

    def _cmd_refresh_prompt(self):
        home = os.path.expanduser("~")
        d = self.cwd
        if d == home:
            d = "~"
        elif d.startswith(home + os.sep):
            d = "~" + d[len(home):]
        self.cmd_prompt_var.set("watermark:%s$" % d)

    def _cmd_echo(self, text, tag=None):
        self.cmd_out.config(state=tk.NORMAL)
        self.cmd_out.insert(tk.END, text, (tag,) if tag else ())
        self.cmd_out.see(tk.END)
        self.cmd_out.config(state=tk.DISABLED)

    def _cmd_set_running(self, on):
        # 入力欄は無効化しない(無効化すると Ctrl-C や ↑↓ のキー入力を
        # 受け取れなくなるため)。二重実行は _cmd_submit のガードで防ぐ。
        self.cmd_stop_btn.config(state=tk.NORMAL if on else tk.DISABLED)
        self.cmd_entry.focus_set()

    def _cmd_submit(self):
        if self.cmd_proc is not None:
            self._cmd_echo(L("busy_running"), "cdim")
            return
        cmd = self.cmd_entry.get("1.0", "end-1c").strip()
        if not cmd:
            return
        self.cmd_entry.delete("1.0", tk.END)
        if not self.cmd_hist or self.cmd_hist[-1] != cmd:
            self.cmd_hist.append(cmd)
        self.cmd_hist_idx = None
        self._cmd_echo(self.cmd_prompt_var.get() + " " + cmd + "\n", "cin")

        if cmd in ("clear", "cls"):
            self.cmd_out.config(state=tk.NORMAL)
            self.cmd_out.delete("1.0", tk.END)
            self.cmd_out.config(state=tk.DISABLED)
            return
        if cmd == "cd" or cmd.startswith(("cd ", "cd\t")):
            target = os.path.expanduser(cmd[2:].strip() or "~")
            if not os.path.isabs(target):
                target = os.path.normpath(os.path.join(self.cwd, target))
            if os.path.isdir(target):
                self.cwd = target
                self._cmd_refresh_prompt()
                self._write({"t": "cwd", "path": self.cwd})   # AI のツールにも反映
            else:
                self._cmd_echo(L("no_such_folder", path=target), "cerr")
            return

        self._cmd_set_running(True)
        threading.Thread(target=self._cmd_run, args=(cmd,), daemon=True).start()

    def _cmd_run(self, cmd):
        try:
            # 独立したプロセスグループで起動する。中止のとき、シェルだけでなく
            # その子(ssh/scp 等)まで一括で止められるようにするため。
            p = subprocess.Popen(cmd, shell=True, cwd=self.cwd, env=self._cmd_env(),
                                 stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                 text=True, bufsize=1, encoding="utf-8",
                                 errors="replace", start_new_session=True)
        except Exception as e:
            self.events.put({"t": "cmd_out", "text": L("cannot_run", err=e)})
            self.events.put({"t": "cmd_done", "code": -1})
            return
        self.cmd_proc = p
        for line in p.stdout:
            self.events.put({"t": "cmd_out", "text": line})
        p.wait()
        self.events.put({"t": "cmd_done", "code": p.returncode})

    def _cmd_stop(self):
        p = self.cmd_proc
        if p is None:
            return
        try:
            os.killpg(os.getpgid(p.pid), signal.SIGTERM)   # プロセスグループごと
        except Exception:
            try:
                p.terminate()
            except Exception:
                pass
        # まだ生きていたら少し待って強制終了
        self.root.after(1500, lambda: self._cmd_kill(p))

    def _cmd_kill(self, p):
        if p is not None and p.poll() is None:
            try:
                os.killpg(os.getpgid(p.pid), signal.SIGKILL)
            except Exception:
                try:
                    p.kill()
                except Exception:
                    pass

    def _cmd_hist_prev(self, _e=None):
        if not self.cmd_hist:
            return "break"
        if self.cmd_hist_idx is None:
            self.cmd_hist_idx = len(self.cmd_hist) - 1
        elif self.cmd_hist_idx > 0:
            self.cmd_hist_idx -= 1
        self.cmd_entry.delete("1.0", tk.END)
        self.cmd_entry.insert("1.0", self.cmd_hist[self.cmd_hist_idx])
        return "break"

    def _cmd_hist_next(self, _e=None):
        if self.cmd_hist_idx is None:
            return "break"
        self.cmd_hist_idx += 1
        self.cmd_entry.delete("1.0", tk.END)
        if self.cmd_hist_idx >= len(self.cmd_hist):
            self.cmd_hist_idx = None            # 最新より下 = 空に
        else:
            self.cmd_entry.insert("1.0", self.cmd_hist[self.cmd_hist_idx])
        return "break"

    def _request_draw_holes(self):
        """_draw_holes は穴を全部描き直す(delete して作り直す)ので、
        タブの切り替えなどで <Configure> が連続して何度も飛んでくると
        そのたびに全部作り直してしまい遅くなる。after_idle でまとめる。"""
        if getattr(self, "_holes_pending", False):
            return
        self._holes_pending = True

        def go():
            self._holes_pending = False
            self._draw_holes()
        self.root.after_idle(go)

    def _draw_holes(self):
        # ノート本文の左と、書き込み欄の左と、両方に同じ穴を敷く
        # (書き込み欄までルーズリーフの続きに見えるように)
        self._draw_holes_on(self.holes)
        self._draw_holes_on(self.write_holes)

    def _draw_holes_on(self, canvas):
        canvas.delete("all")
        t = THEMES[self.theme_name]
        if not t.get("holes"):
            canvas.config(width=1, bg=t["bg"])
            return
        canvas.config(width=36, bg=t["bg"])
        h = canvas.winfo_height() or 600
        hole = t.get("code_bg", "#e9e0c8")   # 紙より一段濃いグレー
        y = 36
        while y < h:
            # 穴本体(薄グレー) + 左下に濃いめの弧で影っぽく。
            # 小さめ・間隔を詰めて本物のルーズリーフに近づけた
            canvas.create_oval(12, y - 6, 24, y + 6, fill=hole, outline=t["dim"])
            canvas.create_arc(12, y - 6, 24, y + 6, start=120, extent=140,
                              style=tk.ARC, outline=t["dim"], width=2)
            y += 48
        # 大学ノートの赤い縦罫。ノート本文のすぐ左(この canvas の右端)に。
        vline = t.get("vline")
        if vline:
            canvas.create_line(35, 0, 35, h, fill=vline, width=1)

    def _request_draw_grid(self, widget, pool_attr):
        """_draw_grid を呼ぶ薄いラッパー。何度呼ばれても取りこぼさない
        よう after_idle 越しにまとめて1回呼ぶ。"""
        pending_attr = pool_attr + "_pending"
        if getattr(self, pending_attr, False):
            return
        setattr(self, pending_attr, True)

        def go():
            setattr(self, pending_attr, False)
            self._draw_grid(widget, pool_attr)
        self.root.after_idle(go)

    def _draw_grid(self, widget, pool_attr):
        """横罫線を、文字の位置を一切見ずに上から下まで固定ピッチで敷く
        (左の穴・縦の赤線と同じ考え方: 中身を一切見ないので中身とズレる
        余地が無い)。

        以前は見えている行を1つずつ実測して、その行の真下に線を置く
        方式(_draw_rules)だった。見出し・絵文字・漢字の多い行などで
        実際の文字の高さが微妙にばらつき、3日以上・何通りも式を変えて
        調整しても、文字と線が重なる/足りない/ズレるを解消できなかった。
        穴や縦の赤線が一度も壊れたことがないのは、そもそも中身を見て
        いないからだと気づき、横罫線もそれに合わせた。ウィジェットの
        高さだけを見て一定間隔(pitch、_apply_themeで計算)に線を置く。
        スクロールや挿入のたびに測り直す必要も無くなったので、以前より
        軽い(スクロールが鈍くなっていた原因もこれだったはず)。"""
        if not hasattr(self, pool_attr):
            setattr(self, pool_attr, [])
        pool = getattr(self, pool_attr)
        color = THEMES[self.theme_name].get("hline")
        pitch = getattr(self, "pitch", 24)
        h = widget.winfo_height()
        if not color or pitch <= 0 or h < pitch:
            for ln in pool:
                ln.place_forget()
            return
        n = int(h // pitch)
        # 行の切れ目ちょうど(pitch境界)ではなく、文字寄り(半分手前)に
        # 線を詰める。ピッチ自体はここでは変えないので、揃っている状態は
        # 崩れない。
        offset = getattr(self, "_line_gap", 0) // 2
        while len(pool) < n:
            pool.append(tk.Frame(widget, height=1, bd=0, highlightthickness=0))
        for i, ln in enumerate(pool):
            if i < n:
                ln.config(bg=color)
                ln.place(in_=widget, x=0, relwidth=1.0,
                         y=(i + 1) * pitch - offset, height=1)
            else:
                ln.place_forget()

    def _apply_theme(self, name):
        t = THEMES[name]
        self.theme_name = name
        f = pick_font(*t["font"]) if t.get("handwriting") else t["font"]
        self.font = f
        code_f = ("Menlo", f[1] - 1)

        self.root.config(bg=t["bg"])
        for w in (self.bar, self.write_row, self.status_frame):
            w.config(bg=t["bg"])                            # ヘッダーも本文と同色
        # コーディング/ハッカーはdimの文字が背景に沈んで見づらい
        # (コントラスト比 約3.9〜4.2:1、fgなら11〜15.6:1)ため、
        # ノート以外ではヘッダーはfgを使う。
        model_fg = t["dim"] if self.theme_name == "paper" else t["fg"]
        self.model_lbl.config(bg=t["bg"], fg=model_fg, font=(f[0], f[1] - 2))
        self.status_lbl.config(bg=t["bg"], fg=t["dim"], font=(f[0], 10))
        self._style_tabs()  # 見た目/AI切替/続きから の3つもここでまとめて設定
        self.cmd_out.config(font=code_f)
        self.cmd_entry.config(font=code_f)
        self.cmd_prompt.config(font=code_f)
        line = t.get("line", t["dim"])
        self.hdr_rule.config(bg=line)                       # ヘッダー下の罫線(赤)
        self.in_rule.config(bg=line)                        # 書き込み欄の上の罫線(赤)
        self.note.config(bg=t["bg"], fg=t["fg"], font=f, insertbackground=t["fg"])

        # 罫線を実測して合わせるのはもうやめる。逆に、罫線の間隔(pitch)を
        # 先に固定で決め、本文の行送り(spacing)をそのpitchに"ぴったり
        # 一致するよう計算で"合わせる。Tkのフォント指標(ascent/descent)
        # は整数px、GAPも整数なので、pitch = ascent+descent+GAP は端数の
        # 出ない厳密な整数になる。spacing2/spacing3にそのGAPをそのまま
        # 渡せば、Tkが実際に描く行の高さは(見出し・絵文字を含め全行とも
        # 同じ書体・同じサイズである限り)必ずascent+descent+GAPになり、
        # pitchと理論上ズレようがない(測って追いかける要素が無い)。
        try:
            fm = tkfont.Font(font=f)
            ascent = fm.metrics("ascent")
            descent = fm.metrics("descent")
        except Exception:
            ascent, descent = int(f[1] * 0.9), int(f[1] * 0.25)
        S = max(6, int(round(f[1] * 0.5)))    # 行間(整数px)
        self.pitch = ascent + descent + S
        self._line_gap = S   # _draw_grid が罫線を文字寄りに詰めるのに使う
        self.status_frame.config(height=self.pitch * 2)   # ステータスバーは常に2行ぶん
        self.note.config(spacing1=0, spacing2=S, spacing3=S)

        # 書き込み欄。ノート本文と地続きに見えるよう、同じ背景・書体・
        # 行間にする。点滅カーソルは止め(insertofftime=0)、代わりに
        # 空のときは矢印(WRITE_MARK)を書き始めの目印として出す。
        write_fg = t["dim"] if getattr(self, "_write_ph", False) else t["input_fg"]
        write_font_size = min(f[1], 13)
        self.write_zone.config(bg=t["bg"], fg=write_fg, font=(f[0], write_font_size),
                               insertbackground=t["input_fg"], insertofftime=0,
                               spacing1=0, spacing2=S, spacing3=S)
        # 右端の手前4文字ぶんで折り返すための余白(全角文字幅≒フォント
        # サイズとして概算)。
        self.write_pad_right.config(bg=t["bg"], width=write_font_size * 4)
        self._draw_holes()

        # 色・書体・寄せだけ。左右の余白(1/3)は _relayout が幅から計算する。
        # 自分の発言は「右側 2/3 のブロックに置く」が、文字は左そろえ。
        # (右寄せにすると2行目以降が右にばらけて読みにくい、との指摘)
        for tg, col in (("you", t["fg"]), ("ai", t["ai"]),
                        ("dim", t["dim"]), ("err", t["err"]), ("gap", t["bg"])):
            self.note.tag_config(tg, foreground=col, justify=tk.LEFT,
                                 spacing1=0, spacing2=S, spacing3=S,
                                 font=f)
        self.note.tag_config("prompt", foreground=t.get("prompt", t["fg"]),
                             justify=tk.LEFT, font=(f[0], f[1], "bold"))
        self.note.tag_config("rule", lmargin1=0, lmargin2=0, rmargin=0,
                             spacing1=0, spacing2=S, spacing3=S)
        self.note.tag_config("code", font=code_f, background=t.get("code_bg", t["bg"]),
                             lmargin1=f[1] * 3, lmargin2=f[1] * 3)
        hl = t.get("hl", {})
        for key, tag in HL_TAG.items():
            self.note.tag_config(tag, foreground=hl.get(key, t["ai"]), font=code_f,
                                 background=t.get("code_bg", t["bg"]))
        self._relayout()
        # テーマ切替は <Configure> を発生させない(ウィンドウサイズは
        # 変わらない)ので、色やpitchが変わる罫線はここで明示的に引き直す。
        self._request_draw_grid(self.note, "_grid_note")
        self._request_draw_grid(self.write_zone, "_grid_write")
        self._style_cmd_pane()

    def _style_cmd_pane(self):
        """コマンドパネルの配色。ハッカーの時は緑系(エラー/終了コードは
        赤のまま)、ノートの時は本文と同じ薄いベージュ地に濃紺の文字、
        それ以外(コーディング)は従来通りの端末風(黒地)のまま。"""
        if self.theme_name == "hacker":
            bg, cf, cin, cdim, csuccess, cerr, entry_bg = (
                "#000000", "#39ff5a", "#00ff66", "#2e7d4f", "#39ff5a",
                "#ff5555", "#0a0f0a")
        elif self.theme_name == "paper":
            bg, cf, cin, cdim, csuccess, cerr, entry_bg = (
                "#f6efdc", "#243b6b", "#5a4636", "#9a8f78", "#2e7d32",
                "#a5341f", "#f6efdc")
        else:
            bg, cf, cin, cdim, csuccess, cerr, entry_bg = (
                "#0f1115", "#d6d6d6", "#4d9fff", "#7a8088", "#4caf50",
                "#ff6b6b", "#1a1d22")
        for w in (self.cmd_pane, self.cmd_row, self.cmid, self.cmd_prompt):
            w.config(bg=bg)
        self.cmd_out.config(bg=bg, fg=cf)
        self.cmd_out.tag_config("cin", foreground=cin)
        self.cmd_out.tag_config("cerr", foreground=cerr)
        self.cmd_out.tag_config("cdim", foreground=cdim)
        self.cmd_out.tag_config("csuccess", foreground=csuccess)
        self.cmd_entry.config(bg=entry_bg, fg=cf, insertbackground=cf)
        self.cmd_prompt.config(fg=cin)

    def _relayout(self, event=None):
        """幅の 1/3 を左右の余白に。自分=左1/3空け右寄せ / 相手=右1/3空け左寄せ。"""
        w = self.note.winfo_width()
        if w < 80:
            self.root.after(60, self._relayout)
            return
        third = int(w / 3)
        near = EDGE                      # 書き出しは赤い縦罫のすぐ右から
        ch = max(1, self.font[1])        # ざっくり全角1文字ぶん
        # 質問ブロックを 4 文字ぶん左へ / 解答ブロックを 4 文字ぶん右へ広げる
        you_left = max(near + 2 * ch, third - 4 * ch)
        ai_right = max(2 * ch, third - 4 * ch)
        self.note.tag_config("you", lmargin1=you_left, lmargin2=you_left, rmargin=near)
        for tag in ("ai", "dim", "err"):
            self.note.tag_config(tag, lmargin1=near, lmargin2=near, rmargin=ai_right)

        # テーマを変えたらモード徽標の色も引き直す（テーマの配色から取る）。
        if hasattr(self, "mode_badge"):
            self._apply_mode_colors()

    def _popup_menu(self, menu, widget):
        """見た目/AI切替ボタン用。普通のButtonの真下にメニューを出す
        (Menubuttonをやめて見た目を他のボタンと揃えるための代わり)。"""
        x = widget.winfo_rootx()
        y = widget.winfo_rooty() + widget.winfo_height()
        try:
            menu.tk_popup(x, y)
        finally:
            menu.grab_release()

    def _choose_theme(self, key):
        if key not in THEMES:
            return
        self._theme_choice.set(key)
        self._apply_theme(key)
        save_cfg({"theme": key})

    def _block_sep(self):
        """発言の切れ目に空の1行。先頭では入れない。
        大学ノートの「1行あけて書く」感じ。行の縦リズムも崩さない。
        横罫線は全行に敷く方式(_draw_rules)に一本化したので、ここでは
        個別には挿入しない。"""
        if self.note.index("end-1c") != "1.0":
            self.note.insert(tk.END, "\n", "gap")

    def _append(self, text, tag, anchor=False):
        """1ブロックを一気に書く(自分の発言・お知らせ・エラー用)。"""
        self.note.config(state=tk.NORMAL)
        self._block_sep()
        start = self.note.index("end-1c")
        if tag == "you" and THEMES[self.theme_name].get("prompt_prefix"):
            self.note.insert(tk.END, "watermark> ", ("prompt", "you"))
        self.note.insert(tk.END, text.rstrip("\n") + "\n", tag)
        if anchor:
            # 自分の発言の先頭に印。返答が来たらここを画面の一番上に置く
            # ことで、Enter を押した瞬間に自分の文が消える問題を防ぐ。
            self.note.mark_set("q_anchor", start)
            self.note.mark_gravity("q_anchor", "left")
        self.note.config(state=tk.DISABLED)

    def _stream_append(self, text, tag):
        """AIの返答を少しずつ流し込む(一瞬で入れ替わって読めない問題の対策)。
        流し込み中は画面を下端に追従させず、直前の自分の発言を上に留める。"""
        self.note.config(state=tk.NORMAL)
        self._block_sep()
        self.note.config(state=tk.DISABLED)
        if self.note_has_anchor():
            self.note.yview("q_anchor")           # 自分の質問を画面最上部へ
        self._stream_step(list(text), tag)

    def _stream_step(self, chars, tag):
        if not chars:
            self.note.config(state=tk.NORMAL)
            self.note.insert(tk.END, "\n", tag)
            self.note.config(state=tk.DISABLED)
            self.note.see(tk.END)
            return
        chunk = "".join(chars[:24])
        del chars[:24]
        self.note.config(state=tk.NORMAL)
        self.note.insert(tk.END, chunk, tag)
        self.note.config(state=tk.DISABLED)
        # 返答が書き込み欄の下に隠れて続きに気づけない問題への対応。
        # 質問直後はq_anchorで質問が見える位置から始まるが、返答が伸びて
        # 画面の下端に達したら、書いている文字を追いかけて自然に下へ
        # 流す(短い返答ならここは実質何もしない=見える範囲のままで済む)。
        self.note.see(tk.END)
        # 40msでもまだ速いとの指摘でさらに遅く。
        self.root.after(70, lambda: self._stream_step(chars, tag))

    def note_has_anchor(self):
        try:
            self.note.index("q_anchor")
            return True
        except tk.TclError:
            return False

    def _on_note_wheel(self, event):
        """1行(表示上の1単位 = _apply_themeでpitchぴったりに揃えている)
        単位でしか止まらないようにする。event.deltaを貯めて、1行分
        たまるたびに yview_scroll(±1, "units") を1回だけ呼ぶ(標準の
        px単位スクロールは自前で止めるので、既定の処理はさせない
        = return "break")。THRESHはトラックパッドの感触を見ながらの
        調整値。"""
        self._wheel_accum = getattr(self, "_wheel_accum", 0) + event.delta
        THRESH = 3
        while self._wheel_accum >= THRESH:
            self.note.yview_scroll(-1, "units")
            self._wheel_accum -= THRESH
        while self._wheel_accum <= -THRESH:
            self.note.yview_scroll(1, "units")
            self._wheel_accum += THRESH
        return "break"

    def _render_reply(self, txt):
        """```コードブロック``` を含む返答を、地の文とコードに分けて描画する。
        コードは等幅・淡い背景 + ざっくりシンタックス着色。ストリーム表示は
        しない(構文の途中で色付けが崩れるため一気に出す)。"""
        self.note.config(state=tk.NORMAL)
        self._block_sep()
        pos = 0
        for m in FENCE_RE.finditer(txt):
            pre = txt[pos:m.start()].strip("\n")
            if pre:
                self.note.insert(tk.END, pre + "\n", "ai")
            code = m.group(2).rstrip("\n")
            c0 = self.note.index("end-1c")
            self.note.insert(tk.END, code + "\n", "code")
            self._highlight(c0, self.note.index("end-1c"))
            pos = m.end()
        tail = txt[pos:].strip("\n")
        if tail:
            self.note.insert(tk.END, tail + "\n", "ai")
        self.note.config(state=tk.DISABLED)
        # ストリーム表示(_stream_step)と同じく、末尾が見える位置まで
        # 下げる。q_anchorだけだと返答が長い時に続きが隠れて見えなかった。
        self.note.see(tk.END)

    def _highlight(self, a, b):
        try:
            src = self.note.get(a, b)
        except tk.TclError:
            return
        for m in CODE_RE.finditer(src):
            tag = HL_TAG.get(m.lastgroup)
            if tag:
                self.note.tag_add(tag, "%s+%dc" % (a, m.start()),
                                  "%s+%dc" % (a, m.end()))

    # ---------- バックエンド ----------
    def _start_backend(self):
        cmd, env = build_backend_command_and_env()
        if cmd is None:
            messagebox.showerror(L("cannot_start_title"),
                                  L("cannot_start_body", err="claude-agent.pl"))
            self.root.destroy()
            return
        try:
            self.proc = subprocess.Popen(
                cmd, env=env,
                stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                # stderr を捨てない: バックエンドが即死したとき、GUI 側に
                # 「なぜ死んだか」を出す手段がこれしかない（実機で
                # 「入力できない」だけが見えて原因不明になった）。
                stderr=subprocess.PIPE, bufsize=1,
                universal_newlines=True, encoding="utf-8",
            )
        except OSError as e:
            messagebox.showerror(L("cannot_start_title"), L("cannot_start_body", err=e))
            self.root.destroy()
            return
        threading.Thread(target=self._reader, daemon=True).start()
        self._stderr_tail = []
        threading.Thread(target=self._reader_err, daemon=True).start()

    _stderr_tail = None

    def _reader_err(self):
        """バックエンドの stderr を最後の 20 行だけ保持する（常駐ログにはしない）。"""
        try:
            for line in self.proc.stderr:
                line = line.rstrip("\n")
                if not line:
                    continue
                self._stderr_tail.append(line)
                if len(self._stderr_tail) > 20:
                    del self._stderr_tail[0]
        except Exception:
            return

    def _reader(self):
        for line in self.proc.stdout:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except ValueError:
                obj = {"t": "note", "text": line}
            self.events.put(obj)
        self.events.put({"t": "bye"})

    def _update_mode(self, mode, writable=None):
        """モードの表示を合わせる。色はテーマの配色から取る（直書きしない）。"""
        if not mode:
            return
        self._mode_key = mode
        self._mode_choice.set(mode)
        if writable is not None:
            self._mode_writable = list(writable)
        short = L("mode_" + mode.replace("-", "_") + "_short")
        self.mode_badge.configure(text=short)
        self._apply_mode_colors()

    def _apply_mode_colors(self):
        try:
            t = THEMES[self.theme_name]
        except Exception:
            return
        key = getattr(self, "_mode_key", "default")
        if key == "bypass":
            fg = t["err"]          # 危険色。常に見えている必要がある
        elif key == "accept-edits":
            fg = t["ai"]
        else:
            fg = t["dim"]
        self.mode_badge.configure(fg=fg, bg=t["bg"])
        self.mode_btn.configure(fg=t["fg"], bg=t["bg"])

    def _write(self, obj):
        if not self.proc or self.proc.poll() is not None:
            return
        try:
            self.proc.stdin.write(json.dumps(obj, ensure_ascii=False) + "\n")
            self.proc.stdin.flush()
        except (BrokenPipeError, ValueError):
            pass

    # ---------- イベント ----------
    def _pump(self):
        try:
            while True:
                obj = self.events.get_nowait()
                try:
                    self._handle(obj)
                except Exception as e:
                    self._append(L("internal_error", err=e), "err")
        except queue.Empty:
            pass
        self.root.after(80, self._pump)

    def _handle(self, obj):
        t = obj.get("t")
        if t == "ready":
            # _fill_menu は self._current_model_id を見て「← 使用中」を
            # 付けるので、_set_model を呼ぶより先に自分でセットしておく
            # (_set_model 自体は後段の短縮表示更新のために引き続き呼ぶ)。
            self._current_model_id = obj.get("model", "")
            # 哪些厂商已有密钥只有 agent 知道（它持有密钥、读过 ~/.claude-agent-env），
            # GUI 自己猜会和 agent 的判断打架，所以只接收、不推断。
            self._has_key = {p.get("name"): bool(p.get("has_key"))
                             for p in obj.get("providers", []) if p.get("name")}
            self._fill_menu(obj.get("models", []))
            self._set_model(obj.get("provider", ""), obj.get("model", ""))
            hist = L("history_encrypted") if obj.get("history") else L("history_off")
            self.status_var.set(L("ready_status", hist=hist))
            self._update_mode(obj.get("mode", "default"), obj.get("writable"))
            self._set_busy(False)
            self._focus_write_zone()
        elif t == "mode":
            self._update_mode(obj.get("mode", "default"), obj.get("writable"))
        elif t == "text":
            txt = str(obj.get("text", ""))
            if "```" in txt:
                self._render_reply(txt)          # コード入り = 一気に着色描画
            else:
                self._stream_append(txt, "ai")   # 地の文だけ = 流し込み
        elif t == "note":
            self._append(str(obj.get("text", "")), "dim")
        elif t == "error":
            self._append(str(obj.get("text", "")), "err")
        elif t == "tool":
            self._append(L("using_tool", name=obj.get("name", "")), "dim")
        elif t == "status":
            self.status_var.set(obj.get("text", "") or "")
        elif t == "model":
            self._set_model(obj.get("provider", ""), obj.get("model", ""))
            # 切替後の「← 使用中」を反映するため、メニュー項目を作り直す。
            self._fill_menu([{"id": k, "label": v} for k, v in
                             getattr(self, "_model_labels", {}).items()])
        elif t == "confirm":
            ok = messagebox.askyesno(
                L("confirm_title"),
                L("confirm_body", prompt=obj.get("prompt", "")))
            self._write({"t": "reply", "value": "y" if ok else "n"})
        elif t == "need_passphrase":
            self._ask_passphrase(obj.get("prompt", L("passphrase_default")),
                                 recover=bool(obj.get("recover")))
        elif t == "need_recovery":
            self._ask_recovery(obj.get("mode", "new"), obj.get("question", ""))
        elif t == "need_key":
            self._ask_provider_key(obj.get("provider", ""))
        elif t == "history_list":
            self._show_history_dialog(obj.get("items", []))
        elif t == "history_loaded":
            self._render_history(obj.get("entries", []))
        elif t == "turn_done":
            self._set_busy(False)
            self.status_var.set("")
        elif t == "cmd_out":
            self._cmd_echo(str(obj.get("text", "")))
        elif t == "cmd_done":
            rc = obj.get("code", 0)
            self._cmd_echo(L("turn_end", code=rc), "cerr" if rc else "csuccess")
            self.cmd_proc = None
            self._cmd_set_running(False)
        elif t == "bye":
            # バックエンドが終了。黙って入力欄を殺すだけだと「打てない」しか
            # 分からないので、stderr の最後の数行と直し方を画面に出す。
            self._set_busy(True)
            self._append(L("backend_exit_title"), "err")
            tail = [ln for ln in getattr(self, "_stderr_tail", []) if ln.strip()]
            for ln in tail[-8:]:
                self._append("  " + ln.strip(), "dim")
            self._append(L("backend_exit_hint"), "dim")
            self.status_var.set(L("bye_status"))

    # ---------- 小物 ----------
    def _set_model(self, provider, model):
        # 生のモデルID(例: gemini-3.5-flash-lite)は長すぎてヘッダーを
        # 圧迫し、「AIを切替」ボタンの文字が切れる原因になっていた。
        # models.txtの説明(_fill_menuでキャッシュ済み)の em-dash 前の
        # 短い人間向け名前(例: "Gemini Flash-Lite")があればそちらを使う。
        self._current_model_id = model
        label = getattr(self, "_model_labels", {}).get(model)
        if label:
            short = re.split(r"\s*[—-]\s", label, maxsplit=1)[0].strip()
        else:
            short = model or provider
        self.model_label_var.set(short)

    def _fill_menu(self, models):
        self.switch_menu.delete(0, tk.END)
        self._model_labels = {m.get("id"): m.get("label", "") for m in models}
        current = getattr(self, "_current_model_id", None)
        # 12件を一次元に並べると探せないので、ベンダーごとの子メニューに束ねる。
        # 選択時は番号ではなくモデルIDを送る（番号は並び順に依存して脆い）。
        self._provider_menus = {}
        order = []
        for m in models:
            p = m.get("provider", "") or "その他"
            if p not in self._provider_menus:
                lbl = p
                for name, info in getattr(self, "_providers", []):
                    if name == p:
                        lbl = provider_label(info) or p
                        break
                if getattr(self, "_has_key", {}).get(p) is False:
                    lbl += L("menu_no_key")
                sub = tk.Menu(self.switch_menu, tearoff=0)
                self.switch_menu.add_cascade(label=lbl, menu=sub)
                self._provider_menus[p] = sub
                order.append(p)
            sub = self._provider_menus[p]
            label = m.get("label", m.get("id", "?"))
            if m.get("id") == current:
                label += L("currently_using")
            sub.add_command(
                label=label,
                command=lambda mid=m.get("id"): self._write(
                    {"t": "user", "text": "/model " + mid}),
            )

    def _open_remote_dialog(self):
        """远程接入（企微长连接）配置面板。

        三条纪律（跟密钥面板一致）：
          · 写的就是命令行那同一个文件，不另开一份配置
          · 状态只显示文件与 audit.log 里的真实内容，不自己造
          · Secret 用掩码输入，已保存时留空表示不修改，绝不把旧值填回控件
        """
        st = remote_status()
        conf = read_kv_conf(WECOM_WS_CONF_PATH)
        dlg = tk.Toplevel(self.root)
        dlg.title(L("remote_title"))
        dlg.transient(self.root)
        dlg.grab_set()
        tk.Label(dlg, text=L("remote_intro"), justify=tk.LEFT,
                 wraplength=470).pack(padx=16, pady=(14, 10))

        form = tk.Frame(dlg)
        form.pack(padx=16, fill=tk.X)
        form.columnconfigure(1, weight=1)

        tk.Label(form, text=L("remote_botid")).grid(row=0, column=0, sticky="w", pady=3)
        bot_var = tk.StringVar(value=conf.get("BOT_ID", ""))
        tk.Entry(form, textvariable=bot_var, width=40).grid(
            row=0, column=1, sticky="we", padx=(8, 0), pady=3)

        secret_label = L("remote_secret")
        if st["configured"]:
            secret_label += L("remote_secret_kept")
        tk.Label(form, text=secret_label).grid(row=1, column=0, sticky="w", pady=3)
        sec_var = tk.StringVar()
        sec_ent = tk.Entry(form, textvariable=sec_var, width=40, show="*")
        sec_ent.grid(row=1, column=1, sticky="we", padx=(8, 0), pady=3)

        tk.Label(form, text=L("remote_allow")).grid(row=2, column=0, sticky="w", pady=3)
        allow_var = tk.StringVar(value=st["allow"])
        tk.Entry(form, textvariable=allow_var, width=40).grid(
            row=2, column=1, sticky="we", padx=(8, 0), pady=3)
        tk.Label(dlg, text=L("remote_allow_hint"), justify=tk.LEFT,
                 wraplength=470).pack(padx=16, pady=(2, 6))

        # 远程权限：本机定，手机端改不了（写 conf，重启远程服务后生效）
        tk.Label(form, text=L("remote_mode")).grid(row=3, column=0, sticky="w", pady=3)
        mode_map = [
            ("default", L("remote_readonly_label")),
            ("accept-edits", L("remote_accept_label")),
            ("bypass", L("remote_bypass_label")),
        ]
        cur_mode = (conf.get("REMOTE_MODE") or "default").strip()
        mode_labels = [lab for _, lab in mode_map]
        mode_var = tk.StringVar(
            value=dict(mode_map).get(cur_mode, L("remote_readonly_label")))
        mode_box = ttk.Combobox(form, textvariable=mode_var, values=mode_labels,
                                state="readonly", width=34)
        mode_box.grid(row=3, column=1, sticky="we", padx=(8, 0), pady=3)

        tk.Label(form, text=L("remote_write_roots")).grid(row=4, column=0, sticky="w", pady=3)
        roots_var = tk.StringVar(value=conf.get("REMOTE_ALLOW_WRITE", ""))
        tk.Entry(form, textvariable=roots_var, width=40).grid(
            row=4, column=1, sticky="we", padx=(8, 0), pady=3)
        for hint in ("remote_mode_hint", "remote_write_roots_hint"):
            tk.Label(dlg, text=L(hint), justify=tk.LEFT,
                     wraplength=470, fg="#555555").pack(padx=16, pady=(0, 4))

        status_var = tk.StringVar()
        status_lbl = tk.Label(dlg, textvariable=status_var, anchor="w", justify=tk.LEFT,
                              wraplength=470)

        def refresh_status():
            cur = remote_status()
            if not cur["configured"]:
                status_var.set(L("remote_status_none"))
            elif cur["last_activity"]:
                status_var.set(L("remote_status_ready", when=cur["last_activity"]))
            else:
                status_var.set(L("remote_status_never"))
            status_lbl.pack(padx=16, anchor="w")

        refresh_status()

        res_var = tk.StringVar()
        res_lbl = tk.Label(dlg, textvariable=res_var, justify=tk.LEFT, wraplength=470)

        btns = tk.Frame(dlg)
        btns.pack(pady=(8, 6))

        def do_save():
            bot = bot_var.get().strip()
            sec = sec_var.get().strip()
            cur = read_kv_conf(WECOM_WS_CONF_PATH)
            if not bot:
                res_var.set(L("remote_need_botid")); res_lbl.pack(padx=16, anchor="w")
                return
            if not sec and not cur.get("BOT_SECRET"):
                res_var.set(L("remote_need_secret")); res_lbl.pack(padx=16, anchor="w")
                return
            # 档位与可写目录：跟凭据写同一份文件，重启远程服务后生效
            sel_label = mode_var.get()
            sel_mode = "default"
            for key, lab in mode_map:
                if lab == sel_label:
                    sel_mode = key
            roots = ",".join([p.strip() for p in roots_var.get().split(",") if p.strip()])
            if roots and sel_mode == "default":
                # 只读档配可写目录是自相矛盾的，别存进去让它在暗处失效
                res_var.set(L("remote_need_mode")); res_lbl.pack(padx=16, anchor="w")
                return
            upd = {"BOT_ID": bot,
                   "REMOTE_MODE": sel_mode,
                   "REMOTE_ALLOW_WRITE": roots}
            if sec:
                upd["BOT_SECRET"] = sec
            if not cur.get("WS_URL"):
                upd["WS_URL"] = "wss://openws.work.weixin.qq.com"
            try:
                write_kv_conf_atomic(WECOM_WS_CONF_PATH, upd)
                allow = allow_var.get().strip()
                if allow:
                    write_kv_conf_atomic(REMOTE_CONF_PATH, {"ALLOW": allow})
            except Exception as e:      # 写失败必须说出来，不许静默
                res_var.set("保存失败：%s" % e); res_lbl.pack(padx=16, anchor="w")
                return
            sec_var.set("")             # 保存后清空，旧值不回填
            res_var.set(L("remote_saved", path=WECOM_WS_CONF_PATH))
            res_lbl.pack(padx=16, anchor="w")
            refresh_status()

        def do_test():
            script = find_wecom_ws_script()
            if not script:
                res_var.set(L("remote_no_script")); res_lbl.pack(padx=16, anchor="w")
                return
            res_var.set(L("remote_testing")); res_lbl.pack(padx=16, anchor="w")
            test_btn.configure(state=tk.DISABLED)
            # ★ 子线程只管算，绝不在子线程里碰 Tk：
            #   从别的线程调 after()/改控件在 Tk 里是不安全的（实测会静默不执行，
            #   表现成「一直停在 正在检查连接…」）。用队列 + 主线程轮询。
            box = queue.Queue()

            def work():
                box.put(run_wecom_check(script))

            def poll():
                try:
                    ok, out = box.get_nowait()
                except queue.Empty:
                    self.root.after(150, poll)
                    return
                res_var.set(("OK " if ok else "NG ") + out)
                res_lbl.pack(padx=16, anchor="w")
                try:
                    test_btn.configure(state=tk.NORMAL)
                except Exception:
                    pass

            threading.Thread(target=work, daemon=True).start()
            self.root.after(150, poll)

        test_btn = tk.Button(btns, text=L("remote_test"), command=do_test)
        tk.Button(btns, text=L("remote_save"), command=do_save).pack(side=tk.LEFT, padx=4)
        test_btn.pack(side=tk.LEFT, padx=4)
        tk.Button(btns, text=L("remote_close"), command=dlg.destroy).pack(side=tk.LEFT, padx=4)
        tk.Label(dlg, text=L("remote_ok_hint"), justify=tk.LEFT,
                 wraplength=470).pack(padx=16, pady=(0, 12))
        dlg.protocol("WM_DELETE_WINDOW", dlg.destroy)

    def _ask_passphrase(self, prompt, recover=False):
        # 確認欄はなし(1回だけ)。打ち間違い対策は「合言葉」で担保する。
        dlg = tk.Toplevel(self.root)
        dlg.title(L("passphrase_title"))
        dlg.transient(self.root)
        dlg.grab_set()
        tk.Label(dlg, text=prompt).pack(padx=16, pady=(14, 4))
        var = tk.StringVar()
        ent = tk.Entry(dlg, show="*", textvariable=var, width=32)
        ent.pack(padx=16, pady=6)
        ent.focus_set()

        def done(_=None):
            self._write({"t": "passphrase", "value": var.get()})
            dlg.destroy()

        ent.bind("<Return>", done)
        btns = tk.Frame(dlg)
        btns.pack(pady=(4, 14))
        tk.Button(btns, text=L("ok"), command=done).pack(side=tk.LEFT, padx=4)
        if recover:
            def use_recovery():
                self._write({"t": "passphrase", "recover": 1})
                dlg.destroy()
            tk.Button(btns, text=L("recover_with_answer"), command=use_recovery).pack(side=tk.LEFT, padx=4)
        dlg.protocol("WM_DELETE_WINDOW",
                     lambda: (self._write({"t": "passphrase", "value": ""}), dlg.destroy()))

    def _ask_recovery(self, mode, question):
        # 合言葉(秘密の質問)。mode="new"=初回設定(質問+答え)、
        # mode="unlock"=復旧(答えだけ)。答えは大文字小文字・前後空白を区別しない。
        dlg = tk.Toplevel(self.root)
        dlg.title(L("secret_title"))
        dlg.transient(self.root)
        dlg.grab_set()
        q_var = tk.StringVar(value=question)
        a_var = tk.StringVar()

        if mode == "new":
            tk.Label(dlg, justify=tk.LEFT,
                     text=L("secret_new_body")).pack(padx=16, pady=(14, 6))
            tk.Label(dlg, text=L("question_label")).pack(anchor="w", padx=16)
            q_ent = tk.Entry(dlg, textvariable=q_var, width=36)
            q_ent.pack(padx=16, pady=(0, 6))
            q_ent.focus_set()
        else:
            tk.Label(dlg, text=L("secret_unlock_body")).pack(padx=16, pady=(14, 6))
            tk.Label(dlg, text=L("question_prefix", q=(question or "?"))).pack(
                anchor="w", padx=16)

        tk.Label(dlg, text=L("answer_label")).pack(anchor="w", padx=16)
        a_ent = tk.Entry(dlg, textvariable=a_var, width=36)
        a_ent.pack(padx=16, pady=(0, 6))
        if mode != "new":
            a_ent.focus_set()

        def done(_=None):
            self._write({"t": "recovery",
                         "question": q_var.get(), "answer": a_var.get()})
            dlg.destroy()

        a_ent.bind("<Return>", done)
        tk.Button(dlg, text=L("ok"), command=done).pack(pady=(4, 14))
        dlg.protocol("WM_DELETE_WINDOW",
                     lambda: (self._write({"t": "recovery", "question": "", "answer": ""}),
                              dlg.destroy()))

    def _ask_provider_key(self, provider):
        # 会話中に、まだキーを登録していないAIへ切り替えようとしたときの
        # 案内ダイアログ。オンボーディング画面と同じ「大きなボタン→貼り付け
        # →疎通確認」の流れをモーダルダイアログにしたもの。
        display = "Gemini" if provider == "gemini" else "Anthropic (Claude)"
        url = ("https://aistudio.google.com/apikey" if provider == "gemini"
               else "https://console.anthropic.com/")

        dlg = tk.Toplevel(self.root)
        dlg.title(L("switch_key_title"))
        dlg.transient(self.root)
        dlg.grab_set()

        tk.Label(dlg, text=L("switch_key_intro", provider=display),
                 wraplength=380, justify=tk.LEFT).pack(padx=18, pady=(16, 12))

        link = tk.Label(dlg, text=L("onboard_open_key_page"), fg="#ffffff",
                         bg="#1a5fb4", cursor=_pointing_cursor(),
                         font=("Helvetica", 14, "bold"), padx=14, pady=8)
        link.pack(pady=(0, 16))
        link.bind("<Button-1>", lambda e: webbrowser.open(url))

        tk.Label(dlg, text=L("onboard_key_label")).pack(anchor="w", padx=18)
        key_var = tk.StringVar()
        ent = tk.Entry(dlg, textvariable=key_var, show="•", width=36)
        ent.pack(padx=18, pady=(2, 6))
        ent.focus_set()

        status = tk.Label(dlg, text="", fg="#a33", wraplength=380)
        status.pack(padx=18, pady=(2, 4))

        def cancel():
            self._write({"t": "key", "value": ""})
            dlg.destroy()

        def submit(_=None):
            key = key_var.get().strip()
            if not key:
                status.config(fg="#a33", text=L("onboard_err_empty"))
                return
            btn.config(state=tk.DISABLED)
            status.config(fg="#2b2b2b", text=L("onboard_checking"))
            threading.Thread(target=self._provider_key_validate_thread,
                              args=(provider, key, dlg, status, btn), daemon=True).start()

        ent.bind("<Return>", submit)
        btnf = tk.Frame(dlg)
        btnf.pack(pady=(2, 16))
        btn = tk.Button(btnf, text=L("onboard_start"), command=submit)
        btn.pack(side=tk.LEFT, padx=4)
        tk.Button(btnf, text=L("cancel"), command=cancel).pack(side=tk.LEFT, padx=4)
        dlg.protocol("WM_DELETE_WINDOW", cancel)

    def _provider_key_validate_thread(self, provider, key, dlg, status, btn):
        ok, code = validate_api_key(provider, key)
        self.root.after(0, lambda: self._provider_key_validate_done(
            ok, code, provider, key, dlg, status, btn))

    def _provider_key_validate_done(self, ok, code, provider, key, dlg, status, btn):
        if not ok:
            btn.config(state=tk.NORMAL)
            status.config(fg="#a33", text=L("onboard_err_api", code=code))
            return
        self._write({"t": "key", "value": key})
        dlg.destroy()

    # ---------- 続きから(過去の会話) ----------
    def _show_history_dialog(self, items):
        if not items:
            messagebox.showinfo(L("resume_title"), L("no_saved_history"))
            return
        dlg = tk.Toplevel(self.root)
        dlg.title(L("resume_title"))
        dlg.transient(self.root)
        dlg.geometry("560x360")
        tk.Label(dlg, text=L("resume_pick")).pack(padx=10, pady=(10, 2))
        lb = tk.Listbox(dlg, font=("", 12), activestyle="dotbox")
        lb.pack(fill=tk.BOTH, expand=True, padx=10, pady=4)
        for it in items:
            lb.insert(tk.END, "%s   %s" % (it.get("started", "?"), it.get("first", "")))
        lb.selection_set(0)
        lb.focus_set()

        def choose(_=None):
            sel = lb.curselection()
            if sel:
                idx = sel[0]
                # ノートらしく「○ページ目/全△ページ」を後で先頭に出すため覚えておく
                self._resume_page = (idx + 1, len(items))
                self._write({"t": "resume", "file": items[idx]["file"]})
            dlg.destroy()

        lb.bind("<Double-Button-1>", choose)
        lb.bind("<Return>", choose)
        btnf = tk.Frame(dlg)
        btnf.pack(fill=tk.X, padx=10, pady=(0, 10))
        tk.Button(btnf, text=L("open"), command=choose).pack(side=tk.RIGHT)
        tk.Button(btnf, text=L("cancel"), command=dlg.destroy).pack(side=tk.RIGHT, padx=(0, 6))

    def _render_history(self, entries):
        self.note.config(state=tk.NORMAL)
        self.note.delete("1.0", tk.END)
        self.note.config(state=tk.DISABLED)
        try:
            self.note.mark_unset("q_anchor")
        except Exception:
            pass
        page = getattr(self, "_resume_page", None)
        self._resume_page = None
        if page:
            self._append(L("resume_page", page=page[0], total=page[1]), "dim")
        for e in entries:
            role = e.get("role")
            txt = str(e.get("text", ""))
            if not txt.strip():
                continue
            if role == "you":
                self._append(txt, "you")
            elif role == "ai":
                if "```" in txt:
                    self._render_reply(txt)
                else:
                    self._append(txt, "ai")
            elif role == "tool":
                self._append("— " + txt + " —", "dim")
            # toolresult はうるさいので再表示しない
        self._append(L("resume_loaded"), "dim")
        self._show_pane("chat")
        self.note.see(tk.END)

    def _set_busy(self, busy):
        self.busy = busy
        self.write_zone.config(state=tk.DISABLED if busy else tk.NORMAL)
        if not busy:
            # 返信が終わったら入力欄へ戻す（毎回クリックさせない）
            self._focus_write_zone()

    def _write_show_marker(self):
        self.write_zone.delete("1.0", tk.END)
        self.write_zone.insert("1.0", WRITE_MARK)
        self._write_ph = True
        self._write_apply_ph_color()

    def _write_apply_ph_color(self):
        t = THEMES[self.theme_name]
        self.write_zone.config(fg=(t["dim"] if self._write_ph else t["input_fg"]))

    def _write_click_clear(self, _event=None):
        # クリックはIMEの変換に関係しないので、ここで消してしまって
        # 問題ない(<Key> で消すとIMEの変換を邪魔するので使わない)。
        if self._write_ph:
            self.write_zone.delete("1.0", tk.END)
            self._write_ph = False
            self._write_apply_ph_color()

    def _write_on_modified(self, _event=None):
        # <<Modified>> は自分の delete/insert(矢印の表示自体)でも飛んで
        # くるので、毎回まずフラグを下ろす(でないと二度と発火しなくなる)。
        self.write_zone.edit_modified(False)
        if not self._write_ph:
            return
        cur = self.write_zone.get("1.0", "end-1c")
        if cur == WRITE_MARK:
            return   # 矢印を表示しただけ(自分の変更)
        # 実際に何か入力された。「矢印+打った文字」のはずなのでそれを
        # 取り除く。
        if cur.startswith(WRITE_MARK):
            typed = cur[len(WRITE_MARK):]
        elif WRITE_MARK in cur:
            typed = cur.replace(WRITE_MARK, "")
        else:
            typed = cur
        if typed != cur:
            self.write_zone.delete("1.0", tk.END)
            if typed:
                self.write_zone.insert("1.0", typed)
        self._write_ph = False
        self._write_apply_ph_color()

    def _write_focus_out(self, _event=None):
        if not self.write_zone.get("1.0", "end-1c").strip():
            self._write_show_marker()

    def _on_return(self, event):
        if event.state & 0x0001:  # Shift+Enter は改行
            return
        self._send_current()
        return "break"

    def _send_current(self):
        if self.busy:
            return
        text = self.write_zone.get("1.0", tk.END).strip()
        # 矢印(WRITE_MARK)が本文の先頭に残ったまま送信されてしまう
        # 不具合があった(IMEの変換タイミングによっては_write_on_modified
        # の除去処理が効かないことがある)。_write_phの状態に関わらず、
        # 送信直前にここでも必ず取り除く(最後の砦)。
        mark = WRITE_MARK.strip()
        if text.startswith(mark):
            text = text[len(mark):].strip()
        if not text:
            return
        self._write_show_marker()            # 書き込み欄を矢印に戻す
        self._append(text, "you", anchor=True)
        self.note.yview("q_anchor")          # 送った自分の発言を画面の一番上へ
        self._set_busy(True)
        self.status_var.set(L("querying_status"))
        self._write({"t": "user", "text": text})

    def _on_close(self):
        try:
            self._write({"t": "quit"})
        except Exception:
            pass
        for p in (self.proc, self.cmd_proc):
            if p and p.poll() is None:
                try:
                    p.terminate()
                except Exception:
                    pass
        self.root.destroy()


def main():
    root = tk.Tk()
    AdvisorGUI(root)
    root.mainloop()


if __name__ == "__main__":
    main()
