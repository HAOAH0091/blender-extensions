# HAOAH's Blender Extensions

个人 Blender 扩展远程仓库。在 Blender 中添加此仓库后可直接安装和更新。

## 在 Blender 中添加

1. 编辑 → 偏好设置 → Get Extensions → 仓库 → + → 添加远程仓库
2. URL 填入：https://HAOAH0091.github.io/blender-extensions/packages/index.json
3. 点击确定，刷新后即可看到可用扩展

## 扩展列表

| 扩展 | 版本 | 说明 |
|------|------|------|
| AOV+ | 2.4.3 | AOV节点管理、输出文件名批处理与选择性渲染 |
| AutoSway | 1.2.0 | 骨骼链正弦波摆动动画 |
| Cache Collector | 1.0.0 | Alembic/USD 缓存文件自动打包 |
| Compify | 2.5.0 | 3D 空间合成 |
| MBB (Maya Blender Bridge) | 2.0.0 | Blender-Maya USD 桥接 |
| Parallax Locker | 1.0.0 | 相机屏幕空间物体锁定 |
| PSD Layer Importer PLUS | 3.3.0 | PSD 图层导入 |

## 更新扩展

每次发布新版本后，在此仓库中更新对应的 .zip 文件，然后重新生成索引：

`
blender --command extension server-generate --repo-dir=./packages
`

提交推送后，Blender 端即可检测到更新。
