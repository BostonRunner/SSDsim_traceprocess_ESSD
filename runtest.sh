docker system prune -af --volumes
./test.sh
python3 separate_storage.py ./results_all
