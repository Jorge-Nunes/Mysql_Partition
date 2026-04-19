# Plano de Implantação — tc_positions Particionada

> **Versão:** 1.0  
> **Data:** Abril 2026  
> **Objetivo:** Implementar particionamento diário com retenção de 90 dias e compressão automática

---

## Pré-requisitos

| Item | Responsável | Status |
|------|-------------|--------|
| Backup do banco realizado | DBA | ⬜ |
| my.cnf com configurações mínimas | DevOps/SysAdmin | ⬜ |
| Credenciais root MySQL | DBA | ⬜ |
| Traccar parado | Ops | ⬜ |

---

## Passo 1 — Parar o Traccar

```bash
# Parar serviço
systemctl stop traccar

# Verificar se parou
systemctl status traccar
```

---

## Passo 2 — Configurar my.cnf

Arquivo: `/etc/mysql/mysql.conf.d/mysqld.cnf` (ou equivalente)

```ini
[mysqld]
event_scheduler         = ON
innodb_file_per_table   = ON
innodb_buffer_pool_size = 4G   # Ajuste: 60-70% da RAM disponível
```

```bash
# Reiniciar MySQL para aplicar
systemctl restart mysql
```

---

## Passo 3 — Verificar configurações

```sql
SELECT @@global.event_scheduler;      -- Deve retornar ON
SELECT @@global.innodb_file_per_table; -- Deve retornar ON
SELECT @@global.innodb_buffer_pool_size / 1024 / 1024 / 1024 AS buffer_pool_gb;
```

---

## Passo 4 — Executar Script 01 (Particionamento)

```bash
mysql -u root -p traccar < /caminho/01_tc_positions_particionamento_COMPLETO.sql
```

**O que faz:**
- DROP TABLE tc_positions (se existir)
- CREATE TABLE com particionamento diário
- Cria 3 procedures
- Cria 8 partições (0 passadas + 7 futuras + p_future)
- Cria 2 eventos automáticos

**Saída esperada:**
```
PARTIÇÕES CRIADAS:
+----------------+----------------+...
| PARTITION_NAME | boundary_epoch | ...
+----------------+----------------+...
| p20260418      | 1744924800     | ...
...
| p_future       | MAXVALUE       | ...
+----------------+----------------+...

EVENTOS CRIADOS:
+---------------------------------+---------+...
| EVENT_NAME                      | STATUS  | ...
+---------------------------------+---------+...
| ev_tc_positions_add_partition  | ENABLED | ...
| ev_tc_positions_drop_old        | ENABLED | ...
+---------------------------------+---------+...
```

---

## Passo 5 — Executar Script 04 (Compressão)

```bash
mysql -u root -p traccar < /caminho/04_compactacao_particoes_antigas.sql
```

**O que faz:**
- Cria procedure `sp_tc_positions_compress_cold_partitions`
- Cria procedure `sp_tc_positions_compress_history`
- Cria tabela log `tc_partition_compress_log`
- Cria evento `ev_tc_positions_compress_cold` (domingo 03:00)

**Nota:** Como tabela está zerada, não comprime nada agora. Compressão automática começa quando partições ficarem frias (>30 dias).

---

## Passo 6 — Executar Script 02 (Validação)

```bash
mysql -u root -p traccar < /caminho/02_checklist_particionamento.sql
```

**Resultado esperado:**
```
✅  OK — Event Scheduler ATIVO
✅  OK — Todos os 2 eventos ENABLED
✅  OK — Partição p_future (MAXVALUE) presente
✅  OK — Partição de amanhã existe
✅  OK — Nenhuma partição expirada encontrada
✅  OK — Janela >= 0 dias (tabela zerada)
✅  OK — Todas as 3 procedures encontradas
```

---

## Passo 7 — Configurar CheckMK

### 7.1 — Criar usuário MySQL somente leitura

```sql
CREATE USER 'traccar_monitor'@'127.0.0.1' IDENTIFIED BY 'Federal@321!';
GRANT SELECT ON information_schema.* TO 'traccar_monitor'@'127.0.0.1';
GRANT SHOW DATABASES ON *.* TO 'traccar_monitor'@'127.0.0.1';
FLUSH PRIVILEGES;
```

### 7.2 — Copiar script de monitoramento

```bash
cp /caminho/03_checkmk_traccar_partitions.py \
   /usr/lib/check_mk_agent/local/traccar_partitions
chmod +x /usr/lib/check_mk_agent/local/traccar_partitions
```

### 7.3 — Configurar credenciais

```bash
# Via variáveis de ambiente
export TRACCAR_DB_HOST=127.0.0.1
export TRACCAR_DB_USER=traccar_monitor
export TRACCAR_DB_PASS=senha_forte_aqui
export TRACCAR_DB_NAME=traccar
```

### 7.4 — Testar

```bash
/usr/lib/check_mk_agent/local/traccar_partitions
```

**Saída esperada:**
```
0 Traccar_EventScheduler - OK - Event Scheduler ATIVO
0 Traccar_ScheduledEvents events_ok=2 OK - Todos os 2 eventos ENABLED
0 Traccar_Partition_Future - OK - Partição p_future (MAXVALUE) presente
0 Traccar_Partition_Tomorrow - OK - Partição de amanhã existe
0 Traccar_Partitions_Expired - OK - Nenhuma partição expirada
0 Traccar_Partitions_FutureCoverage - OK - Cobertura futura OK
0 Traccar_Partitions_DailyCount - OK - Total partições OK
0 Traccar_Partitions_TableSize - OK - Tamanho tabela: X.XX GB
```

---

## Passo 8 — Iniciar o Traccar

```bash
systemctl start traccar

# Verificar logs
tail -f /opt/traccar/logs/tracker-server.log
```

---

## Passo 9 — Monitoramento Contínuo

| Serviço CheckMK | Alerta |
|-----------------|--------|
| `Traccar_EventScheduler` | CRITICAL se OFF |
| `Traccar_ScheduledEvents` | WARN se evento nunca executou |
| `Traccar_Partition_Future` | CRITICAL se ausente |
| `Traccar_Partition_Tomorrow` | WARN se ausente |
| `Traccar_Partitions_Expired` | WARN/CRIT se >0 |

---

## Resumo — Ordem de Execução

| Passo | Ação | Script |
|-------|------|--------|
| 1 | Parar Traccar | — |
| 2 | Configurar my.cnf | — |
| 3 | Reiniciar MySQL | — |
| 4 | Verificar configs | — |
| 5 | Criar tabela particionada | **01** |
| 6 | Instalar compressão | **04** |
| 7 | Validar checklist | **02** |
| 8 | Configurar CheckMK | — |
| 9 | Iniciar Traccar | — |

---

## Tempo Estimado

| Fase | Tempo |
|------|-------|
| Parada Traccar | 1 min |
| Config my.cnf + restart MySQL | 3 min |
| Script 01 | 2 min |
| Script 04 | 1 min |
| Script 02 | 30 seg |
| CheckMK | 2 min |
| Iniciar Traccar | 1 min |
| **Total** | **~10 min** |

---

## Em Caso de Problemas

| Problema | Solução |
|----------|---------|
| Evento não criou partição | `CALL sp_tc_positions_add_partition_tomorrow('traccar', 'tc_positions');` |
| Evento não dropou partição | `CALL sp_tc_positions_drop_old_partitions('traccar', 'tc_positions', 90);` |
| Erro "Table has no partition" | `ALTER TABLE tc_positions ADD PARTITION (PARTITION p_future VALUES LESS THAN MAXVALUE);` |

---

## Automação Resumida

| Tarefa | Automático? | Frequência |
|--------|-------------|------------|
| Criar partição do dia seguinte | ✅ Sim | Diário 01:00 |
| Remover partições >90 dias | ✅ Sim | Diário 02:00 |
| Comprimir partições frias (>30 dias) | ✅ Sim | Semanal 03:00 |
| Monitoramento CheckMK | ✅ Sim | Contínuo |

**Nenhuma intervenção manual necessária após o deploy inicial.**
