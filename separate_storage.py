#!/usr/bin/env python3
import json
import os
import sys
import shutil
from pathlib import Path

# Function to handle saving results in separate directories based on container count
def save_results(result_dir, container_count, test_type="single"):
    # Define the base directory for saving results
    base_dir = Path(result_dir)
    
    # Prepare separate directories for single-container and multi-container tests
    if test_type == "single":
        save_dir = base_dir / "result_single_container"
    elif test_type == "multi":
        save_dir = base_dir / "result_multi_container"
    else:
        raise ValueError("Invalid test_type. Must be 'single' or 'multi'.")
    
    # Create directory if not exists
    if not save_dir.exists():
        save_dir.mkdir(parents=True, exist_ok=True)

    # Generate unique sub-directories for containers
    for container_num in range(1, container_count + 1):
        container_dir = save_dir / f"container_{container_num}"
        container_dir.mkdir(parents=True, exist_ok=True)

    print(f"[INFO] Results will be saved under: {save_dir}")

    return save_dir

# Function to copy results from containers into appropriate directories
def copy_results_from_containers(base_result_dir, test_type="single"):
    # Get the number of containers from the test type (single or multi)
    if test_type == "single":
        container_count = 1
    elif test_type == "multi":
        container_count = 6
    else:
        raise ValueError("Invalid test_type. Must be 'single' or 'multi'.")
    
    # Get the save directory based on test type and container count
    save_dir = save_results(base_result_dir, container_count, test_type)

    # Loop over each container and copy the corresponding result files
    for container_num in range(1, container_count + 1):
        container_result_dir = Path(base_result_dir) / f"c{container_num}"
        
        # Check if container result directory exists
        if container_result_dir.exists():
            # Find all fio JSON files for this container
            for json_file in container_result_dir.glob("fio_c*.json"):
                # Copy each result file to the respective container directory
                shutil.copy(json_file, save_dir / f"container_{container_num}")

    print(f"[INFO] Results for all containers have been copied.")

if __name__ == "__main__":
    # Ensure the script is executed with the required parameters
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <base_result_dir> <test_type>")
        sys.exit(1)

    # Parse the input arguments
    base_result_dir = sys.argv[1]
    test_type = sys.argv[2]  # 'single' or 'multi'

    # Call the function to copy results
    copy_results_from_containers(base_result_dir, test_type)
