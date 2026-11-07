# PURE Neg

面向胶片扫描件的 macOS 除尘与修整工具。从一整卷里选出要处理的底片，检查自动标出的灰尘、划痕和纤维，再逐张修整和导出。

[下载 PURE Neg 0.4.6 Beta 1](https://github.com/easonzhangbin/PURENeg/releases/tag/v0.4.6-beta.1) · Apple 芯片 Mac，macOS 14 或更新版本。

## 界面与操作

### 观片台

![PURE Neg 观片台。候选区位于上方，带原始帧号的底片袋位于下方](docs/images/light-table.png)

导入多张 TIFF 或 JPEG 后，在灯板上点选底片。底片会从袋中移到上方候选区，再点一次可放回。候选区为空时，「下一步」会纳入整卷。右下角的电源按钮可点亮灯板，支持 HDR 的屏幕会提亮透光区域，接缝和印字附近用半透明遮光保留细节。

### 除尘审核

![PURE Neg 0.4.6 Beta 1 的除尘审核页。中央分割对比原图和修复后照片，右半显示红色修复蒙版](docs/images/review.png)

中央画布可切换「原图」「修复后」和「分割对比」，也能缩放检查。左栏用可调颜色和不透明度的蒙版标出修复位置。用画笔补修漏点，用橡皮擦恢复误修，也可从点位列表排除整处。右栏保留原始帧号，显示检测进度和审核状态。批量处理时，默认闲置 4 秒后检测其余照片，操作时暂停。

在 0.4.6 Beta 1 中，通过审核后可「导出当前」，或勾选多张照片后「导出所选」。支持按原始分辨率导出 TIFF、JPEG 或 PNG，并可另存修复蒙版。

## 视觉设计

![PURE Neg 启动画面。深色背景中并排显示应用图标和字标](docs/images/launch.png)

观片台取自实体灯板和半透明底片袋。袋口、帧号与抽出底片的动作让整卷照片的位置一眼可辨。审核页把照片留在中央，工具和批次信息分列两侧。

控制区域使用 macOS 原生玻璃材质，照片保持在独立画布。品牌以石墨灰和暗房黑为底，片基琥珀用于主要操作和选中状态，激光红提示检测进度。修复蒙版默认使用荧光红，可按照片内容调整。

等待预览时，中央保留当前照片的模糊背景，细尘成团卷过画面，近处偶尔掠过虚焦颗粒。预览就绪后，等待画面淡入清晰的修复结果。

## 安装与许可

从 [Releases](https://github.com/easonzhangbin/PURENeg/releases) 下载 macOS 内测 ZIP。解压后保留完整文件夹，双击「打开 PURE Neg.command」。内测包采用临时签名，首次打开时可按 macOS 的提示完成授权。

应用内的「帮助 → PURE Neg 使用指南」包含中英文操作说明。除尘引擎基于 Magnus Holmes 的 [film-dust](https://github.com/magholmes/film-dust)，完整第三方许可随应用提供。

除尘审核截图中的照片由 PURE Neg 作者拍摄。

观片台示例照片由 Jack Delano 拍摄，来自美国国会图书馆版画与摄影部 FSA/OWI 彩色摄影档案。 [铁路编组场](https://www.loc.gov/item/2017878015/) · [铁路站场](https://www.loc.gov/resource/fsac.1a34616/) · [机车车间](https://www.loc.gov/item/2017878063/) · [南水街货运站](https://www.loc.gov/item/2017878163/)
