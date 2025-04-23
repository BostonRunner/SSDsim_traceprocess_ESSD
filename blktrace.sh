cd ./results
blktrace -d /dev/vdb -w 2700 -o - | blkparse -i - >> result.log &
