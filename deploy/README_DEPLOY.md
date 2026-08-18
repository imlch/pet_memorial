# 🐾 宠物寄存格子管理系统 - 部署上线操作手册

> 方案：**前端静态托管 + Supabase（BaaS 后端）**
> 预计首次部署耗时：**30 分钟**

---

## 📋 执行清单（按顺序）

| 阶段 | 任务 | 预计耗时 | 负责人 |
|---|---|---|---|
| 1️⃣ | 注册 Supabase + 建表 | 10 min | 管理员 |
| 2️⃣ | 配置前端 Supabase 密钥 | 2 min | 管理员 |
| 3️⃣ | 部署前端（Vercel 或 自有服务器） | 5-15 min | 管理员 |
| 4️⃣ | 注册第一个门店账号测试 | 3 min | 管理员 |
| 5️⃣ | 配置邮件模板 / 域名 / HTTPS（可选） | 10 min | 管理员 |

---

## 1️⃣ 阶段一：Supabase 初始化

### 1.1 创建 Supabase 项目
1. 打开 [supabase.com](https://supabase.com) 注册/登录
2. 点击 **New Project**，填写：
   - **Name**: `pet-memorial`（或自定义）
   - **Database Password**: 生成强密码并保存（**记下来**，之后可能用到）
   - **Region**: 选离门店最近的节点（国内推荐 `Singapore`，海外看业务区）
   - **Pricing Plan**: 免费版（Free Tier）起步完全够用
3. 等待项目创建完成（约 2 分钟）

### 1.2 运行数据库初始化脚本
1. 进入项目 → 左侧菜单选 **SQL Editor** → **New query**
2. 打开项目文件 [supabase/migrations/001_init_schema.sql](file:///d:/trae/pet_memorial_grid/supabase/migrations/001_init_schema.sql)
3. **全选 → 复制 → 粘贴到 SQL Editor → Run**
4. 看到 `Success. No rows returned` 表示成功
5. （验证）去 **Table Editor** 看是否出现 3 张表：`stores`、`cells`、`memorials`

### 1.3 配置 Email 登录（建议关闭邮箱确认，简化门店注册）
1. 左侧菜单 **Authentication → Providers → Email**
2. 关闭 **Confirm email**（门店管理员注册后直接登录，无需点击邮件链接）
3. 开启 **Secure email change**（保持安全）
4. 点击 **Save**

> ⚠️ **生产环境建议**：保持 Confirm email 开启，但需要确保门店邮箱能正常收到 Supabase 邮件。也可以配置自定义 SMTP（在 Authentication → URL Configuration → SMTP Settings）。

### 1.4 获取项目密钥（超详细图文版）

> 📌 **需要获取的两个值（两个都可公开，无需担心泄露）：**
>
> | 前端变量名 | Supabase 页面名称 | 格式示例 | 是否敏感 |
> |---|---|---|---|
> | `SUPABASE_URL` | **Project URL** | `https://xxxxxxxx.supabase.co` | ❌ 不敏感 |
> | `SUPABASE_ANON_KEY` | **Publishable key（新版）** 或 **anon public（旧版）** | `sb_publishable_xxx...` 或 `eyJhbGciOi...` | ❌ 不敏感（RLS 保护） |
>
> ⚠️ **千万别复制的密钥：** `service_role`（旧版）或 `Secret key`（新版）—— 它们会绕过所有权限检查，仅限后端管理员用。

#### 1.4.1 进入 API 设置页
1. 登录 [supabase.com/dashboard](https://supabase.com/dashboard) 并点进你的项目
2. 左侧菜单拉到最下方，找到 **⚙️ Settings（齿轮图标）** 点击
3. 在展开的二级菜单里点 **API**（新版可能叫 **API Keys**）

```
 左侧菜单示意：
  ┌─────────────────────────────────┐
  │  🏠 Table Editor                │
  │  🔌 SQL Editor                  │
  │  🔐 Authentication              │
  │  ...                            │
  │  ────────────────────           │
  │  ⚙️ Settings         ← 点这里  │
  │    └─ API / API Keys ← 再点这里 │
  └─────────────────────────────────┘
```

#### 1.4.2 复制 Project URL（第一个值）
页面顶部第一张大卡片就是：

```
┌─────────────────────────────────────────────────────────────┐
│ 📍 Project URL                                              │
│  ┌───────────────────────────────────────────────────────┐ │
│  │ https://abcdefghijklmnop.supabase.co     [Copy] ← 点 │ │
│  └───────────────────────────────────────────────────────┘ │
│                                                             │
│ Project Refs:    abcdefghijklmnop                           │
└─────────────────────────────────────────────────────────────┘
```
- 点 **Copy** 复制整串
- 格式一定是 `https://` 开头，`.supabase.co` 结尾
- 末尾**不要带斜杠**，不要多复制 `/rest/v1` 之类的路径

#### 1.4.3 复制 anon / Publishable key（第二个值）
往下滚动找到密钥卡片区，Supabase 目前有 **两种 UI**（新旧体系并存，任选一个即可）：

##### 👉 情况 A：新版 UI（有「API Keys」和「Legacy API Keys」两个 Tab）
默认停在 **API Keys** 这个 Tab，复制标有 **Publishable key** 的那一串：
```
┌─────────────────────────────────────────────────────────────┐
│ [API Keys]  [Legacy API Keys]        ↑ API Keys 已选中     │
│                                                             │
│ 🔓 Publishable key   (用于前端、浏览器、可公开)              │
│  ┌───────────────────────────────────────────────────────┐ │
│  │ sb_publishable_78d4a6b3c2f1e...           [Copy] ← 点│ │
│  └───────────────────────────────────────────────────────┘ │
│                                                             │
│ 🔒 Secret key        (仅后端！❌ 不要复制)                    │
│  ┌───────────────────────────────────────────────────────┐ │
│  │ sb_secret_78d4a6b3c2f1e9a8b7...                       │ │
│  └───────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

##### 👉 情况 B：旧版 UI（直接列出两个 key）
直接复制 **anon public** 那串（下面那个 service_role 别碰）：
```
┌─────────────────────────────────────────────────────────────┐
│ 🔓 anon public    (Safe to expose in browser)               │
│  ┌───────────────────────────────────────────────────────┐ │
│  │ eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3... [Copy]│ │◀ 复制这个！
│  └───────────────────────────────────────────────────────┘ │
│                                                             │
│ 🔒 service_role (🔴 Bypasses RLS — 仅后端用 ❌)             │
│  ┌───────────────────────────────────────────────────────┐ │
│  │ eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJyb2...       │ │
│  └───────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

> 💡 **正确性自检：** 复制出来的字符串开头符合其一即可：
> - ✅ `sb_publishable_` （新版）
> - ✅ `eyJhbGciOiJIUzI1Ni...` （旧版 JWT 开头）
> - ❌ 如果看到 `sb_secret_` 开头 —— 那是后端密钥，换一个复制！

#### 1.4.4 临时保存两个值到记事本
```
（示例，请替换成你自己的）
SUPABASE_URL      = https://abcdefghijklmnop.supabase.co
SUPABASE_ANON_KEY = sb_publishable_78d4a6b3c2f1e9a8b7c6d5e4f...
```

#### 1.4.5 备份密钥到密码管理器（强烈建议！）
把这 4 项保存到 1Password / Bitwarden / 加密备忘录，后续迁库或换设备一定会用到：

```
项目名：宠物寄存格子 Supabase
─────────────────────────────────
Project URL:       https://...
Project Refs:      12字母ID
Publishable/anon:  sb_publishable_... 或 eyJ...
Secret/service:    sb_secret_... 或 eyJ...（后台用，务必妥善保管）
数据库密码:         新建项目时生成的强密码
```

---

## 2️⃣ 阶段二：配置前端密钥

编辑项目文件 [public/index.html](file:///d:/trae/pet_memorial_grid/public/index.html#L555-L556)，把这两行替换掉：

```javascript
// 替换前
const SUPABASE_URL = 'YOUR_SUPABASE_URL_HERE';
const SUPABASE_ANON_KEY = 'YOUR_SUPABASE_ANON_KEY_HERE';

// 替换后（示例）
const SUPABASE_URL = 'https://abcklmnopqrst.supabase.co';
const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3Mi...';
```

---

## 3️⃣ 阶段三：部署前端（两种方式，二选一）

### 🔵 方式 A：Vercel 部署（推荐，0 服务器 + 免费 HTTPS）

**优势**：推送代码自动部署、全球 CDN、自动 HTTPS、免费额度足够

#### 步骤：
1. 把项目推送到 GitHub / GitLab / Bitbucket（公开或私有仓库均可）
   ```bash
   # 如未初始化 git
   cd d:\trae\pet_memorial_grid
   git init
   git add .
   git commit -m "Initial: pet memorial grid with Supabase"
   git branch -M main
   git remote add origin https://github.com/你的用户名/你的仓库.git
   git push -u origin main
   ```
2. 打开 [vercel.com](https://vercel.com) 用 GitHub 账号登录
3. **Add New → Project** → 选择刚推送的仓库
4. 在 Configure 页面，**Framework Preset 选 Other**，**Root Directory 留空**，**Build Command 留空**，**Output Directory 填 `public`**
5. 点击 **Deploy**，等待约 1 分钟完成
6. 部署成功后会给你一个 `https://xxx.vercel.app` 域名，可以直接访问测试
7. （可选）**Settings → Domains** 绑定自己的域名，按提示添加 DNS 解析即可自动配 HTTPS

---

### 🟢 方式 B：自有云服务器 + Nginx（阿里云/腾讯云等 Ubuntu 22.04）

**适用场景**：已有服务器、数据完全可控、需要绑定内网域名等

#### 3.2.1 上传代码到服务器
```bash
# 在你本地电脑的项目目录（Windows PowerShell）
# 方式一：用 scp 上传（假设服务器 IP = 123.123.123.123）
scp -r d:\trae\pet_memorial_grid\public root@123.123.123.123:/var/www/pet-memorial/

# 方式二：服务器上 git clone（推荐）
ssh root@123.123.123.123
mkdir -p /var/www
cd /var/www
git clone https://github.com/你的用户名/你的仓库.git pet-memorial
# 之后更新只需 git pull
```

#### 3.2.2 安装 Nginx + 配置
```bash
apt update && apt install -y nginx

# 上传 nginx 配置（项目里 deploy/nginx-pet-memorial.conf）
cp deploy/nginx-pet-memorial.conf /etc/nginx/sites-available/pet-memorial.conf
# 编辑里面的 server_name 和 root 路径
vim /etc/nginx/sites-available/pet-memorial.conf

# 启用站点
ln -s /etc/nginx/sites-available/pet-memorial.conf /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default   # 禁用默认站点（可选）

# 测试配置并生效
nginx -t && systemctl reload nginx
```

#### 3.2.3 配置 HTTPS（免费，必须！浏览器密码登录要求安全上下文）
```bash
apt install -y certbot python3-certbot-nginx
certbot --nginx -d pet.yourdomain.com
# 按提示填邮箱 + 同意协议 + 选 2（自动重定向 HTTP→HTTPS）
# 证书 90 天有效，certbot 会自动续期
```

---

## 4️⃣ 阶段四：门店账号注册 & 数据迁移

### 4.1 注册第一个门店账号
1. 打开部署好的网站，进入注册页
2. 填写：
   - 门店名称：如「毛毛宠物纪念堂」
   - 邮箱：门店管理员邮箱（如 `maomao@example.com`）
   - 密码：至少 6 位
3. 注册成功后自动登录，进入格子页面
4. 点击顶部 Header 左侧的门店标签（🏪 毛毛宠物纪念堂），调整行列数、地址、电话后保存

### 4.2 （可选）迁移本地 localStorage 数据到云端
如果某台电脑上已经有现存数据（原单机版录入的），按这个步骤迁移：

1. 在原电脑打开旧版 `pet_memorial_grid.html`，按 F12 打开 Console
2. 执行以下代码，把导出结果复制保存（JSON）：
   ```javascript
   copy(localStorage.getItem('pet_memorial_grid_data_v2'))
   // 或者点击导出CSV按钮
   ```
3. 登录新版云端系统，点击 **📤 导入JSON** 按钮，选择刚保存的文件
4. 确认无误后导入完成

### 4.3 为后续门店提供账号
每个门店**自行注册**即可（注册触发器会自动创建属于该账号的 `stores` 记录），门店之间通过 RLS 完全隔离，互不影响。

如果需要管理员代门店创建账号：
- Supabase 后台 **Authentication → Users → Add user** 创建用户
- 创建后把 `stores` 表对应的 `owner_id` 设置为该用户 id，`name` 填门店名

---

## 5️⃣ 阶段五：安全 & 运维加固（生产环境建议）

### 5.1 Supabase 侧
- ✅ **已默认启用** RLS 行级安全（3 张表），门店只能读写自己的数据
- ✅ **已默认启用** Cascade Delete：删除门店→删除格子→删除纪念日
- ⬜ 建议：**Settings → API → JWT Secret** 不要泄露（anon key 可公开，别暴露 service_role key）
- ⬜ 建议：开启 **Database → Backups**（Pro 版），或定期手动导出 SQL

### 5.2 前端侧
- ✅ 代码中只使用 anon key（不用担心泄露）
- ✅ 所有写操作通过 RLS 校验门店归属
- ⬜ 建议：绑定自定义域名后，在 Supabase **Authentication → URL Configuration** 配置 Redirect URLs

### 5.3 监控 & 备份
- **Supabase 仪表盘**：查看 API 调用量、数据库查询性能
- **Vercel / Nginx Log**：监控访问量、异常状态码
- **手动备份操作**（每周一次）：
  ```bash
  # 方式 1：Supabase 后台 Table Editor 逐表导出 CSV
  # 方式 2：使用 Supabase CLI 完整备份
  supabase db dump --db-url postgres://postgres:PASSWORD@DB_HOST:6543/postgres > backup_$(date +%Y%m%d).sql
  ```

---

## 🆘 常见问题 FAQ

**Q1: 登录后提示「门店初始化失败」？**
> A: 通常是 SQL 脚本没跑完整。回到 Supabase SQL Editor，重新运行一遍 `001_init_schema.sql`，确保 `get_my_store` 和 `get_store_grid` 两个 RPC 函数存在。

**Q2: 导入 CSV 提示数量为 0？**
> A: 检查 CSV 首行是否为中文表头。本系统兼容「宠物寄存数据_YYYY-MM-DD.csv」格式（原单机版导出格式）。

**Q3: 一台电脑能切换多个门店吗？**
> A: 可以，但同一浏览器同一时刻只能登录一个门店。切换请先点右上角「👤 退出」。

**Q4: 手机 / 平板能用吗？**
> A: 可以。建议横屏使用格子区。Header 在窄屏下会自动换行。

**Q5: 后续想换成自建后端怎么办？**
> A: Supabase 底层是标准 PostgreSQL，可随时在 Database Settings 里找 Connection String 直接连接自建应用迁移数据。

---

## 📁 项目目录结构（改造后）

```
pet_memorial_grid/
├── public/
│   └── index.html                  # 前端单文件（入口）
├── deploy/
│   └── nginx-pet-memorial.conf     # Nginx 部署配置（方式B用）
├── supabase/
│   └── migrations/
│       └── 001_init_schema.sql     # 数据库建表 + RLS 脚本
├── vercel.json                     # Vercel 部署配置（方式A用）
├── .gitignore
└── README_DEPLOY.md                # 本文档
```

---

**全部完成后，给门店的交付物：**
1. 部署好的网址（HTTPS）
2. 注册步骤指引：打开网址 → 注册新门店 → 填门店名邮箱密码 → 开始使用
3. 操作录屏 / 使用手册（可选）
