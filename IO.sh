#!/bin/bash
set -e

MAX_CONTAINERS=6
USE_CONTAINERS=${USE_CONTAINERS:-$MAX_CONTAINERS}

# Define container images
IMAGES=(
  "ubuntu:22.04"
  "opensuse/leap:15.5"
  "parrotsec/security"
  "debian:11"
  "alpine:3.18"
  "archlinux:latest"
)
IMAGES=("${IMAGES[@]:0:$USE_CONTAINERS}")
NUM_CONTAINERS=${#IMAGES[@]}

CONTAINER_PREFIX="docker_blktest"
TEST_DIR="/mnt/testdir"
BLOCK_SIZE="10K"
FILES_PER_ROUND=8
TOTAL_SIZE=$((2 * 1024 * 1024 * 1024))  # 2GB
TOTAL_FILES=1024
TOTAL_PASSES=2  # Two major rounds of tests

WORKLOADS=(seqrw seqwrite randwrite hotrw hotwrite randrw)

echo "[INFO] Starting cleanup of old containers..."
for i in $(seq 1 $NUM_CONTAINERS); do
  docker rm -f "${CONTAINER_PREFIX}${i}" >/dev/null 2>&1 || true &
done
wait

# Function to install fio in the container
install_fio() {
  local container=$1
  local image=$2
  echo "[INFO] Installing fio in container $container ($image)..."
  case "$image" in
    ubuntu*|debian*|parrotsec*) docker exec "$container" bash -c "apt-get update && apt-get install -y fio" ;;
    alpine*) docker exec "$container" sh -c "apk add --no-cache fio" ;;
    archlinux*) docker exec "$container" bash -c "pacman -Sy --noconfirm fio" ;;
    opensuse*) docker exec "$container" bash -c "zypper --non-interactive install fio" ;;
  esac
}

# Function to prepare each container (install fio, create test directory, etc.)
prepare_container() {
  local idx=$1
  local image=${IMAGES[$idx]}
  local name="${CONTAINER_PREFIX}$((idx+1))"
  echo "[INFO] Starting container $name with image $image..."

  # Create container
  if docker run -dit --name "$name" "$image" bash >/dev/null 2>&1; then
    echo "[INFO] Container $name started successfully."
  else
    docker rm -f "$name" >/dev/null 2>&1 || true
    docker run -dit --name "$name" "$image" sh >/dev/null
    echo "[INFO] Container $name started successfully (fallback to sh)."
  fi

  # Install fio in the container
  install_fio "$name" "$image"
  
  # Create test directory
  echo "[INFO] Creating test directory $TEST_DIR in container $name..."
  docker exec "$name" mkdir -p "$TEST_DIR"

  # Create test files inside the container
  echo "[INFO] Creating $TOTAL_FILES test files in container $name..."
  for i in $(seq 1 $TOTAL_FILES); do
    docker exec "$name" dd if=/dev/zero of=$TEST_DIR/file${i}.dat bs=1M count=1 status=none || true
  done
}

echo "[STEP 1] Preparing containers..."
for i in $(seq 0 $((NUM_CONTAINERS - 1))); do
  prepare_container "$i" &
done
wait
echo "[STEP 1 DONE] All containers prepared."
sleep 10  # Give containers a little more time to settle

# Function to run fio workloads in groups of containers
run_group_write() {
  local group=("$@")
  local round_idx=$1
  shift
  local containers=("$@")

  local shuffled=($(shuf -i 1-$TOTAL_FILES))

  local rounds=$((TOTAL_FILES / FILES_PER_ROUND))

  for round in $(seq 0 $((rounds - 1))); do
    echo "[INFO] Clearing caches..."
    echo 3 > /proc/sys/vm/drop_caches

    for cid in "${containers[@]}"; do
      (
        local container="${CONTAINER_PREFIX}${cid}"
        echo "[INFO] Running fio for container $container, round $round_idx..."

        for j in $(seq 1 $FILES_PER_ROUND); do
          local file_idx=${shuffled[$((round * FILES_PER_ROUND + j - 1))]}
          local rand_kb=$((1800 + RANDOM % 401))  # Random KB size between 1800K and 2200K
          echo "[INFO] Pass $round_idx: Container $cid, File $file_idx, Size $rand_kb KB"

          # Execute fio with different workloads
          case "${WORKLOADS[$((cid - 1))]}" in
            seqrw)
              docker exec "$container" fio --name="c${cid}_f${file_idx}" --filename=$TEST_DIR/file${file_idx}.dat \
                --rw=readwrite --rwmixread=50 --bs=$BLOCK_SIZE --size="${rand_kb}K" --offset=0 --offset_increment=10K \
                --random_distribution=zipf --overwrite=1 --ioengine=sync --direct=1 --numjobs=1 --runtime=3 --time_based \
                --randrepeat=0 --random_generator=tausworthe --output-format=json
              ;;
            seqwrite)
              docker exec "$container" fio --name="c${cid}_f${file_idx}" --filename=$TEST_DIR/file${file_idx}.dat \
                --rw=write --bs=$BLOCK_SIZE --size="${rand_kb}K" --offset=0 --offset_increment=10K \
                --random_distribution=zipf --overwrite=1 --ioengine=sync --direct=1 --numjobs=1 --runtime=3 --time_based \
                --randrepeat=0 --random_generator=tausworthe --output-format=json
              ;;
            randwrite)
              docker exec "$container" fio --name="c${cid}_f${file_idx}" --filename=$TEST_DIR/file${file_idx}.dat \
                --rw=randwrite --bs=$BLOCK_SIZE --size="${rand_kb}K" --offset=0 --offset_increment=10K \
                --random_distribution=zipf --overwrite=1 --ioengine=sync --direct=1 --numjobs=1 --runtime=3 --time_based \
                --randrepeat=0 --random_generator=tausworthe --output-format=json
              ;;
            hotrw)
              docker exec "$container" fio --name="c${cid}_f${file_idx}" --filename=$TEST_DIR/file${file_idx}.dat \
                --rw=randrw --rwmixread=70 --bs=$BLOCK_SIZE --random_distribution=zipf:1.2 --randrepeat=0 \
                --random_generator=tausworthe --ioengine=sync --direct=1 --numjobs=1 --runtime=3 --time_based \
                --randrepeat=0 --random_generator=tausworthe --output-format=json
              ;;
            hotwrite)
              docker exec "$container" fio --name="c${cid}_f${file_idx}" --filename=$TEST_DIR/file${file_idx}.dat \
                --rw=randwrite --bs=$BLOCK_SIZE --random_distribution=zipf:1.2 --randrepeat=0 --random_generator=tausworthe \
                --ioengine=sync --direct=1 --numjobs=1 --runtime=3 --time_based --randrepeat=0 --output-format=json
              ;;
            randrw)
              docker exec "$container" fio --name="c${cid}_f${file_idx}" --filename=$TEST_DIR/file${file_idx}.dat \
                --rw=randrw --rwmixread=50 --bs=$BLOCK_SIZE --size="${rand_kb}K" --offset=0 --offset_increment=10K \
                --random_distribution=zipf --overwrite=1 --ioengine=sync --direct=1 --numjobs=1 --runtime=3 --time_based \
                --randrepeat=0 --random_generator=tausworthe --output-format=json
              ;;
          esac
        done
      ) & 
    done
    wait
    echo "[INFO] Round $round completed."
  done
}

# Run the tests for each round and workload
for pass in $(seq 1 $TOTAL_PASSES); do
  echo "========== Starting round $pass =========="
  run_group_write "$pass" "${WORKLOADS[@]}" &
  wait
  echo "========== Round $pass completed =========="
done

echo "[STEP 3] Writing results, stopping containers..."
for i in $(seq 1 $NUM_CONTAINERS); do
  docker stop "${CONTAINER_PREFIX}${i}" >/dev/null 2>&1 || true
done

echo "[DONE] All containers stopped. Test completed."
