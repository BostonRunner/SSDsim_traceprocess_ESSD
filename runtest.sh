docker system prune -af --volumes
./IO.sh
python3 summarize.py ./results_all
