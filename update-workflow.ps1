# update-workflow.ps1
# Atualiza os nodes do workflow no banco E no histórico (workflow_history) de uma vez.
# Uso: .\update-workflow.ps1 -NodesFile .tmp_nodes.json

param(
    [string]$NodesFile = ".tmp_nodes.json",
    [string]$WorkflowId = "WSfNRxwVYtg0CyNC"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $NodesFile)) {
    Write-Error "Arquivo de nodes não encontrado: $NodesFile"
    exit 1
}

$nodesJson = Get-Content $NodesFile -Raw -Encoding UTF8

# Escapar aspas simples para o psql
$escaped = $nodesJson -replace "'", "''"

$sql = @"
BEGIN;

-- 1. Atualiza workflow_entity (o "rascunho" que o editor mostra)
UPDATE workflow_entity
SET nodes = '$escaped'::jsonb, "updatedAt" = NOW()
WHERE id = '$WorkflowId';

-- 2. Atualiza workflow_history na versão ativa (o que o n8n realmente executa)
UPDATE workflow_history
SET nodes = '$escaped'::json, "updatedAt" = NOW()
WHERE "versionId" = (
    SELECT "activeVersionId" FROM workflow_entity WHERE id = '$WorkflowId'
);

COMMIT;
"@

Write-Host "Atualizando workflow $WorkflowId..." -ForegroundColor Cyan
$result = $sql | docker exec -i postgres psql -U rafael -d app_db
Write-Host $result

Write-Host "Reiniciando n8n..." -ForegroundColor Cyan
docker restart n8n | Out-Null
Start-Sleep -Seconds 10

$health = Invoke-RestMethod -Uri "http://localhost:5678/healthz" -Method GET
Write-Host "n8n status: $($health.status)" -ForegroundColor Green
Write-Host "Pronto! Workflow atualizado e n8n rodando." -ForegroundColor Green
