#!/bin/bash

MAX_ATTEMPTS=1
TIMEOUT=60
IMAGE="library/nginx:alpine"
OUTPUT_CSV="/tmp/registry_speed.csv"

# 生成官方镜像的digest，方便后续对比完整性
docker pull docker.io/$IMAGE > /dev/null 2>&1
official_digest=$(docker inspect --format='{{index .RepoDigests 0}}' docker.io/$IMAGE | cut -d'@' -f2)

# 输出 CSV 表头
echo "Registry,Status,Speed,Time,Integrity" > "$OUTPUT_CSV"

# 解析接口，提取在线的registry url的域名部分
# 使用jq解析json，需要先确保环境有jq
# registries=$(curl -s 'https://status.anye.xyz/status.json' | jq -r '.[] | select(.status=="online") | .url' | sed -E 's#https?://([^/]+).*#\1#')
# 获取在线且不含“需登陆”标签的registry域名
registries=$(curl -s 'https://status.anye.xyz/status.json' | jq -r '
  .[] |
  select(.status=="online") |
  select((.tags[]?.name | contains("需登陆") | not)) |
  .url
' | sed -E 's#https?://([^/]+).*#\1#')

if [ -z "$registries" ]; then
  echo "未获取到可用的在线 Registry 列表，退出."
  exit 1
fi

# 测试单个 registry 函数
test_registry() {
  local registry="$1"
  local attempt=1
  local output
  output=$(mktemp)

  while [ $attempt -le $MAX_ATTEMPTS ]; do
    echo "尝试第 $attempt 次，测试 Registry: $registry"
    # 拉取镜像并计时
    if timeout ${TIMEOUT}s bash -c "time docker pull $registry/$IMAGE" > "$output" 2>&1; then
      status="Good"
      # 获取 real 时间，格式如 0m3.008s 转换为秒数
      pull_time=$(grep real "$output" | awk '{print $2}' | sed 's/0m//;s/s//')
      # 获取镜像大小 MB
      image_size=$(docker image inspect -f '{{.Size}}' $registry/$IMAGE 2>/dev/null | awk '{print $1/1024/1024}')
      # 计算速度 MB/s 保留两位小数
      speed=$(echo "scale=2; $image_size / $pull_time" | bc 2>/dev/null || echo "0")
      # 获取该镜像的digest与官方对比
      registry_digest=$(docker inspect --format='{{index .RepoDigests 0}}' $registry/$IMAGE 2>/dev/null | cut -d'@' -f2 || echo "")
      if [ "$official_digest" = "$registry_digest" ] && [ -n "$registry_digest" ]; then
        integrity="✅ Verified"
      else
        integrity="❌ Mismatch"
      fi

      echo "$registry,$status,${speed} MB/s,${pull_time}s,$integrity" >> "$OUTPUT_CSV"
      rm -f "$output"
      return 0
    else
      echo "Registry $registry 第 $attempt 次尝试失败。"
      attempt=$((attempt + 1))
      sleep 5
    fi
  done

  # 全部尝试失败
  status="Failed"
  echo "$registry,❌ $status,-,-,-" >> "$OUTPUT_CSV"
  rm -f "$output"
  return 1
}

# 清理本地拉取镜像，避免重复
docker rmi -f $IMAGE > /dev/null 2>&1 || true

for registry in $registries; do
  docker rmi -f $registry/$IMAGE > /dev/null 2>&1 || true
  test_registry "$registry"
  docker rmi -f $registry/$IMAGE > /dev/null 2>&1 || true
done

docker rmi -f docker.io/$IMAGE > /dev/null 2>&1 || true

echo "测试完成，结果输出到 $OUTPUT_CSV"
