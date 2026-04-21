# 1. 彻底更新并安装依赖
apt update -y
apt install -y git golang-go curl socat fuser net-tools wget

# 2. 修复 go 和 xcaddy 的 PATH（关键修复）
export PATH=$PATH:/usr/lib/go/bin:$HOME/go/bin
echo 'export PATH=$PATH:/usr/lib/go/bin:$HOME/go/bin' >> \~/.bashrc
echo 'export PATH=$PATH:/usr/lib/go/bin:$HOME/go/bin' >> /root/.bashrc

# 3. 刷新当前 shell
source \~/.bashrc

# 4. 验证是否成功
echo "=== 验证工具 ==="
which git && git --version
which go && go version
echo "PATH 中包含 go: $(echo $PATH | grep -o 'go/bin' || echo '未找到')"
