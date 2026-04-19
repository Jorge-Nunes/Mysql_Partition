/* ============================================================
   TRACCAR — Migração Segura tc_positions 300GB → Particionada
   Estratégia: Shadow Table (zero downtime)
   
   FLUXO:
     Fase 1 — Criar tc_positions_new particionada (vazia)
     Fase 2 — Migrar dados dos últimos 90 dias em lotes
     Fase 3 — Pausar Traccar, sincronizar delta, fazer swap
     Fase 4 — Validar e dropar tabela antiga
   
   Tempo estimado total: 2–6 horas dependendo do volume
   Janela de parada do Traccar: ~5 minutos (só no swap)
   ============================================================ */

USE traccar;

-- ============================================================
-- FASE 0 — Diagnóstico antes de começar
-- ============================================================

-- 0.1 Volume de dados por período
SELECT
    CASE
        WHEN fixtime >= NOW() - INTERVAL 90  DAY THEN 'últimos 90 dias (MANTER)'
        WHEN fixtime >= NOW() - INTERVAL 180 DAY THEN '90–180 dias (DESCARTAR)'
        WHEN fixtime >= NOW() - INTERVAL 365 DAY THEN '180–365 dias (DESCARTAR)'
        ELSE                                         'mais de 1 ano (DESCARTAR)'
    END                         AS periodo,
    FORMAT(COUNT(*), 0)         AS registros,
    ROUND(COUNT(*) * 100.0 /
        (SELECT COUNT(*) FROM tc_positions), 1) AS pct_total
FROM tc_positions
GROUP BY 1
ORDER BY MIN(fixtime);

-- 0.2 Espaço disponível em disco (Linux)
-- Execute no shell: df -h /var/lib/mysql

-- 0.3 Confirmar engine e row_format atual
SELECT
    TABLE_NAME,
    ENGINE,
    ROW_FORMAT,
    ROUND((DATA_LENGTH + INDEX_LENGTH) / 1024/1024/1024, 2) AS size_gb,
    TABLE_ROWS
FROM information_schema.TABLES
WHERE TABLE_SCHEMA = 'traccar'
  AND TABLE_NAME   = 'tc_positions';

-- ============================================================
-- FASE 1 — Criar tabela nova particionada (paralela, vazia)
--           Traccar continua escrevendo na tabela original
-- ============================================================

DROP TABLE IF EXISTS tc_positions_new;

CREATE TABLE `tc_positions_new` (
  `id`          BIGINT        NOT NULL AUTO_INCREMENT,
  `protocol`    VARCHAR(128)           DEFAULT NULL,
  `deviceid`    INT           NOT NULL,
  `servertime`  TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `devicetime`  TIMESTAMP     NOT NULL,
  `fixtime`     TIMESTAMP     NOT NULL,
  `valid`        BIT(1)       NOT NULL,
  `latitude`    DOUBLE        NOT NULL,
  `longitude`   DOUBLE        NOT NULL,
  `altitude`    FLOAT         NOT NULL,
  `speed`       FLOAT         NOT NULL,
  `course`      FLOAT         NOT NULL,
  `address`     VARCHAR(512)           DEFAULT NULL,
  `attributes`  VARCHAR(4000)          DEFAULT NULL,
  `accuracy`    DOUBLE        NOT NULL DEFAULT '0',
  `network`     VARCHAR(4000)          DEFAULT NULL,
  `geofenceids` VARCHAR(128)           DEFAULT NULL,
  PRIMARY KEY (`id`, `fixtime`),
  KEY `position_deviceid_fixtime` (`deviceid`, `fixtime`)
) ENGINE=InnoDB
  DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  PARTITION BY RANGE (UNIX_TIMESTAMP(`fixtime`)) (
    PARTITION p_future VALUES LESS THAN MAXVALUE
  );

-- Criar partições para os últimos 90 dias + 7 dias à frente
CALL sp_tc_positions_add_partitions_range('traccar', 'tc_positions_new', 90, 7);

-- Confirmar partições criadas
SELECT COUNT(*) AS particoes_criadas
FROM information_schema.PARTITIONS
WHERE TABLE_SCHEMA = 'traccar'
  AND TABLE_NAME   = 'tc_positions_new';

-- ============================================================
-- FASE 2 — Migrar dados dos últimos 90 dias em lotes
--
--  Execute este bloco repetidamente até @rows_migrated = 0
--  Cada execução migra 1 dia de dados.
--  Pode rodar com Traccar ativo.
-- ============================================================

DROP PROCEDURE IF EXISTS sp_migrate_positions_batch;
DELIMITER $$
CREATE PROCEDURE sp_migrate_positions_batch(
    IN  p_batch_day     DATE,       -- qual dia migrar (ex: '2025-01-10')
    OUT p_rows_inserted BIGINT
)
BEGIN
    DECLARE v_start TIMESTAMP;
    DECLARE v_end   TIMESTAMP;

    SET v_start = TIMESTAMP(p_batch_day);
    SET v_end   = TIMESTAMP(p_batch_day) + INTERVAL 1 DAY;

    -- Inserir apenas registros que ainda não existem na nova tabela
    INSERT INTO tc_positions_new
        (id, protocol, deviceid, servertime, devicetime, fixtime,
         valid, latitude, longitude, altitude, speed, course,
         address, attributes, accuracy, network, geofenceids)
    SELECT
         id, protocol, deviceid, servertime, devicetime, fixtime,
         valid, latitude, longitude, altitude, speed, course,
         address, attributes, accuracy, network, geofenceids
    FROM tc_positions
    WHERE fixtime >= v_start
      AND fixtime <  v_end
    ON DUPLICATE KEY UPDATE id = id;  -- idempotente: re-run seguro

    SET p_rows_inserted = ROW_COUNT();

    SELECT
        p_batch_day                       AS dia_migrado,
        p_rows_inserted                   AS linhas_inseridas,
        (SELECT COUNT(*) FROM tc_positions_new) AS total_na_nova_tabela;
END$$
DELIMITER ;

-- ── Script Shell para automatizar a migração dia a dia ──────
-- Salve como /tmp/migrate_positions.sh e execute:
--
-- #!/bin/bash
-- START_DATE="2025-01-11"   # NOW() - 90 days
-- END_DATE=$(date +%Y-%m-%d)
-- CURRENT=$START_DATE
-- while [[ "$CURRENT" < "$END_DATE" ]]; do
--   echo "Migrando $CURRENT..."
--   mysql -u root -p'SENHA' traccar -e \
--     "CALL sp_migrate_positions_batch('$CURRENT', @n); SELECT @n;"
--   CURRENT=$(date -d "$CURRENT + 1 day" +%Y-%m-%d)
--   sleep 2   # respiro entre lotes para não saturar I/O
-- done
-- echo "Migração concluída!"

-- ============================================================
-- FASE 3 — SWAP (janela de ~5 minutos com Traccar parado)
--
--  ANTES: pare o serviço Traccar
--    systemctl stop traccar
--
--  Depois rode este bloco:
-- ============================================================

-- 3.1 Migrar o delta (posições inseridas desde o início da migração)
-- Rode a procedure para hoje e ontem para capturar o delta:
-- CALL sp_migrate_positions_batch(CURRENT_DATE, @n);
-- CALL sp_migrate_positions_batch(CURRENT_DATE - INTERVAL 1 DAY, @n);

-- 3.2 Conferir contagem antes do swap
SELECT 'ORIGINAL' AS tabela, COUNT(*) AS registros_90d
FROM tc_positions
WHERE fixtime >= NOW() - INTERVAL 90 DAY
UNION ALL
SELECT 'NOVA', COUNT(*)
FROM tc_positions_new
WHERE fixtime >= NOW() - INTERVAL 90 DAY;

-- 3.3 Swap atômico (renomear as duas tabelas de uma vez)
RENAME TABLE
    tc_positions     TO tc_positions_old,
    tc_positions_new TO tc_positions;

-- 3.4 Validar que a nova tabela está no lugar
SELECT
    TABLE_NAME,
    ROUND((DATA_LENGTH + INDEX_LENGTH)/1024/1024/1024, 2) AS size_gb,
    TABLE_ROWS
FROM information_schema.TABLES
WHERE TABLE_SCHEMA = 'traccar'
  AND TABLE_NAME IN ('tc_positions', 'tc_positions_old');

-- 3.5 Iniciar Traccar novamente
--   systemctl start traccar
--   Verifique os logs: tail -f /opt/traccar/logs/tracker-server.log

-- ============================================================
-- FASE 4 — Após confirmar que tudo funciona (aguarde 24-48h)
--           Dropar a tabela antiga
-- ============================================================

-- ATENÇÃO: só execute após confirmar que o Traccar está
-- operando normalmente com a nova tabela por 24-48 horas

-- DROP TABLE tc_positions_old;

-- ============================================================
-- FASE 5 — Aplicar compressão nas partições frias
--          (após a migração, com o sistema estável)
-- ============================================================

-- Comprime partições com mais de 30 dias (modo simulação primeiro):
-- CALL sp_tc_positions_compress_cold_partitions('traccar', 'tc_positions', 30, 1);

-- Se o resultado parecer ok, execute de verdade:
-- CALL sp_tc_positions_compress_cold_partitions('traccar', 'tc_positions', 30, 0);

-- ============================================================
-- MONITORAMENTO DA MIGRAÇÃO — Progresso em tempo real
-- ============================================================
SELECT
    ROUND(
        (SELECT COUNT(*) FROM tc_positions_new WHERE fixtime >= NOW() - INTERVAL 90 DAY)
        * 100.0
        / NULLIF(
            (SELECT COUNT(*) FROM tc_positions  WHERE fixtime >= NOW() - INTERVAL 90 DAY)
          , 0)
    , 1)                        AS progresso_pct,
    (SELECT COUNT(*) FROM tc_positions_new) AS registros_migrados,
    (SELECT COUNT(*) FROM tc_positions WHERE fixtime >= NOW() - INTERVAL 90 DAY)
                                AS registros_origem_90d,
    ROUND(
        (SELECT DATA_LENGTH + INDEX_LENGTH FROM information_schema.TABLES
          WHERE TABLE_SCHEMA='traccar' AND TABLE_NAME='tc_positions_new')
        / 1024/1024/1024, 2)   AS nova_tabela_gb;
