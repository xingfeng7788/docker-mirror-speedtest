#!/bin/bash

MAX_ATTEMPTS=1
TIMEOUT=60
IMAGE_PATH="library/nginx:alpine"
OFFICIAL_IMAGE="docker.io/library/nginx:alpine"
OUTPUT_CSV="/tmp/registry_speed.csv"

docker pull $OFFICIAL_IMAGE > /dev/null 2>&1
official_digest=$(docker inspect --format='{{index .RepoDigests 0}}' $OFFICIAL_IMAGE | cut -d'@' -f2)

echo "Registry,Status,Speed,Time,Integrity" > "$OUTPUT_CSV"

# 获取在线且不含"需登陆"标签的registry域名
registries=$(curl -s 'https://status.anye.xyz/status.json' | jq -r '
  .[] |
  select(.status=="online") |
  select((.tags[]?.name | contains("需登陆") | not)) |
  .url
' | sed -E 's#https?://([^/]+).*#\1#')

if [ -z "$registries" ]; then
  echo "未获取到可用的在线 Registry 列表，退出。"
  exit 1
fi
test_registry() {
  local registry="$1"
  local attempt=1

  while [ $attempt -le $MAX_ATTEMPTS ]; do
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 测试 $registry 第 $attempt 次尝试"
    
    start=$(date +%s)
    if docker pull $registry/$IMAGE_PATH > /dev/null 2>&1; then
      end=$(date +%s)
      pull_time=$((end - start))

      image_size=$(docker image inspect -f '{{.Size}}' $registry/$IMAGE_PATH 2>/dev/null)
      if [ -n "$image_size" ]; then
        image_size_mb=$(awk "BEGIN {printf \"%.2f\", $image_size/1024/1024}")
        speed=$(awk "BEGIN {printf \"%.2f\", $image_size_mb / $pull_time}")
      else
        speed=0
      fi

      registry_digest=$(docker inspect --format='{{index .RepoDigests 0}}' $registry/$IMAGE_PATH 2>/dev/null | cut -d'@' -f2 || echo "")
      if [ "$official_digest" = "$registry_digest" ] && [ -n "$registry_digest" ]; then
        integrity="Verified"
      else
        integrity="Mismatch"
      fi

      echo "$registry,Good,${speed} MB/s,${pull_time}s,$integrity" >> "$OUTPUT_CSV"
      return 0
    else
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] $registry 第 $attempt 次尝试失败。"
      attempt=$((attempt + 1))
      sleep 5
    fi
  done

  echo "$registry,Failed,-,-,-" >> "$OUTPUT_CSV"
  return 1
}

docker rmi -f $OFFICIAL_IMAGE > /dev/null 2>&1 || true

for r in $registries; do
  docker rmi -f $r/$IMAGE_PATH > /dev/null 2>&1 || true
  test_registry "$r"
  docker rmi -f $r/$IMAGE_PATH > /dev/null 2>&1 || true
done

docker rmi -f $OFFICIAL_IMAGE > /dev/null 2>&1 || true

echo "测试完成，结果输出到 $OUTPUT_CSV"
