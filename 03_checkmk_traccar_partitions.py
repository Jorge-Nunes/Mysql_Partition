#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
=============================================================================
  CheckMK Local Check — Traccar tc_positions Partition Health
  Arquivo : traccar_partitions
  Instalar: /usr/lib/check_mk_agent/local/traccar_partitions
  Permissão: chmod +x /usr/lib/check_mk_agent/local/traccar_partitions

  Saída padrão CheckMK local check:
    <status> <service_name> <metric|-> <summary>
    0 = OK | 1 = WARN | 2 = CRIT | 3 = UNKNOWN

  Dependências:
    pip3 install mysql-connector-python

  Configuração (variáveis abaixo ou via env):
    TRACCAR_DB_HOST, TRACCAR_DB_PORT, TRACCAR_DB_USER,
    TRACCAR_DB_PASS, TRACCAR_DB_NAME
=============================================================================
"""

import os
import sys
from datetime import datetime, timedelta

# ── Tentar importar conector MySQL ──────────────────────────────────────────
try:
    import mysql.connector
except ImportError:
    print("3 Traccar_Partition_Health - - UNKNOWN: mysql-connector-python não instalado")
    sys.exit(0)

# ── Configuração de conexão ──────────────────────────────────────────────────
env_file = "/etc/check_mk/traccar_db.env"
if os.path.exists(env_file):
    with open(env_file, "r") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#"):
                if line.startswith("export "):
                    line = line[7:]
                if "=" in line:
                    k, v = line.split("=", 1)
                    os.environ[k.strip()] = v.strip().strip("'\"")

DB_HOST = os.environ.get("TRACCAR_DB_HOST", "127.0.0.1")
DB_PORT = int(os.environ.get("TRACCAR_DB_PORT", 3306))
DB_USER = os.environ.get("TRACCAR_DB_USER", "traccar")
DB_PASS = os.environ.get("TRACCAR_DB_PASS", "SENHA_AQUI")
DB_NAME = os.environ.get("TRACCAR_DB_NAME", "traccar")

# ── Thresholds ───────────────────────────────────────────────────────────────
RETENTION_DAYS       = 90   # dias de retenção esperados
WARN_EXPIRED         = 1    # partições expiradas antes de WARN
CRIT_EXPIRED         = 3    # partições expiradas antes de CRIT
WARN_FUTURE_DAYS     = 2    # dias futuros cobertos antes de WARN
CRIT_FUTURE_DAYS     = 1    # dias futuros cobertos antes de CRIT
WARN_MIN_PARTITIONS  = 85   # mínimo de partições diárias (WARN)
CRIT_MIN_PARTITIONS  = 80   # mínimo de partições diárias (CRIT)

# ── Helpers ──────────────────────────────────────────────────────────────────
def mk_output(status, name, metrics, summary):
    """Formata linha de saída padrão CheckMK local check."""
    print(f"{status} {name} {metrics} {summary}")

def connect():
    return mysql.connector.connect(
        host=DB_HOST, port=DB_PORT,
        user=DB_USER, password=DB_PASS,
        database=DB_NAME,
        connection_timeout=10
    )

# ── Checks ───────────────────────────────────────────────────────────────────

def check_event_scheduler(cursor):
    """CHECK 1 — Event Scheduler ativo."""
    cursor.execute("SHOW VARIABLES LIKE 'event_scheduler'")
    row = cursor.fetchone()
    val = row[1].upper() if row else "UNKNOWN"
    if val == "ON":
        mk_output(0, "Traccar_EventScheduler", "-",
                  "OK - Event Scheduler ATIVO")
    else:
        mk_output(2, "Traccar_EventScheduler", "-",
                  f"CRIT - Event Scheduler está {val}. Adicione event_scheduler=ON ao my.cnf")


def check_events(cursor):
    """CHECK 2 — Eventos automáticos existem e estão ENABLED."""
    expected = {
        "ev_tc_positions_add_partition",
        "ev_tc_positions_drop_old",
    }
    cursor.execute("""
        SELECT EVENT_NAME, STATUS, LAST_EXECUTED
          FROM information_schema.EVENTS
         WHERE EVENT_SCHEMA = %s
           AND EVENT_NAME IN (
               'ev_tc_positions_add_partition',
               'ev_tc_positions_drop_old'
           )
    """, (DB_NAME,))
    rows = cursor.fetchall()
    found      = {r[0] for r in rows}
    missing    = expected - found
    disabled   = [r[0] for r in rows if r[1] != "ENABLED"]
    never_ran  = [r[0] for r in rows if r[2] is None]

    issues = []
    status = 0

    if missing:
        issues.append(f"ausentes: {', '.join(missing)}")
        status = 2
    if disabled:
        issues.append(f"desabilitados: {', '.join(disabled)}")
        status = max(status, 2)
    if never_ran:
        issues.append(f"nunca executados: {', '.join(never_ran)}")
        status = max(status, 1)

    summary = "OK - Todos os 2 eventos ENABLED" if not issues else "WARN/CRIT - " + "; ".join(issues)
    mk_output(status, "Traccar_ScheduledEvents", f"events_ok={len(found)}", summary)


def check_partitions(cursor):
    """CHECK 3/4/5/6 — Saúde das partições (múltiplos sub-checks)."""
    cursor.execute("""
        SELECT PARTITION_NAME,
               PARTITION_DESCRIPTION,
               TABLE_ROWS,
               DATA_LENGTH + INDEX_LENGTH AS size_bytes
          FROM information_schema.PARTITIONS
         WHERE TABLE_SCHEMA = %s
           AND TABLE_NAME   = 'tc_positions'
    """, (DB_NAME,))
    rows = cursor.fetchall()

    if not rows:
        mk_output(2, "Traccar_Partitions", "-",
                  "CRIT - Tabela tc_positions sem partições ou não existe")
        return

    # ── p_future (MAXVALUE) presente?
    has_future = any(r[0] == "p_future" for r in rows)
    if has_future:
        mk_output(0, "Traccar_Partition_Future", "-",
                  "OK - Partição p_future (MAXVALUE) presente")
    else:
        mk_output(2, "Traccar_Partition_Future", "-",
                  "CRIT - Partição p_future ausente! INSERTs podem falhar")

    # ── Partições diárias (excluir p_future)
    daily = [
        r for r in rows
        if r[0] != "p_future"
        and r[1] is not None
        and r[1] != "MAXVALUE"
    ]
    daily_count = len(daily)

    # ── Partição de amanhã existe?
    tomorrow_pname = "p" + (datetime.now() + timedelta(days=2)).strftime("%Y%m%d")
    has_tomorrow   = any(r[0] == tomorrow_pname for r in daily)
    if has_tomorrow:
        mk_output(0, "Traccar_Partition_Tomorrow", "-",
                  f"OK - Partição de amanhã ({tomorrow_pname}) existe")
    else:
        mk_output(1, "Traccar_Partition_Tomorrow", "-",
                  f"WARN - Partição de amanhã ({tomorrow_pname}) ainda não criada")

    # ── Partições expiradas
    cutoff_epoch = int((datetime.now() - timedelta(days=RETENTION_DAYS)).timestamp())
    expired = [
        r for r in daily
        if int(r[1]) <= cutoff_epoch
    ]
    expired_count = len(expired)
    if expired_count == 0:
        exp_status  = 0
        exp_summary = f"OK - Nenhuma partição expirada (retenção {RETENTION_DAYS}d)"
    elif expired_count < CRIT_EXPIRED:
        exp_status  = 1
        exp_summary = f"WARN - {expired_count} partição(ões) expirada(s)"
    else:
        exp_status  = 2
        exp_summary = f"CRIT - {expired_count} partições expiradas (limpeza falhou?)"
    mk_output(exp_status, "Traccar_Partitions_Expired",
              f"expired={expired_count};{WARN_EXPIRED};{CRIT_EXPIRED}",
              exp_summary)

    # ── Cobertura futura (dias cobertos além de hoje)
    future_epochs = [int(r[1]) for r in daily if int(r[1]) > int(datetime.now().timestamp())]
    if future_epochs:
        max_future_dt   = datetime.fromtimestamp(max(future_epochs))
        future_days_cov = (max_future_dt - datetime.now()).days
    else:
        future_days_cov = 0

    if future_days_cov >= WARN_FUTURE_DAYS:
        fut_status  = 0
        fut_summary = f"OK - {future_days_cov} dia(s) futuro(s) coberto(s)"
    elif future_days_cov >= CRIT_FUTURE_DAYS:
        fut_status  = 1
        fut_summary = f"WARN - Apenas {future_days_cov} dia(s) futuro(s) coberto(s)"
    else:
        fut_status  = 2
        fut_summary = f"CRIT - Cobertura futura insuficiente: {future_days_cov} dia(s)"
    mk_output(fut_status, "Traccar_Partitions_FutureCoverage",
              f"future_days={future_days_cov};{WARN_FUTURE_DAYS};{CRIT_FUTURE_DAYS}",
              fut_summary)

    # ── Quantidade total de partições diárias
    if daily_count >= WARN_MIN_PARTITIONS:
        cnt_status  = 0
        cnt_summary = f"OK - {daily_count} partições diárias"
    elif daily_count >= CRIT_MIN_PARTITIONS:
        cnt_status  = 1
        cnt_summary = f"WARN - Apenas {daily_count} partições diárias (mín esperado {WARN_MIN_PARTITIONS})"
    else:
        cnt_status  = 2
        cnt_summary = f"CRIT - Apenas {daily_count} partições diárias (mín crítico {CRIT_MIN_PARTITIONS})"
    mk_output(cnt_status, "Traccar_Partitions_DailyCount",
              f"daily_count={daily_count};{WARN_MIN_PARTITIONS};{CRIT_MIN_PARTITIONS}",
              cnt_summary)

    # ── Tamanho total da tabela
    total_bytes = sum(r[3] for r in rows if r[3])
    total_mb    = round(total_bytes / 1024 / 1024, 2)
    mk_output(0, "Traccar_Partitions_TableSize",
              f"size_mb={total_mb}MB",
              f"OK - Tamanho total da tabela: {total_mb} MB")


def check_procedures(cursor):
    """CHECK 7 — Procedures existem."""
    expected = {
        "sp_tc_positions_add_partitions_range",
        "sp_tc_positions_add_partition_tomorrow",
        "sp_tc_positions_drop_old_partitions",
    }
    cursor.execute("""
        SELECT ROUTINE_NAME
          FROM information_schema.ROUTINES
         WHERE ROUTINE_SCHEMA = %s
           AND ROUTINE_NAME IN (
               'sp_tc_positions_add_partitions_range',
               'sp_tc_positions_add_partition_tomorrow',
               'sp_tc_positions_drop_old_partitions'
           )
    """, (DB_NAME,))
    found   = {r[0] for r in cursor.fetchall()}
    missing = expected - found

    if not missing:
        mk_output(0, "Traccar_StoredProcedures",
                  f"procs_ok={len(found)}",
                  "OK - Todas as 3 procedures encontradas")
    else:
        mk_output(2, "Traccar_StoredProcedures",
                  f"procs_ok={len(found)}",
                  f"CRIT - Procedures ausentes: {', '.join(missing)}")


# ── Main ─────────────────────────────────────────────────────────────────────
def main():
    try:
        conn   = connect()
        cursor = conn.cursor()

        check_event_scheduler(cursor)
        check_events(cursor)
        check_partitions(cursor)
        check_procedures(cursor)

        cursor.close()
        conn.close()

    except mysql.connector.Error as e:
        mk_output(2, "Traccar_Partition_Health", "-",
                  f"CRIT - Falha na conexão MySQL: {e}")
    except Exception as e:
        mk_output(3, "Traccar_Partition_Health", "-",
                  f"UNKNOWN - Erro inesperado: {e}")


if __name__ == "__main__":
    main()
