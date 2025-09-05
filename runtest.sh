#!/bin/bash
# This script installs dependencies, prepares the test, and runs the workload for the container.
set -euo pipefail

# This function clears data in the container before each test
clear_container_data() {
    local container_name="$1"
    echo "[INFO] Clearing data in container ${container_name}..."
    docker exec "${container_name}" rm -rf /data/*
}

# Run the container's FIO command and return the output
run_fio() {
    local container_name="$1"
    local workload="$2"
    local test_file="/data/testfile.dat"
    local runtime="${RUNTIME:-30}"  # 30 seconds runtime for each workload
    
    # Construct fio command
    fio_cmd="fio --name=${workload} --filename=${test_file} --rw=readwrite --rwmixread=50 --bs=128k --ioengine=libaio --iodepth=1 --direct=1 --time_based --runtime=${runtime} --numjobs=1 --group_reporting=1 --output-format=json"
    
    echo "[RUN] Executing fio for container ${container_name} with workload ${workload}..."
    
    # Execute fio command inside the container
    result=$(docker exec "${container_name}" sh -c "${fio_cmd}")
    echo "$result"
    
    return "$?"
}

# Main testing function
run_single_test() {
    local container_name="$1"
    local workload="$2"

    # Clear the container data before starting the test
    clear_container_data "${container_name}"

    # Run the FIO test
    run_fio "${container_name}" "${workload}"
}

# Main function to execute the entire test process
main() {
    # Ensure the script is executed with the required parameters
    if [ "$#" -lt 1 ]; then
        echo "Usage: $0 <container_name>"
        exit 1
    fi

    container_name="$1"

    # Define workloads for single container
    workloads=("seqrw" "seqwrite" "randwrite" "hotrw" "hotwrite" "randrw")
    
    # Loop through each workload and run tests
    for workload in "${workloads[@]}"; do
        run_single_test "${container_name}" "${workload}"
    done
}

# Loop for 6 containers
for i in $(seq 1 6); do
    container_name="docker_blktest${i}"
    ./test.sh "${container_name}"
done
