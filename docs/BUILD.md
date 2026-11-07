# PURE Neg 构建与技术参考

项目提供两个入口：

- **PhotoCraft 标准滤镜插件**：`dist/plugin/film-dust-local.wasm`，通过「滤镜 → 插件 → 安装插件…」载入。保守处理局部小灰点，支持宿主参数预览、撤销与智能滤镜。
- **PURE Neg 独立应用**：`PURE Neg.app`，支持单帧审核和全卷观片台。可分别检测灰尘、划痕和毛发，在大画布上滚动缩放、补修和恢复细节后再确认。

## 标准插件：安装及手工修正

1. 在 PhotoCraft 打开照片，先 `⌘J` 复制图层，保留原图在下方。
2. 「滤镜 → 插件 → 安装插件…」选择 `film-dust-local.wasm`。
3. 运行「滤镜 → 插件 → Film Dust Local」。`polarity=bright` 用于白色灰尘，`dark` 用于黑色灰尘；`maxSize` 为最大灰点直径，`sensitivity` 越大越激进。
4. 在参数窗口勾选「预览」，选 `mark` 看橙色标记。大图适屏预览会抽样，细小灰点可能看不到。先在主画布放大、框选一小块；必要时在「首选项 → 性能」关闭「低分辨率预览」。检查后取消滤镜预览；要修整张图，先清除选区，重新打开滤镜并在 `repair` 模式下确认。
5. 自动处理后，在修复图层上添加全白图层蒙版，保留下面的原图。

**错误擦掉拉链、纽扣或真实细节：** 点击修复层的蒙版缩略图，用黑色画笔涂抹该处，让下面的原图重新显示；白色画笔可重新显示自动修复。

**漏掉的灰尘：** 点击修复层的图像缩略图，选择污点修复画笔（J）补点。不要在蒙版上补灰尘。修复层保留整张图的像素，全白恢复蒙版不会把新增修补遮住。

插件版使用局部残差、噪声阈值、紧凑区域及真实邻近纹理匹配；**不包含完整 film-dust 的全图场景模型、长毛发检测或柔斑减雾**。这些功能保留在审核应用中。高位深 RGB／灰度支持 8/16 位；不支持 32 位 HDR 或 CMYK。

## 完整算法：先预览，再确认

打开审核应用，无需另行安装 Node.js。

各页面右上角都有「支持 PURE Neg」，也可在「帮助 → PURE Neg 使用指南」中打开同名页面。使用支付宝扫码时请核对收款方 StudioPURE，金额自行决定。

「PURE Neg → 设置」可选择默认导出格式、目录和蒙版，调整 CPU 调度与 Metal 预览，切换界面语言，清理旧审核缓存并保存诊断报告。16 GB 或更少的 Mac 默认开启节省内存。该模式缩小预览缓存，并对超过 6400 万像素的照片使用较小的工作图检测灰尘和纤维。细小痕迹的检测结果可能变化，修复和导出按原始分辨率进行。

### PhotoCraft 当前照片

1. 选择「PhotoCraft 当前照片」，点击「启动 / 连接 PhotoCraft」。
2. 在本工具启动的 PhotoCraft 窗口打开扫描件。普通方式启动的另一个 PhotoCraft 窗口不能直接接入其控制会话。
3. 选择结果目录、灰尘类型和灵敏度。「识别项目」里的「灰尘」「划痕」「毛发／纤维」默认全选，可以单独组合，至少选一项。设置在下一次检测时生效。
4. 右侧画布可切换「原图／修复／分割」。默认显示荧光红（`#FF254D`）修复蒙版，点击「颜色」可自定义并记住下次使用；也可关闭叠加或单独调透明度。用 100% 缩放检查细节，点位列表可定位或排除整处自动修复。
5. 漏点用「补修」（`B`）画在原位置，误修用「橡皮」（`E`）擦掉蒙版、恢复下面的原始像素。「撤销上一笔」或 `⌘Z` 撤销手动画笔；`V` 回到检查工具。每次修改在后台重新生成精确预览，更新完成后才能应用。
6. 点击「确认并导回 PhotoCraft」后，才发布最终结果并添加修复层。取消审核会保留原文档。
7. 导回层使用全白恢复蒙版，支持上文的黑笔恢复误修及 J 工具补漏。原始检测区域另外保存在 `dust-mask.tiff`，与恢复蒙版用途不同。

### Photoshop 当前文档

在 Photoshop 打开文档，在 PURE Neg 选择「从 Photoshop 载入」，再点「载入并预览」。首次使用时在 macOS 的提示中允许 PURE Neg 与 Photoshop 通信。支持 8/16 位 RGB 或灰度文档。PURE Neg 读取当前文档的可见合成，审核后可另存为 TIFF、JPEG 或 PNG，Photoshop 原文档保持原样。

### TIFF 或 JPEG 文件

一次选中多张照片后点击「打开观片台」。点底片将它移到顶部候选区，再点一次放回底片袋。点击「下一步」进入处理页。右侧只列出候选照片并保留原帧号，候选区为空时纳入全部照片。观片台和审核页默认铺满来源屏幕的可用区域。切换照片时，审核页保留同一个窗口。

点开照片会优先检测该张。检测中可直接点另一张切换，正在检测的照片会让出引擎。默认闲置 4 秒后逐张检测本批其余照片，继续操作时暂停。缩放或浏览结束后可从原进度继续。如果修整预览、导出或检测另一张照片需要引擎，闲置时可能重新检测被中断的照片。可在设置关闭「闲置时自动检测」，或点「停止检测」结束本批后台处理。点「检测本批」可手动重新启动。

每帧独立保留排除区域和画笔修整。检查修复结果后，可从左下角直接点「导出当前」，也可在右侧勾选多张预览就绪的照片后点「导出所选」。导出时统一选择目录和 TIFF、JPEG 或 PNG，默认关闭「附带修复蒙版」。导出后可继续用画笔和橡皮擦修整，再导出到独立的新结果文件夹。

选择一张照片时直接生成单帧预览，在审核窗口选择导出格式。可导入 8/16 位不透明 RGB 或灰度 TIFF，也可导入 8 位 RGB 或灰度 JPEG。JPEG 的拍摄方向会在导入时应用。导出时可指定保存位置，确认后为每张照片建立一个名为 `PURENeg-reviewed-…` 的文件夹：

- `cleaned.tiff`、`cleaned.png` 或 `cleaned.jpg` 保存完整分辨率修复图。TIFF 和 PNG 无损，保留源位深；JPEG 以 8 位、95% 质量保存。
- `dust-mask.tiff` 在勾选「附带修复蒙版」时保存，包含本次确认修复区域的 8 位参考蒙版。

准备和预览阶段只写本地工作缓存，不会覆盖原扫描件，不会提交 PhotoCraft 修改。审核时如果原文档被修改或切换，工具拒绝自动导回，已确认输出仍可手工使用。导回的短阶段请暂勿操作 PhotoCraft。

## 处理方式与限制

- 审核应用使用上游完整两遍检测、场景模型、柔斑减雾及纹理修补；大图在工作副本检测、原分辨率修补。
- 划痕检测会在原始分辨率上沿横纵方向连接细而连续的亮／暗痕迹，支持近直的小幅偏斜。毛发增强会沿已发现的窄纤维片段追踪弯曲、断续的尾部。非常淡的尾端、急转处及与实景纹理紧贴的部分仍可能需要手工补修。
- 所有最终合成都尊重审核蒙版，蒙版外像素保持输入数值。
- 本地处理，无需上传照片。新的审核缓存及私密控制凭证存放在 `~/Library/Application Support/PURENeg`。
- 没有 Photoshop 的额外主体选择保护，真实纹理仍需人工检查。
- TIFF 首版不处理透明图像、32 位浮点、CMYK/Lab、BigTIFF、多页或旋转方向标签；请先在编辑器转换。
- 高像素扫描占用较多内存。变更点位或画笔后会重组全尺寸预览，检测不会重跑；可以继续查看原图和调整画布。
- 工具不自动保存、关闭原文档。成功后可删除修复层撤回整次自动处理。

## 从源码运行

Node.js 22+，无 npm 运行时依赖：

```sh
node src/cli.cjs prepare --input scan.tiff --output results --polarity bright --detect dust,scratches,fibers
node src/cli.cjs doctor --launch
node src/cli.cjs prepare-photocraft --output results
node src/cli.cjs preview --review /absolute/path/review.json --edits edits.json
node src/cli.cjs confirm --review /absolute/path/review.json --edits edits.json --output results --mask no
node --test test/*.test.cjs
```

`edits.json` 示例：`{"excludedRegions":[1,4],"strokes":[{"kind":"add","radius":8,"points":[[310,620],[312,624]]}]}`。笔画从原图左上角起算，半径以原图像素计；`kind` 可为 `add` 或 `erase`。CLI 输出 JSON Lines；分析返回 `review`，确认返回 `result`。

在安装 Xcode Command Line Tools 的 Mac 上，可用以下命令构建桌面应用和正式版 ZIP。原生 C++ 内核通过 Node-API 提供加速。

```sh
bash vendor/film-dust/native/build.sh
PACKAGE_RELEASE=1 NODE_BINARY="$(command -v node)" bash scripts/build-macos.sh
```

构建脚本需要对应 Node.js 版本的完整许可。仓库附带 v24.22.1 的许可。使用其他版本时，可用 `NODE_LICENSE` 指定原始许可文件。

使用 Zig 0.15.2 构建 PhotoCraft 的 Wasm 插件。

```sh
ZIG=/path/to/zig bash plugin/build.sh
node --test test/*.test.cjs
```

macOS ZIP 包含应用、双击启动脚本、Node.js、引擎及权重，使用本地临时签名。

局部验收时，用 `APP_ONLY=1` 构建本地应用。该模式使用独立的设置标识并跳过 ZIP 归档。

## 许可

完整引擎基于 `magholmes/film-dust` 提交 `fcf68d6c6a77e4373db28f878c7f80f7b8934f3f`，项目加入按类别选择及原像素划痕／纤维增强。标准 Wasm 滤镜为独立的局部实现，算法设计参考该 MIT 项目。详见[第三方许可说明](../THIRD_PARTY_NOTICES.md)。

软件源码采用 [MIT 许可](../LICENSE)。Photoshop 载入使用 macOS 自动化通信。独立文件处理无需安装 Photoshop。与 PhotoCraft 或原 film-dust 作者没有官方合作或背书关系。
