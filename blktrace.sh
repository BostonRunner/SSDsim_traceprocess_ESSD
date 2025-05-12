#!/bin/bash
cd "${RESULT_DIR:-./results}"
blktrace -d /dev/nvme1n1 -w 12000 -o - | blkparse -i - >> result.log &
