# Microsoft Rewards 自动赚分脚本

> 本仓库 `README.md` 为 **fork 维护者中文版**。英文原版请参考上游：
> [hex-ci/Microsoft-Rewards-Script](https://github.com/hex-ci/Microsoft-Rewards-Script#readme)
>
> 本版本仅增强中文文档与国内构建加速，**运行逻辑与上游 v4 保持一致**。

---

## 目录

- [本 fork 改了什么](#1-本-fork-改了什么)
- [环境要求](#2-环境要求)
- [部署步骤](#3-部署步骤)
- [手动触发一次运行（测试登录）](#4-手动触发一次运行测试登录)
- [两步验证（2FA）配置](#5-两步验证2fa配置)
- [守护与「服务器重启后自动运行」](#6-守护与服务器重启后自动运行)
- [常见问题 / 踩坑记录](#7-常见问题--踩坑记录)
- [从上游同步更新](#8-从上游同步更新)
- [配置选项速查](#9-配置选项速查)

---

## 1. 本 fork 改了什么

| 改动 | 文件 | 说明 |
|------|------|------|
| 国内构建加速 | `Dockerfile` | 切换清华 apt 镜像 + npmmirror 二进制镜像，解决官方源在国内极慢（实测约 200KB/s，完整构建 1 小时以上）的问题 |
| 中文文档 | `README.md`（本文件） | 面向中文 / 国内用户的部署与排障指南，默认显示 |

> 上游 `compose.yaml` 的 healthcheck 为 `pgrep cron > /dev/null || exit 1`（**正确写法**，cron 在跑即 healthy）。
> 早期版本曾出现过 `; exit 1`（永远 unhealthy）的 bug，本 fork 已无此问题。若从其他旧源部署遇到 `unhealthy`，
> 请把该处改为 `|| exit 1`。

---

## 2. 环境要求

- 一台 Linux 服务器（已验证：腾讯云 Ubuntu，2C2G 可用）
- 已安装 Docker 与 Docker Compose（Compose v2，`docker compose` 命令）
- Microsoft 账户（邮箱 + 密码；若开启两步验证 2FA，需配置 TOTP，见第 5 节）

---

## 3. 部署步骤

### 3.1 准备项目与凭证

```bash
git clone https://github.com/maojunzc/Microsoft-Rewards-Script.git
cd Microsoft-Rewards-Script

# 复制环境变量模板并填写账户
cp env.example .env
```

编辑 `.env`，至少填写：

```env
ACCOUNT_1_EMAIL=你的邮箱@163.com
ACCOUNT_1_PASSWORD=你的密码
# 若开启了两步验证，取消下一行注释并填入认证器密钥（Base32）
# ACCOUNT_1_TOTP_SECRET=XXXXXXXXXXXXXXXX
```

### 3.2 调整定时与区域（中国用户重点）

编辑 `compose.yaml` 的 `environment` 段：

```yaml
environment:
    TZ: 'Asia/Shanghai'            # 改成中国时区，cron 才会按北京时间触发
    CRON_SCHEDULE: '0 9 * * *'     # 每天北京时间 09:00 自动运行
    RUN_ON_START: 'false'          # true=容器启动立刻跑一次；false=仅按 cron 跑
    SKIP_RANDOM_SLEEP: 'false'     # false=运行前随机等待 5~50 分钟（避免同一秒集中请求）
```

> `RUN_ON_START: 'true'` 时容器启动会立刻执行一次；日常建议设为 `false`，交给 cron 每天定时跑。

### 3.3 构建并启动

```bash
# 本地构建镜像（已加国内源加速）
docker compose up -d --build

# 若直接用上游预构建镜像（不走本地构建），把 compose.yaml 顶部的
# image: 行取消注释、注释掉 build: 段即可
```

首次构建会下载 Node 基础镜像、npm 依赖、Chromium（约 114MB）及系统依赖，
**有国内源后通常为几分钟到十几分钟**；无国内源时可能超过 1 小时。

### 3.4 验证

```bash
docker ps --filter name=microsoft-rewards-script   # 状态应为 Up ... (healthy)
docker logs -f microsoft-rewards-script            # 应看到 cron 调度已启动
```

---

## 4. 手动触发一次运行（测试登录）

不推荐用 `docker compose run`（会与常驻容器冲突）。直接在常驻容器内执行：

```bash
docker exec -e SKIP_RANDOM_SLEEP=true \
  microsoft-rewards-script \
  bash -c 'cd /usr/src/microsoft-rewards-script && npm start'
```

观察日志：正常流程为 `EMAIL_INPUT → 使用密码 → PASSWORD_INPUT → LOGGED_IN`，
随后自动完成每日任务、阅读赚分、打卡、搜索等。

---

## 5. 两步验证（2FA）配置

若 Microsoft 账户开启了两步验证：

1. 在认证器 App 中查看该账户的 **Base32 密钥**（非 6 位动态码）
2. 在 `.env` 中设置 `ACCOUNT_1_TOTP_SECRET=该密钥`
3. 重启容器：`docker compose up -d`

脚本会读取该密钥自动生成验证码，无需人工干预。

---

## 6. 守护与「服务器重启后自动运行」

本方案已是标准守护，无需 PM2：

- 容器 `restart: unless-stopped` → 容器异常退出会被 Docker 自动拉起
- `docker` 服务开机自启（执行一次确认：`systemctl is-enabled docker`，应为 `enabled`）

两者组合 = 服务器重启后 Docker 先起 → 自动拉起容器 → 容器内 cron 每天定时跑任务。
**无需人工干预，也无需额外的 PM2 进程。**

---

## 7. 常见问题 / 踩坑记录

| 现象 | 原因 | 处理 |
|------|------|------|
| 构建卡在 apt / Chromium 下载 | 国内访问官方源极慢 | 已通过 `Dockerfile` 国内源修复；如仍慢，检查镜像是否生效 |
| `docker ps` 显示 `(unhealthy)` | healthcheck 写成 `exit 1`（旧版 bug） | 改为 `pgrep cron > /dev/null \|\| exit 1` |
| 日志长时间不刷新 | 仅为构建日志缓冲延迟，并非卡死 | 用 `docker stats` / 网速检测确认仍在下载 |
| PC 搜索只完成部分、剩余 15 分没拿 | 服务器到 Bing 网络超时 | 脚本会自动重试；下次 cron 通常能补上 |
| 积分统计 `Browser: 0` / `App: 35` | 账户区域为 `cn`，桌面搜索暂不可赚 | 正常现象，非配置错误 |
| 容器启动后没立即跑任务 | `RUN_ON_START=false` | 改为 `true` 或等 cron 定时触发 |

---

## 8. 从上游同步更新

本仓库 `README.md` 已在 `.gitattributes` 中设置 `merge=ours`，
从上游合并时不会被英文原版覆盖。同步步骤：

```bash
git remote add upstream https://github.com/hex-ci/Microsoft-Rewards-Script.git
git fetch upstream
git merge upstream/v4
```

> 让 `merge=ours` 在本机生效，需注册一次 merge driver（一次即可）：
> ```bash
> git config merge.ours.name "keep ours"
> git config merge.ours.driver "true"
> ```

---

## 9. 配置选项速查

完整英文配置项见上游 [Configuration Options](https://github.com/hex-ci/Microsoft-Rewards-Script#configuration-options)。
常用项（通过 `compose.yaml` 的 `environment` 或 `config.json` 设置）：

- `CRON_SCHEDULE`：cron 表达式，控制每天运行时间（容器时区由 `TZ` 决定）
- `RUN_ON_START`：`true` 容器启动即运行一次；`false` 仅按 cron
- `SKIP_RANDOM_SLEEP`：`false` 运行前随机等待 5~50 分钟
- `ACCOUNT_N_EMAIL` / `ACCOUNT_N_PASSWORD` / `ACCOUNT_N_TOTP_SECRET`：多账户凭证
- `CONFIG_CLUSTERS`：并发集群数
- `CONFIG_ENSURE_STREAK_PROTECTION`：保护连续签到
- `CONFIG_WORKER_*`：开关各类任务（每日任务、特殊活动、更多活动等）

---

*维护者：maojunzc · 基于 [hex-ci/Microsoft-Rewards-Script](https://github.com/hex-ci/Microsoft-Rewards-Script) v4*
