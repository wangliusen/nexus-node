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
    echo '[source.crates-io]\nreplace-with = "ustc"\n[source.ustc]\nregistry = "https://mirrors.ustc.edu.cn/crates.io-index"' > /root/.cargo/config && \
    curl https://sh.rustup.rs -sSf | sh -s -- -y

WORKDIR /tmp
RUN git clone https://github.com/nexus-xyz/nexus-cli.git
WORKDIR /tmp/nexus-cli
RUN git checkout v0.8.10
WORKDIR /tmp/nexus-cli/clients/cli
RUN . /root/.cargo/env && cargo build --release
RUN cp target/release/nexus-network /usr/local/bin/ && chmod +x /usr/local/bin/nexus-network

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
EOF

    cat > entrypoint.sh <<'EOF'
#!/bin/bash
set -e

[ -z "$NODE_ID" ] && { echo "❌ 必须设置 NODE_ID 环境变量" >&2; exit 1; }

LOG_FILE="/nexus-data/nexus-${NODE_ID}.log"
mkdir -p /nexus-data
touch "$LOG_FILE"
echo "▶️ 正在启动节点：$NODE_ID，日志写入 $LOG_FILE"
stdbuf -oL nexus-network start --node-id "$NODE_ID" --log-format=plain > >(tee -a "$LOG_FILE") 2>&1

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

        echo "✅ 实例 $CONTAINER_NAME 启动成功"
    done
}

function add_one_instance() {
    NEXT_IDX=1
    while docker ps -a --format '{{.Names}}' | grep -q "nexus-node-$NEXT_IDX"; do
        ((NEXT_IDX++))
    done


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

    echo "✅ 添加实例 $CONTAINER_NAME 成功"
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

    echo "✅ 修改完成，节点 ID 已更新为 $NEW_ID"
}

function setup_rotation_schedule() {
    mkdir -p "$CONFIG_DIR"

    # 写入默认 ID 配置（可选）
if [ ! -f "$CONFIG_DIR/id-config.json" ]; then
    cat > "$CONFIG_DIR/id-config.json" <<EOF
{
  "nexus-node-1": ["1001", "1002", "1003"],
  "nexus-node-2": ["2001", "2002", "2003"]
}
EOF
    echo "✅ 已生成默认 id-config.json，请根据你自己的节点 ID 修改"
else
    echo "⚠️ 已存在 id-config.json，未覆盖"
fi


    # 写入轮换脚本
    cat > "$CONFIG_DIR/rotate.sh" <<'EOF'
#!/bin/bash
CONFIG="/root/nexus-node/config/id-config.json"
LOG_DIR="/root/nexus-node/logs"

for CONTAINER in $(jq -r 'keys[]' "$CONFIG"); do
    IDS=($(jq -r ".\"$CONTAINER\"[]" "$CONFIG"))
    CURRENT_ID=$(docker inspect "$CONTAINER" --format '{{json .Config.Env}}' | jq -r '.[]' | grep "^NODE_ID=" | cut -d= -f2)

    if [ -z "$CURRENT_ID" ]; then
        echo "$(date) ❌ 无法获取 $CONTAINER 的当前 NODE_ID，跳过"
        continue
    fi

    for i in "${!IDS[@]}"; do
        if [ "${IDS[i]}" == "$CURRENT_ID" ]; then
            NEXT_ID=${IDS[(i+1)%${#IDS[@]}]}
            break
        fi
    done

    echo "$(date) 重启 $CONTAINER 从 $CURRENT_ID ➜ $NEXT_ID" >> "$LOG_DIR/rotation.log"
    docker rm -f "$CONTAINER"
    docker run -dit \
        --name "$CONTAINER" \
        -e NODE_ID="$NEXT_ID" \
        -v "$LOG_DIR":/nexus-data \
        nexus-node:latest
done

EOF

    chmod +x "$CONFIG_DIR/rotate.sh"

    # 如果轮换任务已经存在，就不再重复添加
    if ! crontab -l 2>/dev/null | grep -q "rotate.sh"; then
        (crontab -l 2>/dev/null; echo "0 */2 * * * $CONFIG_DIR/rotate.sh >> $LOG_DIR/rotation.log 2>&1") | crontab -
        echo "✅ 已部署每 2 小时自动轮换计划"
    else
        echo "⚠️ 轮换任务已存在，无需重复添加"
    fi
}


function show_menu() {
    clear
    echo -e "\\n=========== Nexus 节点管理 ==========="
    echo "📁 日志目录: $LOG_DIR"
    echo

    CONTAINERS=$(docker ps -a --filter "name=nexus-node-" --format '{{.Names}}')
    if [ -z "$CONTAINERS" ]; then
        echo "⚠️ 当前没有 Nexus 实例"
    else
        for CONTAINER in $CONTAINERS; do
            STATUS=$(docker inspect -f '{{.State.Status}}' "$CONTAINER")
            NODE_ID=$(docker inspect "$CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}' | grep NODE_ID | cut -d= -f2)
            echo "📦 实例: $CONTAINER | 状态: $STATUS | 节点ID: $NODE_ID"
        done
    fi
function enter_container_ui() {
    echo "当前运行中的实例："
    echo "--------------------------------"

    containers=($(docker ps --filter "name=nexus-node-" --format "{{.Names}}"))
    if [ ${#containers[@]} -eq 0 ]; then
        echo "⚠️ 没有运行中的实例"
        return 1
    fi

    for i in "${!containers[@]}"; do
        node_id=$(docker inspect "${containers[i]}" --format '{{json .Config.Env}}' | jq -r '.[]' | grep "^NODE_ID=" | cut -d= -f2)
        echo "[$((i+1))] 容器: ${containers[i]} | 节点ID: $node_id"
    done

    echo
    read -rp "请输入要进入的实例编号: " input

    if [[ "$input" =~ ^[0-9]+$ && "$input" -le "${#containers[@]}" ]]; then
        index=$((input-1))
        container_name="${containers[index]}"
        node_id=$(docker inspect "$container_name" --format '{{json .Config.Env}}' | jq -r '.[]' | grep "^NODE_ID=" | cut -d= -f2)

        echo "✅ 正在进入容器并启动 nexus-network UI..."
        sleep 1
        docker exec -it "$container_name" bash -c "nexus-network start --node-id $node_id"
    else
        echo "❌ 输入无效，已取消操作"
    fi
}


    echo
    echo "1. 构建镜像"
    echo "2. 启动多个实例"
    echo "3. 停止所有实例"
    echo "4. 更换某实例 node-id"
    echo "5. 添加一个新实例"
    echo "6. 部署自动轮换计划"
    echo "7. 一键进入容器查看日志"
    echo "0. 退出"
}

# 主程序入口
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
        6) setup_rotation_schedule;;
        7) enter_container_ui;;
        0) echo "退出"; exit 0;;
        *) echo "无效选项";;
    esac
    read -rp "按 Enter 继续..."
done
