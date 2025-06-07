#!/bin/bash
set -e

IMAGE_NAME="nexus-node:latest"
BUILD_DIR="/root/nexus-docker"

function check_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        echo "Docker 未安装，正在安装..."
        apt update
        apt install -y apt-transport-https ca-certificates curl software-properties-common
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
        add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
        apt update
        apt install -y docker-ce
        systemctl enable docker
        systemctl start docker
    fi
}

function prepare_build_files() {
    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR"

    cat > Dockerfile <<EOF
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \\
    curl \\
    screen \\
    bash \\
    cron \\
    jq \\
    && rm -rf /var/lib/apt/lists/*

RUN curl -sSL https://cli.nexus.xyz/ | bash
RUN ln -sf /root/.nexus/bin/nexus-network /usr/local/bin/nexus-network

COPY entrypoint.sh /entrypoint.sh
COPY change-id.sh /change-id.sh
RUN chmod +x /entrypoint.sh /change-id.sh

ENTRYPOINT ["/entrypoint.sh"]
EOF

    cat > entrypoint.sh <<'EOF'
#!/bin/bash
set -e

PROVER_ID_FILE="/root/.nexus/node-id"
LOG_FILE="/root/nexus.log"
ID_CONFIG_FILE="/root/.nexus/id_config.json"

mkdir -p "$(dirname "$PROVER_ID_FILE")"
echo "$INITIAL_ID" > "$PROVER_ID_FILE"
echo "初始 node-id: $INITIAL_ID"

# 创建ID配置文件
if [ -n "$ID_LIST" ]; then
    mkdir -p "$(dirname "$ID_CONFIG_FILE")"
    echo "$ID_LIST" | jq '.' > "$ID_CONFIG_FILE"
fi

[ -n "$NEXUS_LOG" ] && LOG_FILE="$NEXUS_LOG"
[ -n "$SCREEN_NAME" ] || SCREEN_NAME="nexus"

if ! command -v nexus-network >/dev/null 2>&1; then
    echo "nexus-network 未安装"
    exit 1
fi

# 设置定时任务自动更换ID
if [ -n "$AUTO_CHANGE_ID" ]; then
    echo "设置每2小时自动更换ID..."
    (crontab -l 2>/dev/null; echo "0 */2 * * * /change-id.sh \"$SCREEN_NAME\" \"$LOG_FILE\"") | crontab -
    service cron start
fi

screen -S "$SCREEN_NAME" -X quit >/dev/null 2>&1 || true

echo "启动 nexus-network..."
screen -dmS "$SCREEN_NAME" bash -c "nexus-network start --node-id $INITIAL_ID &>> $LOG_FILE"

sleep 3

if screen -list | grep -q "$SCREEN_NAME"; then
    echo "实例 [$SCREEN_NAME] 已启动，日志文件：$LOG_FILE"
else
    echo "启动失败：$SCREEN_NAME"
    cat "$LOG_FILE"
    exit 1
fi

tail -f "$LOG_FILE"
EOF

    cat > change-id.sh <<'EOF'
#!/bin/bash
set -e

SCREEN_NAME="$1"
LOG_FILE="$2"
ID_CONFIG_FILE="/root/.nexus/id_config.json"
CURRENT_INDEX_FILE="/root/.nexus/current_id_index"

if [ ! -f "$ID_CONFIG_FILE" ]; then
    echo "$(date) - 错误：找不到ID配置文件" >> "$LOG_FILE"
    exit 1
fi

# 读取当前索引
CURRENT_INDEX=0
if [ -f "$CURRENT_INDEX_FILE" ]; then
    CURRENT_INDEX=$(cat "$CURRENT_INDEX_FILE")
fi

# 计算下一个索引
ID_COUNT=$(jq '.ids | length' "$ID_CONFIG_FILE")
NEXT_INDEX=$(( (CURRENT_INDEX + 1) % ID_COUNT ))

# 获取下一个ID
NEW_ID=$(jq -r ".ids[$NEXT_INDEX]" "$ID_CONFIG_FILE")

# 更新索引
echo "$NEXT_INDEX" > "$CURRENT_INDEX_FILE"

echo "$(date) - 自动更换ID为: $NEW_ID" >> "$LOG_FILE"

# 停止当前实例
screen -S "$SCREEN_NAME" -X quit >/dev/null 2>&1 || true

# 启动新实例
screen -dmS "$SCREEN_NAME" bash -c "nexus-network start --node-id $NEW_ID &>> $LOG_FILE"

# 更新node-id文件
echo "$NEW_ID" > /root/.nexus/node-id
EOF
}

function build_image() {
    cd "$BUILD_DIR"
    docker build -t "$IMAGE_NAME" .
}

function start_instances() {
    read -rp "请输入要创建的实例数量: " INSTANCE_COUNT

    if ! [[ "$INSTANCE_COUNT" =~ ^[0-9]+$ ]] || [ "$INSTANCE_COUNT" -lt 1 ]; then
        echo "无效数量。请输入正整数。"
        exit 1
    fi

    read -rp "是否启用每2小时自动更换ID? (y/n): " ENABLE_AUTO_CHANGE
    AUTO_CHANGE_FLAG=""
    if [[ "$ENABLE_AUTO_CHANGE" =~ ^[Yy]$ ]]; then
        AUTO_CHANGE_FLAG="yes"
    fi

    for i in $(seq 1 "$INSTANCE_COUNT"); do
        CONTAINER_NAME="nexus-node-$i"
        LOG_FILE="/root/nexus-$i.log"
        SCREEN_NAME="nexus-$i"

        echo -e "\n准备实例 $i 的配置: $CONTAINER_NAME"
        
        # 为每个实例输入4个专属ID
        ID_ARRAY=()
        for j in {1..4}; do
            read -rp "请输入第 $j 个ID: " ID
            ID_ARRAY+=("\"$ID\"")
        done
        
        # 创建JSON格式的ID列表
        ID_LIST_JSON="{\"ids\":[$(IFS=,; echo "${ID_ARRAY[*]}")]}"
        INITIAL_ID=$(echo "$ID_LIST_JSON" | jq -r '.ids[0]')

        echo "正在启动实例：$CONTAINER_NAME"
        echo "初始ID: $INITIAL_ID"
        echo "ID列表: $(echo "$ID_LIST_JSON" | jq -c .)"

        docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
        
        if [ -d "$LOG_FILE" ]; then
            echo "⚠️ 检测到日志路径是目录，正在删除并重建为文件：$LOG_FILE"
            rm -rf "$LOG_FILE"
            touch "$LOG_FILE"
            chmod 644 "$LOG_FILE"
        elif [ ! -f "$LOG_FILE" ]; then
            touch "$LOG_FILE"
            chmod 644 "$LOG_FILE"
        fi

        docker run -d \
            --name "$CONTAINER_NAME" \
            -e INITIAL_ID="$INITIAL_ID" \
            -e ID_LIST="$ID_LIST_JSON" \
            -e NEXUS_LOG="$LOG_FILE" \
            -e SCREEN_NAME="$SCREEN_NAME" \
            -e AUTO_CHANGE_ID="$AUTO_CHANGE_FLAG" \
            -v "$LOG_FILE":"$LOG_FILE" \
            "$IMAGE_NAME"

        echo "✅ 启动成功：$CONTAINER_NAME"
    done
}

function stop_all_instances() {
    echo "🛑 正在停止所有 nexus-node-* 容器..."
    docker ps -a --format '{{.Names}}' | grep '^nexus-node-' | while read -r name; do
        echo "停止 $name"
        docker rm -f "$name" >/dev/null 2>&1 || true
    done
    echo "✅ 所有实例已停止。"
}

function restart_instance() {
    read -rp "请输入要重启的实例编号（例如 3 表示 nexus-node-3）: " idx
    CONTAINER_NAME="nexus-node-$idx"
    LOG_FILE="/root/nexus-$idx.log"
    SCREEN_NAME="nexus-$idx"

    echo "正在重启实例 $CONTAINER_NAME..."

    INITIAL_ID=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$CONTAINER_NAME" 2>/dev/null | grep INITIAL_ID= | cut -d= -f2)
    ID_LIST_JSON=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$CONTAINER_NAME" 2>/dev/null | grep ID_LIST= | cut -d= -f2)
    AUTO_CHANGE_FLAG=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$CONTAINER_NAME" 2>/dev/null | grep AUTO_CHANGE_ID= | cut -d= -f2)

    if [ -z "$INITIAL_ID" ]; then
        echo "❌ 找不到实例或配置信息，可能未运行或未创建。"
        return
    fi

    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

    docker run -d \
        --name "$CONTAINER_NAME" \
        -e INITIAL_ID="$INITIAL_ID" \
        -e ID_LIST="$ID_LIST_JSON" \
        -e NEXUS_LOG="$LOG_FILE" \
        -e SCREEN_NAME="$SCREEN_NAME" \
        -e AUTO_CHANGE_ID="$AUTO_CHANGE_FLAG" \
        -v "$LOG_FILE":"$LOG_FILE" \
        "$IMAGE_NAME"

    echo "✅ 已重启：$CONTAINER_NAME"
}

function show_running_ids() {
    echo "🔍 正在查询所有运行中的 Nexus 实例及 ID 信息..."
    docker ps --format '{{.Names}}' | grep '^nexus-node-' | while read -r name; do
        CURRENT_ID=$(docker exec "$name" cat /root/.nexus/node-id 2>/dev/null || echo "未知")
        CURRENT_INDEX=$(docker exec "$name" cat /root/.nexus/current_id_index 2>/dev/null || echo "0")
        ID_COUNT=$(docker exec "$name" jq '.ids | length' /root/.nexus/id_config.json 2>/dev/null || echo "0")
        
        echo "实例: $name"
        echo "  当前ID: $CURRENT_ID"
        echo "  当前索引: $CURRENT_INDEX/$((ID_COUNT-1))"
        echo "  ID列表: $(docker exec "$name" jq -c '.ids' /root/.nexus/id_config.json 2>/dev/null || echo "未知")"
        echo "----------------------------------------"
    done
}

function change_node_id() {
    read -rp "请输入要更换的实例编号（例如 2 表示 nexus-node-2）：" idx
    CONTAINER_NAME="nexus-node-$idx"
    LOG_FILE="/root/nexus-$idx.log"
    SCREEN_NAME="nexus-$idx"

    if ! docker ps -a --format '{{.Names}}' | grep -qw "$CONTAINER_NAME"; then
        echo "❌ 实例 $CONTAINER_NAME 不存在。"
        return
    fi

    # 显示当前ID列表
    echo "当前ID列表:"
    docker exec "$CONTAINER_NAME" jq '.ids' /root/.nexus/id_config.json

    read -rp "请输入要切换到的ID索引 (0-3): " NEW_INDEX
    if ! [[ "$NEW_INDEX" =~ ^[0-3]$ ]]; then
        echo "❌ 无效索引，请输入0-3之间的数字"
        return
    fi

    NEW_ID=$(docker exec "$CONTAINER_NAME" jq -r ".ids[$NEW_INDEX]" /root/.nexus/id_config.json)

    echo "🔁 正在更换 $CONTAINER_NAME 的 node-id 为索引[$NEW_INDEX]: $NEW_ID"

    # 更新索引文件
    docker exec "$CONTAINER_NAME" bash -c "echo $NEW_INDEX > /root/.nexus/current_id_index"

    # 重启容器使更改生效
    docker restart "$CONTAINER_NAME" >/dev/null

    echo "✅ 实例 $CONTAINER_NAME 已切换至新ID"
}

function add_one_instance() {
    NEXT_NUM=1
    while docker ps -a --format '{{.Names}}' | grep -qw "nexus-node-$NEXT_NUM"; do
        ((NEXT_NUM++))
    done

    CONTAINER_NAME="nexus-node-$NEXT_NUM"
    LOG_FILE="/root/nexus-$NEXT_NUM.log"
    SCREEN_NAME="nexus-$NEXT_NUM"

    echo -e "\n准备新实例 $NEXT_NUM 的配置: $CONTAINER_NAME"
    
    # 为实例输入4个专属ID
    ID_ARRAY=()
    for j in {1..4}; do
        read -rp "请输入第 $j 个ID: " ID
        ID_ARRAY+=("\"$ID\"")
    done
    
    # 创建JSON格式的ID列表
    ID_LIST_JSON="{\"ids\":[$(IFS=,; echo "${ID_ARRAY[*]}")]}"
    INITIAL_ID=$(echo "$ID_LIST_JSON" | jq -r '.ids[0]')

    read -rp "是否启用每2小时自动更换ID? (y/n): " ENABLE_AUTO_CHANGE
    AUTO_CHANGE_FLAG=""
    if [[ "$ENABLE_AUTO_CHANGE" =~ ^[Yy]$ ]]; then
        AUTO_CHANGE_FLAG="yes"
    fi

    echo "正在启动实例：$CONTAINER_NAME"
    echo "初始ID: $INITIAL_ID"
    echo "ID列表: $(echo "$ID_LIST_JSON" | jq -c .)"

    docker run -d \
        --name "$CONTAINER_NAME" \
        -e INITIAL_ID="$INITIAL_ID" \
        -e ID_LIST="$ID_LIST_JSON" \
        -e NEXUS_LOG="$LOG_FILE" \
        -e SCREEN_NAME="$SCREEN_NAME" \
        -e AUTO_CHANGE_ID="$AUTO_CHANGE_FLAG" \
        -v "$LOG_FILE":"$LOG_FILE" \
        "$IMAGE_NAME"

    echo "✅ 新实例 $CONTAINER_NAME 已启动，日志：$LOG_FILE"
}

function view_logs() {
    read -rp "请输入实例编号（例如 2 表示 nexus-node-2）: " idx
    LOG_FILE="/root/nexus-$idx.log"

    if [ ! -f "$LOG_FILE" ]; then
        echo "❌ 日志文件 $LOG_FILE 不存在。"
        return
    fi

    echo "📄 正在实时查看日志：$LOG_FILE"
    tail -f "$LOG_FILE"
}

function show_menu() {
    while true; do
        echo ""
        echo "=========== Nexus 节点管理 ==========="
        echo "1. 构建并启动新实例"
        echo "2. 停止所有实例"
        echo "3. 重启指定实例"
        echo "4. 查看运行中的实例及ID信息"
        echo "5. 手动切换实例的ID"
        echo "6. 添加一个新实例"
        echo "7. 查看指定实例日志"
        echo "8. 退出"
        echo "======================================"
        read -rp "请选择操作 (1-8): " choice
        case "$choice" in
            1) check_docker; prepare_build_files; build_image; start_instances ;;
            2) stop_all_instances ;;
            3) restart_instance ;;
            4) show_running_ids ;;
            5) change_node_id ;;
            6) add_one_instance ;;
            7) view_logs ;;
            8) echo "已退出"; exit 0 ;;
            *) echo "无效选择";;
        esac
    done
}

show_menu

