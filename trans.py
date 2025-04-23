
##################################################################################
# Python script for processing blkparse output, including container ID tagging   #
# Author: Ruofei Wu                                                              #
# Updated: 2025-04-18 (with robust parsing fix)                                  #
##################################################################################

# 打开输入输出文件
origin_file = open("./results/result_path.txt", "r")
final = open("./results/io.ascii", "w")
cursor = 0

print("Reading result_path.txt...")
data = origin_file.readlines()

print("Processing lines...")
output = ""

for i in range(len(data)):
    parts = data[i].split()
    try:
        # 提取时间（s → ns）
        time = int(float(parts[3]) * 1e9)

        # 自动定位扇区和大小：通过 '+' 号找位置
        plus_idx = parts.index('+')
        sector = int(parts[plus_idx - 1])
        size = int(parts[plus_idx + 1])

        layer_flag = -1
        container_id = -1

        # 最后两个字段：[-2] 是 [UpperLayer]/[LowerLayer]，[-1] 是 [ContainerX]
        layer = parts[-2]
        if layer == "[UpperLayer]":
            layer_flag = 0
        elif layer == "[LowerLayer]":
            layer_flag = 1

        container_str = parts[-1]
        if container_str.startswith("[Container") and container_str.endswith("]"):
            container_id = int(container_str[10:-1])

        if time > cursor and container_id != -1:
            output += f"{time} 1 0 {sector} {size} {layer_flag} {container_id}\n"
            cursor = 0

    except Exception as e:
        print(f"Error at line {i}: {e}")
        continue

print("Writing io.ascii...")
final.write(output)
origin_file.close()
final.close()
print("Done.")
