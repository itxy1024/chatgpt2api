# 部署与升级

状态：当前

本 fork 的发布镜像默认是 `ghcr.io/itxy1024/chatgpt2api:latest`，源码仓库为 `itxy1024/chatgpt2api`。标准 Compose 将服务暴露在 `3000` 端口，使用 `chatgpt2api-runtime` 命名卷保存可更新的应用运行目录，并单独挂载本地 `data/` 和 `config.json`。运行时配置和数据不应提交到 Git。

## 推送后自动构建

工作流为 `.github/workflows/docker-publish.yml`：先编译后端并构建 Vue 控制台，通过后使用仓库自带的 `GITHUB_TOKEN` 发布 GHCR 镜像，无需 Docker Hub 账号或额外 PAT。

| 触发方式 | 验证与发布行为 |
| --- | --- |
| 推送默认分支 `main` | 发布 `latest`、`main` 和 `sha-<完整提交SHA>` |
| 推送其他分支 | 发布对应分支标签和 `sha-<完整提交SHA>`，不覆盖 `latest` |
| 推送 `v*` 标签 | 发布版本标签、符合语义版本时的版本号及主次版本号标签、提交标签，并创建原有 Release 在线更新包；不覆盖 `latest` |
| Pull Request | 仅验证，不登录 GHCR、不发布镜像或 Release |
| Actions 手动运行 | 发布所选分支或标签的镜像；选择默认分支时更新 `latest`，不创建 Release |

镜像同时支持 `linux/amd64` 和 `linux/arm64`。同一分支的新工作流会取消尚未结束的旧工作流，以免旧提交覆盖新镜像。分支名中的 `/` 等字符由 Docker metadata action 转为合法镜像标签。

首次启用步骤：

1. 在 fork 的 GitHub **Actions** 页面启用工作流（若页面提示已停用）。
2. 提交本次修改并推送到 `main`，或在 Actions 手动运行。仅本地 commit 不会触发 GitHub 构建。
3. 等待工作流的 `verify` 和 `docker` 成功。推送默认分支不会创建 GitHub Release。
4. 在 GitHub Packages 检查 `chatgpt2api` 软件包。需要匿名拉取时将其设为 **Public**；私有镜像需要服务器登录 GHCR。若组织限制 Actions 发布，需允许 Packages 写入；工作流已声明 `packages: write`。

工作流只发布镜像，不会自动更新服务器。修改后的首个构建成功前，已有的 `latest` 仍可能指向旧项目镜像。

## Docker 部署

服务器需安装 Docker Engine 和 Compose v2（`docker compose version` 能输出版本）。以下使用独立目录部署 v3，默认使用 SQLite：

```bash
git clone https://github.com/itxy1024/chatgpt2api.git chatgpt2api-v3
cd chatgpt2api-v3
test -f .env || cp .env.example .env
# 将 .env 中的 CHATGPT2API_AUTH_KEY=your_secret_key_here 替换为私有密钥。
nano .env
# 确认 CHATGPT2API_IMAGE=ghcr.io/itxy1024/chatgpt2api:latest。
# 对外访问时可设置 CHATGPT2API_BASE_URL=http://服务器IP:3000 或正式域名。
test -f config.json || printf '{}\n' > config.json
mkdir -p data
docker compose config --quiet
docker compose pull
docker compose up -d
docker compose ps
docker compose logs --tail=100 app
```

`docker compose ps` 应显示应用运行，并存在宿主机 `3000` 到容器 `80` 的端口映射。开放服务器防火墙和云安全组 TCP 3000 后，访问 `http://服务器IP:3000`，使用 `.env` 中设置的管理员密钥登录。API 基础地址为 `http://服务器IP:3000/v1`。需要 HTTPS 时可通过现有反向代理接入正式域名。

如果旧服务仍占用 `chatgpt2api` 容器名或 3000 端口，先在旧项目目录停止旧服务，或为并行试用修改新 Compose 的 `container_name`，并在新 `.env` 设置 `CHATGPT2API_PORT=3001`。使用新目录和新数据库，旧版账号应导出后重新导入；不复用旧版分散的 JSON 数据作为 v3 数据库。

已有 `.env` 不会因修改 `.env.example` 自动更新。升级本 fork 时检查 `CHATGPT2API_IMAGE`，避免仍拉取 `ghcr.io/yukkcat/chatgpt2api`。SQLite 不需要设置 `STORAGE_BACKEND`。

镜像中的 `/opt/chatgpt2api` 是只读应用种子，`/app` 是受管运行目录。入口脚本读取镜像内 `.image-revision` 作为构建标识，与运行卷的 `.chatgpt2api-image-version` 比较；构建变化或运行目录缺少 `VERSION` 时刷新代码，再按锁文件同步 Python 依赖。CI 构建标识为完整提交 SHA；本地构建没有传入 `SOURCE_REVISION` 时使用应用产物摘要。旧镜像没有构建标识时回退到 `VERSION`。同一镜像正常重启时保留运行文件；即使应用仍显示 3.2.9，新提交构建的镜像也会刷新代码。业务数据始终留在独立的 `data/` 挂载中。

私有 GHCR 镜像需要先登录。使用有 `read:packages` 权限且有权访问软件包的 GitHub PAT，通过交互输入，随后重新执行 `docker compose pull`：

```bash
docker login ghcr.io -u itxy1024
```

### 本地 PostgreSQL 18

需要由 Compose 一并运行 PostgreSQL 时，在 `.env` 中设置数据库密码：

```dotenv
POSTGRES_PASSWORD=replace_with_a_strong_password
```

然后同时加载基础 Compose 和 PostgreSQL overlay：

```bash
docker compose -f docker-compose.yml -f docker-compose.postgres.yml up -d
```

`docker-compose.postgres.yml` 使用官方 `postgres:18-alpine` 镜像，等待数据库健康后再启动应用，并将数据持久化到 `chatgpt2api-postgres-data` 命名卷。数据库端口默认不暴露到宿主机。

`POSTGRES_PASSWORD` 会同时用于初始化数据库和构造 `DATABASE_URL`，因此请仅使用 URL 安全字符（字母、数字、下划线或连字符），不要在两个位置分别编码密码。
启用该模式后，后续启动、升级、查看状态和停止服务都应同时指定这两个 Compose 文件。

查看状态与日志：

```bash
docker compose -f docker-compose.yml -f docker-compose.postgres.yml ps
docker compose -f docker-compose.yml -f docker-compose.postgres.yml logs -f postgres app
```

`.env` 中的 `CHATGPT2API_AUTH_KEY` 优先于 `config.json` 的 `auth-key`。若要使用 `config.json`，先删除或注释 `.env` 中的该值，再填写 `auth-key`。

默认地址：

- 控制台：`http://localhost:3000`
- API：`http://localhost:3000/v1`

本 fork 推荐上述 Compose 流程。也可使用继承的安装脚本，必须显式指定本 fork 的仓库和镜像，避免沿用脚本内的上游默认值：

```bash
curl -fsSL https://raw.githubusercontent.com/itxy1024/chatgpt2api/main/deploy/install.sh \
  | sudo env CHATGPT2API_IMAGE=ghcr.io/itxy1024/chatgpt2api:latest bash -s -- --repo-owner itxy1024 --repo-name chatgpt2api
```

安装脚本会明确询问 Application Database：

- SQLite 本地文件（默认）
- PostgreSQL 18 本地容器（Docker 模式）
- 已有 PostgreSQL URL

选择本地 PostgreSQL 时，脚本会自动生成并保存数据库密码，下载 `docker-compose.postgres.yml`，再与主 Compose 一起启动。重复运行安装脚本会复用已有密码。`CHATGPT2API_THREAD_TOKENS` 默认是 `120`，表示后端同步工作线程的并发容量，只要求正整数且不设置人为最高值；账号、代理和上游服务仍分别执行自己的并发限制。

## 本地开发

后端：

```bash
git clone https://github.com/itxy1024/chatgpt2api.git
cd chatgpt2api
uv sync
uv run main.py
```

Vue 控制台：

```bash
cd web-vue
npm install
npm run dev
```

前端开发服务器默认使用 Vite 端口；后端仍读取项目根目录的 `config.json` 和 `data/`。

## 存储边界

`DATABASE_URL` 选择 Application Database；未设置时使用
`data/chatgpt2api.db`。支持 SQLite 与 PostgreSQL 18，不再通过
`STORAGE_BACKEND` 选择 JSON、Git 或账号专用数据库。

选择数据库不是旧数据迁移操作，不会自动导入 JSON、JSONL、Git 或旧账号
SQLite 文件。图片文件及其相关索引仍按图片存储边界管理。完整边界见
[`storage-architecture.md`](storage-architecture.md)。

## 升级

升级前先在系统设置中执行一次 R2 备份，并确认状态为成功。备份归档始终包含
Application Database：SQLite 使用 `data/application-database.sqlite3`，PostgreSQL
使用 `data/application-database.pgdump`。图片任务记录、PPT / PSD 文件和图片目录
按备份设置选择；外部 WebDAV 仍需独立备份。

未配置 R2 时，应先停止服务再备份。SQLite 可以在停服后复制 `data/chatgpt2api.db`；
PostgreSQL 必须使用 `pg_dump --format=custom`，不能用 `tar data/` 代替数据库备份。
`config.json` 只保留 `auth-key` 等启动配置，也应单独保存：

```bash
pg_dump --format=custom --no-owner --no-privileges "$DATABASE_URL" \
  > backups/chatgpt2api-$(date +%Y%m%d-%H%M%S).pgdump
```

本地 PostgreSQL Compose 可直接在数据库容器内导出：

```bash
docker compose -f docker-compose.yml -f docker-compose.postgres.yml exec -T postgres \
  sh -c 'pg_dump --format=custom --no-owner --no-privileges \
  -U "$POSTGRES_USER" "$POSTGRES_DB"' \
  > backups/chatgpt2api-$(date +%Y%m%d-%H%M%S).pgdump
```

### 控制台在线更新

本 fork 的后台更新检查仍指向 `yukkcat/chatgpt2api` 的 Release。要保留自己的修改，请使用下方镜像升级流程，不要从后台安装上游更新包。分支自动构建只发布镜像，不生成后台在线更新包。

使用当前标准 Compose 部署时，版本弹窗可直接启动在线更新。后端负责下载发布包、校验 SHA-256 与更新清单、替换运行文件、同步依赖和安排容器重启；前端只展示后端任务，刷新页面或重启完成后仍可恢复任务结果。文件或依赖同步失败时会恢复旧文件，并按旧锁文件重新同步依赖。

源码运行和没有挂载受管 `/app` 运行目录的旧容器不会显示“立即更新”，只会给出 Git 或镜像升级提示。首次切换到受管运行目录时，应先更新仓库中的 Compose 文件，再执行一次镜像升级：

```bash
git pull --ff-only
docker compose pull
docker compose up -d
```

不要把 `/app` 运行时卷当作业务备份；它可以从发布镜像重新创建。不要使用 `docker compose down -v` 执行普通升级，因为该命令还会删除 Compose 管理的命名卷。

### 命令行升级

镜像部署升级：

```bash
git pull --ff-only
docker compose pull
docker compose up -d
docker compose ps
docker compose logs --tail=100 app
```

在 fork 的 `main` 推送并等待 Docker 工作流成功后，再执行以上命令。`git pull` 更新服务器上的 Compose 等文件，`pull` 拉镜像，`up -d` 重建应用容器；仅重启旧容器不会拉取新代码。若已维护自己的 Compose 配置，应先检查差异再更新文件。

本地 PostgreSQL Compose 部署升级：

```bash
docker compose -f docker-compose.yml -f docker-compose.postgres.yml pull
docker compose -f docker-compose.yml -f docker-compose.postgres.yml up -d
```

镜像部署固定或回退版本时，在 `.env` 设置 `CHATGPT2API_IMAGE=ghcr.io/itxy1024/chatgpt2api:sha-<完整提交SHA>`（或已发布的版本标签），再执行对应的 `pull` 与 `up`。镜像构建标识变化后，入口脚本会用该镜像刷新受管运行目录；Git 检出标签只影响源码运行，不会改变 Compose 使用的镜像版本。回退镜像不会回退数据库，涉及数据结构变化时还需恢复对应备份。升级后检查：

```bash
docker compose ps
docker logs -f chatgpt2api
```

## 回滚与维护

先停止对应 Compose，再恢复经过验证的代码 / 镜像和备份数据；不要在运行时直接覆盖 `data/`。常用命令：

```bash
docker compose restart
docker compose down
```

`docker image prune` 只清理未使用镜像，不会替代数据备份。
