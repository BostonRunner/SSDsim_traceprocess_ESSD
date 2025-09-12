# ***TRACE PROCESSOR***

## **1. ABOUT THIS PROGRAM**



## **2. BEFORE YOU USE THIS PROGRAM**

Please check if you have installed these programs:

***1.blktrace***

***2.docker***

If you do not have installed these two programs, you can run ***apt install blktrace*** and ***apt install docker.io*** .

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

## **3.HOW TO USE THIS PROGRAM**

#### TEST01: UpperLayer and LowerLayer are in the same SSD(TRACE COLLECTION)

You can download the code by:

```shell
git clone -b main https://github.com/BostonRunner/SSDsim_traceprocess_ESSD
```

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

You can run the shell script **run_multi_containers.sh** to use this program:

```shell
./run_multi_containers.sh
```

In some cloud environments (especially when using ESSD), IOPS often has performance bursts, resulting in the actual experimental IOPS being greater than the purchased configuration. Therefore, you can first run script **run_multi_containers.sh** to get the actual IOPS under maximum load.

#### TEST03: UpperLayer and LowerLayer are in the same SSD(TESTING)



#### TEST04: UpperLayer and LowerLayer are in the same SSD(TESTING)
