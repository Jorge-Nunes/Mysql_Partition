# Traccar — Particionamento e Otimização da tc_positions

> **Versão:** 2.0  
> **Autor:** DBA Traccar  
> **Banco:** MySQL 8.x  
> **Objetivo:** Particionamento diário com retenção de 90 dias, compressão de dados frios e monitoramento via CheckMK

---

## Índice

1. [Visão Geral da Arquitetura](#1-visão-geral-da-arquitetura)
2. [Pré-requisitos](#2-pré-requisitos)
3. [Diagnóstico do Ambiente Atual](#3-diagnóstico-do-ambiente-atual)
4. [Estrutura dos Arquivos](#4-estrutura-dos-arquivos)
5. [Fase 1 — Migração Segura (produção com dados existentes)](#5-fase-1--migração-segura-produção-com-dados-existentes)
6. [Fase 2 — Particionamento e Automação](#6-fase-2--particionamento-e-automação)
7. [Fase 3 — Compactação de Partições Frias](#7-fase-3--compactação-de-partições-frias)
8. [Fase 4 — Validação com Checklist](#8-fase-4--validação-com-checklist)
9. [Fase 5 — Monitoramento com CheckMK](#9-fase-5--monitoramento-com-checkmk)
10. [Configurações do Traccar](#10-configurações-do-traccar)
11. [Estimativa de Ganho de Espaço](#11-estimativa-de-ganho-de-espaço)
12. [Manutenção e Operação](#12-manutenção-e-operação)
13. [Troubleshooting](#13-troubleshooting)
14. [Referência Rápida de Procedures e Eventos](#14-referência-rápida-de-procedures-e-eventos)

---

## 1. Visão Geral da Arquitetura

```
tc_positions (PARTITION BY RANGE UNIX_TIMESTAMP(fixtime))
│
├── p20250112  → dados do dia 11/01  (< 90 dias: ativa)
├── p20250113  → dados do dia 12/01  (< 90 dias: ativa)
├── ...
├── p_hoje     → dados de hoje       (quente: escrita ativa)
├── p_amanha   → dados de amanhã     (criada preventivamente)
└── p_future   → MAXVALUE            (segurança: nunca é dropada)

Partições > 30 dias → ROW_FORMAT=COMPRESSED (economia ~50%)
Partições > 90 dias → DROP PARTITION         (expurgo automático)
```

### Eventos automáticos

| Evento | Frequência | Horário | O que faz |
|---|---|---|---|
| `ev_tc_positions_add_partition` | Diário | 01:00 | Cria partição de amanhã |
| `ev_tc_positions_drop_old` | Diário | 02:00 | Remove partições > 90 dias |
| `ev_tc_positions_optimize_old` | Semanal | 03:00 | OPTIMIZE nas partições antigas |
| `ev_tc_positions_compress_cold` | Semanal | 03:00 | Comprime partições > 30 dias |

---

## 2. Pré-requisitos

### MySQL

```sql
-- Verificar versão (requer 8.x)
SELECT VERSION();

-- Verificar configurações obrigatórias
SHOW VARIABLES LIKE 'event_scheduler';       -- deve ser ON
SHOW VARIABLES LIKE 'innodb_file_per_table'; -- deve ser ON
SHOW VARIABLES LIKE 'log_bin';               -- se ON, requer SUPER para eventos
```

### Adicionar ao `my.cnf` antes de iniciar

```ini
[mysqld]
event_scheduler         = ON
innodb_file_per_table   = ON
innodb_buffer_pool_size = 4G   # ajuste para 60-70% da RAM disponível
```

> **Reinicie o MySQL após alterar o `my.cnf`:**  
> `systemctl restart mysql`

### Espaço em disco

```bash
# Verificar espaço disponível
df -h /var/lib/mysql

# Para migração segura de banco com dados existentes:
# É necessário espaço livre equivalente ao volume dos últimos 90 dias
# Estimativa: total_atual × (90 / dias_totais_de_dados) × 1.2 (margem)
```

### Permissões MySQL necessárias

```sql
-- O usuário que executará os scripts precisa de:
GRANT ALTER, CREATE, DROP, INDEX, INSERT, SELECT, UPDATE,
      DELETE, EXECUTE, EVENT, TRIGGER
ON traccar.*
TO 'seu_usuario'@'localhost';
```

---

## 3. Diagnóstico do Ambiente Atual

> **Execute ANTES de qualquer outro passo.**

```sql
-- 3.1 Volume por período
SELECT
    CASE
        WHEN fixtime >= NOW() - INTERVAL 90  DAY THEN 'últimos 90 dias (MANTER)'
        WHEN fixtime >= NOW() - INTERVAL 180 DAY THEN '90–180 dias'
        WHEN fixtime >= NOW() - INTERVAL 365 DAY THEN '180–365 dias'
        ELSE                                         'mais de 1 ano'
    END                         AS periodo,
    FORMAT(COUNT(*), 0)         AS registros,
    ROUND(COUNT(*) * 100.0 /
        (SELECT COUNT(*) FROM tc_positions), 1) AS pct_total
FROM tc_positions
GROUP BY 1
ORDER BY MIN(fixtime);

-- 3.2 Tamanho da tabela em disco
SELECT
    ROUND((DATA_LENGTH + INDEX_LENGTH) / 1024/1024/1024, 2) AS tamanho_gb,
    ROUND(DATA_FREE / 1024/1024/1024, 2)                    AS fragmentado_gb,
    TABLE_ROWS                                               AS linhas_estimadas
FROM information_schema.TABLES
WHERE TABLE_SCHEMA = 'traccar' AND TABLE_NAME = 'tc_positions';

-- 3.3 Volume diário médio (base para estimativas)
SELECT
    DATE(fixtime)                    AS dia,
    COUNT(DISTINCT deviceid)         AS dispositivos,
    FORMAT(COUNT(*), 0)              AS posicoes,
    ROUND(COUNT(*) / COUNT(DISTINCT deviceid)) AS media_por_dispositivo
FROM tc_positions
WHERE fixtime >= NOW() - INTERVAL 7 DAY
GROUP BY DATE(fixtime)
ORDER BY dia;
```

---

## 4. Estrutura dos Arquivos

```
traccar-particionamento/
│
├── README.md                              ← este arquivo
│
├── 01_tc_positions_particionamento_COMPLETO.sql
│       Criação da tabela particionada, todas as procedures
│       e eventos. Use para ambientes NOVOS ou após migração.
│
├── 02_checklist_particionamento.sql
│       Validação completa com saída ✅ / ⚠️ / ❌.
│       Execute após o deploy e periodicamente.
│
├── 03_checkmk_traccar_partitions.py
│       Script Python para monitoramento contínuo via CheckMK.
│       Instalar no agente CheckMK do servidor de banco.
│
├── 04_compactacao_particoes_antigas.sql
│       Procedure e evento para compressão InnoDB das partições
│       frias (> 30 dias). Execute após estabilizar o deploy.
│
└── 05_migracao_segura_300gb.sql
        Estratégia Shadow Table para migrar bancos com dados
        existentes sem derrubar o Traccar. Execute PRIMEIRO
        se o banco já tiver dados.
```

---

## 5. Fase 1 — Migração Segura (produção com dados existentes)

> **Use esta fase se a tabela `tc_positions` já existe com dados.**  
> Se o banco for novo/vazio, pule para a [Fase 2](#6-fase-2--particionamento-e-automação).

### Estratégia Shadow Table

A tabela continua recebendo dados do Traccar enquanto a migração acontece. A janela de parada é de apenas **~5 minutos** no momento do swap.

```
[Traccar ativo] → escreve em tc_positions (original)
                     ↓
              tc_positions_new (nova, particionada) sendo populada em paralelo
                     ↓
              [Traccar parado ~5min] → RENAME TABLE (swap atômico)
                     ↓
              [Traccar ativo] → escreve em tc_positions (agora particionada)
```

### Passo 1.1 — Preparar e executar a migração

```bash
# Conectar ao MySQL
mysql -u root -p traccar

# Executar o script de migração
SOURCE /caminho/para/05_migracao_segura_300gb.sql;
```

### Passo 1.2 — Migrar dados em lotes (com Traccar ativo)

Crie o script shell e execute em background:

```bash
cat > /tmp/migrate_positions.sh << 'SHELL'
#!/bin/bash
# Ajuste a data de início para: hoje - 90 dias
START_DATE=$(date -d "90 days ago" +%Y-%m-%d)
END_DATE=$(date +%Y-%m-%d)
CURRENT=$START_DATE
MYSQL_CMD="mysql -u root -pSUA_SENHA traccar"

echo "Iniciando migração de $START_DATE até $END_DATE"
echo "Início: $(date)"

while [[ "$CURRENT" < "$END_DATE" ]]; do
    echo -n "Migrando $CURRENT... "
    RESULT=$($MYSQL_CMD -se \
        "CALL sp_migrate_positions_batch('$CURRENT', @n); SELECT @n;")
    echo "$RESULT linhas"
    CURRENT=$(date -d "$CURRENT + 1 day" +%Y-%m-%d)
    sleep 2   # respiro entre lotes
done

echo "Fim: $(date)"
echo "Migração de dados concluída!"
SHELL

chmod +x /tmp/migrate_positions.sh
nohup /tmp/migrate_positions.sh > /tmp/migrate_positions.log 2>&1 &

# Acompanhar progresso
tail -f /tmp/migrate_positions.log
```

### Passo 1.3 — Monitorar progresso

```sql
-- Execute periodicamente para ver o andamento:
SELECT
    ROUND(
        (SELECT COUNT(*) FROM tc_positions_new)
        * 100.0
        / NULLIF((SELECT COUNT(*) FROM tc_positions
                  WHERE fixtime >= NOW() - INTERVAL 90 DAY), 0)
    , 1)                         AS progresso_pct,
    FORMAT((SELECT COUNT(*) FROM tc_positions_new), 0) AS registros_migrados,
    ROUND(
        (SELECT DATA_LENGTH + INDEX_LENGTH
           FROM information_schema.TABLES
          WHERE TABLE_SCHEMA='traccar' AND TABLE_NAME='tc_positions_new')
        / 1024/1024/1024, 2)    AS nova_tabela_gb;
```

### Passo 1.4 — Swap (janela de parada ~5 minutos)

```bash
# 1. Parar o Traccar
systemctl stop traccar

# 2. Aguardar 30 segundos para conexões drenarem
sleep 30
```

```sql
-- 3. Migrar delta do dia atual e ontem
CALL sp_migrate_positions_batch(CURRENT_DATE, @n);
CALL sp_migrate_positions_batch(CURRENT_DATE - INTERVAL 1 DAY, @n);

-- 4. Conferir contagem (diferença < 0.1% é aceitável)
SELECT 'ORIGINAL' AS tabela, COUNT(*) AS registros_90d
FROM tc_positions
WHERE fixtime >= NOW() - INTERVAL 90 DAY
UNION ALL
SELECT 'NOVA', COUNT(*) FROM tc_positions_new
WHERE fixtime >= NOW() - INTERVAL 90 DAY;

-- 5. Swap atômico
RENAME TABLE
    tc_positions     TO tc_positions_old,
    tc_positions_new TO tc_positions;
```

```bash
# 6. Iniciar o Traccar
systemctl start traccar

# 7. Verificar logs por 5 minutos
tail -f /opt/traccar/logs/tracker-server.log
```

### Passo 1.5 — Limpeza (após 48h de estabilidade confirmada)

```sql
-- Somente após confirmar que o Traccar opera normalmente por 48h:
DROP TABLE tc_positions_old;
```

---

## 6. Fase 2 — Particionamento e Automação

> Execute este script para criar as procedures e eventos automáticos.  
> **Para bancos com dados existentes:** execute após concluir a Fase 1.  
> **Para bancos novos:** execute diretamente (o script inclui o `DROP TABLE`).

```bash
mysql -u root -p --verbose traccar \
    < 01_tc_positions_particionamento_COMPLETO.sql \
    2>&1 | tee deploy_fase2.log
```

### O que o script faz

| Passo | Ação |
|---|---|
| 1 | Liga o Event Scheduler |
| 2 | Cria a tabela com partição `p_future` (MAXVALUE) |
| 3–6 | Cria as 4 procedures corrigidas |
| 7 | Bootstrap: 90 partições passadas + 7 futuras |
| 8 | Cria os 3 eventos automáticos com horários escalonados |
| 9 | Exibe confirmação das partições e eventos criados |

### Verificar resultado

```sql
-- Confirmar partições criadas
SELECT COUNT(*) AS total_particoes
FROM information_schema.PARTITIONS
WHERE TABLE_SCHEMA = 'traccar' AND TABLE_NAME = 'tc_positions';
-- Esperado: ~98 (90 passadas + 7 futuras + 1 p_future)

-- Confirmar eventos
SELECT EVENT_NAME, STATUS, STARTS
FROM information_schema.EVENTS
WHERE EVENT_SCHEMA = 'traccar';
-- Esperado: 3 eventos com STATUS = ENABLED
```

---

## 7. Fase 3 — Compactação de Partições Frias

> Execute após a Fase 2 estar estável por pelo menos 24 horas.

### Passo 3.1 — Verificar pré-requisito

```sql
SHOW VARIABLES LIKE 'innodb_file_per_table';
-- Deve retornar: ON
```

### Passo 3.2 — Instalar procedure e evento

```bash
mysql -u root -p traccar < 04_compactacao_particoes_antigas.sql
```

### Passo 3.3 — Simulação antes de executar

```sql
-- DRY RUN: ver o que seria comprimido sem alterar dados
CALL sp_tc_positions_compress_cold_partitions('traccar', 'tc_positions', 30, 1);
```

A saída mostra o tamanho atual e a economia estimada por partição.

### Passo 3.4 — Execução real

```sql
-- Comprimir partições com mais de 30 dias
-- Agende para madrugada ou final de semana (operação intensiva de I/O)
CALL sp_tc_positions_compress_cold_partitions('traccar', 'tc_positions', 30, 0);
```

### Passo 3.5 — Verificar resultado

```sql
CALL sp_tc_positions_compress_history('traccar', 'tc_positions', 7);
-- Mostra: partições comprimidas, tamanho antes/depois, % de economia
```

---

## 8. Fase 4 — Validação com Checklist

Execute após cada fase e sempre que houver dúvida sobre a saúde do ambiente:

```bash
mysql -u root -p traccar < 02_checklist_particionamento.sql
```

### O que é verificado

| Check | O que valida |
|---|---|
| 1 | Event Scheduler está ON |
| 2 | 3 eventos existem e estão ENABLED |
| 3 | Partição `p_future` (MAXVALUE) existe |
| 4 | Partição de amanhã foi criada |
| 5 | Nenhuma partição expirada permanece |
| 6 | Janela de cobertura ≥ 90 dias |
| 7 | 4 procedures existem |
| 8 | Listagem completa com tamanho por partição |

### Resultado esperado (ambiente saudável)

```
✅  OK — Event Scheduler ATIVO
✅  OK — Todos os 3 eventos ENABLED
✅  OK — Partição p_future (MAXVALUE) presente
✅  OK — Partição de amanhã existe
✅  OK — Nenhuma partição expirada encontrada
✅  OK — Janela >= 90 dias
✅  OK — Todas as 4 procedures encontradas
```

---

## 9. Fase 5 — Monitoramento com CheckMK

### Instalação

```bash
# 1. Copiar o script
cp 03_checkmk_traccar_partitions.py \
   /usr/lib/check_mk_agent/local/traccar_partitions

# 2. Tornar executável
chmod +x /usr/lib/check_mk_agent/local/traccar_partitions

# 3. Instalar dependência Python
pip3 install mysql-connector-python

# 4. Criar usuário MySQL somente leitura para monitoramento
```

```sql
CREATE USER 'traccar_monitor'@'127.0.0.1'
    IDENTIFIED BY 'senha_forte_aqui';
GRANT SELECT ON information_schema.* TO 'traccar_monitor'@'127.0.0.1';
GRANT SHOW DATABASES ON *.*           TO 'traccar_monitor'@'127.0.0.1';
FLUSH PRIVILEGES;
```

```bash
# 5. Configurar credenciais via variáveis de ambiente
cat > /etc/check_mk/traccar_db.env << 'EOF'
export TRACCAR_DB_HOST=127.0.0.1
export TRACCAR_DB_USER=traccar_monitor
export TRACCAR_DB_PASS=senha_forte_aqui
export TRACCAR_DB_NAME=traccar
EOF

# Carregar no perfil do agente
echo "source /etc/check_mk/traccar_db.env" >> /etc/check_mk/agent_environ

# 6. Testar localmente
/usr/lib/check_mk_agent/local/traccar_partitions
```

### Serviços monitorados no CheckMK

| Serviço CheckMK | WARN | CRIT |
|---|---|---|
| `Traccar_EventScheduler` | — | Scheduler OFF |
| `Traccar_ScheduledEvents` | Evento nunca executado | Evento ausente/desabilitado |
| `Traccar_Partition_Future` | — | `p_future` ausente |
| `Traccar_Partition_Tomorrow` | Partição de amanhã ausente | — |
| `Traccar_Partitions_Expired` | ≥ 1 expirada | ≥ 3 expiradas |
| `Traccar_Partitions_FutureCoverage` | < 2 dias futuros | < 1 dia futuro |
| `Traccar_Partitions_DailyCount` | < 85 partições | < 80 partições |
| `Traccar_Partitions_TableSize` | — | Informativo |

---

## 10. Configurações do Traccar

### `traccar.xml` — ajustes necessários para relatórios de 45+ dias

```xml
<!-- /opt/traccar/conf/traccar.xml -->

<!-- Aumentar janela máxima de consulta (padrão: 30 dias) -->
<entry key='database.maxQueryInterval'>60</entry>

<!-- Aumentar timeout de query longa -->
<entry key='database.selectTimeout'>300000</entry>
```

### Heap Java — para relatórios com múltiplos dispositivos

```bash
# Localizar o arquivo de configuração da JVM
grep -r "Xmx" /opt/traccar/

# Editar wrapper.conf ou traccar.service
# Aumentar de 512m para 2g (ou mais, dependendo da RAM disponível)
```

```ini
# wrapper.conf
wrapper.java.additional.3=-Xms512m
wrapper.java.additional.4=-Xmx2g
```

```bash
# Reiniciar o Traccar após alterações
systemctl restart traccar
tail -f /opt/traccar/logs/tracker-server.log
```

### Verificar configuração atual

```bash
# Ver heap atual do processo em execução
ps aux | grep traccar | grep -o '\-Xmx[^ ]*'

# Ver maxQueryInterval atual
grep -i 'maxQueryInterval' /opt/traccar/conf/traccar.xml
```

---

## 11. Estimativa de Ganho de Espaço

### Cálculo baseado no volume atual

```sql
-- Execute para calcular a estimativa personalizada do seu ambiente:
SELECT
    ROUND((DATA_LENGTH + INDEX_LENGTH)/1024/1024/1024, 2)   AS tamanho_atual_gb,
    DATEDIFF(MAX(fixtime), MIN(fixtime))                     AS dias_de_dados,
    ROUND(
        (DATA_LENGTH + INDEX_LENGTH)/1024/1024/1024
        * (90.0 / NULLIF(DATEDIFF(MAX(fixtime), MIN(fixtime)), 0))
    , 2)                                                     AS estimativa_apos_expurgo_gb,
    ROUND(
        (DATA_LENGTH + INDEX_LENGTH)/1024/1024/1024
        * (90.0 / NULLIF(DATEDIFF(MAX(fixtime), MIN(fixtime)), 0))
        * 0.45
    , 2)                                                     AS estimativa_apos_compressao_gb
FROM information_schema.TABLES t
JOIN (SELECT MIN(fixtime) mn, MAX(fixtime) mx FROM tc_positions) p ON 1=1
WHERE t.TABLE_SCHEMA = 'traccar' AND t.TABLE_NAME = 'tc_positions';
```

### Referência de redução esperada

| Etapa | Redução | Mecanismo |
|---|---|---|
| DROP partições > 90 dias | **85–92%** do total | `DROP PARTITION` — instantâneo |
| Compressão frias > 30 dias | **40–55%** do restante | `ROW_FORMAT=COMPRESSED` |
| **Total combinado** | **~93–96%** | — |

---

## 12. Manutenção e Operação

### Operações manuais úteis

```sql
-- Forçar criação da partição de amanhã manualmente
CALL sp_tc_positions_add_partition_tomorrow('traccar', 'tc_positions');

-- Forçar expurgo manual
CALL sp_tc_positions_drop_old_partitions('traccar', 'tc_positions', 90);

-- Recriar partições para um intervalo específico
CALL sp_tc_positions_add_partitions_range('traccar', 'tc_positions', 90, 7);

-- Ver histórico de compactações
CALL sp_tc_positions_compress_history('traccar', 'tc_positions', 30);

-- Checar fragmentação por partição
SELECT
    PARTITION_NAME,
    FORMAT(TABLE_ROWS, 0)                                        AS linhas,
    ROUND(DATA_LENGTH/1024/1024, 1)                              AS data_mb,
    ROUND(DATA_FREE/1024/1024, 1)                                AS livre_mb,
    ROUND(DATA_FREE/NULLIF(DATA_LENGTH+DATA_FREE,0)*100, 1)      AS fragmentacao_pct
FROM information_schema.PARTITIONS
WHERE TABLE_SCHEMA = 'traccar'
  AND TABLE_NAME   = 'tc_positions'
  AND PARTITION_NAME != 'p_future'
ORDER BY fragmentacao_pct DESC
LIMIT 10;
```

### Ajustar retenção (ex: mudar de 90 para 60 dias)

```sql
-- 1. Recriar evento com novo valor
DROP EVENT IF EXISTS ev_tc_positions_drop_old;
CREATE EVENT ev_tc_positions_drop_old
ON SCHEDULE EVERY 1 DAY
STARTS (DATE(NOW()) + INTERVAL 1 DAY + INTERVAL 2 HOUR)
DO CALL sp_tc_positions_drop_old_partitions('traccar', 'tc_positions', 60);

-- 2. Aplicar imediatamente
CALL sp_tc_positions_drop_old_partitions('traccar', 'tc_positions', 60);
```

### Backup recomendado por partição

```bash
# Exportar partição específica (ex: antes de dropar)
mysqldump traccar tc_positions \
    --where="fixtime >= '2024-10-01' AND fixtime < '2024-10-02'" \
    --single-transaction \
    | gzip > tc_positions_20241001.sql.gz
```

---

## 13. Troubleshooting

### Evento não executa

```sql
-- Verificar status
SELECT EVENT_NAME, STATUS, LAST_EXECUTED, STARTS
FROM information_schema.EVENTS
WHERE EVENT_SCHEMA = 'traccar';

-- Se STATUS = DISABLED, reabilitar:
ALTER EVENT ev_tc_positions_add_partition ENABLE;

-- Testar procedure manualmente:
CALL sp_tc_positions_add_partition_tomorrow('traccar', 'tc_positions');
```

### Erro: "Table has no partition for value"

```sql
-- A partição p_future foi removida acidentalmente. Recriar:
ALTER TABLE tc_positions
    REORGANIZE PARTITION <ultima_particao> INTO (
        PARTITION <ultima_particao> VALUES LESS THAN (<boundary_original>),
        PARTITION p_future VALUES LESS THAN MAXVALUE
    );

-- Ou recriar do zero (se p_future sumiu e não há partição além da última):
ALTER TABLE tc_positions
    ADD PARTITION (PARTITION p_future VALUES LESS THAN MAXVALUE);
```

### Relatório do Traccar retorna vazio ou erro

```bash
# 1. Verificar maxQueryInterval no traccar.xml
grep 'maxQueryInterval' /opt/traccar/conf/traccar.xml

# 2. Verificar logs de erro Java
grep -i 'error\|exception\|outofmemory' /opt/traccar/logs/tracker-server.log | tail -50

# 3. Testar a query diretamente no banco
```

```sql
EXPLAIN PARTITIONS
SELECT COUNT(*) FROM tc_positions
WHERE deviceid = 1
  AND fixtime BETWEEN NOW() - INTERVAL 45 DAY AND NOW();
-- Coluna "partitions" deve listar ~45 nomes (não todas as partições)
-- Coluna "key" deve mostrar: position_deviceid_fixtime
```

### Event Scheduler para após restart do MySQL

```bash
# Verificar se está no my.cnf
grep 'event_scheduler' /etc/mysql/mysql.conf.d/mysqld.cnf

# Se não estiver, adicionar:
echo "event_scheduler = ON" >> /etc/mysql/mysql.conf.d/mysqld.cnf
systemctl restart mysql
```

---

## 14. Referência Rápida de Procedures e Eventos

### Procedures

| Procedure | Parâmetros | Descrição |
|---|---|---|
| `sp_tc_positions_add_partitions_range` | schema, tabela, dias_atrás, dias_frente | Bootstrap de partições em lote |
| `sp_tc_positions_add_partition_tomorrow` | schema, tabela | Cria partição do dia seguinte |
| `sp_tc_positions_drop_old_partitions` | schema, tabela, keep_days | Expurga partições antigas |
| `optimize_partitions_older_than` | schema, tabela, days_old | OPTIMIZE em partições frias |
| `sp_tc_positions_compress_cold_partitions` | schema, tabela, cold_days, dry_run | Comprime com ROW_FORMAT=COMPRESSED |
| `sp_tc_positions_compress_history` | schema, tabela, last_days | Histórico de compactações |
| `sp_migrate_positions_batch` | data (DATE), OUT rows | Migra 1 dia na shadow table |

### Eventos

| Evento | Schedule | Parâmetros hardcoded |
|---|---|---|
| `ev_tc_positions_add_partition` | Diário 01:00 | schema=traccar, tabela=tc_positions |
| `ev_tc_positions_drop_old` | Diário 02:00 | keep_days=90 |
| `ev_tc_positions_optimize_old` | Semanal 03:00 | days_old=30 |
| `ev_tc_positions_compress_cold` | Semanal 03:00 | cold_days=30, dry_run=0 |

### Tabelas auxiliares criadas

| Tabela | Descrição |
|---|---|
| `tc_partition_compress_log` | Histórico de compactações com tamanho antes/depois |

---

*Documento gerado para implantação em ambiente MySQL 8.x + Traccar.*  
*Última atualização: 2025.*
