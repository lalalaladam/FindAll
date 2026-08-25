# FindAll

[中文](#中文) | [English](#english)

## 中文

### 简介

FindAll 是一款原生 macOS 文件搜索工具，使用 Spotlight 元数据快速查找文件、文件夹和应用程序。应用采用 Swift 与 AppKit 构建，支持简体中文和英文界面。

### 主要功能

- 按名称搜索，支持“包含”“开头匹配”和“完全匹配”三种模式。
- 多关键词模式支持“全部”与“任一”匹配关系；按 Return 确认关键词，按 Command + Return 执行搜索。
- 路径模式提供可滚动的多行输入框，可查看和编辑全部内容，并隐藏不适用的名称筛选条件；兼容换行、带引号和 QSpace 单行空格分隔格式，按 Command + Return 直接检索对应的文件、文件夹和应用程序。
- 按文件夹、应用程序、视频、音频、图像、文档、PPT、Word、Excel、PDF 和压缩包筛选结果。
- 支持智能排序及按名称、路径、类型、大小和修改日期排序。
- 可设置文件夹优先级、文件夹置顶和自定义搜索范围。
- 以简洁且本地化的名称显示常见文件类型；文本被截断时可通过提示查看完整内容。
- 支持快速查看、打开、选择打开方式、在文件管理器中显示、复制文件、复制完整路径、共享和查看简介。
- 可从文件夹搜索结果打开独立的内容窗口；窗口按文件类型以固定标题分组显示第一层项目，文稿类紧随文件夹，常用扩展名优先且同类扩展名集中排列。也可关闭分组后按表头统一排序，并支持刷新、多选和直接拖到浏览器或其他应用。
- 打开多个所选项目时会先请求确认，避免意外同时打开大量窗口或应用。
- 支持自定义全局呼出快捷键和结果列表操作快捷键。
- 可配置窗口位置、窗口大小、置顶、跨空间显示、结果列布局及首选文件管理器。

### 系统要求

- Apple Silicon Mac（arm64）
- macOS 14 或更高版本
- Spotlight 已启用；可在系统设置中授予“完全磁盘访问权限”，以搜索更多位置

> 本项目仍在开发中，功能和兼容性可能继续调整。

---

## English

### Overview

FindAll is a native macOS file-search utility that uses Spotlight metadata to quickly find files, folders, and applications. It is built with Swift and AppKit and provides interfaces in Simplified Chinese and English.

### Features

- Search by name with Contains, Starts With, and Exact matching modes.
- Use multi-keyword search with All or Any matching; press Return to commit a keyword and Command-Return to search.
- Use the scrollable multiline path editor to review and edit complete input while inapplicable name filters stay hidden; newline-separated, quoted, and QSpace-style space-separated paths can be resolved with Command-Return.
- Filter results by folders, applications, videos, audio, images, documents, PPT, Word, Excel, PDF, and archives.
- Use smart ordering or sort by name, path, kind, size, and modification date.
- Configure folder priorities, folders-first ordering, and custom search scopes.
- Display common file kinds with concise, localized names; reveal complete text in a tooltip when a value is truncated.
- Quick Look, open, open with another application, show in a file manager, copy files, copy full paths, share, and get information.
- Open a folder result in a separate contents window; first-level items use fixed type-group headings, with documents directly after folders, common extensions first, and matching extensions kept together. Grouping can be turned off for whole-table column sorting; refresh, multiple selection, and direct dragging to browsers or other apps are also supported.
- Confirm before opening multiple selected items to avoid unintentionally opening many windows or applications.
- Customize the global show/hide shortcut and result-list action shortcuts.
- Configure window placement and size, always-on-top and all-Spaces behavior, result-column layout, and the preferred file manager.

### Requirements

- Apple Silicon Mac (arm64)
- macOS 14 or later
- Spotlight enabled; Full Disk Access can be granted in System Settings to search additional locations

> This project is under active development. Features and compatibility may change.
