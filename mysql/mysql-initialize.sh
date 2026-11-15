#!/bin/bash
DATADIR="/data/db/mysql/data"
SOCK="${DATADIR}/mysql.sock"

if [ ! -d "${DATADIR}/mysql" ];then
    chown -R mysql:mysql /data/db/mysql
    /usr/local/mysql/bin/mysqld --defaults-file=/etc/my.cnf --user=mysql --initialize-insecure
fi

/usr/local/mysql/bin/mysqld --defaults-file=/etc/my.cnf --user=mysql &

for i in {1..30}; do
    /usr/local/mysql/bin/mysqladmin -S $SOCK -uroot ping >/dev/null 2>&1 && break
    sleep 1
done

/usr/local/mysql/bin/mysql -S $SOCK -uroot <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY 'root';
CREATE DATABASE IF NOT EXISTS test DEFAULT CHARACTER SET utf8mb4;
USE test;
CREATE TABLE IF NOT EXISTS user (id INT PRIMARY KEY AUTO_INCREMENT, name VARCHAR(50) NOT NULL);
INSERT INTO user(name) VALUES ('lnmp-ok'),('doubao-test');
EOF

/usr/local/mysql/bin/mysqladmin -S $SOCK -uroot -proot shutdown
exec /usr/local/mysql/bin/mysqld --defaults-file=/etc/my.cnf --user=mysql

