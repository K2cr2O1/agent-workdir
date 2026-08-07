# fcitx5 主题与配置备份

备份时间：2026-08-07

## 当前状态

- **激活主题**：`OriDark`（用户主题，浅色模式）
- **深色备用**：`default-dark`（系统主题，浅色/深色切换时由 `UseDarkTheme` 控制）
- **fcitx5 配置目录**：`~/.config/fcitx5/conf/`
- **fcitx5 用户主题目录**：`~/.local/share/fcitx5/themes/`
- **fcitx5 系统主题目录**：`/usr/share/fcitx5/themes/`

## 目录结构

```
fcitx5-20260807/
├── conf/                      # 用户配置
│   ├── classicui.conf         # 主配置（主题、字体、行为）
│   ├── notifications.conf     # 通知设置
│   └── waylandim.conf         # Wayland 输入法集成
├── themes/
│   ├── OriDark/               # 当前激活主题
│   │   ├── theme.conf
│   │   ├── panel.svg
│   │   └── highlight.svg
│   ├── default/               # 系统默认浅色主题
│   └── default-dark/          # 系统默认深色主题
├── MANIFEST.sha256            # 文件校验
└── README.md                  # 本文件
```

## 还原方法

```bash
# 1. 恢复主题
cp -a themes/OriDark ~/.local/share/fcitx5/themes/

# 2. 恢复系统主题（可选，用于回退）
sudo cp -a themes/default /usr/share/fcitx5/themes/
sudo cp -a themes/default-dark /usr/share/fcitx5/themes/

# 3. 恢复配置
cp -a conf/* ~/.config/fcitx5/conf/

# 4. 重启 fcitx5
fcitx5 -r
```

## 校验

```bash
cd fcitx5-20260807
sha256sum -c MANIFEST.sha256
```

## 注意事项

- `cached_layouts`（运行时缓存，90K）已排除，每个系统会重新生成
- 系统主题来自发行版包，升级 fcitx5 后可能变更
- OriDark 主题上次本地修改：2024-07-15
