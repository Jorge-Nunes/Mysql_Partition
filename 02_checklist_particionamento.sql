/* ============================================================
   TRACCAR — Checklist de Saúde do Particionamento tc_positions
   Como usar:
     mysql -u root -p traccar < 02_checklist_particionamento.sql
   Saída: tabelas formatadas com status OK / ALERTA / ERRO
   ============================================================ */

USE traccar;

-- ============================================================
-- CHECK 1 — Event Scheduler está ON?
-- ============================================================
SELECT '═══════════════════════════════════════════' AS '';
SELECT '  CHECK 1 — EVENT SCHEDULER'                 AS '';
SELECT '═══════════════════════════════════════════' AS '';

SELECT
    @@global.event_scheduler AS valor,
    CASE @@global.event_scheduler
        WHEN 'ON' THEN '✅  OK — Event Scheduler ATIVO'
        ELSE            '❌  ERRO — Event Scheduler INATIVO (adicione event_scheduler=ON no my.cnf)'
    END AS status;

-- ============================================================
-- CHECK 2 — Os 3 eventos existem e estão ENABLED?
-- ============================================================
SELECT '═══════════════════════════════════════════' AS '';
SELECT '  CHECK 2 — EVENTOS AUTOMÁTICOS'             AS '';
SELECT '═══════════════════════════════════════════' AS '';

SELECT
    e.EVENT_NAME,
    e.STATUS,
    e.INTERVAL_VALUE,
    e.INTERVAL_FIELD,
    e.STARTS,
    COALESCE(CAST(e.LAST_EXECUTED AS CHAR), 'nunca executado') AS LAST_EXECUTED,
    CASE
        WHEN e.STATUS = 'ENABLED' THEN '✅  OK'
        WHEN e.STATUS = 'DISABLED' THEN '⚠️  ALERTA — Evento desabilitado'
        ELSE '❌  ERRO — Status inesperado'
    END AS resultado
FROM information_schema.EVENTS e
WHERE e.EVENT_SCHEMA = 'traccar'
  AND e.EVENT_NAME IN (
      'ev_tc_positions_add_partition',
      'ev_tc_positions_drop_old'
  )
ORDER BY e.EVENT_NAME;

-- Alertar se algum evento estiver faltando
SELECT
    CASE
        WHEN COUNT(*) = 2 THEN '✅  OK — Todos os 2 eventos encontrados'
        ELSE CONCAT('❌  ERRO — Apenas ', COUNT(*), '/2 eventos encontrados')
    END AS resumo_eventos
FROM information_schema.EVENTS
WHERE EVENT_SCHEMA = 'traccar'
  AND EVENT_NAME IN (
      'ev_tc_positions_add_partition',
      'ev_tc_positions_drop_old'
  );

-- ============================================================
-- CHECK 3 — Partição p_future (MAXVALUE) existe?
-- ============================================================
SELECT '═══════════════════════════════════════════' AS '';
SELECT '  CHECK 3 — PARTIÇÃO p_future (MAXVALUE)'   AS '';
SELECT '═══════════════════════════════════════════' AS '';

SELECT
    PARTITION_NAME,
    PARTITION_DESCRIPTION,
    CASE
        WHEN PARTITION_NAME = 'p_future' AND PARTITION_DESCRIPTION = 'MAXVALUE'
        THEN '✅  OK — Partição de segurança presente'
        ELSE '❌  ERRO — p_future ausente! INSERTs futuros vão falhar'
    END AS status
FROM information_schema.PARTITIONS
WHERE TABLE_SCHEMA    = 'traccar'
  AND TABLE_NAME      = 'tc_positions'
  AND PARTITION_NAME  = 'p_future';

-- ============================================================
-- CHECK 4 — Partição de AMANHÃ existe?
-- ============================================================
SELECT '═══════════════════════════════════════════' AS '';
SELECT '  CHECK 4 — PARTIÇÃO DE AMANHÃ'             AS '';
SELECT '═══════════════════════════════════════════' AS '';

SET @tomorrow_pname = CONCAT('p', DATE_FORMAT(CURRENT_DATE + INTERVAL 2 DAY, '%Y%m%d'));

SELECT
    @tomorrow_pname AS particao_esperada,
    CASE
        WHEN COUNT(*) > 0 THEN '✅  OK — Partição de amanhã existe'
        ELSE '⚠️  ALERTA — Partição de amanhã ausente (evento ainda não rodou hoje?)'
    END AS status
FROM information_schema.PARTITIONS
WHERE TABLE_SCHEMA   = 'traccar'
  AND TABLE_NAME     = 'tc_positions'
  AND PARTITION_NAME = @tomorrow_pname;

-- ============================================================
-- CHECK 5 — Partições mais antigas que 90 dias ainda existem?
-- ============================================================
SELECT '═══════════════════════════════════════════' AS '';
SELECT '  CHECK 5 — PARTIÇÕES EXPIRADAS (>90 dias)' AS '';
SELECT '═══════════════════════════════════════════' AS '';

SELECT
    PARTITION_NAME,
    FROM_UNIXTIME(CAST(PARTITION_DESCRIPTION AS UNSIGNED)) AS less_than_datetime,
    DATEDIFF(
        NOW(),
        FROM_UNIXTIME(CAST(PARTITION_DESCRIPTION AS UNSIGNED))
    ) AS dias_atras,
    '⚠️  ALERTA — Deveria ter sido dropada' AS status
FROM information_schema.PARTITIONS
WHERE TABLE_SCHEMA   = 'traccar'
  AND TABLE_NAME     = 'tc_positions'
  AND PARTITION_NAME != 'p_future'
  AND PARTITION_NAME IS NOT NULL
  AND CAST(PARTITION_DESCRIPTION AS UNSIGNED)
        <= UNIX_TIMESTAMP(CURRENT_DATE - INTERVAL 90 DAY)
ORDER BY CAST(PARTITION_DESCRIPTION AS UNSIGNED);

SELECT
    CASE
        WHEN COUNT(*) = 0 THEN '✅  OK — Nenhuma partição expirada encontrada'
        ELSE CONCAT('⚠️  ALERTA — ', COUNT(*), ' partição(ões) expirada(s) encontrada(s)')
    END AS resumo_expiracao
FROM information_schema.PARTITIONS
WHERE TABLE_SCHEMA   = 'traccar'
  AND TABLE_NAME     = 'tc_positions'
  AND PARTITION_NAME != 'p_future'
  AND PARTITION_NAME IS NOT NULL
  AND CAST(PARTITION_DESCRIPTION AS UNSIGNED)
        <= UNIX_TIMESTAMP(CURRENT_DATE - INTERVAL 90 DAY);

-- ============================================================
-- CHECK 6 — Janela de cobertura (partição mais antiga e mais nova)
-- ============================================================
SELECT '═══════════════════════════════════════════' AS '';
SELECT '  CHECK 6 — JANELA DE COBERTURA'             AS '';
SELECT '═══════════════════════════════════════════' AS '';

SELECT
    COUNT(*) - 1                    AS total_particoes_diarias,   -- desconta p_future
    FROM_UNIXTIME(MIN(CAST(PARTITION_DESCRIPTION AS UNSIGNED))) AS cobertura_ate,
    DATEDIFF(
        FROM_UNIXTIME(MAX(
            CASE WHEN PARTITION_NAME != 'p_future'
                 THEN CAST(PARTITION_DESCRIPTION AS UNSIGNED)
            END
        )),
        NOW()
    )                               AS dias_futuros_cobertos,
    CASE
        WHEN COUNT(*) - 1 >= 90 THEN '✅  OK — Janela >= 90 dias'
        ELSE CONCAT('⚠️  ALERTA — Apenas ', COUNT(*) - 1, ' partições diárias criadas')
    END AS status
FROM information_schema.PARTITIONS
WHERE TABLE_SCHEMA = 'traccar'
  AND TABLE_NAME   = 'tc_positions';

-- ============================================================
-- CHECK 7 — Procedures existem?
-- ============================================================
SELECT '═══════════════════════════════════════════' AS '';
SELECT '  CHECK 7 — PROCEDURES'                     AS '';
SELECT '═══════════════════════════════════════════' AS '';

SELECT
    r.ROUTINE_NAME,
    r.ROUTINE_TYPE,
    r.CREATED,
    r.LAST_ALTERED,
    '✅  OK' AS status
FROM information_schema.ROUTINES r
WHERE r.ROUTINE_SCHEMA = 'traccar'
  AND r.ROUTINE_NAME IN (
      'sp_tc_positions_add_partitions_range',
      'sp_tc_positions_add_partition_tomorrow',
      'sp_tc_positions_drop_old_partitions'
  )
ORDER BY r.ROUTINE_NAME;

SELECT
    CASE
        WHEN COUNT(*) = 3 THEN '✅  OK — Todas as 3 procedures encontradas'
        ELSE CONCAT('❌  ERRO — Apenas ', COUNT(*), '/3 procedures encontradas')
    END AS resumo_procedures
FROM information_schema.ROUTINES
WHERE ROUTINE_SCHEMA = 'traccar'
  AND ROUTINE_NAME IN (
      'sp_tc_positions_add_partitions_range',
      'sp_tc_positions_add_partition_tomorrow',
      'sp_tc_positions_drop_old_partitions'
  );

-- ============================================================
-- CHECK 8 — Listagem completa de partições com tamanho
-- ============================================================
SELECT '═══════════════════════════════════════════' AS '';
SELECT '  CHECK 8 — LISTAGEM COMPLETA DE PARTIÇÕES' AS '';
SELECT '═══════════════════════════════════════════' AS '';

SELECT
    PARTITION_NAME,
    CASE
        WHEN PARTITION_NAME = 'p_future' THEN 'MAXVALUE (segurança)'
        ELSE CAST(FROM_UNIXTIME(CAST(PARTITION_DESCRIPTION AS UNSIGNED)) AS CHAR)
    END                                                          AS less_than_datetime,
    FORMAT(TABLE_ROWS, 0)                                        AS linhas_estimadas,
    CONCAT(ROUND((DATA_LENGTH + INDEX_LENGTH) / 1024 / 1024, 2), ' MB') AS tamanho
FROM information_schema.PARTITIONS
WHERE TABLE_SCHEMA = 'traccar'
  AND TABLE_NAME   = 'tc_positions'
ORDER BY
    CASE WHEN PARTITION_NAME = 'p_future' THEN 1 ELSE 0 END,
    CAST(PARTITION_DESCRIPTION AS UNSIGNED);

-- ============================================================
-- RESUMO FINAL
-- ============================================================
SELECT '═══════════════════════════════════════════════════════' AS '';
SELECT '  RESUMO — rode sem ❌ ou ⚠️ para considerar saudável'  AS '';
SELECT '═══════════════════════════════════════════════════════' AS '';
