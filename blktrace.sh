#!/bin/bash
cd "${RESULT_DIR:-./results}"
blktrace -d /dev/vdb -w 12000 -o - | blkparse -i - >> result.log &
