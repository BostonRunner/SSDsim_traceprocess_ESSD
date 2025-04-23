import os
import sys

# 可选参数：结果目录，默认 ./results
result_dir = sys.argv[1] if len(sys.argv) > 1 else "./results"

# 路径定义
input_file_path = os.path.join(result_dir, "result.txt")
output_file_path = os.path.join(result_dir, "result_path.txt")
device_path = "/dev/vdb"

# 获取容器 UpperDir 和 LowerDir 信息
def get_overlay_paths(container_name):
    info = os.popen(f"docker container inspect {container_name}").readlines()
    lower_dirs = []
    upper_dir = ""
    for line in info:
        if "LowerDir" in line:
            raw = line.split('"')[-2]
            if ':' in raw:
                lower_dirs = [d for d in raw.split(':') if "init" not in d]
        elif "UpperDir" in line:
            upper_dir = line.split('"')[-2]
    return upper_dir, lower_dirs

# 收集 overlay 路径（动态容器数量）
upper_dirs = []
lower_dirs = []
max_containers = int(os.getenv("USE_CONTAINERS", 6))  # 默认6个容器
for i in range(1, max_containers + 1):
    u, l = get_overlay_paths(f"docker_blktest{i}")
    upper_dirs.append(u)
    lower_dirs.append(l)

# 读取 trace 日志
with open(input_file_path, "r") as infile:
    trace_lines = infile.readlines()

result_lines = []

# 处理每一行 trace
for i, line in enumerate(trace_lines):
    try:
        parts = line.strip().split()
        if len(parts) < 10:
            continue
        sector_idx = parts.index('+') - 1 if '+' in parts else -1
        if sector_idx == -1 or not parts[sector_idx].isdigit():
            continue

        block = int(int(parts[sector_idx]) / 8)

        icheck_cmd = f"debugfs -R 'icheck {block}' {device_path}"
        icheck_result = os.popen(icheck_cmd).readlines()
        if not icheck_result:
            continue
        inode_line = icheck_result[-1]
        inode_parts = inode_line.strip().split()
        if not inode_parts or not inode_parts[-1].isdigit():
            continue
        inode = int(inode_parts[-1])
        if inode == 8:
            continue

        ncheck_cmd = f"debugfs -R 'ncheck {inode}' {device_path}"
        ncheck_result = os.popen(ncheck_cmd).readlines()
        if not ncheck_result:
            continue
        path_line = ncheck_result[-1].strip()
        file_path = "/mnt/docker_tmp" + path_line.split()[-1]

        label = ""
        container_id = -1
        for idx in range(max_containers):
            if file_path.startswith(upper_dirs[idx]):
                label = "[UpperLayer]"
                container_id = idx + 1
                break
            elif any(ld in file_path for ld in lower_dirs[idx]):
                label = "[LowerLayer]"
                container_id = idx + 1
                break

        if label and container_id != -1:
            result_lines.append(f"{line.strip()}\t{file_path}\t{label}\t[Container{container_id}]\n")

    except Exception as e:
        print(f"\nError at line {i}: {e}")
        continue

    sys.stdout.write(f"\rProcessing: {i+1}/{len(trace_lines)} ({(i+1)/len(trace_lines)*100:.2f}%)")
    sys.stdout.flush()

with open(output_file_path, "w") as outfile:
    outfile.writelines(result_lines)

print("\nProcessing complete! Result written to result_path.txt.")

