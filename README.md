# FindAll

[中文](#中文) | [English](#english)

## 中文

### 简介

FindAll 是一款原生 macOS 文件搜索工具，当前版本使用 macOS Spotlight 元数据查找
文件、文件夹和应用，并提供结果筛选、排序和快捷操作。

### 系统要求

初始目标环境：

- Apple Silicon Mac（arm64）
- macOS 14 或更高版本

在首个正式版本发布前，系统版本和架构要求仍可能根据实现与测试结果调整。

### 从源码构建

项目使用 Swift、AppKit、Foundation、Quick Look、`NSWorkspace` 和 Spotlight
元数据 API 构建。

工程标识：

- Project：`FindAll.xcodeproj`
- Scheme：`FindAll`
- Product：`FindAll.app`
- Bundle Identifier：`com.lalalaladam.FindAll`

数值构建号必须使用当前 Git commit 数量：

```bash
git rev-list --count HEAD
```

---

## English

### Overview

FindAll is a native macOS file-search utility. The current version uses macOS
Spotlight metadata to find files, folders, and applications and provides result
filtering, ordering, and keyboard-friendly actions.

### Requirements

Initial deployment target:

- Apple Silicon Mac (arm64)
- macOS 14 or later

The supported macOS version and architectures may be revised before the first
stable release based on implementation and testing.

### Building from Source

The project uses Swift, AppKit, Foundation, Quick Look, `NSWorkspace`, and
Spotlight metadata APIs.

Project identifiers:

- Project: `FindAll.xcodeproj`
- Scheme: `FindAll`
- Product: `FindAll.app`
- Bundle Identifier: `com.lalalaladam.FindAll`

The numeric build number must equal the current Git commit count:

```bash
git rev-list --count HEAD
```
