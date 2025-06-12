#!/bin/bash
set -e

BASE_DIR="/root/nexus-node"
IMAGE_NAME="nexus-node:latest"
BUILD_DIR="$BASE_DIR/build"
LOG_DIR="$BASE_DIR/logs"
CONFIG_DIR="$BASE_DIR/config"

function init_dirs() {
    mkdir -p "$BUILD_DIR" "$LOG_DIR" "$CONFIG_DIR"
    chmod 777 "$LOG_DIR"
}

function check_docker() {
    [ -x "$(command -v docker)" ] || {
        echo "Docker 未安装，正在安装..."
        apt update
        apt install -y apt-transport-https ca-certificates curl software-properties-common
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
        add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
        apt update && apt install -y docker-ce
        systemctl enable docker && systemctl start docker
    }
}

function prepare_build_files() {
    init_dirs
    cd "$BUILD_DIR"

    cat > Dockerfile <<'EOF'
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    curl git build-essential pkg-config libssl-dev \
    clang libclang-dev cmake jq ca-certificates && \
    rm -rf /var/lib/apt/lists/*

RUN mkdir -p /root/.cargo && \
    echo -e '[source.crates-io]\nreplace-with = "ustc"\n[source.ustc]\nregistry = "https://mirrors.ustc.edu.cn/crates.io-index"' > /root/.cargo/config && \
    curl https://sh.rustup.rs -sSf | sh -s -- -y

WORKDIR /tmp
RUN git clone https://github.com/nexus-xyz/nexus-cli.git --depth 1 && \
    cd nexus-cli && \
    git checkout $(git describe --tags $(git rev-list --tags --max-count=1)) && \
    cd clients/cli && \
    bash -c "source /root/.cargo/env && cargo build --release" && \
    cp target/release/nexus-network /usr/local/bin/ && \
    chmod +x /usr/local/bin/nexus-network

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
EOF

    cat > entrypoint.sh <<'EOF'
#!/bin/bash
set -e

if [ -z "$NODE_ID" ]; then
    echo "❌ 必须设置 NODE_ID 环境变量" >&2
    exit 1
fi

LOG_FILE="/nexus-data/nexus-${NODE_ID}.log"
mkdir -p /nexus-data
touch "$LOG_FILE"
echo "▶️ 启动 Nexus 节点 ID: $NODE_ID，日志记录至 $LOG_FILE"
exec nexus-network start --node-id "$NODE_ID" >> "$LOG_FILE" 2>&1
EOF

    chmod +x entrypoint.sh
}

function build_image() {
    cd "$BUILD_DIR"
    echo "🔧 开始构建 Docker 镜像..."
    docker build --no-cache -t "$IMAGE_NAME" . || {
        echo "❌ 镜像构建失败" >&2
        exit 1
    }
    echo "✅ 镜像构建完成"
}

function validate_node_id() {
    [[ "$1" =~ ^[0-9]+$ ]] || {
        echo "❌ node-id 必须是数字" >&2
        return 1
    }
    return 0
}

function start_instances() {
    init_dirs

    read -rp "请输入要创建的实例数量: " INSTANCE_COUNT
    [[ "$INSTANCE_COUNT" =~ ^[0-9]+$ ]] || { echo "❌ 请输入有效数字" >&2; exit 1; }

    for i in $(seq 1 "$INSTANCE_COUNT"); do
        while true; do
            read -rp "请输入第 $i 个实例的 node-id: " NODE_ID
            validate_node_id "$NODE_ID" && break
        done

        CONTAINER_NAME="nexus-node-$i"

        docker rm -f "$CONTAINER_NAME" 2>/dev/null || true

        docker run -dit \
            --name "$CONTAINER_NAME" \
            -e NODE_ID="$NODE_ID" \
            -v "$LOG_DIR":/nexus-data \
            "$IMAGE_NAME"

        echo "✅ 实例 $CONTAINER_NAME (NodeID: $NODE_ID) 启动成功"
        echo "日志文件: $LOG_DIR/nexus-${NODE_ID}.log"
    done
}

function add_one_instance() {
    init_dirs

    NEXT_IDX=$(docker ps -a --filter "name=nexus-node-" --format '{{.Names}}' | sed 's/nexus-node-//' | sort -n | tail -1 | awk '{print $1+1}')
    [ -z "$NEXT_IDX" ] && NEXT_IDX=1

    while true; do
        read -rp "请输入新实例的 node-id: " NODE_ID
        validate_node_id "$NODE_ID" && break
    done

    CONTAINER_NAME="nexus-node-$NEXT_IDX"

    docker rm -f "$CONTAINER_NAME" 2>/dev/null || true

    docker run -dit \
        --name "$CONTAINER_NAME" \
        -e NODE_ID="$NODE_ID" \
        -v "$LOG_DIR":/nexus-data \
        "$IMAGE_NAME"

    echo "✅ 新实例添加成功"
    echo "实例名称: $CONTAINER_NAME"
    echo "节点ID: $NODE_ID"
    echo "日志文件: $LOG_DIR/nexus-${NODE_ID}.log"
}

function change_node_id() {
    read -rp "请输入要修改的实例编号: " idx
    read -rp "请输入新的 node-id: " NEW_ID
    
    validate_node_id "$NEW_ID" || return 1

    CONTAINER_NAME="nexus-node-$idx"

    docker rm -f "$CONTAINER_NAME" 2>/dev/null || true

    docker run -dit \
        --name "$CONTAINER_NAME" \
        -e NODE_ID="$NEW_ID" \
        -v "$LOG_DIR":/nexus-data \
        "$IMAGE_NAME"

    echo "✅ 修改完成"
    echo "实例名称: $CONTAINER_NAME"
    echo "节点ID: $NEW_ID"
    echo "日志文件: $LOG_DIR/nexus-${NEW_ID}.log"
}

function setup_rotation_schedule() {
    init_dirs
    
    cat > "$CONFIG_DIR/id-config.json" <<EOF
{
  "nexus-node-1": ["1001", "1002", "1003"],
  "nexus-node-2": ["2001", "2002", "2003"]
}
EOF

    cat > "$CONFIG_DIR/rotate.sh" <<'EOF'
#!/bin/bash
CONFIG="/root/nexus-node/config/id-config.json"
LOG_DIR="/root/nexus-node/logs"

for CONTAINER in $(jq -r 'keys[]' "$CONFIG"); do
    IDS=($(jq -r ".$CONTAINER[]" "$CONFIG"))
    CURRENT_ID=$(docker inspect "$CONTAINER" --format '{{.Config.Env}}' | grep -oP 'NODE_ID=\K\d+')
    
    for i in "${!IDS[@]}"; do
        if [ "${IDS[i]}" == "$CURRENT_ID" ]; then
            NEXT_ID=${IDS[(i+1)%${#IDS[@]}]}
            break
        fi
    done

    echo "$(date) 轮换 $CONTAINER 从 $CURRENT_ID 到 $NEXT_ID" >> "$LOG_DIR/rotation.log"

    docker rm -f "$CONTAINER"
    docker run -dit \
        --name "$CONTAINER" \
        -e NODE_ID="$NEXT_ID" \
        -v "$LOG_DIR":/nexus-data \
        nexus-node:latest
done
EOF

    chmod +x "$CONFIG_DIR/rotate.sh"
    (crontab -l 2>/dev/null; echo "0 */6 * * * $CONFIG_DIR/rotate.sh >> $LOG_DIR/rotation.log 2>&1") | crontab -

    echo "✅ 自动轮换计划已部署"
    echo "配置见: $CONFIG_DIR/id-config.json"
    echo "轮换日志: $LOG_DIR/rotation.log"
}

function show_menu() {
    clear
    echo -e "\n=========== Nexus 节点管理 ==========="
    echo -e "📂 日志目录: $LOG_DIR\n"

    CONTAINERS=$(docker ps -a --filter "name=nexus-node-" --format '{{.Names}}')
    RUNNING_COUNT=$(docker ps --filter "name=nexus-node-" --filter "status=running" -q | wc -l)

    if [ -z "$CONTAINERS" ]; then
        echo "⚠️ 当前没有 Nexus 实例"
    else
        echo "🔍 当前运行中的实例数量: $RUNNING_COUNT"
        echo

        for CONTAINER in $CONTAINERS; do
            STATUS=$(docker inspect -f '{{.State.Status}}' "$CONTAINER")
            NODE_ID=$(docker inspect "$CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}' | grep NODE_ID | cut -d= -f2)
            echo "实例: $CONTAINER | 状态: $STATUS | 节点ID: $NODE_ID"
        done
    fi

    echo -e "\n1. 构建镜像  2. 批量启动  3. 停止所有实例"
    echo "4. 更换node-id  5. 添加单个实例  6. 查看日志"
    echo "7. 部署轮换计划  0. 退出"
    echo "======================================"
}

# 主程序
check_docker
init_dirs

while true; do
    show_menu
    read -rp "请选择操作: " choice
    case "$choice" in
        1) prepare_build_files; build_image;;
        2) start_instances;;
        3) docker rm -f $(docker ps -aq --filter "name=nexus-node-") || true;;
        4) change_node_id;;
        5) add_one_instance;;
        6) ls -lh "$LOG_DIR" | grep -v rotation.log; read -rp "输入要查看的日志编号: " idx && tail -f "$LOG_DIR/nexus-${idx}.log";;
        7) setup_rotation_schedule;;
        0) echo "退出脚本"; exit 0;;
        *) echo "⚠️ 无效选项";;
    esac
    read -rp "按Enter键继续..."
done
