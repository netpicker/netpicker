docker compose down
mv docker-compose.yml docker-compose.yml.bak.$(date +%s)
git pull
docker compose pull
docker compose up -d
