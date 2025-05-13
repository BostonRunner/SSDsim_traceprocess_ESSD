#!/bin/bash
USE_CONTAINERS=${USE_CONTAINERS:-6}
RESULT_DIR="result${USE_CONTAINERS}"

rm -rf "$RESULT_DIR/"
mkdir "$RESULT_DIR"
cd "$RESULT_DIR" || exit
echo "directory created"
touch result.txt
touch result.log
echo "result.txt result.log created"
echo "blktrace activating"
cd ..

docker kill $(docker ps -q)
docker system prune -af --volumes
sleep 3

RESULT_DIR="$RESULT_DIR" ./blktrace.sh
sleep 3
USE_CONTAINERS=$USE_CONTAINERS RESULT_DIR="$RESULT_DIR" ./IO.sh
sleep 3

cd "$RESULT_DIR" || exit
# grep 'A' result.log | grep " W " > result_temp.txt
grep -E " W | WS " result.log | grep " D " > result_temp.txt
sort -n -k 4 result_temp.txt > result.txt
cd ..

echo "processing I/O trace..." & sleep 60
echo 3 | sudo tee /proc/sys/vm/drop_caches   #
# sudo find /mnt/emu -xdev -type f > /dev/null  #
python3 main.py "$RESULT_DIR"
python3 trans.py "$RESULT_DIR"
echo "program finished"
