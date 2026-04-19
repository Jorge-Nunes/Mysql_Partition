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
5. [Plano de Implantação (Passo a Passo)](#5-plano-de-implantação-passo-a-passo)
6. [Migração Segura (Bancos com Dados Existentes)](#6-migração-segura-bancos-com-dados-existentes)
7. [Configurações do Traccar](#7-configurações-do-traccar)
8. [Estimativa de Ganho de Espaço](#8-estimativa-de-ganho-de-espaço)
9. [Manutenção e Operação](#9-manutenção-e-operação)
10. [Troubleshooting](#10-troubleshooting)
11. [Referência Rápida de Procedures e Eventos](#11-referência-rápida-de-procedures-e-eventos)

---

## 1. Visão Geral da Arquitetura

```text
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

### Responsabilidades e Status
| Item | Responsável | Status |
|------|-------------|--------|
| Backup do banco realizado | DBA | ⬜ |
| my.cnf com configurações mínimas | DevOps/SysAdmin | ⬜ |
| Credenciais root MySQL | DBA | ⬜ |
| Traccar parado para manutenção | Ops | ⬜ |

### MySQL

```sql
-- Verificar versão (requer 8.x)
SELECT VERSION();

-- Verificar configurações obrigatórias
SHOW VARIABLES LIKE 'event_scheduler';       -- deve ser ON
SHOW VARIABLES LIKE 'innodb_file_per_table'; -- deve ser ON
SHOW VARIABLES LIKE 'log_bin';               -- se ON, requer SUPER para eventos
```

### Espaço em disco

```bash
# Verificar espaço disponível na partição do MySQL
df -h /var/lib/mysql

# Para migração segura de banco com dados existentes:
# É necessário espaço livre equivalente ao volume dos últimos 90 dias
# Estimativa: total_atual × (90 / dias_totais_de_dados) × 1.2 (margem)
```

### Permissões MySQL necessárias
O usuário que executará os scripts precisa de permissões completas sobre o schema:
```sql
GRANT ALTER, CREATE, DROP, INDEX, INSERT, SELECT, UPDATE,
      DELETE, EXECUTE, EVENT, TRIGGER
ON traccar.*
TO 'seu_usuario'@'localhost';
```

---

## 3. Diagnóstico do Ambiente Atual

> **Execute ANTES de qualquer outro passo para entender o cenário.**

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

```text
traccar-particionamento/
│
├── README.md                              ← Este arquivo, detalhando os conceitos e arquitetura.
│
├── 01_tc_positions_particionamento_COMPLETO.sql
│       Criação da tabela particionada, todas as procedures e eventos.
│       Use na implantação passo a passo para novos bancos ou bancos a recriar base.
│
├── 02_checklist_particionamento.sql
│       Validação completa com saída ✅ / ⚠️ / ❌.
│       Execute após o deploy e periodicamente.
│
├── 03_checkmk_traccar_partitions.py
│       Script Python para monitoramento contínuo via CheckMK.
│
├── 04_compactacao_particoes_antigas.sql
│       Procedure e evento para compressão InnoDB das partições frias (> 30 dias).
│
├── 05_migracao_segura_300gb.sql
│       Estratégia Shadow Table para migrar bancos com dados existentes.
│
└── 06_plano_implantacao.md
        Resumo prático do deploy executado.
```

---

## 5. Plano de Implantação (Passo a Passo)

Este passo a passo unificado baseia-se no novo desenho do plano de implantação. **Use se o banco for novo, ou se for adequado descartar (ou ter backup fora) a tabela `tc_positions` antiga.**  
*Se precisa manter os dados atuais e reescrevê-los em produção on-line, vá para o item 6 (Migração Segura).*

### 5.1 Ordem de Execução

| Passo | Ação | Script Relacionado |
|-------|------|--------|
| **1** | Parar Traccar | — |
| **2** | Configurar my.cnf | — |
| **3** | Reiniciar MySQL | — |
| **4** | Verificar configs | — |
| **5** | Criar tabela particionada e eventos | `01_tc_positions_particionamento_COMPLETO.sql` |
| **6** | Instalar compressão automática | `04_compactacao_particoes_antigas.sql` |
| **7** | Validar deploy (Checklist) | `02_checklist_particionamento.sql` |
| **8** | Configurar CheckMK | `03_checkmk_traccar_partitions.py` |
| **9** | Iniciar Traccar | — |

**Tempo Estimado Total:** ~10 min.

### Passo 1 — Parar o Traccar

```bash
# Parar serviço e garantir interrupção de gravações no banco
systemctl stop traccar
systemctl status traccar
```

### Passo 2 e 3 — Configurar my.cnf e Reiniciar MySQL

Adicione/ajuste no arquivo `/etc/mysql/mysql.conf.d/mysqld.cnf` (ou `/etc/my.cnf`):

```ini
[mysqld]
event_scheduler         = ON
innodb_file_per_table   = ON
innodb_buffer_pool_size = 4G   # Ajuste para: 60-70% da RAM disponível no servidor
```

Após ajustar o arquivo:
```bash
systemctl restart mysql
```

### Passo 4 — Verificar configurações

Aguarde o MySQL voltar e execute a verificação para confirmar se as opções surtiram efeito:

```sql
SELECT @@global.event_scheduler;      -- Deve retornar ON
SELECT @@global.innodb_file_per_table; -- Deve retornar ON
SELECT @@global.innodb_buffer_pool_size / 1024 / 1024 / 1024 AS buffer_pool_gb;
```

### Passo 5 — Executar Módulo de Particionamento

O script abaixo cria a partição baseada em `fixtime`, procedures auxiliares e configura os agendamentos.
> **ATENÇÃO:** O arquivo 01 inclui o comando `DROP TABLE tc_positions;`. Somente siga por aqui se for cenário de base zerada ou descartável.

```bash
mysql -u root -p traccar < /caminho/para/01_tc_positions_particionamento_COMPLETO.sql
```

**O que ele faz:**
- DROP da tabela `tc_positions` (se existir) e recria
- Gera partições retroativas (se solicitado em script), da data de hoje, 7 futuras e a `p_future`
- Cria e habilita eventos automáticos no MySQL para fatiamento diário.

### Passo 6 — Executar Módulo de Compressão

Adiciona suporte para compressão transparente no MySQL (dados > 30 dias tornam-se compactados).

```bash
mysql -u root -p traccar < /caminho/para/04_compactacao_particoes_antigas.sql
```

**Como a tabela acabou de nascer vazia, a compressão ocorrerá apenas após 30 dias.**

### Passo 7 — Validação e Auditoria

Teste se a infraestrutura do MySQL montou devidamente a operação:

```bash
mysql -u root -p traccar < /caminho/para/02_checklist_particionamento.sql
```
Você deverá obter logs visualmente similares a:
```text
✅  OK — Event Scheduler ATIVO
✅  OK — Todos os eventos estao ENABLED
✅  OK — Partição p_future (MAXVALUE) presente
✅  OK — Partição de amanhã existe
✅  OK — Nenhuma partição expirada encontrada
✅  OK — Todas as procedures encontradas
```

### Passo 8 — Configurar Monitoramento CheckMK

**8.1) Criar usuário de leitura MySQL**
```sql
CREATE USER 'traccar_monitor'@'127.0.0.1' IDENTIFIED BY 'SenhaForte123!';
GRANT SELECT ON information_schema.* TO 'traccar_monitor'@'127.0.0.1';
GRANT SHOW DATABASES ON *.* TO 'traccar_monitor'@'127.0.0.1';
FLUSH PRIVILEGES;
```

**8.2) Implantar o plugin no agente Linux**
```bash
cp /caminho/para/03_checkmk_traccar_partitions.py /usr/lib/check_mk_agent/local/traccar_partitions
chmod +x /usr/lib/check_mk_agent/local/traccar_partitions
```

**8.3) Criar varíaveis de ambiente c/ credenciais**
```bash
export TRACCAR_DB_HOST=127.0.0.1
export TRACCAR_DB_USER=traccar_monitor
export TRACCAR_DB_PASS=SenhaForte123!
export TRACCAR_DB_NAME=traccar
```

Teste o script digitando `/usr/lib/check_mk_agent/local/traccar_partitions`. Deve sair `0 Traccar_EventScheduler - OK...` e status verde.

### Passo 9 — Iniciar o Traccar

```bash
systemctl start traccar
tail -f /opt/traccar/logs/tracker-server.log
```
O particionamento está implantado e em modo autônomo. **Nenhuma intervenção manual necessária após o deploy inicial.**

---

## 6. Migração Segura (Bancos com Dados Existentes)

Se você **preza pela tabela de posições anterior e quer reter os dados (ex: manter até 90 dias)** e o banco é grande, siga usando **Shadow Table**. A janela de indisponibilidade é de **~5 minutos**, transferindo a grande massa em modo online.

```text
[Traccar ativo] → escreve em tc_positions (original)
                     ↓
              tc_positions_new (nova particionada sendo populada em pararelo)
                     ↓
              [Traccar parado ~5min] → RENAME TABLE (swap atômico)
                     ↓
              [Traccar ativo] → escreve em tc_positions (particionada)
```

1. **Rodar script inicial de Shadow Table:**
   `mysql -u root -p traccar < 05_migracao_segura_300gb.sql`  
   Isso criará a `tc_positions_new` já particionada e a procedure `sp_migrate_positions_batch`.
2. **Transferir em lotes, enquanto Traccar roda normalmente:**
   Execute iterativamente (em script loop bash) copiando desde `-90 dias` até o dia de ontem. 
   ```bash
   while [[ "$CURRENT" < "$END_DATE" ]]; do
       mysql -u root -pSenha -se "CALL sp_migrate_positions_batch('$CURRENT', @n);"
       sleep 1
       CURRENT=$(date -d "$CURRENT + 1 day" +%Y-%m-%d)
   done
   ```
3. **Pausa e SWAP Final:**
   - Pare o traccar (`systemctl stop traccar`).
   - Copie o Delta de hoje que ficou faltando: `CALL sp_migrate_positions_batch(CURRENT_DATE, @n);`
   - Swap no banco: `RENAME TABLE tc_positions TO tc_positions_old, tc_positions_new TO tc_positions;`
   - Ligue o Traccar e retorne à **Fase de Automação (Passo 5 e Passo 6 do item 5)** para injetar os gatilhos, comentando/rejeitando o trecho `DROP TABLE` do script `01`.

---

## 7. Configurações do Traccar

Estas configurações no lado Java ajudam na leitura de bases longas.

### `traccar.xml`

```xml
<!-- /opt/traccar/conf/traccar.xml -->

<!-- Aumentar janela máxima de consulta permitida via API e Relatórios (padrão 30) -->
<entry key='database.maxQueryInterval'>90</entry>

<!-- Aumentar timeout de query longa -->
<entry key='database.selectTimeout'>300000</entry>
```

### Heap JVM do Traccar

Edite o arquivo de serviços java do traccar para tolerar reports puxados:
```ini
# wrapper.conf ou systemd variables (dependendo do ambiente de SO)
wrapper.java.additional.3=-Xms512m
wrapper.java.additional.4=-Xmx4g
```
> Reinicie com `systemctl restart traccar`

---

## 8. Estimativa de Ganho de Espaço

**Referência de redução esperada em bases transacionais superpovoadas:**
| Etapa | Redução | Mecanismo |
|---|---|---|
| DROP partições > 90 dias | **85–92%** do total de linhas | `DROP PARTITION` — instantâneo sobre a filesystem |
| Compressão frias > 30 dias | **40–55%** do arquivo `.ibd` da fatia | `ROW_FORMAT=COMPRESSED` |
| **Total combinado** | **~93–96%** de otimização I/O e volume | — |

---

## 9. Manutenção e Operação

A base se policia sozinha diariamente, mas operações manuais comuns incluem:

```sql
-- Forçar criação da partição de amanhã manualmente
CALL sp_tc_positions_add_partition_tomorrow('traccar', 'tc_positions');

-- Forçar expurgo emergencial (remove tudo excedendo 90)
CALL sp_tc_positions_drop_old_partitions('traccar', 'tc_positions', 90);

-- Recriar partições para um intervalo avulso (ex: falhas longas no banco)
CALL sp_tc_positions_add_partitions_range('traccar', 'tc_positions', 90, 7);

-- Ver log interno do sucesso ou status das compressões automáticas
CALL sp_tc_positions_compress_history('traccar', 'tc_positions', 30);

-- Checar fragmentação visível (data livre sobressaída) de partições
SELECT PARTITION_NAME, FORMAT(TABLE_ROWS, 0) AS linhas,
       ROUND(DATA_FREE/NULLIF(DATA_LENGTH+DATA_FREE,0)*100, 1) AS fragmentacao_pct
FROM information_schema.PARTITIONS
WHERE TABLE_SCHEMA = 'traccar' AND TABLE_NAME = 'tc_positions'
ORDER BY fragmentacao_pct DESC LIMIT 5;
```

---

## 10. Troubleshooting

### Evento parou de fatiar ou não executa
```sql
-- Verifica se o Scheduler global caiu
SELECT @@global.event_scheduler;

-- Habilita o evento diretamente pela DDL
ALTER EVENT ev_tc_positions_add_partition ENABLE;
```

### Relatório do Traccar retorna vazio ou erro
```bash
# Verificar logs de erro Java. É comum cair em Timeouts longos não alterados no traccar.xml.
grep -i 'error\|exception\|outofmemory' /opt/traccar/logs/tracker-server.log | tail -50
```

### Event Scheduler para após restart do MySQL
Garanta que salvou no `/etc/mysql/mysql.conf.d/mysqld.cnf` a flag `event_scheduler=ON` dentro da sessão `[mysqld]`.

### Erro "Table has no partition for value"
A partição extrema de segurança (`p_future`) não foi recriada e a tabela chegou em datas futuras vazias de escopo.
```sql
ALTER TABLE tc_positions
      ADD PARTITION (PARTITION p_future VALUES LESS THAN MAXVALUE);
```

---

## 11. Referência Rápida de Procedures e Eventos

### Procedures
| Procedure | Parâmetros | Descrição |
|---|---|---|
| `sp_tc_positions_add_partitions_range` | schema, tabela, dias_atrás, dias_frente | Bootstrap recursivo de partições em lote |
| `sp_tc_positions_add_partition_tomorrow` | schema, tabela | Cria a partição individual para acomodar as gravações das próximas 24h |
| `sp_tc_positions_drop_old_partitions` | schema, tabela, keep_days | Expurga com DRop Partition as fatias passadas obsoletas |
| `sp_tc_positions_compress_cold_partitions` | schema, tabela, cold_days, dry_run | Refatora o ROW_FORMAT visando ganhar estática de armzenamento |

### Eventos (Jobs Automáticos)
| Evento | Timing de Acionamento | Direcionamento |
|---|---|---|
| `ev_tc_positions_add_partition` | Diário às 01:00 am | Prepara ponteiro logico pra a partir da meia noite |
| `ev_tc_positions_drop_old` | Diário às 02:00 am | Expurga fatias menores de 90 dias em formato O(1) de disco |
| `ev_tc_positions_compress_cold` | Domingos às 03:00 am | Escaneia por tabelas intactas com vida acima de 30 dias |

---
*Documento Unificado de Implantação e Operações — Particionamento Diário tc_positions.*
