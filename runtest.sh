docker system prune -af --volumes
./test.sh
python3 summarize.py ./results_all
