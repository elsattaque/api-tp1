# TP1 : piloter Docker par son API, en Bash et jq

## Partie 1 : explorer l'API

### 1.1

Commande utilisée : 
```bash
dapi GET /version | jq
```

Sortie :
```json
{
  "Version": "29.9.2",
  "ApiVersion": "1.56",
}
```

### 1.2

Commande utilisée : 
```bash
dapi GET /info | jq '{Containers, ContainersRunning, Images, OperatingSystem, NCPU}'
```

Sortie :
```json
{
  "Containers": 1,
  "ContainersRunning": 0,
  "Images": 1,
  "OperatingSystem": "Docker Desktop",
  "NCPU": 4,
}
```

### 1.3

Commande utilisée : 
```bash
dapi GET /info | jq '.MemTotal / (1024*1024*1024) | round'
```

Sortie :
```bash
4
```

### 1.4

Commande utilisée : 
```bash
dapi GET '/containers/json?all=true' | jq '.[] | "\(.Names[0])   \(.State)   \(.Image)"'
```

Sortie :
```json
{
  "/unruffled_sutherland   exited   hello-world"
}
```

### 1.5

Commande utilisée : 
```bash
dapi GET /images/json | jq '.[] | .RepoTags[]'
```

Sortie :
```json
{
  "hello-world:latest"
}
```

Commande utilisée : 
```bash
dapi GET /images/json | jq 'map(.Size) | add / 1000000'
```

Sortie :
```bash
0.025874
```

## Partie 2 : le cycle de vie d'un conteneur

### Tableau des codes HTTP

| Étape | Requête | Code HTTP | Signification | 
| --- | --- | --- | --- |
| 2.1 | `POST /images/create` |  200 |  Ok |
| 2.2 | `POST /containers/create` |  201 |  Created |
| 2.2 bis | même requête, une seconde fois |  409 |  Conflict |
| 2.3 | `POST /containers/{id}/start` |  204 |  No content |
| 2.3 bis | même requête, une seconde fois |  304 |  Not Modified  |
| 2.5 | `DELETE` sur un conteneur en marche |  409 |  Conflict  |
| 2.6 | `POST …/stop` |  204 |  No content  |
| 2.6 bis | même requête, une seconde fois |  304 |  Not Modified  |
| 2.7 | `DELETE /containers/{id}` |  204 |  No content  |
| 2.7 bis | `GET /containers/{id}/json` après suppression |  404 |  Not Found  |
| 3.1 | `POST /exec/{id}/start` d'une commande qui échoue |  200 |  Ok  |

### 2.1

```bash
dapi POST '/images/create?fromImage=nginx&tag=alpine' | tail -n 3
```

```bash
→ HTTP 200
{"status":"Pull complete","progressDetail":{"hidecounts":true},"id":"b9b388a21ecf"}{"status":"Digest: sha256:a3554c0d0b48177b1413c26e01f695334428020d9df01243fbae3e11cfd17417"}
{"status":"Status: Downloaded newer image for nginx:alpine"}
```

**Pourquoi l'API ne répond-elle pas en un seul bloc ?**

Le téléchargement est long (plusieurs couches). En flux, Docker montre la progression en temps réel, au lieu de faire attendre le client sans réponse jusqu'à la fin.

### 2.2

```bash
BODY=$(jq -n '{
  Image: "nginx:alpine",
  Labels: {tp: "api-rest"},
  ExposedPorts: {"80/tcp": {}},
  HostConfig: {PortBindings: {"80/tcp": [{HostPort: "8088"}]}}
}')
dapi POST '/containers/create?name=web-tp1' "$BODY" | jq
```

```bash
→ HTTP 201 
{
  "Id": "96ec92aadc1d6f289be063188ac5b57a413712fbaec7d37e7671fdc442991c1a",
  "Warnings": []
}
```

**Quel code obtenez-vous, et que dit le message ?**

```bash
→ HTTP 409
{
  "message": "Conflict. The container name \"/web-tp1\" is already in use by container \"96ec92aadc1d6f289be063188ac5b57a413712fbaec7d37e7671fdc442991c1a\". You have to remove (or rename) that container to be able to reuse that name."
}
```

On obtient 409 Conflict : le nom web-tp1 est déjà pris par le conteneur créé juste avant. Docker refuse d'en créer un second avec le même nom. Il faut d'abord supprimer ou renommer l'existant. Créer deux fois la même chose ne réussit donc pas deux fois.

### 2.3

```bash
dapi POST /containers/web-tp1/start
```

**Quel code ? Pourquoi la réponse n'a-t-elle pas de corps ?**

```bash
→ HTTP 204
```

On obtient 204 No Content : le conteneur a bien démarré. La réponse n'a pas de corps parce qu'il n'y a rien à renvoyer, l'action a réussi et le code suffit à le dire. Justement, 204 veut dire « succès, sans contenu ».

**Quel code obtenez-vous maintenant, et que signifie-t-il ?**

```bash
→ HTTP 304
```

On obtient 304 Not Modified : le conteneur tourne déjà, donc Docker ne fait rien, l'état démarré est déjà atteint. Relancer start ne change rien, l'opération se comporte de façon idempotente.

### 2.4

```bash
dapi GET /containers/web-tp1/json | jq '{Status: .State.Status, StartedAt: .State.StartedAt, HostPort: .NetworkSettings.Ports["80/tcp"][0].HostPort, Labels: .Config.Labels}'
```

```json
→ HTTP 200
{
  "Status": "running",
  "StartedAt": "2026-10-26T11:56:15.449661761Z",
  "HostPort": "8088",
  "Labels": {
    "desktop.docker.io/wsl-distro": "Debian",
    "maintainer": "NGINX Docker Maintainers <docker-maint@nginx.com>",
    "tp": "api-rest"
  }
}
```

### 2.5

```bash
dapi DELETE /containers/web-tp1
```

```bash
→ HTTP 409
{"message":"cannot remove container \"web-tp1\": container is running: stop the container before removing or force remove"}
```

**Quel code ? Pourquoi est-ce le bon code, plutôt que 400 ou 403 ?**

On obtient 409 Conflict, c'est la bonne requête car ça signifie que c'est en conflit avec l'état de la ressource. Il faut d'abord l'arrêter, ou forcer la suppression. Donc ce n'est pas un 400 (Bad Request), et on a le droit de supprimer le conteneur, donc ce n'est pas un 403 (Forbidden).

### 2.6

1ère fois :
```bash
→ HTTP 204
```

2ème fois :
```bash
→ HTTP 304
```

**Que signifie le paramètre t ?**

t est le délai en secondes que Docker accorde au conteneur pour s'arrêter proprement avant de le tuer.

### 2.7

Suppression :
```bash
→ HTTP 204
```

Vérification :
```bash
→ HTTP 404 
```

**Que renverrait un deuxième DELETE ? Peut-on dire que DELETE est idempotent ici ?**

Un deuxième DELETE renverrait 404, car le conteneur n'existe plus. DELETE est quand même idempotent : on peut le répéter, le résultat reste le même (le conteneur est supprimé). Seul le code de réponse change.

## Partie 3 : exécuter une commande, lire les logs

### 3.1

Sortie de l'étape 2 :
```bash
nginx version: nginx/1.31.8
NAME="Alpine Linux"
ID=alpine
→ HTTP 200
```

Sortie de l'étape 3 :
```bash
→ HTTP 200
{
  "ExitCode": 0,
  "Running": false
}
```

Sortie de l'étape 2 avec ls /nexiste-pas :
```bash
ls: /nexiste-pas: No such file or directory
→ HTTP 200
```

Sortie de l'étape 3 avec ls /nexiste-pas :
```bash
→ HTTP 200
{
  "ExitCode": 1,
  "Running": false
}
```

L'étape 2 renvoie 200 alors que la commande a échoué (ExitCode = 1). Le code HTTP indique seulement que l'API a bien fait son travail : elle a lancé la commande et renvoyé sa sortie. Pour savoir si la commande a réussi, il faut lire son ExitCode à l'étape 3. Un 200 ne veut donc pas dire que la commande a réussi.

### 3.2

```bash
00000000: 0100 0000 0000 005b 3137 322e 3137 2e30  .......[172.17.0
00000010: 2e31 202d 202d 205b 3237 2f4f 6374 2f32  .1 - - [27/Oct/2
```

Les 8 octets d'en-tête contiennent :
- l'octet 1 : le flux d'origine (01 = stdout, 02 = stderr) ;
- les octets 2 à 4 : des zéros ;
- les octets 5 à 8 : la taille du message qui suit.

Le conteneur web-tp1 a été créé sans TTY. Docker envoie alors stdout et stderr sur la même connexion et ajoute cet en-tête pour qu'on puisse les séparer. En 3.1, l'exec était lancé avec Tty: true : la sortie est alors un flux brut unique, sans en-tête.
