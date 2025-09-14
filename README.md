All-in-one single-node Ceph (size=1) experiment kit.

0) Optional bootstrap (Ubuntu):
   cd scripts && sudo ./00_bootstrap_k8s.sh
1) Run experiment:
   cd scripts && ./10_run_all_single_node_s1.sh
2) Cleanup:
   cd scripts && ./90_cleanup.sh
To uninstall rook and wipe disks:
   UNINSTALL_ROOK=yes WIPE_OSD=yes ./90_cleanup.sh
