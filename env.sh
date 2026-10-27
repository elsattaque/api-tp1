# dapi MÉTHODE CHEMIN [JSON]
# Le corps de la réponse va sur stdout (pour jq), le code HTTP sur stderr.
dapi() {
  local method=$1 path=$2 data=${3:-}
  local args=(-sS --unix-socket "$DOCKER_SOCK" -X "$method"
              -w '%{stderr}→ HTTP %{http_code}\n')
  if [[ -n $data ]]; then
    args+=(-H 'Content-Type: application/json' --data "$data")
  fi
  curl "${args[@]}" "http://localhost$path"
}
