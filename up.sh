docker compose down
docker compose pull
for volume in $(docker volume ls -q | egrep 'netpicker_(policy-data|secret|git)'); do docker run -u 0 --rm -v $volume:/volume netpicker/db chown -R 911:911 /volume; done
docker compose up -d
