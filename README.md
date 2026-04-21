目前的脚本最稳妥的运行环境依然是：Ubuntu 20.04+ 或 Debian 11+。
更新环境
```
apt update && apt install -y curl sudo
```
运行代码
方案一
```
curl -sLO https://raw.githubusercontent.com/OneQ1st/emby/main/emby.sh
chmod +x emby.sh
sudo ./emby.sh
```
方案二
```
# 先修复环境（强烈建议先运行这行）
apt update -y && apt install -y git curl wget psmisc
```
运行代码
```
curl -sLO https://raw.githubusercontent.com/OneQ1st/emby/main/deploy.sh
chmod +x deploy.sh
sudo ./deploy.sh
```
