# 安装编译依赖
sudo yum install -y git gcc gcc-c++ make automake libtool openssl-devel mariadb-connector-c-devel

# 编译安装新版 sysbench
cd /tmp
git clone https://github.com/akopytov/sysbench.git
cd sysbench
./autogen.sh
./configure
make -j$(nproc)
sudo make install

# 验证
sysbench --version
sysbench --help | grep mysql-ssl


# install mysql client
sudo dnf install -y mariadb105
