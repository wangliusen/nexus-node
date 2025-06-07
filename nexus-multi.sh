#!/bin/bash
set -e

IMAGE_NAME="nexus-node:latest"
BUILD_DIR="/root/nexus-docker"

NODE_IDS=("5452629" "5529708")
CONTAINER_NAMES=("nexus-node-3" "nexus-node-4")
LOG_FILES=("/root/nexus-3.log" "/root/nexus-4.log")
SCREEN_NAMES=("nexus-3" "nexus-4")

function run_new_instances() {
    for i in "${!NODE_IDS[@]}"; do
        CONTAINER_NAME="${CONTAINER_NAMES[$i]}"
        NODE_ID="${NODE_IDS[$i]}"
        LOG_FILE="${LOG_FILES[$i]}"
        SCREEN_NAME="${SCREEN_NAMES[$i]}"

        echo "准备启动新实例：$CONTAINER_NAME (node-id=$NODE_ID)"

        docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
        [ ! -f "$LOG_FILE" ] && touch "$LOG_FILE" && chmod 644 "$LOG_FILE"

        docker run -d \
            --name "$CONTAINER_NAME" \
            -e NODE_ID="$NODE_ID" \
            -e NEXUS_LOG="$LOG_FILE" \
            -e SCREEN_NAME="$SCREEN_NAME" \
            -v "$LOG_FILE":"$LOG_FILE" \
            "$IMAGE_NAME"

        echo "已启动容器：$CONTAINER_NAME"
    done

    echo -e "\n新节点已启动。日志文件："
    for log in "${LOG_FILES[@]}"; do
        echo "  - $log"
    done
}

run_new_instances
