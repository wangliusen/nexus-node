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
    cron \\
    bash \\
    jq \\
    && rm -rf /var/lib/apt/lists/*

RUN curl -sSL https://cli.nexus.xyz/ | bash && \\
    cp /root/.nexus/bin/nexus-network /usr/local/bin/nexus-network && \\
    chmod +x /usr/local/bin/nexus-network

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
EOF

    cat > entrypoint.sh <<'EOF'
#!/bin/bash
set -e

PROVER_ID_FILE="/root/.nexus/node-id"
LOG_FILE="/root/nexus.log"

# 确保日志文件存在且可写
mkdir -p "$(dirname "$PROVER_ID_FILE")"
touch "$LOG_FILE" && chmod 644 "$LOG_FILE"

echo "$NODE_ID" > "$PROVER_ID_FILE"
echo "使用的 node-id: $NODE_ID"

[ -n "$NEXUS_LOG" ] && LOG_FILE="$NEXUS_LOG"
[ -n "$SCREEN_NAME" ] || SCREEN_NAME="nexus"

if ! command -v nexus-network >/dev/null 2>&1; then
    echo "nexus-network 未安装"
    exit 1
fi

screen -S "$SCREEN_NAME" -X quit >/dev/null 2>&1 || true

echo "启动 nexus-network..."
screen -dmS "$SCREEN_NAME" bash -c "nexus-network start --node-id $NODE_ID &>> $LOG_FILE"

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

    for i in $(seq 1 "$INSTANCE_COUNT"); do
    read -rp "请输入第 $i 个实例的 node-id: " NODE_ID
    CONTAINER_NAME="nexus-node-$i"
    LOG_FILE="/root/nexus-$i.log"
    SCREEN_NAME="nexus-$i"

    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

    # ✅ 插入这段日志路径修复
    if [ -d "$LOG_FILE" ]; then
        echo "⚠️ $LOG_FILE 是目录，正在删除并重新创建为空日志文件..."
        rm -rf "$LOG_FILE"
        touch "$LOG_FILE"
        chmod 644 "$LOG_FILE"
    elif [ ! -f "$LOG_FILE" ]; then
        touch "$LOG_FILE"
        chmod 644 "$LOG_FILE"
    fi

    docker run -d \
        --name "$CONTAINER_NAME" \
        -e NODE_ID="$NODE_ID" \
        -e NEXUS_LOG="$LOG_FILE" \
        -e SCREEN_NAME="$SCREEN_NAME" \
        -v "$LOG_FILE":"$LOG_FILE" \
        "$IMAGE_NAME"

    echo "✅ 启动成功：$CONTAINER_NAME"
done

}

function stop_all_instances() {
    echo "🛑 停止所有 Nexus 实例..."
    docker ps -a --format '{{.Names}}' | grep '^nexus-node-' | while read -r name; do
        docker rm -f "$name" >/dev/null 2>&1 && echo "停止 $name"
    done
}

function restart_instance() {
    read -rp "请输入实例编号（如 2 表示 nexus-node-2）: " idx
    CONTAINER_NAME="nexus-node-$idx"
    LOG_FILE="/root/nexus-$idx.log"
    SCREEN_NAME="nexus-$idx"

    NODE_ID=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$CONTAINER_NAME" 2>/dev/null | grep NODE_ID= | cut -d= -f2)
    [ -z "$NODE_ID" ] && echo "❌ 未找到实例或 ID" && return

    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1
    docker run -d \
        --name "$CONTAINER_NAME" \
        -e NODE_ID="$NODE_ID" \
        -e NEXUS_LOG="$LOG_FILE" \
        -e SCREEN_NAME="$SCREEN_NAME" \
        -v "$LOG_FILE":"$LOG_FILE" \
        "$IMAGE_NAME"
    echo "✅ 已重启：$CONTAINER_NAME"
}

function change_node_id() {
    read -rp "请输入要更换的实例编号: " idx
    read -rp "请输入新的 node-id: " NEW_ID
    [ -z "$NEW_ID" ] && echo "❌ node-id 不能为空" && return

    CONTAINER_NAME="nexus-node-$idx"
    LOG_FILE="/root/nexus-$idx.log"
    SCREEN_NAME="nexus-$idx"

    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1
    docker run -d \
        --name "$CONTAINER_NAME" \
        -e NODE_ID="$NEW_ID" \
        -e NEXUS_LOG="$LOG_FILE" \
        -e SCREEN_NAME="$SCREEN_NAME" \
        -v "$LOG_FILE":"$LOG_FILE" \
        "$IMAGE_NAME"

    echo "✅ 实例 $CONTAINER_NAME 已使用新 ID 启动"
}

function add_one_instance() {
    NEXT_NUM=1
    while docker ps -a --format '{{.Names}}' | grep -qw "nexus-node-$NEXT_NUM"; do
        ((NEXT_NUM++))
    done

    read -rp "请输入新实例的 node-id: " NODE_ID
    CONTAINER_NAME="nexus-node-$NEXT_NUM"
    LOG_FILE="/root/nexus-$NEXT_NUM.log"
    SCREEN_NAME="nexus-$NEXT_NUM"

    # 确保日志文件存在且可写
    if [ -d "$LOG_FILE" ]; then
        echo "⚠️ $LOG_FILE 是目录，正在删除并重新创建为空日志文件..."
        rm -rf "$LOG_FILE"
    fi
    
    touch "$LOG_FILE" && chmod 644 "$LOG_FILE"
    if [ $? -ne 0 ]; then
        echo "❌ 无法创建日志文件 $LOG_FILE，请检查权限"
        return 1
    fi

    docker run -d \
        --name "$CONTAINER_NAME" \
        -e NODE_ID="$NODE_ID" \
        -e NEXUS_LOG="$LOG_FILE" \
        -e SCREEN_NAME="$SCREEN_NAME" \
        -v "$LOG_FILE":"$LOG_FILE" \
        "$IMAGE_NAME"

    echo "✅ 添加实例成功：$CONTAINER_NAME"
    echo "日志文件路径: $LOG_FILE"
}

function view_logs() {
    read -rp "请输入实例编号: " idx
    LOG_FILE="/root/nexus-$idx.log"
    [ ! -f "$LOG_FILE" ] && echo "❌ 日志不存在" && return
    tail -f "$LOG_FILE"
}

function show_running_ids() {
    echo "📋 当前正在运行的实例及 ID："
    docker ps --format '{{.Names}}' | grep '^nexus-node-' | while read -r name; do
        ID=$(docker exec "$name" cat /root/.nexus/node-id 2>/dev/null)
        echo "$name: $ID"
    done
}
function setup_rotation_schedule() {
    echo "📦 正在部署 ID 自动轮换配置..."

    # 写入配置文件
    cat > /root/nexus-id-config.json <<EOF
{
  "nexus-node-1": ["5506144", "5527605", "5529708", "4911"],
  "nexus-node-2": ["5506140", "5452629", "5439291", "4273838"]
}
EOF

    # 初始化状态文件
    cat > /root/nexus-id-state.json <<EOF
{
  "nexus-node-1": 0,
  "nexus-node-2": 0
}
EOF

    # 写入轮换脚本
    cat > /root/nexus-rotate.sh <<'EOS'
#!/bin/bash
CONFIG=/root/nexus-id-config.json
STATE=/root/nexus-id-state.json

function get_next_index() {
    local current=$1
    local max=$2
    echo $(((current + 1) % max))
}

[ ! -f "$STATE" ] && cp "$CONFIG" "$STATE" && sed -i 's/\[.*\]/0/g' "$STATE"

for INSTANCE in $(jq -r 'keys[]' "$CONFIG"); do
    IDS=($(jq -r ".\"$INSTANCE\"[]" "$CONFIG"))
    CURRENT_INDEX=$(jq -r ".\"$INSTANCE\"" "$STATE")
    NEXT_INDEX=$(get_next_index "$CURRENT_INDEX" "${#IDS[@]}")
    NEW_ID=${IDS[$NEXT_INDEX]}

    echo "[$(date)] $INSTANCE 使用新的 node-id: $NEW_ID"

    docker rm -f "$INSTANCE" >/dev/null 2>&1
    docker run -d \
        --name "$INSTANCE" \
        -e NODE_ID="$NEW_ID" \
        -e NEXUS_LOG="/root/${INSTANCE//nexus-node-/nexus-}.log" \
        -e SCREEN_NAME="${INSTANCE//nexus-node-/nexus-}" \
        -v "/root/${INSTANCE//nexus-node-/nexus-}.log":"/root/${INSTANCE//nexus-node-/nexus-}.log" \
        nexus-node:latest

    jq ".\"$INSTANCE\" = $NEXT_INDEX" "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
done
EOS

    chmod +x /root/nexus-rotate.sh

    # 加入 crontab，每 2 小时执行一次
    (crontab -l 2>/dev/null; echo "0 */2 * * * /root/nexus-rotate.sh >> /root/nexus-rotate.log 2>&1") | crontab -

    echo "✅ 自动轮换计划已部署！每 2 小时轮换一次 node-id"
}

function show_menu() {
    while true; do
        echo ""
        echo "=========== Nexus 节点管理 ==========="
        echo "1. 构建并启动新实例"
        echo "2. 停止所有实例"
        echo "3. 重启指定实例"
        echo "4. 查看运行中的实例及 ID"
        echo "5. 退出"
        echo "6. 更换某个实例的 node-id（并自动重启）"
        echo "7. 添加一个新实例"
        echo "8. 查看指定实例日志"
        echo "9. 一键部署自动 ID 轮换计划（每 2 小时）"
        echo "======================================"
        read -rp "请选择操作 (1-9): " choice
        case "$choice" in
            1) check_docker; prepare_build_files; build_image; start_instances ;;
            2) stop_all_instances ;;
            3) restart_instance ;;
            4) show_running_ids ;;
            5) echo "退出"; exit 0 ;;
            6) change_node_id ;;
            7) add_one_instance ;;
            8) view_logs ;;
            9) setup_rotation_schedule ;;
            *) echo "无效选项，请输入 1-9" ;;
        esac
    done
}

# 启动菜单
show_menu
