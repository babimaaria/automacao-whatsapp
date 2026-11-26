# Replicar este ambiente em outro computador

Guia para subir uma cópia idêntica desta stack (n8n + Evolution API +
Postgres + Redis + ngrok + Adminer) em outra máquina, incluindo os dados —
de forma que **não seja necessário escanear o QR code do WhatsApp de novo**.

Isso é possível porque, nesta configuração, a credencial de login do
WhatsApp (sessão Baileys) fica salva **dentro do Postgres** (tabela
`Session`, vinculada à `Instance` da Barbara) e não em um arquivo solto —
então migrar o banco migra a sessão logada junto.

## Pré-requisitos na máquina nova

- [Docker Desktop](https://docs.docker.com/get-docker/) instalado e rodando
  (no Windows, com WSL2 habilitado).
- Git instalado.
- Uma conta [ngrok](https://ngrok.com/) (grátis serve) com authtoken próprio
  — **não reutilize o mesmo authtoken em duas máquinas simultaneamente**,
  gere um novo se for rodar em paralelo, ou pare a instância antiga antes de
  subir a nova.

## Imagens exatas usadas (para reprodução idêntica)

| Serviço | Imagem:tag |
|---|---|
| n8n | `n8nio/n8n:latest` |
| evolution-api | `evoapicloud/evolution-api:v2.3.7` |
| postgres | `ankane/pgvector:latest` |
| redis | `redis:alpine` |
| ngrok | `ngrok/ngrok:alpine` |
| adminer | `adminer:latest` |

O `docker-compose.yml` do repositório já fixa a tag `v2.3.7` da Evolution
API (importante — versões diferentes podem ter schema de banco
incompatível). As demais usam `:latest`; se quiser uma reprodução 100%
determinística, fixe também os digests atuais:

```bash
docker images --digests | grep -E "n8n|postgres|pgvector|ngrok|redis|adminer"
```

## Passo 1 — Clonar o repositório

```bash
git clone https://github.com/<seu-usuario>/n8n-evoapi-ngrok.git
cd n8n-evoapi-ngrok
```

## Passo 2 — Criar os arquivos de configuração local

```bash
cp .env.example .env
cp ngrok.yml.example ngrok.yml
```

Edite `.env` e `ngrok.yml` com os valores reais (peça-os a quem administra
o projeto — não ficam no git por segurança):

- `.env`: `POSTGRES_USER`, `POSTGRES_PASSWORD`, `N8N_BASIC_AUTH_USER/PASSWORD`,
  `AUTHENTICATION_API_KEY` (Evolution API) — idealmente os **mesmos valores**
  da máquina original, para evitar qualquer inconsistência ao restaurar o
  dump do banco (usuário/senha do Postgres precisam bater com o dump).
- `ngrok.yml`: `authtoken` da conta ngrok (pode ser um authtoken novo,
  diferente da máquina original).

## Passo 3 — Exportar os dados da máquina original

Na máquina **original** (onde o projeto já roda):

```bash
# Dump completo do Postgres (inclui dados do n8n E da Evolution API,
# sessão do WhatsApp incluída)
docker exec postgres pg_dump -U <POSTGRES_USER> -d <POSTGRES_DB> -F c -f /tmp/app_db.dump
docker cp postgres:/tmp/app_db.dump ./app_db.dump
```

Copie o arquivo `app_db.dump` gerado para a máquina nova (pendrive, SCP,
serviço de arquivos — como preferir; é só um arquivo binário, ~150-200MB
nesta instância).

> **Não é necessário** copiar o volume `lab_evolution_instances` — ele fica
> vazio nesta configuração (`DATABASE_ENABLED=true` na Evolution API desvia
> tudo para o Postgres). Também não é necessário copiar o volume `n8n_data`
> separadamente, já que os workflows do n8n também vivem no Postgres.

## Passo 4 — Subir a stack vazia na máquina nova

```bash
docker compose up -d postgres
```

Aguarde ~10s o Postgres inicializar, depois pare-o antes de restaurar (para
evitar conexões concorrentes durante o restore):

```bash
docker compose stop postgres
docker compose up -d postgres
```

## Passo 5 — Restaurar o dump

```bash
docker cp ./app_db.dump postgres:/tmp/app_db.dump
docker exec postgres pg_restore -U <POSTGRES_USER> -d <POSTGRES_DB> --clean --if-exists /tmp/app_db.dump
```

Se o banco `<POSTGRES_DB>` ainda não existir (primeira inicialização do
container cria automaticamente a partir do `.env`), confirme o nome antes
de restaurar:

```bash
docker exec postgres psql -U <POSTGRES_USER> -l
```

## Passo 6 — Subir o restante da stack

```bash
docker compose up -d
```

Aguarde ~20-30s todos os serviços estabilizarem, depois confirme:

```bash
docker compose ps
docker exec postgres psql -U <POSTGRES_USER> -d <POSTGRES_DB> -c "SELECT id, name, \"connectionStatus\" FROM \"Instance\";"
```

Se a linha da instância `Barbara` aparecer com `connectionStatus = open`
(ou mesmo `close`, mas sem exigir QR novo ao consultar
`/instance/connect/Barbara`), a sessão migrou corretamente.

## Passo 7 — Checar a conexão do WhatsApp

```bash
curl -s "http://localhost:8080/instance/connectionState/Barbara" -H "apikey: <AUTHENTICATION_API_KEY>"
```

- Se vier `{"state":"open"}` e os logs (`docker logs lab_evolution_api`)
  mostrarem eventos chegando normalmente → migrou sem precisar de QR. ✅
- Se vier `close` ou pedir reconexão, gere um QR novo apenas desta vez:
  ```bash
  curl -s "http://localhost:8080/instance/connect/Barbara" -H "apikey: <AUTHENTICATION_API_KEY>"
  ```
  (resposta trará um campo `base64` com a imagem do QR para escanear no
  WhatsApp da Barbara).

> **Atenção:** se a instância original (máquina antiga) continuar rodando
> AO MESMO TEMPO que a nova com a mesma sessão restaurada, o WhatsApp pode
> tratar isso como dois dispositivos conflitantes e gerar os bugs de
> sincronização documentados em `PROJETO.md` (seção "Dispositivos
> fantasma"). **Pare a instância antiga antes de ativar a nova em
> produção.**

## Passo 8 — Reapontar o webhook para a nova URL do ngrok

A URL pública do ngrok é por conta/túnel — vai ser diferente na máquina
nova. Depois do `docker compose up -d`:

```bash
curl http://localhost:4040/api/tunnels
```

Copie a `public_url` retornada e reaponte o webhook:

```bash
curl -X POST "http://localhost:8080/webhook/set/Barbara" \
  -H "apikey: <AUTHENTICATION_API_KEY>" -H "Content-Type: application/json" \
  -d '{"webhook": {"url": "https://<nova-url>/webhook/message", "enabled": true, "events": ["MESSAGES_UPSERT"], "webhookByEvents": false, "webhookBase64": false}}'
```

Confirme:
```bash
curl "http://localhost:8080/webhook/find/Barbara" -H "apikey: <AUTHENTICATION_API_KEY>"
```

## Passo 9 — Gerar nova API key do n8n (se for usar a API REST)

Tokens de API do n8n não migram pelo dump de forma utilizável externamente
pela UI — gere um novo em **Settings → n8n API → Create API Key** dentro da
interface web do n8n (`http://localhost:5678`), usando o usuário/senha
definidos em `.env` (`N8N_BASIC_AUTH_USER`/`PASSWORD`).

## Passo 10 (opcional) — Watchdog automático

Se quiser o mesmo comportamento de auto-recuperação em caso de travamento
da sessão Baileys (bug documentado em `PROJETO.md`), copie também
`watchdog-evolution.ps1` e rode:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File watchdog-evolution.ps1
```

## Resumo rápido (checklist)

- [ ] Docker + Git instalados na máquina nova
- [ ] `git clone` do repositório
- [ ] `.env` e `ngrok.yml` criados a partir dos `.example`, com valores reais
- [ ] `pg_dump` feito na máquina original e copiado para a nova
- [ ] Postgres subido isolado, dump restaurado via `pg_restore`
- [ ] Stack completa no ar (`docker compose up -d`)
- [ ] `connectionState` da instância `Barbara` confirmado `open` (sem QR)
- [ ] Máquina original parada (evitar sessão duplicada)
- [ ] Webhook reapontado para a nova URL do ngrok
- [ ] Nova API key do n8n gerada, se for usar a API REST
