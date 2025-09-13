# ***TRACE PROCESSOR***

## **1. ABOUT THIS PROGRAM**



## **2. BEFORE YOU USE THIS PROGRAM**

Please check if you have installed these programs:

***1.blktrace***

***2.docker***

If you do not have installed these two programs, you can run ***apt install blktrace*** and ***apt install docker.io*** .



## **3.HOW TO USE THIS PROGRAM**

#### TEST01: UpperLayer and LowerLayer are in the same SSD(TRACE COLLECTION)

You can download the code by:

```shell
git clone -b main https://github.com/BostonRunner/SSDsim_traceprocess_ESSD
```

Please prepare an isolated disk for docker data storage, for example, "***/dev/vdb***". It must be formatted in the form of ext4,  and if you want to store the images and the data of containers in the directory ***/mnt/docker_tmp*** and mount it on the disk, you can use these two commands:

```shell
mkfs.ext4 /dev/vdb
mount /dev/vdb /mnt/docker_tmp
```

After installing these two,  please edit ***daemon.json*** in ***/etc/docker***, for example:

```shell
vim /etc/docker/daemon.json
```

In this program, the data of containers should be in a clean storage device that do not have any other writing traces. So we can proposed that if you want to store the images and the data of containers in the directory ***/mnt/docker_tmp***, which has been mounted on device ***/dev/vdb***, you can write this in ***daemon.json***:

```json
{
	"data-root":"/mnt/docker_tmp"
}
```

Then you can run this command to restart the docker in order to activate the new setting:

```shell
systemctl restart docker
```

And great, you can edit ***blktrace.sh*** and ***main.py*** to make adjustment to the new device and directory

You can run the shell script **run.sh** to use this program:

```shell
USE_CONTAINERS=$i ./run.sh
```

**$i** is the number of containers you want to test, we recommend the number should between 1 and 6. For example, if we want to get the traces of 6 containers, we can run like this:

```shell
USE_CONTAINERS=6 ./run.sh
```

Also, if you want to run it in the background, you can use ***nohup*** like this:

```shell
nohup env USE_CONTAINERS=$i ./run.sh &
```

**$i** is the number of containers you want to test, we recommend the number should between 1 and 6. For example, if we want to get the traces of 6 containers, we can run like this:

```shell
nohup env USE_CONTAINERS=6 ./run.sh &
nohup env USE_CONTAINERS=6 ./run.sh > run6.out 2>&1 &
```

When the program ends, you will find a directory named ***result$i***, ***$i*** is the number of containers you want to test. The file ***io.ascii*** is what you need to run in ssdsim, and the file ***result_path.txt*** is what you can check and analyze.

#### TEST02: UpperLayer and LowerLayer are in the same SSD(TESTING)

You can download the code by:

```shell
git clone -b origin https://github.com/BostonRunner/SSDsim_traceprocess_ESSD
```

Please prepare an isolated disk for docker data storage**(AT LEAST 50GB)**, for example, "***/dev/vdb***". It must be formatted in the form of ext4,  and if you want to store the images and the data of containers in the directory ***/mnt/docker_tmp*** and mount it on the disk, you can use these two commands:

```shell
mkfs.ext4 /dev/vdb
mount /dev/vdb /mnt/docker_tmp
```

After installing these two,  please edit ***daemon.json*** in ***/etc/docker***, for example:

```shell
vim /etc/docker/daemon.json
```

In this program, the data of containers should be in a clean storage device that do not have any other writing traces. So we can proposed that if you want to store the images and the data of containers in the directory ***/mnt/docker_tmp***, which has been mounted on device ***/dev/vdb***, you can write this in ***daemon.json***:

```json
{
	"data-root":"/mnt/docker_tmp"
}
```

Then you can run this command to restart the docker in order to activate the new setting:

```shell
systemctl restart docker
```

And great, you can edit ***blktrace.sh*** and ***main.py*** to make adjustment to the new device and directory

You can run the shell script **run_multi_containers.sh** to use this program:

```shell
./run_multi_containers.sh
```

In some cloud environments (especially when using ESSD), IOPS often has performance bursts, resulting in the actual experimental IOPS being greater than the purchased configuration. Therefore, you can first run script **run_single_containers.sh** to get the actual IOPS under maximum load:

```
./run_single_containers.sh
```



#### TEST03: UpperLayer and LowerLayer are in TWO SSDs respectively(TESTING)

You can download the code by:

```shell
git clone -b optimize-lower-upper https://github.com/BostonRunner/SSDsim_traceprocess_ESSD
```

Please prepare **TWO** isolated disk for docker data storage**(AT LEAST 10GB+45GB)**, for example, "***/dev/vdb***" and "**/dev/vdc**". It must be formatted in the form of ext4,  and if you want to store the images in the directory ***/mnt/docker/lower*** and the data of containers in the directory  **/mnt/docker/lower** and mount them on the disk, you can use these four commands:

```shell
mkfs.ext4 /dev/vdb
mkfs.ext4 /dev/vdc
mount /dev/vdb /mnt/docker/lower
mount /dev/vdc /mnt/docker/upper
```

Also, you can make directories for every container:

```
cd /mnt/docker/lower
mkdir c1 c2 c3 c4 c5 c6
cd /mnt/docker/upper
mkdir c1 c2 c3 c4 c5 c6
```

You can run the shell script **run_multi_containers.sh** to use this program:

```shell
./run_multi_containers.sh
```

In some cloud environments (especially when using ESSD), IOPS often has performance bursts, resulting in the actual experimental IOPS being greater than the purchased configuration. Therefore, you can first run script **run_multi_containers.sh** to get the actual IOPS under maximum load:

```
./run_single_containers.sh
```

#### TEST04: UpperLayer and LowerLayer are in the same SSD(TESTING)

You can download the code by:

```shell
git clone -b optimize-6upper-lower https://github.com/BostonRunner/SSDsim_traceprocess_ESSD
```

Please prepare **SEVEN** isolated disk for docker data storage**(AT LEAST 10GB+6x10GB)**, for example, **FROM "*/dev/vdb*" , "*/dev/vdc*" TO "*/dev/vdh*"**. It must be formatted in the form of ext4,  and if you want to store the images in the directory ***/mnt/docker/lower*** and the data of containers in the directory  **/mnt/docker/lower** and mount them on the disk, you can use these commands:

```shell
#!/bin/bash

# Configuration variables
BASE_DIR="/mnt/docker"
LOWER_DIR="${BASE_DIR}/lower"
UPPER_DIR="${BASE_DIR}/upper"
DEVICES=("/dev/vdb" "/dev/vdc" "/dev/vdd" "/dev/vde" "/dev/vdf" "/dev/vdg" "/dev/vdh")
SUB_DIRS=("c1" "c2" "c3" "c4" "c5" "c6")

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root" >&2
    exit 1
fi

# Create base directories
mkdir -p "${LOWER_DIR}" "${UPPER_DIR}" || exit 1

# Create subdirectories in upper directory only (for now)
mkdir -p "${UPPER_DIR}/"{c1,c2,c3,c4,c5,c6} || exit 1

# Format devices (skip if already formatted)
for device in "${DEVICES[@]}"; do
    if ! blkid -o value -s TYPE "$device" >/dev/null 2>&1; then
        echo "Formatting ${device}..."
        mkfs.ext4 -F "$device" || exit 1
    fi
done

# Mount the main lower device
mount "${DEVICES[0]}" "${LOWER_DIR}" || exit 1

# Create subdirectories in lower directory after mounting
mkdir -p "${LOWER_DIR}/"{c1,c2,c3,c4,c5,c6} || exit 1

# Mount subdevices to upper subdirectories
for i in "${!SUB_DIRS[@]}"; do
    mount "${DEVICES[i+1]}" "${UPPER_DIR}/${SUB_DIRS[i]}" || exit 1
done

echo "All operations completed successfully"
```

You can run the shell script **run_multi_containers.sh** to use this program:

```shell
./run_multi_containers.sh
```

In some cloud environments (especially when using ESSD), IOPS often has performance bursts, resulting in the actual experimental IOPS being greater than the purchased configuration. Therefore, you can first run script **run_multi_containers.sh** to get the actual IOPS under maximum load:

```
./run_single_containers.sh
```

#### 
