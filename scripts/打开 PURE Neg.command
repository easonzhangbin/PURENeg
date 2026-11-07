#!/bin/zsh -f

fail() {
    print -ru2 -- "PURE Neg 无法启动：$1"
    print -ru2 -- "请重新解压下载的完整 PURE Neg ZIP，并从解压后的文件夹双击此启动助手。"
    if [[ -t 0 && -t 2 ]]; then
        read -r '?按回车关闭此窗口…' || true
    fi
    exit 1
}

script=${0:a}
[[ -f "$script" && ! -L "$script" ]] || fail "启动助手须为压缩包中的实际文件。"

directory=${script:h}
app="${directory:A}/PURE Neg.app"
plist="$app/Contents/Info.plist"
# This identifier is retained across versions for settings and macOS permissions.
bundle_id=local.filmdust.photocraft.review

[[ ! -L "$app" ]] || fail "同目录的 PURE Neg.app 是符号链接。"
[[ -d "$app" ]] || fail "同目录找不到 PURE Neg.app。"
[[ -f "$plist" && ! -L "$app/Contents" && ! -L "$plist" ]] || fail "应用包结构无效。"

identifier=$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$plist") || fail "无法读取应用标识。"
[[ "$identifier" == "$bundle_id" ]] || fail "应用标识与 PURE Neg 不符。"

/usr/bin/codesign --verify --deep --strict "$app" || fail "应用签名校验未通过。"
signature=$(LC_ALL=C /usr/bin/codesign --display --verbose=4 "$app" 2>&1) || fail "无法读取应用签名。"
print -r -- "$signature" | /usr/bin/grep -Fxq 'Signature=adhoc' || fail "应用签名与此安装包不符。"
print -r -- "$signature" | /usr/bin/grep -Fxq "Identifier=$bundle_id" || fail "签名中的应用标识与 PURE Neg 不符。"

# The ad-hoc signature checks bundle integrity. Use this helper with the official ZIP.
print -r -- "正在打开 PURE Neg。此版本使用临时签名，尚未经过 Apple 公证。"
attributes=$(/usr/bin/xattr -s "$app") || fail "无法读取应用的隔离状态。"
if print -r -- "$attributes" | /usr/bin/grep -Fxq 'com.apple.quarantine'; then
    /usr/bin/xattr -d -s com.apple.quarantine "$app" || fail "无法移除这个应用副本的隔离标记。"
fi

/usr/bin/open -n -a "$app" || fail "macOS 未能打开应用。若出现安全提示，可在「系统设置 → 隐私与安全性」查看「仍要打开」。"
