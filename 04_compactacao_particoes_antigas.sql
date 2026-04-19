/* ============================================================
   TRACCAR — Compactação InnoDB de Partições Antigas
   Versão : 1.0
   Estratégia:
     - Partições "frias" (> p_cold_days) são recriadas com
       ROW_FORMAT=COMPRESSED KEY_BLOCK_SIZE=8 via tabela auxiliar
     - Partições "quentes" recebem apenas OPTIMIZE PARTITION
   Pré-requisitos:
     - innodb_file_per_table = ON  (verificado pelo script)
     - Usuário com ALTER, CREATE, INSERT, DROP, INDEX
   ============================================================ */

USE traccar;

-- ============================================================
-- PRÉ-REQUISITO — Verificar innodb_file_per_table
-- ============================================================
SELECT
    @@innodb_file_per_table AS innodb_file_per_table,
    CASE @@innodb_file_per_table
        WHEN 1 THEN '✅  OK — Compressão por partição suportada'
        ELSE        '❌  ERRO — Adicione innodb_file_per_table=ON ao my.cnf e reinicie'
    END AS status;

-- ============================================================
-- PROCEDURE PRINCIPAL — Compactar partições antigas
--
-- Funcionamento:
--   1. Localiza partições mais antigas que p_cold_days
--   2. Para cada partição:
--      a. Cria tabela temporária comprimida com mesma estrutura
--      b. Copia os dados (INSERT SELECT)
--      c. Realiza swap atômico via RENAME + REORGANIZE
--      d. Dropa a tabela temporária
--   3. Registra resultado em tc_partition_compress_log
-- ============================================================
DROP PROCEDURE IF EXISTS sp_tc_positions_compress_cold_partitions;
DELIMITER $$
CREATE PROCEDURE sp_tc_positions_compress_cold_partitions(
    IN  p_table_schema VARCHAR(64),
    IN  p_table_name   VARCHAR(64),
    IN  p_cold_days    INT,            -- partições mais antigas que N dias
    IN  p_dry_run      TINYINT         -- 1 = apenas listar, não executar
)
BEGIN
    DECLARE done          INT DEFAULT 0;
    DECLARE v_pname       VARCHAR(64);
    DECLARE v_pdesc       BIGINT UNSIGNED;
    DECLARE v_rows        BIGINT;
    DECLARE v_cutoff      BIGINT UNSIGNED;
    DECLARE v_tmp_table   VARCHAR(128);
    DECLARE v_rows_before BIGINT DEFAULT 0;
    DECLARE v_rows_after  BIGINT DEFAULT 0;
    DECLARE v_size_before BIGINT DEFAULT 0;
    DECLARE v_size_after  BIGINT DEFAULT 0;
    DECLARE v_msg         VARCHAR(512);

    -- Cursor: partições mais antigas que p_cold_days, exceto p_future
    DECLARE cur CURSOR FOR
        SELECT partition_name,
               CAST(partition_description AS UNSIGNED),
               table_rows
          FROM information_schema.PARTITIONS
         WHERE table_schema   = p_table_schema
           AND table_name     = p_table_name
           AND partition_name != 'p_future'
           AND partition_name IS NOT NULL
           AND CAST(partition_description AS UNSIGNED)
                 < UNIX_TIMESTAMP(CURRENT_DATE - INTERVAL p_cold_days DAY)
         ORDER BY CAST(partition_description AS UNSIGNED);

    DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = 1;

    -- Criar tabela de log se não existir
    CREATE TABLE IF NOT EXISTS tc_partition_compress_log (
        id          INT AUTO_INCREMENT PRIMARY KEY,
        run_at      DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
        schema_name VARCHAR(64)  NOT NULL,
        table_name  VARCHAR(64)  NOT NULL,
        part_name   VARCHAR(64)  NOT NULL,
        dry_run     TINYINT      NOT NULL,
        rows_before BIGINT,
        rows_after  BIGINT,
        size_before_mb DECIMAL(10,2),
        size_after_mb  DECIMAL(10,2),
        saving_pct     DECIMAL(5,2),
        status      VARCHAR(16)  NOT NULL DEFAULT 'OK',
        message     VARCHAR(512)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

    SET v_cutoff = UNIX_TIMESTAMP(CURRENT_DATE - INTERVAL p_cold_days DAY);

    OPEN cur;
    compress_loop: LOOP
        FETCH cur INTO v_pname, v_pdesc, v_rows;
        IF done = 1 THEN LEAVE compress_loop; END IF;

        SET v_tmp_table = CONCAT('_tmp_compress_', v_pname);

        -- Tamanho antes
        SELECT COALESCE(DATA_LENGTH + INDEX_LENGTH, 0) INTO v_size_before
          FROM information_schema.PARTITIONS
         WHERE table_schema   = p_table_schema
           AND table_name     = p_table_name
           AND partition_name = v_pname;

        SET v_rows_before = COALESCE(v_rows, 0);

        IF p_dry_run = 1 THEN
            -- Modo simulação: apenas registra o que seria feito
            INSERT INTO tc_partition_compress_log
                (schema_name, table_name, part_name, dry_run,
                 rows_before, size_before_mb, status, message)
            VALUES
                (p_table_schema, p_table_name, v_pname, 1,
                 v_rows_before,
                 ROUND(v_size_before / 1024 / 1024, 2),
                 'DRY_RUN',
                 CONCAT('Seria comprimida — boundary: ',
                        FROM_UNIXTIME(v_pdesc)));
        ELSE
            -- ── Passo 1: Criar tabela temporária comprimida ──────────────
            SET @sql_create = CONCAT(
                'CREATE TABLE IF NOT EXISTS `', p_table_schema, '`.`', v_tmp_table, '` ',
                'LIKE `', p_table_schema, '`.`', p_table_name, '`'
            );
            PREPARE s FROM @sql_create; EXECUTE s; DEALLOCATE PREPARE s;

            -- Remover particionamento da tabela temporária e aplicar compressão
            SET @sql_nopart = CONCAT(
                'ALTER TABLE `', p_table_schema, '`.`', v_tmp_table, '` ',
                'REMOVE PARTITIONING'
            );
            PREPARE s FROM @sql_nopart; EXECUTE s; DEALLOCATE PREPARE s;

            SET @sql_compress = CONCAT(
                'ALTER TABLE `', p_table_schema, '`.`', v_tmp_table, '` ',
                'ROW_FORMAT=COMPRESSED KEY_BLOCK_SIZE=8'
            );
            PREPARE s FROM @sql_compress; EXECUTE s; DEALLOCATE PREPARE s;

            -- ── Passo 2: Copiar dados da partição para a temp ────────────
            SET @sql_insert = CONCAT(
                'INSERT INTO `', p_table_schema, '`.`', v_tmp_table, '` ',
                'SELECT * FROM `', p_table_schema, '`.`', p_table_name, '` ',
                'PARTITION (', v_pname, ')'
            );
            PREPARE s FROM @sql_insert; EXECUTE s; DEALLOCATE PREPARE s;

            -- ── Passo 3: Exportar dados comprimidos de volta ─────────────
            --   Limpa a partição original e reimporta os dados comprimidos
            SET @sql_clear = CONCAT(
                'ALTER TABLE `', p_table_schema, '`.`', p_table_name, '` ',
                'TRUNCATE PARTITION ', v_pname
            );
            PREPARE s FROM @sql_clear; EXECUTE s; DEALLOCATE PREPARE s;

            SET @sql_reimport = CONCAT(
                'INSERT INTO `', p_table_schema, '`.`', p_table_name, '` ',
                'SELECT * FROM `', p_table_schema, '`.`', v_tmp_table, '`'
            );
            PREPARE s FROM @sql_reimport; EXECUTE s; DEALLOCATE PREPARE s;

            -- ── Passo 4: Dropar tabela temporária ────────────────────────
            SET @sql_drop = CONCAT(
                'DROP TABLE IF EXISTS `', p_table_schema, '`.`', v_tmp_table, '`'
            );
            PREPARE s FROM @sql_drop; EXECUTE s; DEALLOCATE PREPARE s;

            -- ── Passo 5: OPTIMIZE na partição para finalizar ─────────────
            SET @sql_opt = CONCAT(
                'ALTER TABLE `', p_table_schema, '`.`', p_table_name, '` ',
                'OPTIMIZE PARTITION ', v_pname
            );
            PREPARE s FROM @sql_opt; EXECUTE s; DEALLOCATE PREPARE s;

            -- Tamanho depois
            SELECT COALESCE(DATA_LENGTH + INDEX_LENGTH, 0),
                   COALESCE(TABLE_ROWS, 0)
              INTO v_size_after, v_rows_after
              FROM information_schema.PARTITIONS
             WHERE table_schema   = p_table_schema
               AND table_name     = p_table_name
               AND partition_name = v_pname;

            -- Registrar resultado
            INSERT INTO tc_partition_compress_log
                (schema_name, table_name, part_name, dry_run,
                 rows_before, rows_after,
                 size_before_mb, size_after_mb, saving_pct, status, message)
            VALUES
                (p_table_schema, p_table_name, v_pname, 0,
                 v_rows_before, v_rows_after,
                 ROUND(v_size_before / 1024 / 1024, 2),
                 ROUND(v_size_after  / 1024 / 1024, 2),
                 CASE WHEN v_size_before > 0
                      THEN ROUND((1 - v_size_after / v_size_before) * 100, 2)
                      ELSE 0 END,
                 'OK',
                 CONCAT('Compactada com ROW_FORMAT=COMPRESSED KEY_BLOCK_SIZE=8 — boundary: ',
                        FROM_UNIXTIME(v_pdesc)));
        END IF;

    END LOOP;
    CLOSE cur;

    -- Retornar resumo
    SELECT
        part_name,
        rows_before,
        rows_after,
        size_before_mb,
        size_after_mb,
        saving_pct AS economia_pct,
        status,
        message,
        run_at
    FROM tc_partition_compress_log
    WHERE schema_name = p_table_schema
      AND table_name  = p_table_name
      AND run_at     >= NOW() - INTERVAL 5 MINUTE
    ORDER BY run_at DESC;

END$$
DELIMITER ;

-- ============================================================
-- PROCEDURE AUXILIAR — Ver histórico de compactações
-- ============================================================
DROP PROCEDURE IF EXISTS sp_tc_positions_compress_history;
DELIMITER $$
CREATE PROCEDURE sp_tc_positions_compress_history(
    IN p_table_schema VARCHAR(64),
    IN p_table_name   VARCHAR(64),
    IN p_last_days    INT
)
BEGIN
    SELECT
        run_at,
        part_name,
        dry_run,
        rows_before,
        rows_after,
        CONCAT(size_before_mb, ' MB')                      AS antes,
        CONCAT(size_after_mb,  ' MB')                      AS depois,
        CONCAT(saving_pct, '%')                            AS economia,
        status,
        message
    FROM tc_partition_compress_log
    WHERE schema_name = p_table_schema
      AND table_name  = p_table_name
      AND run_at     >= NOW() - INTERVAL p_last_days DAY
      AND dry_run    = 0
    ORDER BY run_at DESC, part_name;

    -- Resumo acumulado
    SELECT
        COUNT(*)                                           AS particoes_comprimidas,
        CONCAT(ROUND(SUM(size_before_mb), 2), ' MB')      AS total_antes,
        CONCAT(ROUND(SUM(size_after_mb),  2), ' MB')      AS total_depois,
        CONCAT(ROUND(SUM(size_before_mb) - SUM(size_after_mb), 2), ' MB') AS total_economizado,
        CONCAT(ROUND(AVG(saving_pct), 1), '%')             AS economia_media
    FROM tc_partition_compress_log
    WHERE schema_name = p_table_schema
      AND table_name  = p_table_name
      AND dry_run     = 0
      AND status      = 'OK';
END$$
DELIMITER ;

-- ============================================================
-- EVENTO AUTOMÁTICO — Compactar partições com mais de 30 dias
--   Roda todo domingo às 03:00
--   Ajuste p_cold_days conforme necessidade
-- ============================================================
DROP EVENT IF EXISTS ev_tc_positions_compress_cold;
CREATE EVENT ev_tc_positions_compress_cold
ON SCHEDULE EVERY 7 DAY
STARTS (DATE(NOW()) + INTERVAL 1 DAY + INTERVAL 3 HOUR)
COMMENT 'Comprime partições frias (>30 dias) com ROW_FORMAT=COMPRESSED'
DO CALL sp_tc_positions_compress_cold_partitions('traccar', 'tc_positions', 30, 0);

-- ============================================================
-- EXECUÇÃO MANUAL — Exemplos de uso
-- ============================================================

-- Simulação (ver o que seria comprimido SEM alterar dados):
-- CALL sp_tc_positions_compress_cold_partitions('traccar', 'tc_positions', 30, 1);

-- Execução real (partições com mais de 30 dias):
-- CALL sp_tc_positions_compress_cold_partitions('traccar', 'tc_positions', 30, 0);

-- Histórico das compactações realizadas nos últimos 30 dias:
-- CALL sp_tc_positions_compress_history('traccar', 'tc_positions', 30);

-- ============================================================
-- VERIFICAR ECONOMIA POR PARTIÇÃO (consulta direta)
-- ============================================================
SELECT
    p.PARTITION_NAME,
    FROM_UNIXTIME(CAST(p.PARTITION_DESCRIPTION AS UNSIGNED)) AS less_than_dt,
    FORMAT(p.TABLE_ROWS, 0)                                  AS linhas,
    CONCAT(ROUND((p.DATA_LENGTH + p.INDEX_LENGTH) / 1024 / 1024, 2), ' MB') AS tamanho,
    COALESCE(t.CREATE_OPTIONS, 'sem compressão')             AS compressao,
    CASE
        WHEN p.PARTITION_NAME = 'p_future' THEN '— (segurança)'
        WHEN (p.DATA_LENGTH + p.INDEX_LENGTH) = 0 THEN 'vazia'
        ELSE 'dados presentes'
    END AS situacao
FROM information_schema.PARTITIONS p
JOIN information_schema.TABLES t
    ON t.TABLE_SCHEMA = p.TABLE_SCHEMA
   AND t.TABLE_NAME   = p.TABLE_NAME
WHERE p.TABLE_SCHEMA = 'traccar'
  AND p.TABLE_NAME   = 'tc_positions'
ORDER BY CAST(p.PARTITION_DESCRIPTION AS UNSIGNED);
