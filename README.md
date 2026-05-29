# Start everything
docker compose up -d

# Start a specific container
docker compose up <CONTAINER> -d

If UI is closed, do "docker compose up gaze-capture -d"

# Stop everything
docker compose down

# Watch all logs
tail -f logs/*.log

# Watch a specific log
tail -f logs/<CONTAINER>.log

# Watch detailed predictions
docker compose exec task-pred task-pred monitor

# How to check audio sources (system and microphone)
pactl list short sources