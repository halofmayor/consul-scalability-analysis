docker network create consul-net

docker run -d --name consul-server \
  --net consul-net \
  --cpus="1.0" \
  --memory="512m" \
  -p 8500:8500 \
  -p 8600:8600/udp \
  hashicorp/consul:latest agent -server -bootstrap-expect=1 -ui -client=0.0.0.0

  docker exec -it consul-server consul members

  curl http://localhost:8500/v1/status/leader

  # Inserir uma chave simulando a configuração de arranque de uma aplicação
curl --request PUT \
  --data '{"db_host": "db.internal", "db_port": 5432, "timeout": 30, "feature_flags": {"new_ui": true}}' \
  http://localhost:8500/v1/kv/config/app-service

  curl http://localhost:8500/v1/kv/config/app-service


  /////

docker run --rm -i --net consul-net grafana/k6 run - --vus 10 --duration 10s << 'EOF'
import http from 'k6/http';
export default function () {
  http.get('http://consul-server:8500/v1/kv/config/app-service?consistent');
}
EOF