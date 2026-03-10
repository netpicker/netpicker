bash down.sh
mv docker-compose.yml docker-compose.yml.bak.$(date +%s)
git pull
docker compose pull
bash up.sh
