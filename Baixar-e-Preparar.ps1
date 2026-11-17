<#
.SYNOPSIS
  Baixa o pacote de instalacao do equipamento (Agente SIGA + Equipment Status + scripts) e o Cabinet, confere e deixa tudo pronto
  em uma pasta. Pode rodar por PowerShell remoto (LogMeIn), sem tela. A INSTALACAO em si (INSTALAR.bat) abre janelas e precisa da
  area de trabalho do PC (sessao do usuario).

.EXAMPLE
  # pelo PowerShell remoto (so baixa, extrai e confere; nao instala):
  powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol='Tls12'; & ([scriptblock]::Create((Invoke-RestMethod 'https://raw.githubusercontent.com/crocha89/Atualiza-o1711/main/Baixar-e-Preparar.ps1')))"

.PARAMETER Repo
  Repositorio do GitHub com instaladores.zip (pacote), link (URL do zip do Cabinet) e, se quiser, hashes.txt.
.PARAMETER Destino
  Onde fica tudo. Cria Destino\cache (zips baixados) e Destino\instalacao (a pasta que o INSTALAR.bat usa).
.PARAMETER UrlCabinet
  URL do zip do Cabinet. Vazio = le do arquivo "link" do repositorio (assim a versao muda sem mexer neste script).
.PARAMETER SemVerificar
  Nao roda a verificacao sem alterar nada (Instalar-Equipamento.ps1 -Simular) no fim.
.PARAMETER Instalar
  Depois de preparar, chama o INSTALAR.bat. So funciona numa sessao com tela (nao em PowerShell remoto sem desktop).
.PARAMETER Forcar
  Baixa de novo mesmo que o zip ja esteja no cache.
#>
param(
    [string]$Repo = 'crocha89/Atualiza-o1711',
    [string]$Ramo = 'main',
    [string]$Destino = 'C:\Temp\Atualizacao',
    [string]$UrlCabinet = '',
    [switch]$SemVerificar,
    [switch]$Instalar,
    [switch]$Forcar,
    # repassados ao assistente (Instalar-Equipamento.ps1) quando -Instalar:
    [string]$Modelo = '',
    [string]$Oncoprod = '',
    [string]$Ativo = '',
    [string]$Serie = '',
    [string]$Local = '',
    [string]$LinkHamachi = '',
    [switch]$SemHamachi,
    [switch]$SemDiagnostico,
    [switch]$SemPerguntar
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'     # a barra de progresso do PowerShell 5.1 deixa o download umas 8 vezes mais lento
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
$raw = "https://raw.githubusercontent.com/$Repo/$Ramo"
$cache = Join-Path $Destino 'cache'
$inst = Join-Path $Destino 'instalacao'

function Passo($n, $t) { Write-Host ''; Write-Host "[$n] $t" -ForegroundColor Cyan }
function Ok($t) { Write-Host "    [ok] $t" -ForegroundColor Green }
function Aviso($t) { Write-Host "    [!] $t" -ForegroundColor Yellow }

function Baixa($url, $saida) {
    for ($i = 1; $i -le 3; $i++) {
        try {
            Invoke-WebRequest -Uri $url -OutFile $saida -UseBasicParsing -TimeoutSec 900
            if ((Get-Item $saida).Length -gt 0) { return }
        }
        catch { Aviso "tentativa $i falhou: $($_.Exception.Message)"; Start-Sleep -Seconds (5 * $i) }
    }
    throw "Nao consegui baixar $url"
}

# hashes.txt (opcional): uma linha por arquivo, "SHA256  nome". Garante que o que chegou e o que foi testado.
$hashes = @{}
function CarregaHashes {
    $h = Join-Path $cache 'hashes.txt'
    Remove-Item $h -ErrorAction SilentlyContinue
    try { Invoke-WebRequest -Uri "$raw/hashes.txt" -OutFile $h -UseBasicParsing -TimeoutSec 60 } catch { Aviso 'o repositorio nao publica hashes.txt: vou so mostrar os hashes, sem conferir.'; return }
    foreach ($l in Get-Content $h) { if ($l -match '^\s*([0-9A-Fa-f]{64})\s+\*?(.+?)\s*$') { $script:hashes[$Matches[2]] = $Matches[1].ToUpper() } }
}
function ConfereHash($arquivo) {
    $nome = Split-Path $arquivo -Leaf
    $h = (Get-FileHash $arquivo -Algorithm SHA256).Hash
    if (-not $hashes.ContainsKey($nome)) { Aviso "sem hash publicado para $nome (SHA256 $h)"; return $true }
    if ($hashes[$nome] -ne $h) { return $false }
    Ok "hash conferido: $nome"
    return $true
}

New-Item -ItemType Directory -Force $cache | Out-Null
try { Start-Transcript -Path (Join-Path $Destino 'preparar.log') -Append | Out-Null } catch {}
Write-Host "Preparando a instalacao em $Destino  (PowerShell $($PSVersionTable.PSVersion), sessao $((Get-Process -Id $PID).SessionId))"

# ---------------------------------------------------------------- 1) pacote
Passo 1 'Pacote de instalacao (Agente SIGA, Equipment Status e scripts)'
CarregaHashes
$zipPacote = Join-Path $cache 'instaladores.zip'
Baixa "$raw/instaladores.zip" $zipPacote
if (-not (ConfereHash $zipPacote)) { throw 'instaladores.zip nao confere com o hash publicado. Nada foi instalado.' }
Ok ('instaladores.zip: {0:N1} MB' -f ((Get-Item $zipPacote).Length / 1MB))

# ---------------------------------------------------------------- 2) Cabinet
Passo 2 'Cabinet (release)'
$url = $UrlCabinet
if (-not $url) { $url = (Invoke-WebRequest -Uri "$raw/link" -UseBasicParsing).Content.ToString().Trim([char]0xFEFF, ' ', "`r", "`n", "`t") }
if ($url -notmatch '^https://') { throw "O arquivo link do repositorio nao tem uma URL https valida: '$url'" }
$zipCabinet = Join-Path $cache (Split-Path $url -Leaf)
Write-Host "    origem: $url"
$jaTem = (Test-Path $zipCabinet) -and -not $Forcar
if ($jaTem -and -not (ConfereHash $zipCabinet)) { Aviso 'o zip do cache nao confere; baixando de novo.'; $jaTem = $false }
if ($jaTem) { Ok 'ja estava no cache, nao baixei de novo.' }
else {
    Baixa $url $zipCabinet
    if (-not (ConfereHash $zipCabinet)) { throw 'O zip do Cabinet nao confere com o hash publicado. Nada foi instalado.' }
}
Ok ('{0}: {1:N1} MB' -f (Split-Path $zipCabinet -Leaf), ((Get-Item $zipCabinet).Length / 1MB))

# ---------------------------------------------------------------- 3) extrair
Passo 3 "Extrair para $inst"
if (Test-Path $inst) { Remove-Item $inst -Recurse -Force }
Expand-Archive -Path $zipPacote -DestinationPath $inst -Force
Expand-Archive -Path $zipCabinet -DestinationPath $inst -Force
$falta = @('INSTALAR.bat', 'Instalar-Equipamento.ps1', 'Agente\AgenteSiga.exe', 'EquipmentStatus\EquipmentStatusSetup.exe') | Where-Object { -not (Test-Path (Join-Path $inst $_)) }
if ($falta) { throw "O pacote veio incompleto, falta: $($falta -join ', ')" }
$cab = @(Get-ChildItem $inst -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'Gtt.HealthTrack.Cabinet.exe') })
if ($cab.Count -ne 1) { throw "Esperava uma pasta com Gtt.HealthTrack.Cabinet.exe e achei $($cab.Count): $(($cab | ForEach-Object Name) -join ', ')" }
Ok "Cabinet em $($cab[0].Name); Agente e Equipment Status ao lado."

# ---------------------------------------------------------------- 4) verificacao (nao altera nada)
if (-not $SemVerificar -and -not $Instalar) {
    Passo 4 'Verificacao (nao altera nada): nome do PC, Hamachi, servidor'
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $inst 'Instalar-Equipamento.ps1') -Simular
}

# ---------------------------------------------------------------- 5) proximo passo
Passo 5 'Proximo passo'
$sessao = (Get-Process -Id $PID).SessionId
if ($Instalar) {
    $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($sessao -eq 0) { Aviso 'Esta janela roda na sessao 0 (sem tela): o instalador abre o navegador, o Cabinet e janelas. Nao instalei; rode pela tela do PC.' }
    elseif (-not $admin) { Aviso 'Abra o PowerShell como Administrador e rode de novo com -Instalar (ou de dois cliques no INSTALAR.bat).' }
    else {
        $fw = @{}
        foreach ($k in 'Modelo', 'Oncoprod', 'Ativo', 'Serie', 'Local', 'LinkHamachi', 'SemHamachi', 'SemDiagnostico', 'SemPerguntar') {
            if ($PSBoundParameters.ContainsKey($k)) { $fw[$k] = $PSBoundParameters[$k] }
        }
        $fw['Repo'] = $Repo; $fw['Ramo'] = $Ramo
        try { Stop-Transcript | Out-Null } catch {}
        & (Join-Path $inst 'Instalar-Equipamento.ps1') @fw     # o assistente: pergunta o modelo e faz o resto
        return
    }
}
if (-not $Instalar -or $sessao -eq 0) {
    Write-Host "    Na area de trabalho do PC (pelo controle remoto), de dois cliques em:" -ForegroundColor White
    Write-Host "      $(Join-Path $inst 'INSTALAR.bat')" -ForegroundColor White
    Write-Host '    (antes: nome do PC certo e Hamachi instalado e conectado; veja LEIA-ME-INSTALACAO.txt)'
}
try { Stop-Transcript | Out-Null } catch {}
