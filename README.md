# ohos-ghc

本项目为 OpenHarmony 平台编译了 ghc，并发布预构建包。

本项目是 Harmonybrew 项目基础设施的一部分，主要供内部使用。我们也将其开源，有需要者可自取。

## 获取预构建包

前往 [release 页面](https://github.com/Harmonybrew/ohos-ghc/releases) 获取。

## 用法

这是一个 Stage 2 编译器，仅供 Stage 3 真机自举使用。在本项目中，它被用作 ghc 这个 formula 的自举种子。

它尚未通过完整的自举测试，可能存在未知的 Bug、缺少部分标准库优化，请勿将其用于生产环境或日常 Haskell 开发。

## 从源码构建

**1\. 手动构建**

需要用一台 Linux x64 服务器来运行项目里的 build.sh，以实现 ghc 的交叉编译。

这里以 Ubuntu 24.04 x64 作为示例：
```bash
sudo apt update && sudo apt install -y \
  build-essential \
  unzip \
  xz-utils \
  autoconf \
  python3 \
  libgmp-dev \
  libffi-dev
git clone https://github.com/Harmonybrew/ohos-ghc.git
cd ohos-ghc
./build.sh --all
```

构建完成后，产物位于 `ghc-ohos-work/ghc-9.12.2-ohos-arm64.tar.gz`。

**2\. 使用流水线构建**

如果你熟悉 GitHub Actions，你可以直接复用项目内的工作流配置，使用 GitHub 的流水线来完成构建。

这种情况下，你使用的是 GitHub 提供的构建机，不需要自己准备构建环境。

只需要这么做，你就可以进行你的个人构建：
1. Fork 本项目，生成个人仓
2. 在个人仓的“Actions”菜单里面启用工作流
3. 在个人仓提交代码或发版本，触发流水线运行
