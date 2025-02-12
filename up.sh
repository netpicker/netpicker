docker compose pull
for volume in $(docker volume ls -q | egrep 'netpicker_(policy-data|secret)'); do docker run -u 0 --rm -v $volume:/volume busybox chown -R 911:911 /volume; done
docker compose up -d
