# nexus-node
wget -qO nexus-multi.sh https://raw.githubusercontent.com/figo118/nexus-node/main/nexus-multi.sh || curl -sLo nexus-multi.sh https://raw.githubusercontent.com/figo118/nexus-node/main/nexus-multi.sh && chmod +x nexus-multi.sh && sudo ./nexus-multi.sh


/root/nexus-manager.sh	脚本	主管理脚本，提供菜单操作（启动、重启、轮换、日志、添加实例等）
/root/nexus-docker/	目录	Docker 镜像构建目录
└── Dockerfile	文件	构建基础镜像（Ubuntu + nexus CLI + screen）
└── entrypoint.sh	文件	容器内启动脚本
/root/nexus-rotate.sh	脚本	自动轮换 ID 脚本，每 2 小时由 crontab 执行
/root/nexus-id-config.json	配置	所有实例的 4 个轮换 ID 列表
/root/nexus-id-state.json	配置	每个实例当前使用 ID 的索引（0~3）
/root/nexus-rotate.log	日志	自动轮换脚本的运行日志
/root/nexus-1.log ~ /root/nexus-6.log	日志	各个实例运行日志（每个实例独立日志）
