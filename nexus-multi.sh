!/bin/bash
set -e

IMAGE_NAME="nexus-node:latest"
BUILD_DIR="/root/nexus-docker"
LOG_DIR="/var/log/nexus"  # 集中管理日志的目录

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

function init_log_dir() {
    # 创建日志目录并设置适当权限
    mkdir -p "$LOG_DIR"
    chmod 755 "$LOG_DIR"
    if [ ! -w "$LOG_DIR" ]; then
        echo "❌ 无法写入日志目录 $LOG_DIR，请检查权限"
        return 1
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
    logrotate \\
    && rm -rf /var/lib/apt/lists/*

RUN curl -sSL https://cli.nexus.xyz/ | bash && \\
    cp /root/.nexus/bin/nexus-network /usr/local/bin/nexus-network && \\
    chmod +x /usr/local/bin/nexus-network

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# 添加日志轮转配置
COPY nexus-logrotate /etc/logrotate.d/nexus

ENTRYPOINT ["/entrypoint.sh"]
EOF

    cat > entrypoint.sh <<'EOF'
#!/bin/bash
set -e

PROVER_ID_FILE="/root/.nexus/node-id"
LOG_FILE="/var/log/nexus/nexus.log"

# 确保日志目录和文件存在且可写
mkdir -p "$(dirname "$PROVER_ID_FILE")" "$(dirname "$LOG_FILE")"
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

    # 添加日志轮转配置
    cat > nexus-logrotate <<'EOF'
/var/log/nexus/*.log {
    daily
    missingok
    rotate 7
    compress
    delaycompress
    notifempty
    copytruncate
}
EOF
}

function build_image() {
    cd "$BUILD_DIR"
    if ! docker build -t "$IMAGE_NAME" .; then
        echo "❌ 镜像构建失败"
        return 1
    fi
}

function prepare_log_file() {
    local log_file="$1"
    
    if [ -d "$log_file" ]; then
        echo "⚠️ $log_file 是目录，正在删除并重新创建为空日志文件..."
        rm -rf "$log_file"
    fi
    
    touch "$log_file" && chmod 644 "$log_file"
    if [ $? -ne 0 ]; then
        echo "❌ 无法创建日志文件 $log_file，请检查权限"
        return 1
    fi
}

function start_instances() {
    read -rp "请输入要创建的实例数量: " INSTANCE_COUNT
    if ! [[ "$INSTANCE_COUNT" =~ ^[0-9]+$ ]] || [ "$INSTANCE_COUNT" -lt 1 ]; then
        echo "无效数量。请输入正整数。"
        return 1
    fi

    init_log_dir || return 1

    for i in $(seq 1 "$INSTANCE_COUNT"); do
        read -rp "请输入第 $i 个实例的 node-id: " NODE_ID
        CONTAINER_NAME="nexus-node-$i"
        LOG_FILE="$LOG_DIR/nexus-$i.log"
        SCREEN_NAME="nexus-$i"

        docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

        prepare_log_file "$LOG_FILE" || continue

        if ! docker run -d \
            --name "$CONTAINER_NAME" \
            -e NODE_ID="$NODE_ID" \
            -e NEXUS_LOG="$LOG_FILE" \
            -e SCREEN_NAME="$SCREEN_NAME" \
            -v "$LOG_FILE":"$LOG_FILE" \
            -v "$LOG_DIR":"$LOG_DIR" \
            "$IMAGE_NAME"; then
            echo "❌ 启动容器 $CONTAINER_NAME 失败"
            continue
        fi

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
    LOG_FILE="$LOG_DIR/nexus-$idx.log"
    SCREEN_NAME="nexus-$idx"

    NODE_ID=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$CONTAINER_NAME" 2>/dev/null | grep NODE_ID= | cut -d= -f2)
    [ -z "$NODE_ID" ] && echo "❌ 未找到实例或 ID" && return 1

    prepare_log_file "$LOG_FILE" || return 1

    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1
    if ! docker run -d \
        --name "$CONTAINER_NAME" \
        -e NODE_ID="$NODE_ID" \
        -e NEXUS_LOG="$LOG_FILE" \
        -e SCREEN_NAME="$SCREEN_NAME" \
        -v "$LOG_FILE":"$LOG_FILE" \
        -v "$LOG_DIR":"$LOG_DIR" \
        "$IMAGE_NAME"; then
        echo "❌ 重启容器 $CONTAINER_NAME 失败"
        return 1
    fi

    echo "✅ 已重启：$CONTAINER_NAME"
}

function change_node_id() {
    read -rp "请输入要更换的实例编号: " idx
    read -rp "请输入新的 node-id: " NEW_ID
    [ -z "$NEW_ID" ] && echo "❌ node-id 不能为空" && return 1

    CONTAINER_NAME="nexus-node-$idx"
    LOG_FILE="$LOG_DIR/nexus-$idx.log"
    SCREEN_NAME="nexus-$idx"

    prepare_log_file "$LOG_FILE" || return 1

    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1
    if ! docker run -d \
        --name "$CONTAINER_NAME" \
        -e NODE_ID="$NEW_ID" \
        -e NEXUS_LOG="$LOG_FILE" \
        -e SCREEN_NAME="$SCREEN_NAME" \
        -v "$LOG_FILE":"$LOG_FILE" \
        -v "$LOG_DIR":"$LOG_DIR" \
        "$IMAGE_NAME"; then
        echo "❌ 启动容器 $CONTAINER_NAME 失败"
        return 1
    fi

    echo "✅ 实例 $CONTAINER_NAME 已使用新 ID 启动"
}

function add_one_instance() {
    NEXT_NUM=1
    while docker ps -a --format '{{.Names}}' | grep -qw "nexus-node-$NEXT_NUM"; do
        ((NEXT_NUM++))
    done

    read -rp "请输入新实例的 node-id: " NODE_ID
    CONTAINER_NAME="nexus-node-$NEXT_NUM"
    LOG_FILE="$LOG_DIR/nexus-$NEXT_NUM.log"
    SCREEN_NAME="nexus-$NEXT_NUM"

    init_log_dir || return 1
    prepare_log_file "$LOG_FILE" || return 1

    if ! docker run -d \
        --name "$CONTAINER_NAME" \
        -e NODE_ID="$NODE_ID" \
        -e NEXUS_LOG="$LOG_FILE" \
        -e SCREEN_NAME="$SCREEN_NAME" \
        -v "$LOG_FILE":"$LOG_FILE" \
        -v "$LOG_DIR":"$LOG_DIR" \
        "$IMAGE_NAME"; then
        echo "❌ 启动容器 $CONTAINER_NAME 失败"
        return 1
    fi

    echo "✅ 添加实例成功：$CONTAINER_NAME"
    echo "日志文件路径: $LOG_FILE"
}

function view_logs() {
    read -rp "请输入实例编号: " idx
    LOG_FILE="$LOG_DIR/nexus-$idx.log"
    [ ! -f "$LOG_FILE" ] && echo "❌ 日志不存在" && return 1
    tail -f "$LOG_FILE"
}

function show_running_ids() {
    echo "📋 当前正在运行的实例及 ID："
    docker ps --format '{{.Names}}' | grep '^nexus-node-' | while read -r name; do
        ID=$(docker exec "$name" cat /root/.nexus/node-id 2>/dev/null || echo "无法获取ID")
        echo "$name: $ID"
    done
}

function setup_rotation_schedule() {
    echo "📦 正在部署 ID 自动轮换配置..."
    init_log_dir || return 1

    # 检查配置文件是否已存在，避免覆盖
    if [ -f "/root/nexus-id-config.json" ]; then
        echo "⚠️ 配置文件 /root/nexus-id-config.json 已存在，将使用现有配置"
    else
        # 创建空的配置文件模板，让用户自己填写
        cat > /root/nexus-id-config.json <<'EOF'
{
  "nexus-node-1": ["请替换为您的node-id列表"],
  "nexus-node-2": ["请替换为您的node-id列表"]
}
EOF
        echo "✅ 已创建配置文件模板 /root/nexus-id-config.json"
        echo "请编辑此文件，替换为您自己的 node-id 列表"
    fi

    # 初始化状态文件（如果不存在）
    if [ ! -f "/root/nexus-id-state.json" ]; then
        cat > /root/nexus-id-state.json <<'EOF'
{
  "nexus-node-1": 0,
  "nexus-node-2": 0
}
EOF
        echo "✅ 已初始化状态文件 /root/nexus-id-state.json"
    fi

    # 写入轮换脚本
    cat > /root/nexus-rotate.sh <<'EOS'
#!/bin/bash
CONFIG=/root/nexus-id-config.json
STATE=/root/nexus-id-state.json
LOG_DIR="/var/log/nexus"

function get_next_index() {
    local current=$1
    local max=$2
    echo $(((current + 1) % max))
}

[ ! -f "$STATE" ] && echo "❌ 状态文件不存在" && exit 1
[ ! -f "$CONFIG" ] && echo "❌ 配置文件不存在" && exit 1

for INSTANCE in $(jq -r 'keys[]' "$CONFIG"); do
    IDS=($(jq -r ".\"$INSTANCE\"[]" "$CONFIG"))
    [ ${#IDS[@]} -eq 0 ] && continue
    
    CURRENT_INDEX=$(jq -r ".\"$INSTANCE\"" "$STATE")
    NEXT_INDEX=$(get_next_index "$CURRENT_INDEX" "${#IDS[@]}")
    NEW_ID=${IDS[$NEXT_INDEX]}

    echo "[$(date)] $INSTANCE 使用新的 node-id: $NEW_ID"

    docker rm -f "$INSTANCE" >/dev/null 2>&1
    docker run -d \
        --name "$INSTANCE" \
        -e NODE_ID="$NEW_ID" \
        -e NEXUS_LOG="$LOG_DIR/${INSTANCE//nexus-node-/nexus-}.log" \
        -e SCREEN_NAME="${INSTANCE//nexus-node-/nexus-}" \
        -v "$LOG_DIR/${INSTANCE//nexus-node-/nexus-}.log":"$LOG_DIR/${INSTANCE//nexus-node-/nexus-}.log" \
        -v "$LOG_DIR":"$LOG_DIR" \
        nexus-node:latest

    jq ".\"$INSTANCE\" = $NEXT_INDEX" "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
done
EOS

    chmod +x /root/nexus-rotate.sh

    # 加入 crontab，每 2 小时执行一次
    (crontab -l 2>/dev/null; echo "0 */2 * * * /root/nexus-rotate.sh >> /var/log/nexus/nexus-rotate.log 2>&1") | crontab -

    echo "✅ 自动轮换计划已部署！每 2 小时轮换一次 node-id"
    echo "请确保已正确编辑 /root/nexus-id-config.json 文件"
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
            1) check_docker; prepare_build_files; build_image && start_instances ;;
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
