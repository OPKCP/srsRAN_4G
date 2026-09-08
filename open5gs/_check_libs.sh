#!/bin/sh
# Проверка линковки всех демонов Open5GS
for d in mmed hssd sgwcd sgwud smfd upfd pcrfd; do
  n=$(ldd /usr/bin/open5gs-$d 2>&1 | grep -c 'not found')
  echo "${d}: notfound=${n}"
done
