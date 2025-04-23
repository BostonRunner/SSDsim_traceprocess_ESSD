#!/bin/bash
rm -rf results/
mkdir results
cd ./results || exit
echo "directory created"
touch result.txt
touch result.log
echo "result.txt result.log created"
echo "blktrace activating"
cd ..
docker kill $(docker ps -q)
docker system prune -af --volumes
sleep 3
./blktrace.sh
sleep 3
./IO.sh
sleep 3


cd ./results || exit
# grep 'A' result.log | grep " W " > result_temp.txt
grep 'W' result.log > result_temp.txt
sort -n -k 4 result_temp.txt > result.txt
cd ..

echo "processing I/O trace..." & sleep 60
echo 3 | sudo tee /proc/sys/vm/drop_caches   # 
# sudo find /mnt/emu -xdev -type f > /dev/null  #
python3 main.py
python3 trans.py
echo "program finished"
