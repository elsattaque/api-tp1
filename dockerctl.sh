#!/usr/bin/env bash
set -euo pipefail

SOCK=${DOCKER_SOCK:-/var/run/docker.sock}
LABEL_KEY=tp
LABEL_VALUE=api-rest
BODY=$(mktemp)
trap 'rm -f "$BODY"' EXIT

# api MÉTHODE CHEMIN [JSON]
# Écrit le corps de la réponse dans $BODY et affiche le code HTTP.
api() {
  local method=$1 path=$2 data=${3:-}
  local args=(-sS --unix-socket "$SOCK" -X "$method" -o "$BODY" -w '%{http_code}')
  if [[ -n $data ]]; then
    args+=(-H 'Content-Type: application/json' --data "$data")
  fi
  # si Docker est injoignable, curl affiche 000 : c'est expect qui gère l'erreur
  curl "${args[@]}" "http://localhost$path" || true
}

die() { echo "erreur : $*" >&2; exit 1; }

# expect CODE CODE_ATTENDU...
# Arrête le script si CODE n'est pas un des codes attendus, avec le message de Docker.
expect() {
  local code=$1 ok msg
  shift
  for ok in "$@"; do
    if [[ $code == "$ok" ]]; then return 0; fi
  done
  if [[ $code == 000 ]]; then
    die "impossible de joindre Docker sur $SOCK"
  fi
  msg=$(jq -r '.message // empty' "$BODY" 2>/dev/null || true)
  die "${msg:-réponse inattendue} (HTTP $code)"
}

# Encode une chaîne pour la placer dans une URL.
uri() { jq -rn --arg s "$1" '$s | @uri'; }

# Comme Docker, on impose un premier caractère alphanumérique (ce qui refuse aussi « .. »).
check_name() {
  [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || die "nom invalide : '$1' (lettres, chiffres, _ . - uniquement)"
}

# Liste les conteneurs du TP (filtre sur le label) dans $BODY.
tp_containers() {
  local filters code
  # « label » est un mot-clé de jq : la variable ne peut pas s'appeler $label
  filters=$(jq -nc --arg tp_label "$LABEL_KEY=$LABEL_VALUE" '{label: [$tp_label]}')
  code=$(api GET "/containers/json?all=true&filters=$(uri "$filters")")
  expect "$code" 200
}

# remove_container ID : arrête puis supprime le conteneur.
remove_container() {
  local code
  code=$(api POST "/containers/$1/stop?t=5")
  expect "$code" 204 304
  code=$(api DELETE "/containers/$1")
  expect "$code" 204
}

cmd_ls() {
  tp_containers
  printf '%-20s %-10s %-25s %s\n' NOM ETAT IMAGE PORTS
  jq -r '.[] | [
      .Names[0][1:],
      .State,
      .Image,
      ([(.Ports // [])[] | select(.PublicPort) | "\(.PublicPort)->\(.PrivatePort)"]
        | unique | join(",") | if . == "" then "-" else . end)
    ] | @tsv' "$BODY" |
  while IFS=$'\t' read -r name state image ports; do
    printf '%-20s %-10s %-25s %s\n' "$name" "$state" "$image" "$ports"
  done
}

cmd_run() {
  [[ $# -eq 2 || $# -eq 3 ]] || die "usage : $0 run NOM IMAGE [PORT_HÔTE:PORT_CONTENEUR]"
  local name=$1 image=$2 ports=${3:-} host_port='' cont_port='' code body id err msg
  check_name "$name"
  if [[ -n $ports ]]; then
    [[ $ports =~ ^([0-9]+):([0-9]+)$ ]] || die "ports invalides : '$ports' (attendu PORT_HÔTE:PORT_CONTENEUR)"
    host_port=${BASH_REMATCH[1]}
    cont_port=${BASH_REMATCH[2]}
  fi
  # sans tag, /images/create téléchargerait tous les tags de l'image
  [[ ${image##*/} == *[:@]* ]] || image+=:latest

  code=$(api GET "/images/$image/json")
  if [[ $code == 404 ]]; then
    code=$(api POST "/images/create?fromImage=$(uri "$image")")
    expect "$code" 200
    # la réponse est un flux : une erreur de téléchargement arrive dedans, avec un code 200
    err=$(jq -rs 'map(.error // empty) | first // empty' "$BODY")
    [[ -z $err ]] || die "téléchargement de $image : $err"
  else
    expect "$code" 200
  fi

  body=$(jq -n --arg image "$image" --arg key "$LABEL_KEY" --arg value "$LABEL_VALUE" \
              --arg hp "$host_port" --arg cp "$cont_port" '
    {Image: $image, Labels: {($key): $value}}
    | if $cp == "" then . else
        .ExposedPorts = {"\($cp)/tcp": {}}
        | .HostConfig.PortBindings = {"\($cp)/tcp": [{HostPort: $hp}]}
      end')
  code=$(api POST "/containers/create?name=$name" "$body")
  expect "$code" 201
  id=$(jq -r .Id "$BODY")

  code=$(api POST "/containers/$id/start")
  if [[ $code != 204 ]]; then
    # créé mais impossible à démarrer (port déjà pris…) : on ne le laisse pas traîner
    msg=$(jq -r '.message // empty' "$BODY" 2>/dev/null || true)
    if [[ $(api DELETE "/containers/$id?force=true") != 204 ]]; then
      echo "attention : le conteneur $name n'a pas pu être supprimé" >&2
    fi
    die "${msg:-démarrage impossible} (HTTP $code)"
  fi
  echo "${id:0:12}"
}

cmd_exec() {
  [[ $# -ge 2 ]] || die "usage : $0 exec NOM COMMANDE..."
  local name=$1 code cmd body exec_id exit_code
  shift
  check_name "$name"
  # tableau JSON des arguments (jq --args prendrait « -v » pour une option).
  # rtrimstr plutôt que .[:-1] : jq 1.6 ne renvoie pas l'élément vide final de split.
  cmd=$(printf '%s\0' "$@" | jq -Rs 'rtrimstr("\u0000") | split("\u0000")')
  body=$(jq -n --argjson cmd "$cmd" '{Cmd: $cmd, AttachStdout: true, AttachStderr: true, Tty: true}')
  code=$(api POST "/containers/$name/exec" "$body")
  expect "$code" 201
  exec_id=$(jq -r .Id "$BODY")

  # avec Tty, la sortie arrive brute, sans les en-têtes de 8 octets
  code=$(api POST "/exec/$exec_id/start" "$(jq -n '{Detach: false, Tty: true}')")
  expect "$code" 200
  cat "$BODY"

  code=$(api GET "/exec/$exec_id/json")
  expect "$code" 200
  exit_code=$(jq -r '.ExitCode // empty' "$BODY")
  [[ -n $exit_code ]] || die "code de sortie de la commande inconnu"
  exit "$exit_code"
}

cmd_rm() {
  [[ $# -eq 1 ]] || die "usage : $0 rm NOM"
  local name=$1 code id
  check_name "$name"
  code=$(api GET "/containers/$name/json")
  if [[ $code == 404 ]]; then
    echo "$name : déjà absent"
    return 0
  fi
  expect "$code" 200
  if [[ $(jq -r --arg key "$LABEL_KEY" '.Config.Labels[$key] // empty' "$BODY") != "$LABEL_VALUE" ]]; then
    die "$name n'est pas un conteneur du TP (label $LABEL_KEY=$LABEL_VALUE absent)"
  fi
  id=$(jq -r .Id "$BODY")
  remove_container "$id"
  echo "$name supprimé"
}

cmd_clean() {
  local ids names i
  tp_containers
  mapfile -t ids < <(jq -r '.[].Id' "$BODY")
  mapfile -t names < <(jq -r '.[].Names[0][1:]' "$BODY")
  if [[ ${#ids[@]} -eq 0 ]]; then
    echo "aucun conteneur du TP"
    return 0
  fi
  for i in "${!ids[@]}"; do
    remove_container "${ids[$i]}"
    echo "${names[$i]} supprimé"
  done
}

case ${1:-} in
  ls|run|exec|rm|clean) cmd=$1; shift; "cmd_$cmd" "$@" ;;
  *) echo "usage : $0 {ls|run|exec|rm|clean} …" >&2; exit 2 ;;
esac
