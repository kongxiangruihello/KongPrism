#!/bin/bash
# 双击运行：先跑测试（含用真实 sing-box 校验生成的配置），再编译 KongPrism 并安装到“应用程序”文件夹。
# 输出同时保存在 build/build.log。
cd "$(dirname "$0")"
bash scripts/build-app.sh --test --install
status=$?
echo
if [[ $status -eq 0 ]]; then
  echo "完成。KongPrism 已安装并启动，菜单栏里有三棱镜图标，可以关闭这个窗口。"
else
  echo "构建失败（退出码 $status）。详细信息在 build/build.log。"
fi
