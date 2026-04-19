/* ============================================================
   TRACCAR - tc_positions particionada por dia (90 dias)
   Versão: 2.0 CORRIGIDA
   Correções aplicadas:
     [FIX-1] Variáveis de sessão (@var) substituídas por literais nos EVENTs
     [FIX-2] DATABASE() substituído por 'traccar' literal nos EVENTs
     [FIX-3] MAXVALUE adicionado via p_future para segurança de INSERTs
     [FIX-4] REORGANIZE PARTITION usado para inserir antes do p_future
     [FIX-5] Horários escalonados nos eventos (01h, 02h, 03h)
     [FIX-6] event_scheduler orientado a persistir via my.cnf
   Requisitos: MySQL 8.x
   Atenção: Execute este script COM A TABELA VAZIA ou recém-criada
   ============================================================ */

-- ============================================================
-- PASSO 0 — Schema e configuração de sessão
-- ============================================================
USE traccar;

SET NAMES utf8mb4;
SET time_zone = 'America/Sao_Paulo';   -- ajuste para seu fuso horário

-- ============================================================
-- PASSO 1 — Garantir Event Scheduler ativo (sessão)
--            Para persistir após restart adicione ao my.cnf:
--            [mysqld]
--            event_scheduler = ON
-- ============================================================
SET GLOBAL event_scheduler = ON;

-- ============================================================
-- PASSO 2 — Recriar a tabela tc_positions com particionamento
--            ATENÇÃO: o DROP abaixo apaga TODOS os dados.
--            Comente a linha DROP se a tabela já existir e
--            você quiser apenas corrigir procedures/eventos.
-- ============================================================
DROP TABLE IF EXISTS `tc_positions`;

CREATE TABLE `tc_positions` (
  `id`          BIGINT        NOT NULL AUTO_INCREMENT,
  `protocol`    VARCHAR(128)           DEFAULT NULL,
  `deviceid`    INT           NOT NULL,
  `servertime`  TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `devicetime`  TIMESTAMP     NOT NULL,
  `fixtime`     TIMESTAMP     NOT NULL,
  `valid`       BIT(1)        NOT NULL,
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
    -- Partição de segurança: captura qualquer data sem partição definida.
    -- [FIX-3] Evita erro "Table has no partition for value" se o evento atrasar.
    PARTITION p_future VALUES LESS THAN MAXVALUE
  );

-- ============================================================
-- PASSO 3 — Procedure: criar partições diárias em lote (bootstrap)
--            Uso: criação inicial e reprocessamentos pontuais
-- ============================================================
DROP PROCEDURE IF EXISTS sp_tc_positions_add_partitions_range;
DELIMITER $$
CREATE PROCEDURE sp_tc_positions_add_partitions_range(
    IN p_table_schema VARCHAR(64),
    IN p_table_name   VARCHAR(64),
    IN p_back_days    INT,
    IN p_ahead_days   INT
)
BEGIN
    DECLARE d DATE;
    DECLARE pname    VARCHAR(32);
    DECLARE boundary BIGINT UNSIGNED;
    DECLARE exists_count INT;

    SET d = CURRENT_DATE - INTERVAL p_back_days DAY;

    WHILE d <= CURRENT_DATE + INTERVAL p_ahead_days DAY DO
        -- Nome da partição = meia-noite do dia SEGUINTE (ex: p20250412 = dados DO DIA 11)
        SET pname    = CONCAT('p', DATE_FORMAT(d + INTERVAL 1 DAY, '%Y%m%d'));
        SET boundary = UNIX_TIMESTAMP(d + INTERVAL 1 DAY);

        SELECT COUNT(*) INTO exists_count
          FROM information_schema.PARTITIONS
         WHERE TABLE_SCHEMA   = p_table_schema
           AND TABLE_NAME     = p_table_name
           AND PARTITION_NAME = pname;

        -- [FIX-4] REORGANIZE PARTITION p_future para manter MAXVALUE no final
        IF exists_count = 0 THEN
            SET @sql = CONCAT(
                'ALTER TABLE `', p_table_schema, '`.`', p_table_name, '` ',
                'REORGANIZE PARTITION p_future INTO (',
                'PARTITION ', pname, ' VALUES LESS THAN (', boundary, '), ',
                'PARTITION p_future VALUES LESS THAN MAXVALUE)'
            );
            PREPARE s FROM @sql; EXECUTE s; DEALLOCATE PREPARE s;
        END IF;

        SET d = d + INTERVAL 1 DAY;
    END WHILE;
END$$
DELIMITER ;

-- ============================================================
-- PASSO 4 — Procedure: criar partição de amanhã (chamada diária)
-- ============================================================
DROP PROCEDURE IF EXISTS sp_tc_positions_add_partition_tomorrow;
DELIMITER $$
CREATE PROCEDURE sp_tc_positions_add_partition_tomorrow(
    IN p_table_schema VARCHAR(64),
    IN p_table_name   VARCHAR(64)
)
BEGIN
    DECLARE d DATE;
    DECLARE pname    VARCHAR(32);
    DECLARE boundary BIGINT UNSIGNED;
    DECLARE exists_count INT;

    -- Partição para AMANHÃ: nome = dia depois de amanhã, boundary = meia-noite de depois de amanhã
    SET d        = CURRENT_DATE + INTERVAL 1 DAY;
    SET pname    = CONCAT('p', DATE_FORMAT(d + INTERVAL 1 DAY, '%Y%m%d'));
    SET boundary = UNIX_TIMESTAMP(d + INTERVAL 1 DAY);

    SELECT COUNT(*) INTO exists_count
      FROM information_schema.PARTITIONS
     WHERE TABLE_SCHEMA   = p_table_schema
       AND TABLE_NAME     = p_table_name
       AND PARTITION_NAME = pname;

    -- [FIX-4] Reorganiza p_future ao invés de ADD PARTITION
    IF exists_count = 0 THEN
        SET @sql = CONCAT(
            'ALTER TABLE `', p_table_schema, '`.`', p_table_name, '` ',
            'REORGANIZE PARTITION p_future INTO (',
            'PARTITION ', pname, ' VALUES LESS THAN (', boundary, '), ',
            'PARTITION p_future VALUES LESS THAN MAXVALUE)'
        );
        PREPARE s FROM @sql; EXECUTE s; DEALLOCATE PREPARE s;
    END IF;
END$$
DELIMITER ;

-- ============================================================
-- PASSO 5 — Procedure: dropar partições antigas (retenção)
-- ============================================================
DROP PROCEDURE IF EXISTS sp_tc_positions_drop_old_partitions;
DELIMITER $$
CREATE PROCEDURE sp_tc_positions_drop_old_partitions(
    IN p_table_schema VARCHAR(64),
    IN p_table_name   VARCHAR(64),
    IN p_keep_days    INT
)
BEGIN
    DECLARE cutoff BIGINT UNSIGNED;
    DECLARE drop_sql TEXT DEFAULT NULL;

    -- [MELHORIA] Aumentar o limite do GROUP_CONCAT para evitar falha ao excluir muitas partições juntas
    SET SESSION group_concat_max_len = 100000;

    SET cutoff = UNIX_TIMESTAMP(CURRENT_DATE - INTERVAL p_keep_days DAY);

    SELECT CONCAT(
               'ALTER TABLE `', p_table_schema, '`.`', p_table_name, '` DROP PARTITION ',
               GROUP_CONCAT(partition_name ORDER BY partition_name)
           )
      INTO drop_sql
      FROM information_schema.PARTITIONS
     WHERE table_schema      = p_table_schema
       AND table_name        = p_table_name
       AND partition_name    != 'p_future'          -- [FIX-3] nunca dropar o MAXVALUE
       AND partition_name    IS NOT NULL
       AND CAST(partition_description AS UNSIGNED) <= cutoff;

    IF drop_sql IS NOT NULL THEN
        SET @s = drop_sql;
        PREPARE s FROM @s; EXECUTE s; DEALLOCATE PREPARE s;
    END IF;
END$$
DELIMITER ;

-- ============================================================
-- PASSO 6 — Procedure: OPTIMIZE em partições antigas (REMOVIDO)
--   Aviso: O procedimento genérico de dar "OPTIMIZE" em partições 
--   com mais de X dias foi desabilitado.
--   MOTIVO: Se você usar o script 04 (ROW_FORMAT=COMPRESSED), o 
--   OPTIMIZE PARTITION vai reconstruir a partição e estragar a
--   compressão gerando um I/O excessivo. O trabalho de limpeza fria
--   agora deve ficar a cargo exclusivamente do script 04_compactacao.
-- ============================================================
-- DROP PROCEDURE IF EXISTS optimize_partitions_older_than;
-- (Procedimento removido estrategicamente)

-- ============================================================
-- PASSO 7 — Criar partições iniciais (0 dias atrás + 30 à frente)
--            Apenas partições futuras + p_future (tabela zerada)
-- ============================================================
CALL sp_tc_positions_add_partitions_range('traccar', 'tc_positions', 0, 30);

-- ============================================================
-- PASSO 8 — Recriar EVENTs com literais (sem variáveis de sessão)
--            [FIX-1] [FIX-2] Parâmetros hardcoded
--            [FIX-5] Horários escalonados para evitar concorrência
-- ============================================================

-- 8.1 — Criar partição de amanhã (01:00)
DROP EVENT IF EXISTS ev_tc_positions_add_partition;
CREATE EVENT ev_tc_positions_add_partition
ON SCHEDULE EVERY 1 DAY
STARTS (DATE(NOW()) + INTERVAL 1 DAY + INTERVAL 1 HOUR)
COMMENT 'Cria partição diária para o dia seguinte'
DO CALL sp_tc_positions_add_partition_tomorrow('traccar', 'tc_positions');

-- 8.2 — Dropar partições com mais de 90 dias (02:00)
DROP EVENT IF EXISTS ev_tc_positions_drop_old;
CREATE EVENT ev_tc_positions_drop_old
ON SCHEDULE EVERY 1 DAY
STARTS (DATE(NOW()) + INTERVAL 1 DAY + INTERVAL 2 HOUR)
COMMENT 'Remove partições com mais de 90 dias'
DO CALL sp_tc_positions_drop_old_partitions('traccar', 'tc_positions', 90);

-- 8.3 — OPTIMIZE em partições com mais de 30 dias (REMOVIDO)
-- Evento desabilitado por conflitar com compressão (script 04).
-- DROP EVENT IF EXISTS ev_tc_positions_optimize_old;

-- ============================================================
-- PASSO 9 — Confirmar instalação
-- ============================================================
SELECT 'PARTIÇÕES CRIADAS:' AS info;
SELECT PARTITION_NAME,
       PARTITION_DESCRIPTION AS boundary_epoch,
       FROM_UNIXTIME(CAST(PARTITION_DESCRIPTION AS UNSIGNED)) AS less_than_datetime,
       TABLE_ROWS
FROM information_schema.PARTITIONS
WHERE TABLE_SCHEMA = 'traccar'
  AND TABLE_NAME   = 'tc_positions'
ORDER BY CAST(PARTITION_DESCRIPTION AS UNSIGNED);

SELECT 'EVENTOS CRIADOS:' AS info;
SELECT EVENT_NAME, STATUS, INTERVAL_VALUE, INTERVAL_FIELD,
       STARTS, LAST_EXECUTED
FROM information_schema.EVENTS
WHERE EVENT_SCHEMA = 'traccar';
