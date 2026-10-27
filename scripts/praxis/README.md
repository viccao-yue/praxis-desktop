# scripts/praxis

`apps/desktop/scripts/prepare-workdsh-runtime.mjs` 在 Profile 安装完成后调用这里的脚本。

| 文件 | 作用 |
| --- | --- |
| `patch-account-menu.mjs` | 设置菜单：去掉联系我们/登录，未登录显示「设置」，点击打开设置 |
| `patch-signin-waiting.mjs` | 去掉「开始使用 / 等待登录」弹窗，首次引导跳过强制登录（个人区与企业区共用） |
| `patch-sidebar-icons.mjs` | 左侧栏插件、自动化任务图标 |
| `patch-skillhub-plaza.mjs` | 插件广场改成侧栏页面，并去掉重复的技能页 |
| `AccountMenu.tsx` | 设置菜单的参考实现，不参与打包 |
