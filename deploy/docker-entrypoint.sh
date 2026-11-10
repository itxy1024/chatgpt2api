#!/bin/sh
set -eu

seed_root=/opt/chatgpt2api
runtime_root=/app
marker_name=.chatgpt2api-image-version
seed_version="$(tr -d '\r\n' < "${seed_root}/VERSION")"
seed_revision="${seed_version}"
if [ -s "${seed_root}/.image-revision" ]; then
  seed_revision="$(tr -d '\r\n' < "${seed_root}/.image-revision")"
fi
installed_image_version=""

if [ -f "${runtime_root}/${marker_name}" ]; then
  installed_image_version="$(tr -d '\r\n' < "${runtime_root}/${marker_name}")"
fi

# 构建提交变化时刷新代码；同一镜像重启仍保留控制台在线更新的文件。
if [ ! -f "${runtime_root}/VERSION" ] || [ "${installed_image_version}" != "${seed_revision}" ]; then
  mkdir -p "${runtime_root}"
  find "${runtime_root}" -mindepth 1 -maxdepth 1 \
    ! -name data \
    ! -name config.json \
    ! -name .venv \
    ! -name "${marker_name}" \
    -exec rm -rf -- {} +

  for source in "${seed_root}"/* "${seed_root}"/.[!.]* "${seed_root}"/..?*; do
    [ -e "${source}" ] || continue
    [ "$(basename "${source}")" = ".venv" ] && continue
    cp -a "${source}" "${runtime_root}/"
  done

  marker_tmp="${runtime_root}/${marker_name}.tmp"
  printf '%s\n' "${seed_revision}" > "${marker_tmp}"
  mv "${marker_tmp}" "${runtime_root}/${marker_name}"
fi

cd "${runtime_root}"
uv sync --frozen --no-dev --no-install-project
exec "$@"
