# Automação Shopee/Mercado Livre — WhatsApp (Barbara)

Documento de referência do que este projeto faz, como está montado e os
problemas conhecidos. Serve tanto para humanos quanto para IA assistente
(Claude/ChatGPT) retomarem o contexto rapidamente.

## O que o fluxo faz

A Barbara manda links de produto (Shopee, hoje; Mercado Livre pausado — ver
abaixo) para si mesma no WhatsApp. Um workflow n8n escuta essas mensagens via
webhook da Evolution API e:

1. Extrai o link Shopee da mensagem.
2. Busca dados do produto (nome, preço, imagem, se está em promoção) via
   Shopee Affiliate GraphQL API.
3. Gera uma legenda formatada (preço, desconto, aviso de desconto extra no
   Pix quando há promoção).
4. Opcionalmente gera uma imagem ambientada do produto via Bria AI.
5. Publica a legenda + imagem em um dos dois grupos de WhatsApp da Barbara.

### Comando de roteamento `!g2`

Link normal → vai para o grupo padrão ("Garimpo da Ba | Home"). Prefixando a
mensagem com `!g2 <link>` → vai para o grupo "Garimpo da Ba | Beauty" em vez
do padrão. Implementado no node `Extrair Links Shopee` via constante
`DESTINO_GRUPO_BEAUTY`; o `remoteJid` final é propagado via `$json.remoteJid`
por todo o resto do pipeline, sem hardcode downstream.

### Lembretes de data promocional (9.9, 10.10, 11.11, etc.)

No node `Gerar Legenda e Montar Mensagem` existe um bloco que, em uma data
específica do ano, a cada N produtos processados, anexa um link de cupom à
legenda. Controlado por um contador em `$getWorkflowStaticData('global')`
(`contadorXX`) e um check de mês/dia (`hoje.getUTCMonth()`/`getUTCDate()`).
Esse bloco é editado manualmente a cada nova data comercial (mudar data,
link do cupom, e o `% N` de frequência).

### Mercado Livre (PAUSADO)

Investigado a fundo e pausado a pedido da usuária em 10/10/2026. O ML não
tem API pública de geração de link de afiliado (diferente da Shopee) — o
link é só concatenação de parâmetros fixos (`matt_word`, `matt_tool`) na URL
do produto. Além disso, `GET /items/{id}` e `/sites/MLB/search` retornam 403
mesmo autenticados como a própria dona da conta — bloqueio institucional do
ML, não ligado ao tipo de OAuth. Caminho viável sem infra nova: comando `!ml`
onde a Barbara manda a FOTO do produto + legenda, e o Gemini Vision lê
nome/preço direto da imagem. Tem um bug conhecido não corrigido: como a foto
enviada é print de tela inteiro do app (com navbar, botões, toasts), a Bria
AI "pendura" o print inteiro dentro da cena ambientada em vez de tratar só o
produto. Decisão da usuária: não mexer até decidir uma abordagem (crop
automático, desativar Bria nesse fluxo, ou pedir foto já recortada).

## Stack e onde cada coisa mora

| Serviço | Imagem | Porta | Função |
|---|---|---|---|
| n8n | `n8nio/n8n` | 5678 | Orquestra o workflow |
| evolution-api | `evoapicloud/evolution-api:v2.3.7` | 8080 | Gateway WhatsApp (Baileys) |
| postgres | `ankane/pgvector` | 5432 | Banco do n8n **e** da Evolution API (sessão Baileys incluída) |
| redis | `redis:alpine` | 6380→6379 | Cache da Evolution API |
| ngrok | `ngrok/ngrok:alpine` | 4040 | Túnel público para o webhook do n8n |
| adminer | `adminer` | 8081 | Interface web pro Postgres |

**Importante:** a credencial de login do WhatsApp (sessão Baileys) está
salva no **Postgres**, tabela `Session` (coluna de creds, vinculada à
`Instance` `Barbara`), não em arquivo/volume local. O volume Docker
`lab_evolution_instances` existe mas fica vazio nesta configuração
(`DATABASE_ENABLED=true` na Evolution API desvia a persistência pro banco).
Isso é relevante para migração — ver `REPLICAR-AMBIENTE.md`.

### Workflow principal

- ID: `WSfNRxwVYtg0CyNC`
- Nodes relevantes: `Extrair Links Shopee`, `Buscar Produto Shopee`,
  `Gerar Legenda e Montar Mensagem`, `Tem Imagem?`, `Enviar Imagem`.

### Grupos WhatsApp

- Padrão (Home): `120363407870056827@g.us`
- Beauty: `120363414116153617@g.us`
- Para descobrir JID de um grupo novo: `GET /group/fetchAllGroups/Barbara?getParticipants=false`
  na Evolution API, procurar pelo `subject`.

## Credenciais e onde ficam

Nenhum segredo real fica versionado no git — tudo vem de `.env` (local,
ignorado) ou do `SKILL.md` local (fora do repo). Os arquivos `.env.example`
e `ngrok.yml.example` no repo mostram a estrutura esperada, com placeholders.

- **n8n API**: token JWT gerado em Settings → n8n API → Create API Key
  (expira; gerar novo quando der 401).
- **Evolution API**: `AUTHENTICATION_API_KEY` no `.env`.
- **Shopee Affiliate**: AppId + Secret, usados para assinar requisições
  GraphQL (SHA256 de AppId+Timestamp+Payload+Secret).
- **Bria AI**: `api_token` (plano gratuito: 100 gerações, crédito único,
  não documentado se recarrega).
- **Ngrok**: authtoken em `ngrok.yml` (local, ignorado pelo git).

## Bugs recorrentes e como diagnosticar

### 1. Evolution API / Baileys trava silenciosamente (o mais comum)

**Sintoma:** links da Barbara param de gerar execução no n8n. Toda a cadeia
parece saudável: n8n local responde 200, ngrok público responde 200, webhook
configurado corretamente, e `GET /instance/connectionState/Barbara` retorna
`{"state":"open"}`.

**Causa:** esse `state: open` é só um valor em cache — não garante que a
sessão Baileys está processando eventos de verdade. A causa raiz observada
é um erro `429` (`rate-overlimit`) do próprio WhatsApp durante alguma
operação interna (ex: `groupMetadata`/`updateGroupMetadataCache`), que trava
a sessão por dentro. Depois disso, `docker logs lab_evolution_api` para de
imprimir qualquer linha nova — nem eventos, nem mais erros.

**Diagnóstico:**
```bash
date -u                                     # hora atual UTC
docker logs lab_evolution_api --tail 5      # timestamp da última linha
```
Se a última linha de log for de muito tempo atrás (minutos/horas) mesmo com
o container "Up" há dias, confirma a trava.

**Correção:** `docker restart lab_evolution_api` — a sessão permanece
logada (não precisa escanear QR), só reinicia o processo. Aguardar ~20s e
conferir que logs voltaram a aparecer com timestamp fresco.

**Correção automática:** existe um script watchdog (`watchdog-evolution.ps1`)
que monitora os logs do container e reinicia automaticamente se detectar
2 minutos sem nenhuma linha nova. Ver seção própria abaixo.

### 2. Limite mensal do ngrok gratuito

**Sintoma:** execuções simplesmente param de aparecer no n8n, sem erro do
lado da Evolution API. A URL pública do ngrok responde `403` com HTML de
erro `ERR_NGROK_727` para QUALQUER requisição, mesmo com tudo (containers,
instância WhatsApp) funcionando normalmente.

**Diagnóstico:**
```bash
curl -s -o /dev/null -w "%{http_code}\n" https://<url-ngrok>/webhook/message -X POST -d '{}'
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:5678/webhook/message -X POST -d '{}'
```
Se a URL pública der `403` mas a local der `200`, é limite estourado.
Confirmar lendo o corpo da resposta (menciona `ERR_NGROK_727` e
`dashboard.ngrok.com/billing`).

**Correção:** criar conta ngrok nova (grátis, cota zerada), gerar authtoken
novo, atualizar em `ngrok.yml`, `docker compose restart ngrok`, pegar nova
URL pública (`curl http://localhost:4040/api/tunnels`), e reapontar o
webhook da Evolution API:
```bash
curl -X POST "http://localhost:8080/webhook/set/Barbara" \
  -H "apikey: <evolution_api_key>" -H "Content-Type: application/json" \
  -d '{"webhook": {"url": "https://<nova-url>/webhook/message", "enabled": true, "events": ["MESSAGES_UPSERT"], "webhookByEvents": false, "webhookBase64": false}}'
```
**Sempre atualizar o webhook a cada troca de domínio ngrok** — a URL pública
muda a cada restart, a menos que seja domínio fixo pago.

### 3. Dispositivos "fantasma" no WhatsApp (causa menos comum, mais séria)

Se o problema 1 estiver acontecendo com muita frequência mesmo após
reconectar, verificar na tela do WhatsApp da Barbara (celular → Aparelhos
conectados) se há mais de um dispositivo linkado — um "fantasma" de uma
reconexão anterior que não foi limpa corretamente pode causar conflitos de
sincronização que afetam especificamente o chat da própria Barbara consigo
mesma (self-chat). Correção: remover TODOS os dispositivos listados no
celular, depois fazer logout + gerar QR novo na Evolution API.

### 4. Docker Desktop congelado (Windows/WSL2)

Se `docker restart`/`docker ps` travarem sem retornar, é o host (Docker
Desktop/WSL2) que travou, não um problema de container. Sintoma: comandos
Docker simplesmente não respondem, nem com timeout longo.

**Correção (via PowerShell como Administrador):**
```powershell
Get-Process | Where-Object { $_.ProcessName -match "Docker|com.docker|vpnkit|wsl" } | Stop-Process -Force
wsl --shutdown
```
(Esperado: falha de "Acesso negado" em `vmmemWSL` — processo protegido do
sistema, não é erro real.) Depois reabrir o Docker Desktop manualmente pela
interface gráfica — os containers voltam automaticamente (`restart:
unless-stopped`/`always` no compose).

## Watchdog automático (`watchdog-evolution.ps1`)

Script PowerShell que fica em loop infinito verificando se `docker logs
lab_evolution_api --tail 1` mudou nos últimos 30s; se não mudou E não há
nenhuma linha nova nos últimos 120s (via `docker logs --since`), reinicia o
container automaticamente e loga em `watchdog-evolution.log` (ignorado pelo
git).

**Limitação atual:** roda como processo solto (`powershell.exe ... -File
watchdog-evolution.ps1 &`), não como serviço/tarefa do Windows — não
sobrevive a reinício da máquina nem a logoff. Para rodar:
```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File watchdog-evolution.ps1
```
Para torná-lo permanente (sobrevive a reboot), seria necessário registrar
como Tarefa Agendada do Windows com `Register-ScheduledTask`, o que exige
PowerShell elevado ("Executar como Administrador") — não feito ainda porque
a tentativa automática deu "Acesso negado" sem elevação.

## Editar o workflow (node `Gerar Legenda e Montar Mensagem` etc.)

Preferencial: API REST do n8n (`PUT /api/v1/workflows/{id}`) — ver
`REPLICAR-AMBIENTE.md` para detalhes de endpoints.

**Atenção a CRLF:** os arquivos de código dos nodes usam `\r\n`. A
ferramenta de edição por diff (Read + Edit) normaliza/strip `\r` na
exibição, então um `old_string` copiado do Read nunca casa com os bytes
reais do arquivo. Usar `sed -i 's/.../.../'` direto no arquivo preserva
CRLF corretamente.

Se o token da API do n8n expirar (401), existe também um caminho via
PostgreSQL direto, documentado em `REPLICAR-AMBIENTE.md` — mas a API é
sempre preferível porque cuida do `workflow_history` automaticamente (o
n8n 2.x executa a partir de `workflow_history.activeVersionId`, não do
campo `nodes` cru de `workflow_entity`; editar um sem o outro não tem
efeito).

## Regra de ouro operacional

**Nunca enviar mensagens de teste via WhatsApp (Evolution API) sem perguntar
antes à Barbara.** Sempre pedir para ela mesma mandar um link de teste e
checar a execução no n8n.
