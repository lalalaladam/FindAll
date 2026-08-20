# FindAll

[中文](#中文) | [English](#english)

## 中文

### 简介

FindAll 是一款原生 macOS 文件搜索工具。它使用 macOS Spotlight 元数据索引快速
查找文件、文件夹和应用，并提供可自定义的结果操作快捷键、收藏文件夹和目录优先级。

FindAll 的目标不是成为应用启动器或建立另一套文件索引，而是为 Spotlight 搜索结果
提供更高效、可预测、键盘友好的文件操作界面。

### 计划功能

- 使用 Spotlight 索引实时搜索文件、文件夹和应用。
- 按文件名、路径、文件类型、大小和修改时间查看及筛选结果。
- 使用原生表格排序、调整列宽、重排列和隐藏列。
- 收藏常用文件夹，并限定搜索范围。
- 将指定文件夹中的结果设为普通、优先或置顶。
- 自定义打开、快速预览、在 Finder 中显示、复制文件和复制路径等快捷键。
- 复制文件名、完整 POSIX 路径、父文件夹路径或文件 URL。
- 使用 Quick Look 预览，并将结果拖放到 Finder 或其他应用。
- 支持多选及适用的批量文件操作。
- 将设置、收藏和排序偏好保存在本机。

### 第一阶段范围

第一阶段只使用公开的 macOS Spotlight 和文件系统 API，不建立自有文件索引，不安装
后台守护进程，也不索引文件内容。

第一阶段不包括：

- 文件内容全文搜索、OCR 或语义搜索。
- AI、自然语言命令、插件或工作流系统。
- 剪贴板历史、计算器、网页搜索或窗口管理。
- 云端同步或专用云盘 API。
- 永久删除文件。

### 搜索与排序

Spotlight 提供候选结果，FindAll 在本地应用收藏和目录优先级。默认分组顺序为：

1. 用户手动固定的项目。
2. 置顶文件夹中的匹配结果。
3. 优先文件夹中的匹配结果。
4. 其他匹配结果。

每组内部再按匹配质量或用户选择的表格排序方式排列。FindAll 不修改 Spotlight 索引。

### 安全与隐私

- 搜索查询、收藏目录、快捷键和使用偏好保存在本机。
- FindAll 不上传文件名、路径或搜索内容。
- 用户选择的目录权限应通过 macOS 提供的安全作用域书签持久化。
- 删除操作只将项目移到废纸篓，不提供永久删除。
- FindAll 不需要管理员权限，不修改 SIP，也不安装后台服务。

### 系统要求

初始目标环境：

- Apple Silicon Mac（arm64）
- macOS 14 或更高版本

在首个正式版本发布前，系统版本和架构要求仍可能根据实现与测试结果调整。

### 从源码构建

项目计划使用 Swift、SwiftUI、AppKit、Foundation、Quick Look、`NSWorkspace` 和
Spotlight 元数据 API 构建。

Xcode 工程尚未建立。工程建立后，预计使用：

- Project：`FindAll.xcodeproj`
- Scheme：`FindAll`
- Product：`FindAll.app`
- Bundle Identifier：`com.lalalaladam.FindAll`

数值构建号必须使用当前 Git commit 数量：

```bash
git rev-list --count HEAD
```

### 已知限制

- FindAll 只能返回 Spotlight 已索引并允许当前进程访问的项目。
- 被 Spotlight 隐私设置排除的目录可能无法搜索。
- Spotlight 索引正在建立或损坏时，结果可能缺失或延迟。
- 隐藏文件、系统保护目录、外接磁盘和云端占位文件的可见性取决于索引、挂载状态和权限。
- 第一阶段不保证搜索文件内容。

---

## English

### Overview

FindAll is a native macOS file-search utility. It uses the macOS Spotlight
metadata index to find files, folders, and applications quickly, while adding
customizable result-action shortcuts, favorite folders, and directory priorities.

FindAll is not intended to become an application launcher or create a second
filesystem index. Its purpose is to provide a faster, predictable, and
keyboard-friendly interface for acting on Spotlight search results.

### Planned Features

- Search Spotlight-indexed files, folders, and applications as the user types.
- View and filter results by name, path, type, size, and modification date.
- Sort, resize, reorder, and hide columns in a native table.
- Save favorite folders and restrict searches to a selected scope.
- Mark folders as normal, preferred, or pinned for global-result ordering.
- Customize shortcuts for opening, previewing, revealing, copying, and path actions.
- Copy a filename, full POSIX path, parent-folder path, or file URL.
- Preview with Quick Look and drag results to Finder or other applications.
- Select multiple results and perform applicable batch actions.
- Store settings, favorites, and ordering preferences locally.

### Initial Scope

The initial version uses only public macOS Spotlight and filesystem APIs. It
does not create a custom file index, install a background daemon, or index file
contents.

The initial version does not include:

- Full-content, OCR, or semantic search.
- AI, natural-language commands, plugins, or workflows.
- Clipboard history, calculator, web search, or window management.
- Cloud synchronization or provider-specific cloud APIs.
- Permanent file deletion.

### Search and Ordering

Spotlight supplies candidate results. FindAll applies local favorite and folder
priorities in this default group order:

1. Items manually pinned by the user.
2. Matches inside pinned folders.
3. Matches inside preferred folders.
4. All other matches.

Items within a group are ordered by match quality or the table sort selected by
the user. FindAll does not modify the Spotlight index.

### Security and Privacy

- Search queries, favorite folders, shortcuts, and preferences remain local.
- FindAll does not upload filenames, paths, or search text.
- Persist access to user-selected directories with macOS security-scoped bookmarks.
- Destructive actions move items to Trash; permanent deletion is not provided.
- FindAll does not require administrator privileges, modify SIP, or install a daemon.

### Requirements

Initial deployment target:

- Apple Silicon Mac (arm64)
- macOS 14 or later

The supported macOS version and architectures may be revised before the first
stable release based on implementation and testing.

### Building from Source

The project is planned to use Swift, SwiftUI, AppKit, Foundation, Quick Look,
`NSWorkspace`, and Spotlight metadata APIs.

The Xcode project has not been created yet. Its expected identifiers are:

- Project: `FindAll.xcodeproj`
- Scheme: `FindAll`
- Product: `FindAll.app`
- Bundle Identifier: `com.lalalaladam.FindAll`

The numeric build number must equal the current Git commit count:

```bash
git rev-list --count HEAD
```

### Known Limitations

- FindAll can return only items indexed by Spotlight and accessible to the process.
- Folders excluded in Spotlight Privacy may not be searchable.
- Results may be incomplete or delayed while an index is building or damaged.
- Hidden files, protected system locations, external volumes, and cloud placeholders
  depend on indexing, mount state, and permissions.
- The initial version does not guarantee file-content search.
