# 发布 PURE Neg 更新

正式版使用 Sparkle 自动检查。首次运行时检查一次，之后按上次检查时间每隔一小时检查。用户也可以从应用菜单立即检查，发现新版本后由用户确认安装。

从 [Sparkle 发布页](https://github.com/sparkle-project/Sparkle/releases) 下载并解压完整发行包。PURE Neg 需要 Sparkle 2.9.0 或更新的稳定 2.x 版本。先通过发行包内的 `bin/generate_keys --account easonzhangbin.PURENeg.production` 在 macOS 钥匙串中生成一次签名密钥。后续发行沿用同一密钥。应用只内嵌公钥。

```sh
export SPARKLE_DIR="/absolute/path/to/extracted/Sparkle"
export PURENEG_APPCAST_URL="https://github.com/easonzhangbin/PURENeg/releases/latest/download/appcast.xml"
export PURENEG_UPDATE_PUBLIC_KEY="$("$SPARKLE_DIR/bin/generate_keys" --account easonzhangbin.PURENeg.production -p)"
PACKAGE_RELEASE=1 bash scripts/build-macos.sh
```

每次正式发版都要递增 `CFBundleVersion`。构建同时生成用户下载包与仅含应用的 `-update.zip`。在独立的目录中签发更新，下面以 Apple 芯片版 0.4.7 为例。

```sh
update_stage="$(mktemp -d)"
cp dist/release-0.4.7/PURE-Neg-0.4.7-macos-arm64-update.zip "$update_stage/"
"$SPARKLE_DIR/bin/generate_appcast" \
  --account easonzhangbin.PURENeg.production \
  --download-url-prefix "https://github.com/easonzhangbin/PURENeg/releases/download/v0.4.7/" \
  --link "https://github.com/easonzhangbin/PURENeg" \
  --maximum-deltas 0 "$update_stage"
"$SPARKLE_DIR/bin/sign_update" --account easonzhangbin.PURENeg.production \
  --verify "$update_stage/appcast.xml"
```

把用户下载包、`-update.zip` 和签名后的 `appcast.xml` 一并上传到同一个 GitHub Release 草稿。核对 appcast 的版本号和安装包地址后，再发布并设为最新正式版。签名后的文件须原样上传。 在 README 的 `macos-installer` 链接和发布说明顶部链接本次的完整安装包。未集成 Sparkle 的既有版本需要先下载并安装一次。

本地测试可用 `APP_ONLY=1 PURENEG_UPDATE_TEST=1` 配合 `http://localhost:<端口>/appcast.xml` 和独立的测试签名密钥。正式构建只接受 HTTPS。
