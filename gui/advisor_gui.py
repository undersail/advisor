#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
advisor_gui.py  ―  advisor 的单窗口图形界面前端

在后台启动 `advisor gui`（即 perl claude-agent.pl --gui），用一行一条的 JSON
通信。输入区在笔记下方（系统输入法可直接使用，还能绕开 Terminal.app 的
双字节字符问题），提问与回答会交替追加到同一张笔记上
（没有带边框的输入框）。

界面有两种：
  - 笔记：像在米色纸上书写。对方的回复缩进两个字。
  - 黑客：黑底绿字。

依赖：仅需 Python 3.x + tkinter（标准库自带）。不需要外部库。
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
import time
import tkinter as tk
import webbrowser
from tkinter import font as tkfont
from tkinter import messagebox
from tkinter import simpledialog
from tkinter import ttk

# 正文左侧留白（px）。笔记本左侧有红色竖线（大学笔记本的页边线），
# 从它紧右边开始书写，因此取较小的值。
EDGE = 10

# ---------- 语言 ----------
# 下载用户七成来自海外，因此双语/多语支持成为必需。
# LANG 环境变量在双击启动 GUI 应用时可能为空
# （因为不经过登录 shell），不可靠。因此直接读取 macOS 自身的
# 语言设置。判定不出时，为照顾本项目的既有用户，
# 默认使用日语。按钮文字只用 _S/L() 切换，
# 布局（padx 等）本身未改动，若某语言更长/更短，
# 可能还要单独调整头部留白。
def _detect_lang():
    # 若设置了 CLAUDE_LANG=en/ja/zh 则最优先（用于在不改系统语言的情况下
    # 检查显示语言）。zh-Hans / zh_CN 这类写法也按 zh 处理。
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
            # 把 zh-Hans / zh-Hant / zh_CN / zh_TW 统一当作中文。
            # 用简体显示繁体内容会有问题，但优先保证「能用中文阅读」。
            return "zh"
        if out:
            return "en"
    except Exception:
        pass
    # 判定不出的环境（非 macOS 等）默认用中文。
    return "zh"


# 显示语言的回退顺序。未翻译的语言按此顺序回退（zh 未译 -> en -> ja）。
# 保证不会返回空字符串。
_LANG_FALLBACK = {
    "ja": ("ja", "en"),
    "en": ("en", "ja"),
    "zh": ("zh", "en", "ja"),
}


LANG = _detect_lang()

# key: {ja, en, zh}。格式化字符串用 L(key, **kwargs) 填充。
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
    "confirm_allow": {
        "ja": "許可する",
        "en": "Allow",
        "zh": "同意执行",
    },
    "confirm_deny": {
        "ja": "拒否する",
        "en": "Deny",
        "zh": "拒绝",
    },
    "confirm_countdown": {
        "ja": "あと {sec} 秒で自動的に拒否します（Enter は拒否）",
        "en": "Auto-deny in {sec}s (Enter = deny)",
        "zh": "还有 {sec} 秒自动拒绝（回车 = 拒绝）",
    },
    "confirm_expired": {
        "ja": "（時間切れのため拒否しました。この操作は実行されていません）",
        "en": "(Timed out, so it was denied. Nothing was executed.)",
        "zh": "（已超时并拒绝，这次操作没有执行）",
    },
    "confirm_stale": {
        "ja": "（前の確認への遅れた返事を 1 件無視しました）",
        "en": "(Ignored a late reply to an earlier confirmation.)",
        "zh": "（忽略了一条上一道确认的迟到答复）",
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
    # macOS 菜单栏（屏幕最上方的系统菜单，与应用内头部不同）
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
    # 首次启动、尚未登记 API 密钥时显示的引导画面
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
    # 会话中试图切换到尚未登记密钥的 AI 时的提示
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
    # ---- 远程接入（企业微信 · 长连接）----
    "menu_tools": {"ja": "ツール", "en": "Tools", "zh": "工具"},
    "menu_session": {"ja": "セッション", "en": "Session", "zh": "会话"},
    "menu_session_continue": {
        "ja": "前回の続きから再開", "en": "Continue latest conversation",
        "zh": "接着上次的对话"},
    "menu_session_continue_named": {
        "ja": "名前を指定して再開…", "en": "Continue a named conversation…",
        "zh": "接着指定的对话…"},
    "menu_session_list": {
        "ja": "保存済みの一覧", "en": "List saved conversations",
        "zh": "列出现有对话"},
    "menu_session_name": {
        "ja": "この会話に名前を付ける…", "en": "Name this conversation…",
        "zh": "给本会话起名…"},
    "menu_session_search": {
        "ja": "保存済みを検索…", "en": "Search saved conversations…",
        "zh": "搜索历史…"},
    "session_continue_note": {
        "ja": "\n--- %s（前回の会話を読み込んで再開しました。上の表示は再現しません）---\n",
        "en": "\n--- %s (previous conversation loaded; earlier text is not replayed) ---\n",
        "zh": "\n--- %s（已载入上一场对话；上面的内容不会重放）---\n"},
    "session_continue_none_note": {
        "ja": "\n--- %s（続けられる会話が見つからず、新しい会話で始まります）---\n",
        "en": "\n--- %s (nothing to continue; starting a new conversation) ---\n",
        "zh": "\n--- %s（没有可接着的对话，这次是新会话）---\n"},
    "session_ask_name_title": {
        "ja": "この会話の名前", "en": "Name for this conversation",
        "zh": "给这场会话起个名字"},
    "session_ask_continue_title": {
        "ja": "続ける会話の名前（保存済みの一覧は「保存済みの一覧」で確認）",
        "en": "Name of the conversation to continue",
        "zh": "要接着哪一场（名字；可用「列出现有对话」查看）"},
    "session_ask_search_title": {
        "ja": "検索する語", "en": "Word to search",
        "zh": "要搜索的词"},
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
    "remote_svc_running": {
        "zh": "后台服务：运行中（pid %(pid)s，档位 %(mode)s）",
        "en": "Service: running (pid %(pid)s, mode %(mode)s)",
        "ja": "常駐サービス：稼働中（pid %(pid)s、モード %(mode)s）",
    },
    "remote_svc_stopped": {
        "zh": "后台服务：没有在跑（点「启动服务」就开始，或重启电脑后手动启动）",
        "en": "Service: not running (click \"Start service\", or start it again after a reboot)",
        "ja": "常駐サービス：停止中（「サービス開始」を押すか、再起動後に手動で起動してください）",
    },
    "remote_start": {
        "zh": "启动服务",
        "en": "Start service",
        "ja": "サービス開始",
    },
    "remote_stop": {
        "zh": "停止服务",
        "en": "Stop service",
        "ja": "サービス停止",
    },
    "remote_no_script_start": {
        "zh": "找不到 remote/wecom-ws.pl，无法启动（这台机器上没部署远程组件）",
        "en": "Cannot start: remote/wecom-ws.pl not found on this machine.",
        "ja": "起動できません：この環境に remote/wecom-ws.pl がありません。",
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
    "focus_click_hint": {
        "ja": "（この窓がキーボード入力を受け取れていません。入力欄を一度クリックしてください）",
        "en": "(This window is not receiving keyboard input. Click the input box once.)",
        "zh": "（窗口没拿到键盘输入：点一下输入框就能打字了）"},
    "remote_group_cred": {
        "ja": "接続情報", "en": "Connection", "zh": "接入凭据"},
    "remote_group_perm": {
        "ja": "権限（この Mac 側で決める）", "en": "Permissions (decided here)",
        "zh": "权限（在本机决定）"},
    "remote_group_svc": {
        "ja": "サービスと結果", "en": "Service and result", "zh": "服务与结果"},
    "remote_no_script_paths": {
        "ja": "wecom-ws.pl が見つかりません。次を探しました:\n%s\nsetup.sh を実行するか、"
              "リポジトリから起動してください。",
        "en": "wecom-ws.pl was not found. Looked in:\n%s\nRun setup.sh, or start from the repository.",
        "zh": "找不到 wecom-ws.pl。找过这些位置：\n%s\n请先跑一次 setup.sh，或从仓库目录启动。"},
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
    """取文案。

    条目有两种写法：
        (原字符串, English)                        … 旧格式（中文回退到英文）
        {"ja": ..., "en": ..., "zh": ...}          … 加入中文的格式
    未翻译的语言按 _LANG_FALLBACK 的顺序回退，不会返回空字符串。
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


# 书写区为空时显示的提示。点击后整段消失，可从开头
# 重新书写（_write_click_clear）。不用闪烁的竖线光标，
# 而是停止闪烁（insertofftime=0），用这个箭头标出书写起点。
WRITE_MARK = L("write_mark")

CFG_PATH = os.path.expanduser("~/.claude-agent/gui.json")

# ```lang ... ``` 代码块检测
FENCE_RE = re.compile(r"```[ \t]*([\w+.\-]*)[ \t]*\n(.*?)```", re.DOTALL)
# 粗略的通用高亮（针对 python/js/sh/json 等）。
# 排列顺序即优先级：字符串 → 注释 → 数值 → 关键字。
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

# 主题定义。布局所有模式通用（优先可读性）：
#   自己的发言 = 右对齐，块左侧留 1/3 空白
#   对方的回复 = 左对齐，块右侧留 1/3 空白
#   发言之间加浅色分隔线。只有颜色、字体、孔洞随模式变化。
#   prompt_prefix = 给自己的发言加彩色的「watermark> 」（终端风格）
#   handwriting   = 若有手写风字体就使用（依赖环境）
#   holes         = 左侧活页本的孔
THEMES = {
    "paper": {
        "label": "ノート", "label_en": "Note", "label_zh": "笔记", "handwriting": True, "holes": True,
        # 背景稍微调亮，文字（提问与回答）则再调深一些，使其更
        # 清晰（只调亮背景的话对比度会下降
        # 的缘故。实际对比度是上升的：fg 9.57→12.5,
        # ai 7.74→10.8)。
        "bg": "#faf4e6", "fg": "#1a2c54", "ai": "#463420",   # 青黑墨水 / 茶色
        "dim": "#9a8f78", "err": "#a5341f", "rule": "#d7b7ab", "code_bg": "#efe6cf",
        "line": "#c96b63",                                    # 旧式活页本的红色横线
        "hline": "#9fb0c9",     # 横线（深灰蓝）。用 PhotoImage 嵌入时
                                # 在本机绘制不出来，所以改成与已经
                                # 能画出的竖线（Canvas.create_line）相同的
                                # 实际部件（tk.Frame）方式
        "vline": "#c96b63",                                   # 左侧竖线（红）。书写起点标记
        "input_bg": "#f0e7d2", "input_fg": "#1a2c54",
        "hl": {"kw": "#7a3b8f", "str": "#8a5a2b", "com": "#9a8f78", "num": "#3a5a3a"},
        "font": ("Hiragino Maru Gothic ProN", 12),  # 稍小一点，以多显示几行
    },
    "coding": {
        "label": "コーディング", "label_en": "Code", "label_zh": "编程", "prompt_prefix": True,
        "bg": "#1e1e1e", "fg": "#d4d4d4", "ai": "#cfcfcf", "prompt": "#c586c0",
        "dim": "#7a7a7a", "err": "#f48771", "rule": "#3a3a3a", "code_bg": "#252526",
        "line": "#3a3a3a", "input_bg": "#252526", "input_fg": "#d4d4d4",
        "hl": {"kw": "#569cd6", "str": "#ce9178", "com": "#6a9955", "num": "#b5cea8"},
        "font": ("Menlo", 13),
    },
    "hacker": {
        "label": "ハッカー", "label_en": "Hacker", "label_zh": "黑客", "prompt_prefix": True,
        # 除错误/退出码（err）外全部用绿色。以前
        # prompt 和 hl.kw/num 是青色系，因此改为偏绿。
        "bg": "#000000", "fg": "#39ff5a", "ai": "#33dd88", "prompt": "#00ff66",
        "dim": "#2e7d4f", "err": "#ff5555", "rule": "#2e9d55", "code_bg": "#041004",
        "line": "#2e9d55", "input_bg": "#041004", "input_fg": "#39ff5a",
        "hl": {"kw": "#00ff66", "str": "#9dff9d", "com": "#2e7d4f", "num": "#a8ffcb"},
        "font": ("Menlo", 13),
    },
}


def pick_font(family, size):
    """若没有指定 family 则依次尝试替代字体。手写风字体存在就用它。"""
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
WECOM_WS_PID_PATH = os.path.expanduser("~/.claude-agent/wecom-ws.pid")
WECOM_WS_LOG_PATH = os.path.expanduser("~/.claude-agent/wecom-ws.log")


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


def remote_service_status():
    """远程服务是否在跑 —— 只读 wecom-ws.pl 自己写的 pid 文件，不猜、不另立状态。"""
    info = {"running": False, "pid": 0, "mode": "", "allow": "", "started": ""}
    try:
        if not os.path.exists(WECOM_WS_PID_PATH):
            return info
        with open(WECOM_WS_PID_PATH, encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if "=" not in line:
                    continue
                k, v = line.split("=", 1)
                if k == "pid":
                    info["pid"] = int(v) if v.isdigit() else 0
                elif k == "mode":
                    info["mode"] = v
                elif k == "allow_write":
                    info["allow"] = "" if v == "-" else v
                elif k == "started":
                    info["started"] = v
    except Exception:
        return info
    if info["pid"] <= 0:
        return info
    try:
        os.kill(info["pid"], 0)          # 只探活，不发送信号
        info["running"] = True
    except OSError:
        info["running"] = False          # 残留文件（上次被 SIGKILL）
    return info


def start_remote_service(script, mode="default", allow=""):
    """在后台起 wecom-ws.pl --serve。返回 (ok, 提示)。不把 Secret 放进 argv。"""
    args = ["perl", script, "--serve"]
    if mode and mode != "default":
        args.append("--mode=" + mode)
    if allow:
        args.append("--allow-write=" + allow)
    try:
        os.makedirs(os.path.dirname(WECOM_WS_LOG_PATH), exist_ok=True)
        logf = open(WECOM_WS_LOG_PATH, "ab")
        p = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=logf,
                             stderr=logf, start_new_session=True,
                             cwd=os.path.dirname(script), env=service_env())
        # 起来后等一小会儿：真起来会写出 pid 文件，被拒（已有实例）会立刻退出
        for _ in range(20):
            time.sleep(0.1)
            st = remote_service_status()
            if st["running"]:
                return True, "已启动：pid=%d 档位=%s" % (st["pid"], st["mode"] or mode)
            if p.poll() is not None:
                return False, "启动失败（退出码 %s），看日志：%s" % (p.returncode, WECOM_WS_LOG_PATH)
        return True, "已启动（pid 稍后写入）"
    except Exception as e:
        return False, "启动失败：%s" % e


def stop_remote_service(timeout=6.0):
    """停掉正在跑的远程服务：先 TERM（它会写 ws_stop 并清理 pid），再 KILL。"""
    st = remote_service_status()
    if not st["running"]:
        return False, "没有在跑的服务"
    pid = st["pid"]
    try:
        os.kill(pid, signal.SIGTERM)
    except OSError as e:
        return False, "发送 SIGTERM 失败：%s" % e
    deadline = time.time() + timeout
    while time.time() < deadline:
        time.sleep(0.2)
        if not remote_service_status()["running"]:
            return True, "已停止（pid=%d）" % pid
    try:
        os.kill(pid, signal.SIGKILL)
    except OSError:
        pass
    return True, "已强制停止（pid=%d，未响应 SIGTERM）" % pid


def wecom_ws_search_paths():
    """按优先级返回查找 wecom-ws.pl 的候选位置（找不到时输出**查过哪些位置**）。"""
    here = os.path.dirname(os.path.abspath(__file__))
    raw = [
        os.path.join(here, "..", "remote", "wecom-ws.pl"),           # 仓库内
        os.path.join(here, "remote", "wecom-ws.pl"),
        os.path.join(os.path.expanduser("~/claude-build"), "remote", "wecom-ws.pl"),
    ]
    rd = _bundled_resource_dir()
    if rd:
        raw.insert(0, os.path.join(rd, "remote", "wecom-ws.pl"))     # .app 同梱
        raw.insert(0, os.path.join(rd, "wecom-ws.pl"))
    out = []
    for c in raw:
        c = os.path.normpath(c)
        if c not in out:
            out.append(c)
    return out


def find_wecom_ws_script():
    """找 remote/wecom-ws.pl：仓库布局、构建目录、.app 同梱都试一遍，都找不到就返回 ''."""
    here = os.path.dirname(os.path.abspath(__file__))
    """找 remote/wecom-ws.pl：仓库布局与构建目录布局都试一遍，都找不到就返回 ''。"""
    here = os.path.dirname(os.path.abspath(__file__))
    for c in wecom_ws_search_paths():
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
    """macOS 用 pointinghand，其他平台（X11）用 hand2。

    写死的话 Linux 上的 Tk 会因 bad cursor spec 崩溃。
    macOS 的外观与行为保持不变（darwin 下仍为 pointinghand）。
    """
    return "pointinghand" if sys.platform == "darwin" else "hand2"


def _providers_path():
    """providers.txt 的位置。依次为 随包(Resources) → 仓库根目录 → ~/claude-build。"""
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
    """读取 providers.txt。

    返回值: [(name, {key_env, default_model, key_url, ja, en, zh}), ...]（按文件顺序）
    这里是唯一的来源。不要在 GUI 侧另写密钥名或 URL。
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
    """读取 models.txt: [{id, ja, en, zh, provider, base_url}, ...]"""
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
    # 把 ~/.claude-agent-env 里的 "export VAR=值" 形式解析成字典返回。
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
    # 任何厂商都按「该厂商自己的密钥是否存在」来判定。
    # 密钥名从 providers.txt 取（不要在这里写死 GEMINI/ANTHROPIC）。
    env = read_env_file()
    provider = env.get("CLAUDE_PROVIDER", "")
    if not provider:
        return False
    for name, info in read_providers():
        if name == provider:
            return bool(env.get(info["key_env"]))
    return False


def _bundled_resource_dir():
    # 用 setup.sh 构建时，claude-agent.pl / models.txt 已经和
    # advisor_gui.py 在同一目录（~/claude-build/）。
    # 若是双击即可运行的单体应用（py2app 标准构建），
    # 它们应随包放在应用的 Contents/Resources/ 下，因此去那里找。
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
    # 即使从未执行过 setup.sh（没有 ~/claude-build），也要能运行：
    # 把随包附带的 agent 主体放到 ~/claude-build 下再启动。
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


def service_env():
    """给**远程服务**用的环境：与 GUI 自己的后端、命令行包装脚本保持同一套。

    两处不一致踩过：命令行启动时 `~/bin/advisor` 会 export CLAUDE_CURL /
    CLAUDE_MODELS_FILE；GUI 起远程服务时原来什么都没传（只继承 GUI 进程的环境），
    于是同一个 agent 在两条起动路径上拿到的环境不一样 —— 手机端就表现为
    「本机会话没起来」。这里统一到同一份。
    """
    env = dict(os.environ)
    try:
        env.update(read_env_file())
    except Exception:
        pass
    env.setdefault("CLAUDE_CURL", "curl")
    env.setdefault("CLAUDE_MODELS_FILE", os.path.expanduser("~/claude-build/models.txt"))
    # 远程服务该用哪一个 agent：直接告诉它，别让它自己猜布局。
    # （仓库里是 <repo>/agent/claude-agent.pl，setup.sh 装的是 ~/claude-build/claude-agent.pl）
    for cand in (os.path.expanduser("~/claude-build/claude-agent.pl"),
                 os.path.join(os.path.dirname(os.path.abspath(__file__)),
                              "..", "agent", "claude-agent.pl")):
        if os.path.isfile(cand):
            env.setdefault("CLAUDE_AGENT", os.path.abspath(cand))
            break
    return env


def build_backend_command_and_env():
    # 若存在 ~/bin/advisor（setup.sh 生成的包装脚本）就用它。
    # 若不存在（未执行 setup.sh），直接启动随包附带的 agent。
    wrapper = os.path.expanduser("~/bin/advisor")
    if os.path.isfile(wrapper) and os.access(wrapper, os.X_OK):
        return [wrapper, "gui"], None
    if not ensure_backend_files():
        return None, None
    env = service_env()
    env["CLAUDE_MODELS_FILE"] = os.path.expanduser("~/claude-build/models.txt")
    agent = os.path.expanduser("~/claude-build/claude-agent.pl")
    return ["perl", agent, "--gui"], env


def validate_api_key(provider, api_key, base_url="", model=""):
    """当场验证密钥是否真的可用（不同厂商的调用方式不同）。

    gemini     : x-goog-api-key 请求头 + generateContent
    anthropic  : x-api-key + anthropic-version 请求头 + /v1/messages
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
    """只改写所选厂商的密钥。

    不删除其他厂商的密钥 —— 只因试了别的厂商就丢掉已登记的密钥，
    那是事故。既有行的顺序也保持不变。
    """
    info = {}
    for name, i in read_providers():
        if name == provider:
            info = i
            break
    keyvar = info.get("key_env", "")
    if not keyvar:
        raise RuntimeError("providers.txt 中没有 %s 的定义" % provider)
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
        self.root.geometry("560x800")          # A5 大学笔记本的比例（竖长）
        # Dock/窗口图标（尽量）。只用 tkinter 的话 Dock 里可能
        # 一直是 Python 的图标，但至少试一下。
        try:
            png = os.path.expanduser("~/claude-build/advisor.png")
            if os.path.isfile(png):
                self._icon_img = tk.PhotoImage(file=png)
                self.root.iconphoto(True, self._icon_img)
        except Exception:
            pass

        self.events = queue.Queue()
        self.proc = None
        # 启动后端时追加的参数（--continue 等）。会话的延续由
        # 「启动参数」决定，所以切换 ＝ 重启。
        self._extra_args = []
        self.busy = False
        self.pane = "chat"                      # "chat" / "cmd"
        self.cwd = os.path.expanduser("~")      # 命令面板的当前目录
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
        # 启动后立刻把焦点交给书写区。不交的话就会「窗口出来了
        # 但敲什么都不进去」（在真机上踩过）。
        self._focus_write_zone(force=True)
        self._activate_window()
        # macOS 上可能出现「窗口出来了但没成为前台应用」，
        # 只做一次 focus_force 进不去。只自我监视 5 秒，
        # 在焦点落到输入框之前反复重取（取不到就把原因显示到画面上）。
        self._focus_ok = False
        self.root.after(200, lambda: self._focus_watchdog(0))
        self._start_backend()
        self.root.bind("<FocusIn>", self._on_window_focus, add="+")
        # 即使焦点不在也能输入，所以在整个窗口上捕获按键
        self.root.bind("<Key>", self._on_root_key, add="+")
        self.root.after(80, self._pump)

    def _activate_window(self):
        """把窗口切到前台应用。macOS 上瞬间置顶最有效。"""
        try:
            self.root.deiconify()
            self.root.lift()
            self.root.attributes("-topmost", True)
            self.root.after(300, lambda: self.root.attributes("-topmost", False))
            self.root.focus_force()
        except Exception:
            pass

    def _focus_watchdog(self, tries):
        """启动后只监视 5 秒，看焦点是否到了输入框，没到就重取。

        Xvfb 这种「始终没有焦点」的环境里只放弃并显示原因，
        不无限重试（避免在测试或无头环境里失控）。
        """
        try:
            if self.root.focus_get() is self.write_zone:
                self._focus_ok = True
                return
            if tries >= 12:
                if not getattr(self, "_focus_ok", False):
                    self._focus_hint_shown = True
                    # 也显示到状态栏（即使注释读不到也能察觉）
                    try:
                        self.status_var.set(L("focus_click_hint"))
                    except Exception:
                        pass
                    try:
                        self._append(L("focus_click_hint"), "dim")
                    except Exception:
                        pass
                return
            if str(self.write_zone.cget("state")) not in ("disabled", "1"):
                self.root.focus_force()
                self.write_zone.focus_set()
            self.root.after(400, lambda: self._focus_watchdog(tries + 1))
        except Exception:
            pass

    def _on_root_key(self, event):
        """把焦点不在输入框时敲下的按键转给输入框（最后的防线）。

        即使窗口在前台，焦点不在任何地方时敲下的字符会被丢弃，
        就成了「输入不了」。只拾取可打印字符并插入输入框。
        """
        try:
            if event.widget is self.write_zone:
                return None
            if str(self.write_zone.cget("state")) in ("disabled", "1"):
                return None
            ch = getattr(event, "char", "") or ""
            if ch and ch.isprintable() and not (event.state & 0x4):
                self.write_zone.focus_set()
                self._focus_ok = True
                self.write_zone.insert(tk.INSERT, ch)
                return "break"
        except Exception:
            pass
        return None

    def _on_window_focus(self, _event=None):
        try:
            if self.root.focus_get() is None:
                self._focus_write_zone()
        except Exception:
            pass

    def _focus_write_zone(self, force=False):
        """把焦点交给输入框。

        force=True 用于启动直后。macOS 上即使窗口出来了，
        只调 focus_set() 也可能收不到键盘输入（真机上出现过
        「敲了也什么都没进去」），所以用 focus_force()
        让窗口本身夺取键盘焦点。
        等待回复之后的恢复用 force=False（不打扰其他应用）。
        """
        try:
            if str(self.write_zone.cget("state")) in ("disabled", "1"):
                return
            if force:
                try:
                    self.root.deiconify()
                    self.root.lift()
                    self.root.focus_force()
                except Exception:
                    pass
            self.write_zone.focus_set()
        except Exception:
            pass

    # ---------- 首次启动、未登记 API 密钥时显示的引导画面 ----------
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

        # 7 个厂商用单选按钮横排会溢出，所以改用一个下拉框。
        # 显示名从 providers.txt 取（不要在这里直写厂商名）。
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

        # 让非技术用户一眼看出「这是能按的按钮」，所以不用裸露的 URL，
        # 而是做成有色、较大的按钮式标签（小的下划线链接
        # 容易被看漏，收到过这样的反馈）。
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
        """返回下拉框中选中的厂商名及其定义。"""
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

    # ---------- macOS 菜单栏（屏幕最上方的系统菜单，与应用内的
    # 头部 [ 对话 ][ 命令 ] 等不是一回事） ----------
    def _build_menubar(self):
        menubar = tk.Menu(self.root)
        self.root.config(menu=menubar)

        # 最前面的应用菜单（About/隐藏/服务/退出）由 Tk 自己
        # 按 Bundle 名自动准备，但其内容文案是编译进 Tk 本体的
        # 固定英文，既不随 OS 语言设置变化，也不受这里的
        # 翻译影响（Tk 用 setAppleMenu: 这个旧 Cocoa API 自行
        # 注册）。即使自己加一个名为 "apple" 的菜单也不会
        # 被合并，只会多出一个空菜单，所以不建。本地化交给
        # _localize_native_app_menu() 直接改写 OS 原生菜单
        # 完成。这里只挂钩子，保证选择「退出」时能正确
        # 收尾（_on_close）。
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

        # 会话：继续已保存的对话／命名／搜索。
        # 这是不必手打 --continue 等参数的入口。
        session_menu = tk.Menu(menubar, tearoff=0)
        menubar.add_cascade(label=L("menu_session"), menu=session_menu)
        self.session_menu = session_menu   # 保留下来，方便测试内省其内容
        session_menu.add_command(label=L("menu_session_continue"),
                                 command=self._session_continue_last)
        session_menu.add_command(label=L("menu_session_continue_named"),
                                 command=self._session_continue_named)
        session_menu.add_command(label=L("menu_session_list"),
                                 command=lambda: self._session_cmd("/history"))
        session_menu.add_separator()
        session_menu.add_command(label=L("menu_session_name"),
                                 command=self._session_name)
        session_menu.add_command(label=L("menu_session_search"),
                                 command=self._session_search)

        # 工具：远程连接设置（与登记密钥一样，在 GUI 内完成）
        tools_menu = tk.Menu(menubar, tearoff=0)
        menubar.add_cascade(label=L("menu_tools"), menu=tools_menu)
        tools_menu.add_command(label=L("remote_menu"),
                               command=self._open_remote_dialog)

        # 若用 name="window"，Tk 会自动生成条目，但其内容
        # （Minimize/Zoom 等）是固定英文，无法翻译。所以自建条目。
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
        # Tk 自动生成的应用菜单（About/隐藏/服务/退出）
        # 内容是固定英文，无法通过 Tk 改写（见 _build_menubar 内的说明）。
        # 只有能用 pyobjc（仅在 py2app 构建时随包）时，
        # 才直接改写 OS 原生菜单来做本地化。没有的环境什么都不做，
        # 保持英文（不会坏掉）。
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

    # ---------- 界面 ----------
    def _build_ui(self):
        self.bar = tk.Frame(self.root)
        self.bar.pack(fill=tk.X)

        # 头部按钮若用 tk.Button/Menubutton，macOS 会自作主张
        # 画出自己的外观（带边框的部件），即使改 relief 或颜色也
        # 不生效。改用 tk.Label + 点击的组合，则由 Tk 自己
        # 绘制，可以做成任意外观（与对话标签页相同的手写风）。
        self.tab_chat = tk.Label(self.bar, text=L("tab_chat"), cursor=_pointing_cursor(), padx=3)
        self.tab_chat.bind("<Button-1>", lambda e: self._show_pane("chat"))
        # 左侧留白与红线的起点（padx=56）对齐（与右侧按钮组
        # 对齐的思路相同）。
        self.tab_chat.pack(side=tk.LEFT, padx=(56, 1), pady=2)
        self.tab_cmd = tk.Label(self.bar, text=L("tab_cmd"), cursor=_pointing_cursor(), padx=3)
        self.tab_cmd.bind("<Button-1>", lambda e: self._show_pane("cmd"))
        self.tab_cmd.pack(side=tk.LEFT, padx=1, pady=2)

        self.model_lbl = tk.Label(self.bar, textvariable=self.model_label_var)
        self.model_lbl.pack(side=tk.LEFT, padx=10, pady=6)

        # 外观、AI 切换、从上次继续这三项也同样用 tk.Label + 点击处理，
        self.theme_btn = tk.Label(self.bar, cursor=_pointing_cursor(), padx=8, pady=2)
        self.theme_menu = tk.Menu(self.theme_btn, tearoff=0)
        self.theme_btn.bind("<Button-1>", lambda e: self._popup_menu(self.theme_menu, self.theme_btn))
        self._theme_choice = tk.StringVar(value=self.theme_name)
        for key, spec in THEMES.items():
            self.theme_menu.add_radiobutton(
                label=theme_label(spec), value=key, variable=self._theme_choice,
                command=lambda k=key: self._choose_theme(k))
        # 右侧留白与红线的终点（padx=56）对齐。这里是最右边的
        # 按钮，所以右侧额外再加一点留白。
        self.theme_btn.pack(side=tk.RIGHT, padx=(6, 56), pady=3)

        # 不固定宽度，随文字长度（固定宽度会截断文字并与箭头重叠）
        self.switch_btn = tk.Label(self.bar, text=L("switch_btn"), cursor=_pointing_cursor(),
                                   padx=8, pady=2)
        self.switch_menu = tk.Menu(self.switch_btn, tearoff=0)
        self.switch_btn.bind("<Button-1>", lambda e: self._popup_menu(self.switch_menu, self.switch_btn))
        self.switch_btn.pack(side=tk.RIGHT, padx=6, pady=3)

        self.hist_btn = tk.Label(self.bar, text=L("hist_btn"), cursor=_pointing_cursor(),
                                 padx=8, pady=2)
        self.hist_btn.bind("<Button-1>", lambda e: self._write({"t": "list_history"}))
        self.hist_btn.pack(side=tk.RIGHT, padx=6, pady=3)

        # 交互模式切换。必须随时能看出当前是哪个模式，
        # 否则会被理解成「没确认就自己跑了」（悄悄改变行为最糟）。
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

        # 常设徽标（bypass 时改变颜色）。
        self.mode_badge = tk.Label(self.bar, text="", cursor=_pointing_cursor(), padx=6, pady=2)
        self.mode_badge.pack(side=tk.RIGHT, padx=(6, 0), pady=3)
        self._mode_key = "default"
        self._mode_writable = []

        # 头部下方的细线（通用）。
        self.hdr_rule = tk.Frame(self.root, height=1)
        self.hdr_rule.pack(side=tk.TOP, fill=tk.X, padx=56)

        # 对话面板与命令面板叠放在同一位置，切换用
        # tkraise 而不是 pack_forget/pack。pack_forget 似乎会把
        # 其中的分隔线与孔洞 Frame 一并全部解除映射，
        # 在旧 Mac 上切换要花好几秒（用 tkraise 只需交换叠放
        # 顺序即可）。
        self.pane_host = tk.Frame(self.root)
        self.pane_host.pack(side=tk.TOP, fill=tk.BOTH, expand=True)

        # ================= 对话面板 ================= 
        self.chat_pane = tk.Frame(self.pane_host)
        self.chat_pane.place(relx=0, rely=0, relwidth=1, relheight=1)

        # 状态栏。最下方，始终保证 2 行的高度
        # （用 pack_propagate(False) 让高度不随内容多少变化）。
        self.status_frame = tk.Frame(self.chat_pane)
        self.status_frame.pack(side=tk.BOTTOM, fill=tk.X)
        self.status_frame.pack_propagate(False)
        self.status_lbl = tk.Label(self.status_frame, textvariable=self.status_var,
                                   anchor=tk.NW, justify=tk.LEFT)
        # 左端与红线（与上面的 in_rule 相同的 padx=56）起点对齐。
        self.status_lbl.pack(fill=tk.BOTH, expand=True, padx=(56, 0))

        self.in_rule = tk.Frame(self.chat_pane, height=1)
        self.in_rule.pack(side=tk.BOTTOM, fill=tk.X, padx=56)

        # 书写区。不再是以前那种带边框的框 + 发送按钮，而是看起来像
        # 笔记延续的 4 行区域（分隔线与孔洞也与笔记正文相同）。
        # Enter 发送，Shift+Enter 换行。
        self.write_row = tk.Frame(self.chat_pane)
        # ★ 让输入区和对话区看起来是**两个不同的面**。
        #   以前与正文同背景，显得「连成一片」，但有人指出
        #   不知道在哪里输入，因此分隔开。
        self.write_row.pack(side=tk.BOTTOM, fill=tk.X)
        self.write_sep = tk.Frame(self.chat_pane, height=1)
        self.write_sep.pack(side=tk.BOTTOM, fill=tk.X)
        self.write_holes = tk.Canvas(self.write_row, width=36, highlightthickness=0)
        self.write_holes.pack(side=tk.LEFT, fill=tk.Y)
        self.write_holes.bind("<Configure>", lambda e: self._request_draw_holes())
        # 在靠右端（4 个字符处）折行用的留白。尺寸固定，所以要
        # 在 write_zone(expand=True) 之前 pack 以确保位置
        # （与 send_btn 同理。顺序颠倒的话就留不出空隙）。
        self.write_pad_right = tk.Frame(self.write_row, width=1)
        self.write_pad_right.pack(side=tk.RIGHT, fill=tk.Y)
        self.write_zone = tk.Text(self.write_row, height=4, wrap=tk.CHAR,
                                  relief=tk.FLAT, highlightthickness=0, bd=0,
                                  padx=18, pady=0)
        self.write_zone.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        self.write_zone.bind("<Return>", self._on_return)
        # 占位符（箭头）在 <<Modified>>（内容实际变化后的
        # 通知）时清除。若用 <Key> 清除会打断 IME 转换前的原始输入，
        # 过去曾有只有第一个字符按英文字母输入的故障。
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
        # 触控板的默认滚动会停在半个像素上，导致分隔线与
        # 文字在那一瞬间看起来错位。改成只以 1 行（=pitch）为
        # 单位停留。
        self.note.bind("<MouseWheel>", self._on_note_wheel)

        # ================= 命令面板 ================= 
        # 背景固定为黑底（终端风），与主题无关。文字色只由
        # _style_cmd_pane() 按主题调整（黑客主题用绿，
        # 其他用默认配色）。这里只把 CB 当初始值。
        self.CB = CB = "#0f1115"
        CF = CIN = CERR = CDIM = CSUCCESS = "#d6d6d6"  # 稍后由 _style_cmd_pane 覆盖
        self.cmd_pane = tk.Frame(self.pane_host, bg=CB)
        self.cmd_pane.place(relx=0, rely=0, relwidth=1, relheight=1)
        # 目录路径深了会变长，放在同一行会挤压输入框，
        # 所以路径显示单独占一行（上），输入框（下）始终
        # 能用满整个宽度。
        self.cmd_row = tk.Frame(self.cmd_pane, bg=CB)
        self.cmd_row.pack(side=tk.BOTTOM, fill=tk.X)
        self.cmd_prompt = tk.Label(self.cmd_pane, textvariable=self.cmd_prompt_var,
                                   anchor=tk.W, bg=CB, fg=CIN)
        self.cmd_prompt.pack(side=tk.BOTTOM, fill=tk.X, padx=(10, 8), pady=(0, 2))
        self.cmd_stop_btn = tk.Button(self.cmd_row, text=L("stop_btn"), width=5,
                                      state=tk.DISABLED, command=self._cmd_stop)
        self.cmd_stop_btn.pack(side=tk.RIGHT, padx=(2, 8), pady=6)
        # 带路径的长命令太挤、不好看，所以从 2 行改成 3 行
        # （这只是单条命令的显示区域，不是写多行脚本的地方，
        # 所以 Return 不是换行而是发送，Up/Down 不是移动光标
        # 而是照旧调用历史）。
        self.cmd_entry = tk.Text(self.cmd_row, height=3, wrap=tk.CHAR, relief=tk.FLAT,
                                 bg="#1a1d22", fg=CF, insertbackground=CF,
                                 highlightthickness=0, padx=4, pady=2)
        self.cmd_entry.pack(side=tk.LEFT, fill=tk.X, expand=True, padx=(8, 4), pady=6)
        self.cmd_entry.bind("<Return>", lambda e: (self._cmd_submit(), "break")[1])
        self.cmd_entry.bind("<Up>", self._cmd_hist_prev)
        self.cmd_entry.bind("<Down>", self._cmd_hist_next)
        self.cmd_entry.bind("<Control-c>", lambda e: (self._cmd_stop(), "break")[1])
        self.cmd_hist = []          # 命令历史（仅本次会话）
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
        self.chat_pane.tkraise()   # 启动后先把对话面板放到前面

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
        """把头部所有按钮（对话/命令 标签页 + 外观/AI 切换/
        从上次继续）统一成同一风格。笔记模式用手写风＋下划线，
        编程/黑客不用边框，统一成「[ 项目 ]」这种朴素外观
        （以前那种按钮式边框，被指出只有笔记没有边框，显得不齐）。
        只把选中的标签页加粗。
        （全部是 tk.Label，所以用不了 activebackground 等 Button 专用选项）"""
        t = THEMES[self.theme_name]
        paper = self.theme_name == "paper"
        active = getattr(self, "pane", "chat")
        tabs = (("chat", self.tab_chat, L("tab_chat")), ("cmd", self.tab_cmd, L("tab_cmd")))
        utils = ((self.hist_btn, L("hist_btn")), (self.switch_btn, L("switch_btn")),
                 (self.mode_btn, L("mode_btn")),
                 (self.theme_btn, theme_label(t) + " ▾"))
        # 左右两端与红线对齐是为笔记（有竖线、横线）做的调整。
        # 编程/黑客是全黑且没有红线，[ ] 又占宽度，
        # 用同样的留白会挤到「从上次继续」完全被遮住。
        # 笔记的布局不动，只把其他模式的留白收紧。
        self.tab_chat.pack_configure(padx=(56 if paper else 4, 1))
        self.theme_btn.pack_configure(padx=(6, 56 if paper else 4))
        # 按钮之间的间隙、按钮自身的内边距，在编程/黑客下也
        # 收紧（字体也小一档）。笔记不改。
        gap = 6 if paper else 2
        self.model_lbl.pack_configure(padx=(10 if paper else 4))
        self.tab_cmd.pack_configure(padx=(1 if paper else gap))
        self.switch_btn.pack_configure(padx=gap)
        self.hist_btn.pack_configure(padx=gap)
        # 未选中标签页的颜色。dim 与背景的对比度太低
        # （按主题约 2.8〜4.2:1），会融进背景、难以与选中态区分，
        # 收到过这样的反馈。ai 在各主题里本来就对比度高
        # （7.7〜11.8:1），与选中态（fg）的颜色也明显不同，所以改用它。
        off_color = t["ai"]

        def deco(label):
            return label if paper else "[ %s ]" % label

        for name, btn, label in tabs:
            on = (name == active) or (name == "chat" and active not in ("chat", "cmd"))
            if paper:
                f = self.font
                fs = max(9, f[1] - 1)   # 稍小一点以收窄宽度
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
                fs = max(10, f[1])   # 手写风字体小了会糊，所以保持正文字号
                btn.config(text=deco(label), relief=tk.FLAT, bd=0, highlightthickness=0,
                           font=(f[0], fs, "underline"), fg=t["dim"], bg=t["bg"])
            else:
                # 常用按钮所以用 fg 而不是 dim（理由与上面的 tabs 相同）。
                btn.config(text=deco(label), relief=tk.FLAT, bd=0, highlightthickness=0,
                           font=("Hiragino Sans", 10), fg=t["fg"], bg=t["bg"], padx=2)

    # ---------- 命令面板 ----------
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
        # 不禁用输入框（禁用后就收不到 Ctrl-C 和 ↑↓ 的按键
        # 输入）。重复执行由 _cmd_submit 里的守卫防止。
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
                self._write({"t": "cwd", "path": self.cwd})   # 也反映到 AI 的工具
            else:
                self._cmd_echo(L("no_such_folder", path=target), "cerr")
            return

        self._cmd_set_running(True)
        threading.Thread(target=self._cmd_run, args=(cmd,), daemon=True).start()

    def _cmd_run(self, cmd):
        try:
            # 在独立的进程组里启动。中止时能连同 shell 的
            # 子进程（ssh/scp 等）一起停掉。
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
            os.killpg(os.getpgid(p.pid), signal.SIGTERM)   # 整个进程组
        except Exception:
            try:
                p.terminate()
            except Exception:
                pass
        # 若还活着就稍等片刻再强制结束
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
            self.cmd_hist_idx = None            # 比最新更往下 = 清空
        else:
            self.cmd_entry.insert("1.0", self.cmd_hist[self.cmd_hist_idx])
        return "break"

    def _request_draw_holes(self):
        """_draw_holes 会重画所有孔洞（delete 后重建），所以
        标签页切换等导致 <Configure> 连续多次到来时，
        每次都会全部重建而变慢。用 after_idle 合并处理。"""
        if getattr(self, "_holes_pending", False):
            return
        self._holes_pending = True

        def go():
            self._holes_pending = False
            self._draw_holes()
        self.root.after_idle(go)

    def _draw_holes(self):
        # 在笔记正文左侧和书写区左侧都铺同样的孔洞
        # （让书写区看起来像活页本的延续）
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
        hole = t.get("code_bg", "#e9e0c8")   # 比纸面深一档的灰
        y = 36
        while y < h:
            # 孔洞本体（浅灰） + 左下用稍深的弧线做出阴影效果。
            # 更小、间距更密，以接近真正的活页本
            canvas.create_oval(12, y - 6, 24, y + 6, fill=hole, outline=t["dim"])
            canvas.create_arc(12, y - 6, 24, y + 6, start=120, extent=140,
                              style=tk.ARC, outline=t["dim"], width=2)
            y += 48
        # 大学笔记本的红色竖线。紧靠笔记正文左侧（这个 canvas 的右端）。
        vline = t.get("vline")
        if vline:
            canvas.create_line(35, 0, 35, h, fill=vline, width=1)

    def _request_draw_grid(self, widget, pool_attr):
        """调用 _draw_grid 的薄包装。无论调用多少次都不漏画，
        所以经由 after_idle 合并成一次调用。"""
        pending_attr = pool_attr + "_pending"
        if getattr(self, pending_attr, False):
            return
        setattr(self, pending_attr, True)

        def go():
            setattr(self, pending_attr, False)
            self._draw_grid(widget, pool_attr)
        self.root.after_idle(go)

    def _draw_grid(self, widget, pool_attr):
        """横线完全不看文字位置，从上到下按固定间距铺设
        （与左侧孔洞、垂直红线同一思路：完全不看内容，所以没有与内容
        错位的余地）。

        以前是逐个实测可见行、把线放在该行正下方
        的方式（_draw_rules）。标题、emoji、汉字多的行等
        实际文字高度会有细微差异，试了 3 天以上、换了多种公式
        也没能消除文字与线重叠／不足／错位的问题。
        孔洞和垂直红线一次都没坏过，是因为它们根本不看内容
        —— 意识到这一点后，横线也照此处理。只看部件的
        高度，按固定间距（pitch，在 _apply_theme 里计算）放线。
        滚动或插入时也不必重新测量，所以比以前
        更轻（滚动变钝的原因应该也是这个）。"""
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
        # 不是卡在行与行的交界处（pitch 边界），而是靠近文字（往前半个）
        # 把线往里收。pitch 本身在这里不变，所以已经对齐的状态
        # 不会崩。
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
            w.config(bg=t["bg"])                            # 头部也与正文同色
        # 编程/黑客主题里 dim 的字会沉进背景、难以辨认
        # （对比度约 3.9〜4.2:1，用 fg 则是 11〜15.6:1），
        # 所以笔记以外的主题头部用 fg。
        model_fg = t["dim"] if self.theme_name == "paper" else t["fg"]
        self.model_lbl.config(bg=t["bg"], fg=model_fg, font=(f[0], f[1] - 2))
        self.status_lbl.config(bg=t["bg"], fg=t["dim"], font=(f[0], 10))
        self._style_tabs()  # 外观/AI 切换/从上次继续 这三项也在这里一并设置
        self.cmd_out.config(font=code_f)
        self.cmd_entry.config(font=code_f)
        self.cmd_prompt.config(font=code_f)
        line = t.get("line", t["dim"])
        self.hdr_rule.config(bg=line)                       # 头部下方的线（红）
        self.in_rule.config(bg=line)                        # 书写区上方的线（红）
        self.note.config(bg=t["bg"], fg=t["fg"], font=f, insertbackground=t["fg"])

        # 不再实测线的位置去迁就文字。反过来，先把线的间距（pitch）
        # 固定下来，再让正文的行距（spacing）用计算
        # 精确对上这个 pitch。Tk 的字体指标（ascent/descent）
        # 是整数 px，GAP 也是整数，所以 pitch = ascent+descent+GAP 是
        # 不会出现小数的严格整数。把这个 GAP 原样传给
        # spacing2/spacing3，Tk 实际绘制的行高（包含标题、emoji，
        # 只要所有行字体字号一致）必定是 ascent+descent+GAP，
        # 理论上不可能与 pitch 错位（没有需要测量追赶的要素）。
        try:
            fm = tkfont.Font(font=f)
            ascent = fm.metrics("ascent")
            descent = fm.metrics("descent")
        except Exception:
            ascent, descent = int(f[1] * 0.9), int(f[1] * 0.25)
        S = max(6, int(round(f[1] * 0.5)))    # 行間(整数px)
        self.pitch = ascent + descent + S
        self._line_gap = S   # _draw_grid 把线往文字侧收时使用
        self.status_frame.config(height=self.pitch * 2)   # 状态栏始终占 2 行
        self.note.config(spacing1=0, spacing2=S, spacing3=S)

        # 书写区。与对话区换底色，上方加 1px 的分隔线
        # （同色时会有人说「不知道哪里是输入框」）。
        # 停掉闪烁光标（insertofftime=0），为空时显示箭头（WRITE_MARK）。
        write_fg = t["dim"] if getattr(self, "_write_ph", False) else t["input_fg"]
        write_font_size = min(f[1], 13)
        self.write_zone.config(bg=t["input_bg"], fg=write_fg, font=(f[0], write_font_size),
                               insertbackground=t["input_fg"], insertofftime=0,
                               spacing1=0, spacing2=S, spacing3=S)
        # 在靠右端 4 个字符处折行用的留白（按全角字符宽≈字号
        # 粗略估算）。
        self.write_pad_right.config(bg=t["input_bg"], width=write_font_size * 4)
        try:
            self.write_row.config(bg=t["input_bg"])
            self.write_holes.config(bg=t["input_bg"])
            self.write_sep.config(bg=t["rule"])
        except Exception:
            pass
        self._draw_holes()

        # 只管颜色、字体、对齐。左右留白（1/3）由 _relayout 按宽度计算。
        # 自己的发言放在「右侧 2/3 的块里」，但文字左对齐。
        # （右对齐时第二行以后会往右散开、难读，收到过这样的反馈）
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
        # 切换主题不会触发 <Configure>（窗口尺寸不变）
        # 所以颜色和 pitch 变化的线要在这里显式重画。
        self._request_draw_grid(self.note, "_grid_note")
        self._request_draw_grid(self.write_zone, "_grid_write")
        self._style_cmd_pane()

    def _style_cmd_pane(self):
        """命令面板的配色。黑客主题用绿色系（错误/退出码仍是
        红色），笔记主题用与正文相同的浅米色底、深蓝字，
        其他（编程）保持原来的终端风（黑底）。"""
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
        """宽度 1/3 作为左右留白。自己=左空 1/3 右对齐 / 对方=右空 1/3 左对齐。"""
        w = self.note.winfo_width()
        if w < 80:
            self.root.after(60, self._relayout)
            return
        third = int(w / 3)
        near = EDGE                      # 书写从红色竖线紧右边开始
        ch = max(1, self.font[1])        # 粗略按一个全角字符宽
        # 把提问块向左扩展 4 个字符 / 把回答块向右扩展 4 个字符
        you_left = max(near + 2 * ch, third - 4 * ch)
        ai_right = max(2 * ch, third - 4 * ch)
        self.note.tag_config("you", lmargin1=you_left, lmargin2=you_left, rmargin=near)
        for tag in ("ai", "dim", "err"):
            self.note.tag_config(tag, lmargin1=near, lmargin2=near, rmargin=ai_right)

        # 换主题后模式徽标的颜色也重画（取自主题配色）。
        if hasattr(self, "mode_badge"):
            self._apply_mode_colors()

    def _popup_menu(self, menu, widget):
        """给外观/AI 切换按钮用。在普通 Button 正下方弹出菜单
        （为了不用 Menubutton、让外观与其他按钮一致而做的替代）。"""
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
        """发言之间空一行。开头不加。
        像大学笔记本那样「隔一行写」。也不破坏行的垂直节奏。
        横线已统一成给所有行都铺的方式（_draw_rules），所以这里
        不再单独插入。"""
        if self.note.index("end-1c") != "1.0":
            self.note.insert(tk.END, "\n", "gap")

    def _append(self, text, tag, anchor=False):
        """一次写出一整块（自己的发言、通知、错误用）。"""
        self.note.config(state=tk.NORMAL)
        self._block_sep()
        start = self.note.index("end-1c")
        if tag == "you" and THEMES[self.theme_name].get("prompt_prefix"):
            self.note.insert(tk.END, "watermark> ", ("prompt", "you"))
        self.note.insert(tk.END, text.rstrip("\n") + "\n", tag)
        if anchor:
            # 自己发言的开头加标记。回复到来时把这里放到画面最上方，
            # 以避免「按下 Enter 的瞬间自己的文字就消失」的问题。
            self.note.mark_set("q_anchor", start)
            self.note.mark_gravity("q_anchor", "left")
        self.note.config(state=tk.DISABLED)

    def _stream_append(self, text, tag):
        """把 AI 的回复一点点流式写入（针对瞬间替换、来不及读的问题）。
        流式写入期间不让画面追随底端，而是把刚才自己的发言留在上方。"""
        self.note.config(state=tk.NORMAL)
        self._block_sep()
        self.note.config(state=tk.DISABLED)
        if self.note_has_anchor():
            self.note.yview("q_anchor")           # 把自己的提问放到画面最上方
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
        # 应对「回复被书写区挡住、看不出还有后续」的问题。
        # 提问刚结束时会用 q_anchor 从看得见提问的位置开始，回复变长后
        # 到达画面底端时，就追随正在写入的文字自然向下
        # 滚动（回复短时这里等于什么都不做＝保持可见范围）。
        self.note.see(tk.END)
        # 有人反馈 40ms 仍然太快，所以再放慢。
        self.root.after(70, lambda: self._stream_step(chars, tag))

    def note_has_anchor(self):
        try:
            self.note.index("q_anchor")
            return True
        except tk.TclError:
            return False

    def _on_note_wheel(self, event):
        """只以 1 行（显示上的 1 个单位 = _apply_theme 里对齐到 pitch 的）
        为单位停留。累积 event.delta，攒够 1 行就只调用一次
        yview_scroll(±1, "units")（默认的按 px 滚动由我们自己停掉，
        即不让 Tk 执行默认处理
        = return "break"）。THRESH 是边摸触控板手感边
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
        """把含 ```代码块``` 的回复分成正文和代码来绘制。
        代码用等宽字体、浅色背景 + 粗略语法着色。不做流式显示
        （语法中途未完成时着色会乱，所以一次性输出）。"""
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
        # 与流式显示（_stream_step）一样，滚动到能看见末尾的位置。
        # 只用 q_anchor 时回复较长会看不到后续。
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

    # ---------- 后端 ----------
    def _start_backend(self):
        cmd, env = build_backend_command_and_env()
        if cmd is not None and self._extra_args:
            cmd = list(cmd) + list(self._extra_args)
        if cmd is None:
            messagebox.showerror(L("cannot_start_title"),
                                  L("cannot_start_body", err="claude-agent.pl"))
            self.root.destroy()
            return
        try:
            self.proc = subprocess.Popen(
                cmd, env=env,
                stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                # 不要丢弃 stderr：后端立刻死掉时，GUI 侧唯一能
                # 显示「为什么死了」的手段就是这个（真机上只看到
                # 「输入不了」、完全查不出原因）。
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
        """只保留后端 stderr 的最后 20 行（不做常驻日志）。"""
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
        """同步模式的显示。颜色取自主题配色（不要写死）。"""
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
            fg = t["err"]          # 危险色。必须始终可见
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

    # ---------- 事件 ----------
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
            # _fill_menu 会看 self._current_model_id 来加「← 使用中」，
            # 所以要在调用 _set_model 之前先自己设好
            # （_set_model 本身仍要继续调用，用于后续更新简短显示）。
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
                self._render_reply(txt)          # 含代码 = 一次性着色绘制
            else:
                self._stream_append(txt, "ai")   # 只有正文 = 流式写入
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
            # 为了反映切换后的「← 使用中」，重建菜单项。
            self._fill_menu([{"id": k, "label": v} for k, v in
                             getattr(self, "_model_labels", {}).items()])
        elif t == "confirm":
            self._show_confirm(obj)
        elif t == "confirm_cancel":
            # 后端已经自己按超时/无人应答收尾 —— 把这道题的弹窗撤掉，
            # 不然留一个「同意」按钮在那儿，点下去会落到下一个操作上
            self._close_confirm(obj.get("cid"), expired=True)
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
            # 后端已退出。只默默把输入框废掉的话，用户只看到「打不了字」，
            # 所以把 stderr 的最后几行和处理办法显示到画面上。
            self._set_busy(True)
            self._append(L("backend_exit_title"), "err")
            tail = [ln for ln in getattr(self, "_stderr_tail", []) if ln.strip()]
            for ln in tail[-8:]:
                self._append("  " + ln.strip(), "dim")
            self._append(L("backend_exit_hint"), "dim")
            self.status_var.set(L("bye_status"))

    # ---------- 杂项 ----------
    def _set_model(self, provider, model):
        # 原始模型 ID（例: gemini-3.5-flash-lite）太长，会
        # 挤压头部，还导致「切换 AI」按钮的文字被截断。
        # 若 models.txt 的说明（已由 _fill_menu 缓存）里 em-dash 前面有
        # 简短的可读名字（例: "Gemini Flash-Lite"），就用它。
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
        # 12 个条目排成一维不好找，所以按厂商收进子菜单。
        # 选择时发送的不是序号而是模型 ID（序号依赖排列顺序，很脆弱）。
        self._provider_menus = {}
        order = []
        for m in models:
            p = m.get("provider", "") or "其他"
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
        # 外观与主体用相同的主题色、相同的字体（用默认字体的话
        # 只有这里的文字显得细/小，收到过这样的反馈）。
        # 在没有主题/字体的环境（测试用的假对象等）也回退到默认值，避免崩溃。
        th = THEMES.get(getattr(self, "theme_name", None) or "paper", THEMES["paper"])
        ui_font = getattr(self, "font", None)

        def _lab(parent, text="", **kw):
            if ui_font:
                kw.setdefault("font", ui_font)
            kw.setdefault("bg", th["bg"])
            kw.setdefault("fg", th["fg"])
            kw.setdefault("justify", tk.LEFT)
            return tk.Label(parent, text=text, **kw)

        def _entry(parent, var, show=None):
            _kw = {"font": ui_font} if ui_font else {}
            e = tk.Entry(parent, textvariable=var, width=42, **_kw,
                         bg=th["input_bg"], fg=th["input_fg"],
                         insertbackground=th["input_fg"], relief=tk.SOLID, bd=1)
            if show:
                e.configure(show=show)
            return e

        def _group(title_key):
            fr_kw = {"bg": th["bg"], "fg": th["fg"], "bd": 1,
                     "relief": tk.GROOVE, "labelanchor": "nw"}
            if ui_font:
                fr_kw["font"] = ui_font
            fr = tk.LabelFrame(dlg, text=L(title_key), **fr_kw)
            fr.pack(fill=tk.X, padx=18, pady=(0, 8))
            fr.columnconfigure(1, weight=1)
            return fr

        _lab(dlg, L("remote_intro"), wraplength=520).pack(padx=18, pady=(14, 10), anchor="w")

        # ---- 接入凭据 ----
        cred = _group("remote_group_cred")
        _lab(cred, L("remote_botid")).grid(row=0, column=0, sticky="w", padx=(10, 6), pady=4)
        bot_var = tk.StringVar(value=conf.get("BOT_ID", ""))
        _entry(cred, bot_var).grid(row=0, column=1, sticky="we", padx=(0, 10), pady=4)

        secret_label = L("remote_secret")
        if st["configured"]:
            secret_label += L("remote_secret_kept")
        _lab(cred, secret_label).grid(row=1, column=0, sticky="w", padx=(10, 6), pady=4)
        sec_var = tk.StringVar()
        sec_ent = _entry(cred, sec_var, show="*")
        sec_ent.grid(row=1, column=1, sticky="we", padx=(0, 10), pady=4)

        _lab(cred, L("remote_allow")).grid(row=2, column=0, sticky="w", padx=(10, 6), pady=4)
        allow_var = tk.StringVar(value=st["allow"])
        _entry(cred, allow_var).grid(row=2, column=1, sticky="we", padx=(0, 10), pady=4)
        _lab(cred, L("remote_allow_hint"), fg=th["dim"], wraplength=500).grid(
            row=3, column=0, columnspan=2, sticky="w", padx=10, pady=(0, 6))

        # ---- 权限：档位名称与本机完全一致（同一套 _S 条目，免得两处说法不同）----
        perm = _group("remote_group_perm")
        _lab(perm, L("remote_mode")).grid(row=0, column=0, sticky="w", padx=(10, 6), pady=4)
        mode_map = [
            ("default", L("mode_default")),
            ("accept-edits", L("mode_accept_edits")),
            ("bypass", L("mode_bypass")),
        ]
        cur_mode = (conf.get("REMOTE_MODE") or "default").strip()
        mode_labels = [lab for _, lab in mode_map]
        mode_var = tk.StringVar(
            value=dict(mode_map).get(cur_mode, L("mode_default")))
        mode_box = ttk.Combobox(perm, textvariable=mode_var, values=mode_labels,
                                state="readonly", width=38,
                                **({"font": ui_font} if ui_font else {}))
        mode_box.grid(row=0, column=1, sticky="we", padx=(0, 10), pady=4)

        _lab(perm, L("remote_write_roots")).grid(row=1, column=0, sticky="w",
                                                padx=(10, 6), pady=4)
        roots_var = tk.StringVar(value=conf.get("REMOTE_ALLOW_WRITE", ""))
        _entry(perm, roots_var).grid(row=1, column=1, sticky="we", padx=(0, 10), pady=4)
        hint_row = 2
        for hint in ("remote_mode_hint", "remote_write_roots_hint"):
            _lab(perm, L(hint), fg=th["dim"], wraplength=500).grid(
                row=hint_row, column=0, columnspan=2, sticky="w", padx=10, pady=(0, 4))
            hint_row += 1

        # ---- 服务与结果：结果固定在这一块，不再「点一次跳一次」----
        svc = _group("remote_group_svc")
        svc.columnconfigure(0, weight=1)
        status_var = tk.StringVar()
        status_lbl = _lab(svc, anchor="w", wraplength=500, textvariable=status_var)
        status_lbl.grid(row=0, column=0, columnspan=2, sticky="w", padx=10, pady=(4, 0))

        svc_var = tk.StringVar()
        svc_lbl = _lab(svc, anchor="w", wraplength=500, fg=th["ai"], textvariable=svc_var)
        svc_lbl.grid(row=1, column=0, columnspan=2, sticky="w", padx=10, pady=(2, 0))

        res_var = tk.StringVar()
        res_lbl = _lab(svc, anchor="w", wraplength=500, fg=th["err"], textvariable=res_var)
        res_lbl.grid(row=2, column=0, columnspan=2, sticky="w", padx=10, pady=(4, 8))

        def refresh_service():
            st = remote_service_status()
            if st["running"]:
                svc_var.set(L("remote_svc_running", pid=st["pid"],
                               mode=st["mode"] or "default"))
            else:
                svc_var.set(L("remote_svc_stopped"))
            try:
                start_btn.configure(state=tk.DISABLED if st["running"] else tk.NORMAL)
                stop_btn.configure(state=tk.NORMAL if st["running"] else tk.DISABLED)
            except Exception:
                pass

        def do_start():
            script = find_wecom_ws_script()
            if not script:
                res_var.set(L("remote_no_script_paths")
                            % "\n".join("  " + p for p in wecom_ws_search_paths()))
                return
            # 用面板里当前选的档位（已经保存过才算数：读文件里的真值）
            cur = read_kv_conf(WECOM_WS_CONF_PATH)
            ok, msg = start_remote_service(
                script, cur.get("REMOTE_MODE", "default") or "default",
                cur.get("REMOTE_ALLOW_WRITE", ""))
            res_var.set(msg)
            refresh_service()

        def do_stop():
            ok, msg = stop_remote_service()
            res_var.set(msg)
            refresh_service()

        def refresh_status():
            cur = remote_status()
            if not cur["configured"]:
                status_var.set(L("remote_status_none"))
            elif cur["last_activity"]:
                status_var.set(L("remote_status_ready", when=cur["last_activity"]))
            else:
                status_var.set(L("remote_status_never"))

        refresh_status()
        refresh_service()

        res_var = tk.StringVar()
        res_lbl = tk.Label(dlg, textvariable=res_var, justify=tk.LEFT, wraplength=470)

        btns = tk.Frame(dlg, bg=th["bg"])
        btns.pack(pady=(8, 6))

        def do_save():
            bot = bot_var.get().strip()
            sec = sec_var.get().strip()
            cur = read_kv_conf(WECOM_WS_CONF_PATH)
            if not bot:
                res_var.set(L("remote_need_botid"))
                return
            if not sec and not cur.get("BOT_SECRET"):
                res_var.set(L("remote_need_secret"))
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
                res_var.set(L("remote_need_mode"))
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
                res_var.set("保存失败：%s" % e)
                return
            sec_var.set("")             # 保存后清空，旧值不回填
            res_var.set(L("remote_saved", path=WECOM_WS_CONF_PATH))
            refresh_status()

        def do_test():
            script = find_wecom_ws_script()
            if not script:
                res_var.set(L("remote_no_script"))
                return
            res_var.set(L("remote_testing"))
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
                try:
                    test_btn.configure(state=tk.NORMAL)
                except Exception:
                    pass

            threading.Thread(target=work, daemon=True).start()
            self.root.after(150, poll)

        test_btn = tk.Button(btns, text=L("remote_test"), command=do_test)
        tk.Button(btns, text=L("remote_save"), command=do_save).pack(side=tk.LEFT, padx=4)
        start_btn = tk.Button(btns, text=L("remote_start"), command=do_start)
        start_btn.pack(side=tk.LEFT, padx=4)
        stop_btn = tk.Button(btns, text=L("remote_stop"), command=do_stop)
        stop_btn.pack(side=tk.LEFT, padx=4)
        test_btn.pack(side=tk.LEFT, padx=4)
        tk.Button(btns, text=L("remote_close"), command=dlg.destroy).pack(side=tk.LEFT, padx=4)
        _lab(dlg, L("remote_ok_hint"), fg=th["dim"], wraplength=520).pack(
            padx=18, pady=(0, 12), anchor="w")
        dlg.protocol("WM_DELETE_WINDOW", dlg.destroy)

    def _show_confirm(self, obj):
        """确认对话框：拒绝是默认按钮、带倒计时、可被 confirm_cancel 撤掉。

        不用 messagebox.askyesno 的两个原因：
          ① 它的默认按钮是「是」，回车就等于同意 —— 人没想清楚就按了回车；
          ② 它阻塞在这条事件处理里，后端超时收尾后也没法关掉它，
             留着的那一下「同意」会被下一个确认吃掉。
        """
        self._close_confirm(None, quiet=True)
        cid = str(obj.get("cid") or "")
        prompt = str(obj.get("prompt") or "")
        try:
            wait = int(obj.get("timeout") or 0)
        except (TypeError, ValueError):
            wait = 0
        dlg = tk.Toplevel(self.root)
        dlg.title(L("confirm_title"))
        dlg.transient(self.root)
        body = str(obj.get("prompt") or "")
        tk.Label(dlg, text=L("confirm_title"), font=(self.font[0], self.font[1] + 1, "bold"),
                 fg=self.c["fg"], bg=self.c["bg"]).pack(anchor="w", padx=14, pady=(12, 4))
        txt = tk.Text(dlg, height=min(12, max(3, body.count("\n") + 2)), width=64,
                      wrap="word", bg=self.c["input_bg"], fg=self.c["fg"],
                      relief="flat", highlightthickness=1,
                      highlightbackground=self.c["border"], font=self.font)
        txt.insert("1.0", L("confirm_body", prompt=prompt))
        txt.configure(state="disabled")
        txt.pack(padx=14, pady=(0, 8), fill="both", expand=True)
        tick_var = tk.StringVar(value="")
        if wait > 0:
            tk.Label(dlg, textvariable=tick_var, fg=self.c["dim"], bg=self.c["bg"],
                     font=self.font).pack(anchor="w", padx=14)
        btns = tk.Frame(dlg, bg=self.c["bg"])
        btns.pack(fill="x", padx=14, pady=(6, 12))

        def answer(val):
            self._write({"t": "reply", "cid": cid, "value": val})
            self._close_confirm(cid, quiet=True)

        deny = tk.Button(btns, text=L("confirm_deny"), command=lambda: answer("n"))
        deny.pack(side=tk.RIGHT, padx=(6, 0))
        tk.Button(btns, text=L("confirm_allow"), command=lambda: answer("y")).pack(side=tk.RIGHT)
        # 回车 = 拒绝（默认按钮），误按回车不会放行
        dlg.bind("<Return>", lambda e: (answer("n"), "break")[1])
        dlg.bind("<Escape>", lambda e: (answer("n"), "break")[1])
        dlg.protocol("WM_DELETE_WINDOW", lambda: answer("n"))
        deny.focus_set()
        self._confirm = {"cid": cid, "dlg": dlg, "timer": None, "left": wait}
        if wait > 0:
            self._confirm_tick()
        dlg.lift()

    def _confirm_tick(self):
        st = getattr(self, "_confirm", None)
        if not st or not st.get("dlg"):
            return
        left = st.get("left") or 0
        if left <= 0:
            # 自己先到点了：按拒绝回，并把弹窗撤掉（后端可能同时也作废了这道题）
            cid = st.get("cid") or ""
            self._write({"t": "reply", "cid": cid, "value": "n"})
            self._close_confirm(cid, expired=True)
            return
        try:
            if not st["dlg"].winfo_exists():
                return
        except Exception:
            return
        st["left"] = left - 1
        try:
            for child in st["dlg"].winfo_children():
                if isinstance(child, tk.Label) and child.cget("textvariable"):
                    child.configure(text=L("confirm_countdown", sec=left))
        except Exception:
            pass
        st["timer"] = self.root.after(1000, self._confirm_tick)

    def _close_confirm(self, cid, expired=False, quiet=False):
        st = getattr(self, "_confirm", None)
        if not st:
            return
        if cid is not None and str(cid) != str(st.get("cid") or ""):
            return                      # 不是这道题（迟到的作废通知），不理会
        try:
            if st.get("timer"):
                self.root.after_cancel(st["timer"])
        except Exception:
            pass
        try:
            if st.get("dlg"):
                st["dlg"].destroy()
        except Exception:
            pass
        self._confirm = None
        if expired and not quiet:
            self._append(L("confirm_expired"), "dim")

    def _ask_passphrase(self, prompt, recover=False):
        # 没有确认框（只做一次）。防打错由「口令」保证。
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
        # 口令（密保问题）。mode="new"=首次设置（问题+答案），
        # mode="unlock"=恢复（只要答案）。答案不区分大小写与前后空白。
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
        # 会话中试图切换到尚未登记密钥的 AI 时的
        # 提示对话框。把引导画面同样的「大按钮 → 粘贴
        # → 连通性检查」流程做成模态对话框。
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

    # ---------- 从上次继续（过去的对话） ----------
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
                # 为了像笔记那样稍后在开头显示「第 ○ 页/共 △ 页」而先记下
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
            # toolresult 太吵，不再显示
        self._append(L("resume_loaded"), "dim")
        self._show_pane("chat")
        self.note.see(tk.END)

    def _set_busy(self, busy):
        self.busy = busy
        self.write_zone.config(state=tk.DISABLED if busy else tk.NORMAL)
        if not busy:
            # 回复结束后把输入交回输入框（不必每次点击）
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
        # 点击与 IME 的转换无关，所以在这里清掉
        # 没有问题（用 <Key> 清会干扰 IME 的转换，所以不用）。
        if self._write_ph:
            self.write_zone.delete("1.0", tk.END)
            self._write_ph = False
            self._write_apply_ph_color()

    def _write_on_modified(self, _event=None):
        # <<Modified>> 在自身 delete/insert（箭头显示本身）时也会
        # 触发，所以每次都先把标志放下来（否则再也不会触发）。
        self.write_zone.edit_modified(False)
        if not self._write_ph:
            return
        cur = self.write_zone.get("1.0", "end-1c")
        if cur == WRITE_MARK:
            return   # 只是显示了箭头（自身改动）
        # 确实输入了什么。应该是「箭头+敲入的文字」，所以把它
        # 去掉。
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
        if event.state & 0x0001:  # Shift+Enter 换行
            return
        self._send_current()
        return "break"

    def _send_current(self):
        if self.busy:
            return
        text = self.write_zone.get("1.0", tk.END).strip()
        # 箭头（WRITE_MARK）留在正文开头就被发送出去的
        # 故障曾有发生（取决于 IME 的转换时机，_write_on_modified
        # 的去除处理有时不生效）。与 _write_ph 的状态无关，
        # 发送前在这里也一定要去掉（最后的防线）。
        mark = WRITE_MARK.strip()
        if text.startswith(mark):
            text = text[len(mark):].strip()
        if not text:
            return
        self._write_show_marker()            # 把书写区恢复成箭头
        self._append(text, "you", anchor=True)
        self.note.yview("q_anchor")          # 把自己发出的发言放到画面最上方
        self._set_busy(True)
        self.status_var.set(L("querying_status"))
        self._write({"t": "user", "text": text})

    # ---------- 会话（继续历史、命名、搜索） ----------
    def _session_cmd(self, text):
        """把 `/history` 等作为一个回合发送（本地完成的命令）。"""
        if not (self.proc and self.proc.poll() is None):
            return
        self._append(text, "you")
        self._set_busy(True)
        self.status_var.set(L("querying_status"))
        self._write({"t": "user", "text": text})

    def _session_name(self):
        nm = simpledialog.askstring(L("menu_session_name"),
                                    L("session_ask_name_title"), parent=self.root)
        if nm and nm.strip():
            self._session_cmd("/name " + nm.strip())

    def _session_search(self):
        w = simpledialog.askstring(L("menu_session_search"),
                                   L("session_ask_search_title"), parent=self.root)
        if w and w.strip():
            self._session_cmd("/search " + w.strip())

    def _session_continue_last(self):
        self._session_restart(["--continue"], L("session_continue_note"))

    def _session_continue_named(self):
        nm = simpledialog.askstring(L("menu_session_continue_named"),
                                    L("session_ask_continue_title"), parent=self.root)
        if nm is None:
            return
        nm = nm.strip()
        if not nm:
            return
        self._session_restart(["--continue=" + nm], L("session_continue_note"))

    def _session_restart(self, extra, note_fmt):
        """停止后端，用指定参数重新启动（＝切换对话）。"""
        label = extra[0].split("=", 1)[-1] if extra else ""
        try:
            self._write({"t": "quit"})
        except Exception:
            pass
        try:
            if self.proc and self.proc.poll() is None:
                self.proc.terminate()
                try:
                    self.proc.wait(timeout=5)
                except Exception:
                    self.proc.kill()
        except Exception:
            pass
        self._extra_args = list(extra)
        # 之前的显示原样保留（清掉的话会让人觉得「之前聊的都去哪了」）。
        self._append(note_fmt % label, "dim")
        self._start_backend()

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
