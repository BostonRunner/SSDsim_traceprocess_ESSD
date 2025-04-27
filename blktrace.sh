#!/bin/bash
cd "${RESULT_DIR:-./results}"
blktrace -d /dev/vdb -w 2700 -o - | blkparse -i - >> result.log &
