# PURE Neg 维护规则

**重要提示：每次更新 PURE Neg 前，先核对上游 film-dust。**

1. 读取 `vendor/film-dust/UPSTREAM.json` 中的基准提交。在 [magholmes/film-dust](https://github.com/magholmes/film-dust) 核对最新正式发布的版本和对应提交，再查看默认分支的最新提交。以提交历史判断上游是否领先于基准。
2. 如果上游有新版本或新提交，先提醒用户并附上链接。明确哪些改动已正式发布，哪些只在默认分支。由用户决定是否升级内核。
3. 如果暂时无法连接 GitHub，说明本次未能核对。
