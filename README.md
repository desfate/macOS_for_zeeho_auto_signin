# macOS 极核（ZEEHO）自动签到

非官方的 macOS 个人自用工具：用极核 App 已登录会话里的 Token，每天自动签到，并在菜单栏 / 桌面卡片上显示积分和车辆概要。

> **本项目与极核（ZEEHO）/ 春风动力（CFMOTO）无任何关联，也不是官方产品。**

## 免责声明

1. 仅供个人学习与自用。禁止用于商业用途、批量账号、灰产或任何违反极核用户协议、相关法律法规的行为。
2. 本工具会调用非公开的 H5 / App 接口。接口随时可能变更、风控或失效，作者不保证可用，也不提供任何形式的承诺或技术支持。
3. Token 等同账号凭证。泄露会导致他人操控你的账号。官方 App 为**单会话**：别处使用同一 Token 可能把手机 App 挤下线。请妥善保管 `config/local.json`，不要提交到 Git、不要发到群里。
4. 无法通过短信验证码自动换 Token。过期后必须自己从 App 抓包更新。本仓库不协助绕过登录鉴权、不提供破解或批量登录方案。
5. 使用本软件产生的账号封禁、积分异常、数据丢失、设备问题或任何其他后果，均由使用者自行承担。作者及贡献者不对任何直接或间接损失负责。
6. 仓库中的 `app_id` / `app_secret` 来自公开 H5 客户端，仅用于接口签名，**不是**你的登录 Token。请勿把它们与 Bearer Token 搞混。

继续使用即表示你已阅读并同意以上条款。

## 功能

- 每天自动签到（对齐 [MonicaGmm/zeeho-quanx](https://github.com/MonicaGmm/zeeho-quanx) 的签到流程）
- macOS 菜单栏 + 桌面卡片：总积分、连签、车辆电量 / 续航 / 里程 / 锁车状态
- Token 失效时在卡片上粘贴新的 `Authorization: Bearer …`

## 环境

- macOS 14+（Apple Silicon）
- Python 3.13（或系统 `python3`）
- Xcode Command Line Tools（`swiftc`）

## 安装

```bash
git clone https://github.com/desfate/macOS_for_zeeho_auto_signin.git
cd macOS_for_zeeho_auto_signin
cp config/local.example.json config/local.json
```

编辑 `config/local.json`，把 `token` 换成你自己的 UUID。

编译菜单栏应用（会安装到 `~/Applications/ZeehoSignin.app`）：

```bash
chmod +x macos/build.sh
./macos/build.sh
open ~/Applications/ZeehoSignin.app
```

手动跑一次签到：

```bash
python3 scripts/zeeho_signin.py --status-only   # 只刷新状态
python3 scripts/zeeho_signin.py                 # 未签则签到
python3 scripts/zeeho_signin.py --set-token 'Bearer 或 URL 或 UUID'
```

## 如何抓 Token

H5 签到接口**不会签发** Token，只是带着用。从已登录的极核 App 抓包：

1. 任意业务请求头：`Authorization: Bearer xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`
2. 或打开签到页的地址：`https://h5.zeehoev.com/activity/signin?token=bearer%20<uuid>`

只要 UUID 这一段。不要抄 `Cfmoto-X-Sign` / `appId`，那是签名，不是登录凭证。

过期后在卡片点「更新 Token」，粘贴整段 `Authorization` 或 URL 即可。

## 定时任务（每天 08:30，上海时区）

```bash
ROOT="$(pwd)"
PYTHON_BIN="$(command -v python3)"
mkdir -p logs
sed \
  -e "s|REPO_ROOT|$ROOT|g" \
  -e "s|PYTHON_BIN|$PYTHON_BIN|g" \
  scripts/com.zeeho.signin.plist.example \
  > ~/Library/LaunchAgents/com.zeeho.signin.plist
launchctl unload ~/Library/LaunchAgents/com.zeeho.signin.plist 2>/dev/null || true
launchctl load ~/Library/LaunchAgents/com.zeeho.signin.plist
```

## 目录

```
config/local.example.json          # 配置模板（不要提交你的 local.json）
scripts/zeeho_signin.py            # 签到脚本
scripts/com.zeeho.signin.plist.example
macos/build.sh                     # 编译菜单栏应用
macos/ZeehoSignin/                 # SwiftUI 源码
```

## 致谢

- 签到流程参考 [MonicaGmm/zeeho-quanx](https://github.com/MonicaGmm/zeeho-quanx)
- 车辆接口与签名方式参考社区对极核 App 的公开研究

## 许可证

MIT。免责声明见上文，其效力优于对可用性的任何默示保证。
