--------------------------------------------------------------------------------
-- Tests for various scenarios with the column rewrite optimization
-- for AT on AOCO tables
--------------------------------------------------------------------------------

PREPARE attribute_encoding_check AS
SELECT c.relname, a.attname, e.filenum, e.attoptions FROM pg_attribute_encoding e, pg_class c, pg_attribute a
WHERE e.attrelid = c.oid AND e.attnum = a.attnum and e.attrelid = a.attrelid AND c.relname LIKE $1;

CREATE TABLE if not exists relfilenodecheck(segid int, relname text, relfilenodebefore int, relfilenodeafter int, casename text);

PREPARE capturerelfilenodebefore AS
    INSERT INTO relfilenodecheck SELECT -1 segid, relname, pg_relation_filenode(relname::text) as relfilenode, NULL::int, $1 as casename FROM pg_class WHERE relname LIKE $2
                                 UNION SELECT gp_segment_id segid, relname, pg_relation_filenode(relname::text) as relfilenode, NULL::int, $1 as casename  FROM gp_dist_random('pg_class')
                                 WHERE relname LIKE $2 ORDER BY segid;

PREPARE checkrelfilenodediff AS
SELECT a.segid, b.casename, b.relname, (relfilenodebefore != a.relfilenode) rewritten
FROM
    (
        SELECT -1 segid, relname, pg_relation_filenode(relname::text) as relfilenode
        FROM pg_class
        WHERE relname LIKE $2
        UNION
        SELECT gp_segment_id segid, relname, pg_relation_filenode(relname::text) as relfilenode
        FROM gp_dist_random('pg_class')
        WHERE relname LIKE $2 ORDER BY segid
    )a, relfilenodecheck b
WHERE b.casename LIKE $1 and b.relname LIKE $2 and a.segid = b.segid;

--------------------------------------------------------------------------------
-- Test if ALTER COLUMN TYPE and ADD COLUMN on AOCO doesn't rewrite the entire table
--------------------------------------------------------------------------------

CREATE TABLE alter_type_aoco(a int, b int, c int) using ao_column;
INSERT INTO alter_type_aoco VALUES (20,1,2);
EXECUTE attribute_encoding_check ('alter_type_aoco');
SELECT * FROM gp_toolkit.__gp_aocsseg('alter_type_aoco') ORDER BY segment_id, column_num;
EXECUTE capturerelfilenodebefore ('alter_column', 'alter_type_aoco');
SELECT * FROM alter_type_aoco;

ALTER TABLE alter_type_aoco ALTER COLUMN b TYPE text;

EXECUTE attribute_encoding_check ('alter_type_aoco');
SELECT * FROM gp_toolkit.__gp_aocsseg('alter_type_aoco') ORDER BY segment_id, column_num;
EXECUTE checkrelfilenodediff ('alter_column', 'alter_type_aoco');
-- data is intact
SELECT * FROM alter_type_aoco;
INSERT INTO alter_type_aoco VALUES (20,'1',2);
-- data is intact
SELECT * FROM alter_type_aoco;

ALTER TABLE alter_type_aoco ADD COLUMN d int;

INSERT INTO alter_type_aoco VALUES (20,'1',2, 3);
-- check if we chose correct filenum for newly added column
EXECUTE attribute_encoding_check ('alter_type_aoco');
SELECT * FROM gp_toolkit.__gp_aocsseg('alter_type_aoco') ORDER BY segment_id, column_num;
DROP TABLE alter_type_aoco;
CHECKPOINT;
-- check if all files are dropped correctly
SELECT * FROM gp_toolkit.gp_check_orphaned_files WHERE split_part(filename,'.',1) = (SELECT oid::text FROM pg_class WHERE relname = 'alter_type_aoco');

--------------------------------------------------------------------------------
-- Test if column rewrite handles deleted rows in blockdirectory correctly for
-- more than 1 minipage

-- We create a table and its blkdir and insert enough data to have more than one
-- minipage in the block directory, and check if the column rewrite rewrites the
-- blockdirectory correctly
--------------------------------------------------------------------------------
CREATE TABLE alter_type_aoco_delete(a int, b int, c int) USING ao_column;
CREATE INDEX at_aoco_idx on alter_type_aoco_delete(c);
INSERT INTO alter_type_aoco_delete SELECT 1,i,i FROM generate_series(1,10000)i;
DELETE FROM alter_type_aoco_delete WHERE b%3 = 1;
EXECUTE capturerelfilenodebefore ('alter_column', 'alter_type_aoco_delete');
SELECT count(*) FROM alter_type_aoco_delete;

ALTER TABLE alter_type_aoco_delete ALTER COLUMN b TYPE text;

EXECUTE attribute_encoding_check ('alter_type_aoco_delete');
SELECT * FROM gp_toolkit.__gp_aocsseg('alter_type_aoco_delete') ORDER BY segment_id, column_num;
SELECT gp_segment_id, (gp_toolkit.__gp_aoblkdir('alter_type_aoco_delete')).* FROM gp_dist_random('gp_id');
EXECUTE checkrelfilenodediff ('alter_column', 'alter_type_aoco_delete');
SELECT count(b) FROM alter_type_aoco_delete;
SELECT count(*) FROM alter_type_aoco_delete;

--------------------------------------------------------------------------------
-- Test if column rewrite handles blockdirectory and visimap
-- for deleted rows correctly with multiple blocks in same segfile

-- Here, we insert data into two different blocks and delete all rows from first
-- block. We test if that block is still replicated in the rewritten col
--------------------------------------------------------------------------------
CREATE TABLE alter_type_aoco_delete1(a int, b int, c int) USING ao_column;
CREATE INDEX at_aoco_idx1 on alter_type_aoco_delete1(c);
INSERT INTO alter_type_aoco_delete1 VALUES (1,2,2);
INSERT INTO alter_type_aoco_delete1 VALUES (1,3,3);
DELETE FROM alter_type_aoco_delete1 WHERE b = 2;
EXECUTE attribute_encoding_check ('alter_type_aoco_delete1');
SELECT * FROM gp_toolkit.__gp_aocsseg('alter_type_aoco_delete1') ORDER BY segment_id, column_num;
SELECT (gp_toolkit.__gp_aovisimap('alter_type_aoco_delete1')).* FROM gp_dist_random('gp_id');
SELECT gp_segment_id, (gp_toolkit.__gp_aoblkdir('alter_type_aoco_delete1')).* FROM gp_dist_random('gp_id');
EXECUTE capturerelfilenodebefore ('alter_column', 'alter_type_aoco_delete1');
SELECT * FROM alter_type_aoco_delete1;

ALTER TABLE alter_type_aoco_delete1 ALTER COLUMN b TYPE text;

EXECUTE attribute_encoding_check ('alter_type_aoco_delete1');
SELECT * FROM gp_toolkit.__gp_aocsseg('alter_type_aoco_delete1') ORDER BY segment_id, column_num;
SELECT (gp_toolkit.__gp_aovisimap('alter_type_aoco_delete1')).* FROM gp_dist_random('gp_id');
SELECT gp_segment_id, (gp_toolkit.__gp_aoblkdir('alter_type_aoco_delete1')).* FROM gp_dist_random('gp_id');
EXECUTE checkrelfilenodediff ('alter_column', 'alter_type_aoco_delete1');
SELECT b FROM alter_type_aoco_delete1;
SELECT * FROM alter_type_aoco_delete1;

--------------------------------------------------------------------------------
-- Test if column rewrite handles blockdirectory and visimap
-- for deleted rows correctly with multiple blocks in same segfile

-- Here, we insert data into two different blocks and delete all rows from second
-- block. We test if that block is still replicated in the rewritten col
--------------------------------------------------------------------------------
CREATE TABLE alter_type_aoco_delete2(a int, b int, c int) USING ao_column;
CREATE INDEX at_aoco_idx2 on alter_type_aoco_delete2(c);
INSERT INTO alter_type_aoco_delete2 VALUES (1,2,2);
INSERT INTO alter_type_aoco_delete2 VALUES (1,3,3);
DELETE FROM alter_type_aoco_delete2 WHERE b = 3;
EXECUTE attribute_encoding_check ('alter_type_aoco_delete2');
SELECT * FROM gp_toolkit.__gp_aocsseg('alter_type_aoco_delete2') ORDER BY segment_id, column_num;
SELECT (gp_toolkit.__gp_aovisimap('alter_type_aoco_delete2')).* FROM gp_dist_random('gp_id');
SELECT gp_segment_id, (gp_toolkit.__gp_aoblkdir('alter_type_aoco_delete2')).* FROM gp_dist_random('gp_id');
EXECUTE capturerelfilenodebefore ('alter_column', 'alter_type_aoco_delete2');
SELECT * FROM alter_type_aoco_delete2;

ALTER TABLE alter_type_aoco_delete2 ALTER COLUMN b TYPE text;

EXECUTE attribute_encoding_check ('alter_type_aoco_delete2');
SELECT * FROM gp_toolkit.__gp_aocsseg('alter_type_aoco_delete2') ORDER BY segment_id, column_num;
SELECT (gp_toolkit.__gp_aovisimap('alter_type_aoco_delete2')).* FROM gp_dist_random('gp_id');
SELECT gp_segment_id, (gp_toolkit.__gp_aoblkdir('alter_type_aoco_delete2')).* FROM gp_dist_random('gp_id');
EXECUTE checkrelfilenodediff ('alter_column', 'alter_type_aoco_delete2');
SELECT b FROM alter_type_aoco_delete2;
SELECT * FROM alter_type_aoco_delete2;

--------------------------------------------------------------------------------
-- Test if AT ALTER COLUMN TYPE works fine when we need a full table rewrite.

-- We perform a AT subcmd which requires a full table rewrite, and check results
-- for the AT ALTER COLUMN TYPE after the table is fully rewritten
--------------------------------------------------------------------------------


CREATE TABLE alter_type_aoco_fullrewrite(a int, b int, c int) using ao_column;
INSERT INTO alter_type_aoco_fullrewrite VALUES (20,1,2);
EXECUTE attribute_encoding_check ('alter_type_aoco_fullrewrite');
SELECT * FROM gp_toolkit.__gp_aocsseg('alter_type_aoco_fullrewrite') ORDER BY segment_id, column_num;
EXECUTE capturerelfilenodebefore ('alter_column', 'alter_type_aoco_fullrewrite');
SELECT * FROM alter_type_aoco_fullrewrite;

ALTER TABLE alter_type_aoco_fullrewrite ALTER COLUMN b TYPE text, ALTER COLUMN C SET ENCODING (compresslevel=4);

EXECUTE attribute_encoding_check ('alter_type_aoco_fullrewrite');
SELECT * FROM gp_toolkit.__gp_aocsseg('alter_type_aoco_fullrewrite') ORDER BY segment_id, column_num;
EXECUTE checkrelfilenodediff ('alter_column', 'alter_type_aoco_fullrewrite');
-- data is intact
SELECT * FROM alter_type_aoco_fullrewrite;
INSERT INTO alter_type_aoco_fullrewrite VALUES (20,'1',2);
-- data is intact
SELECT * FROM alter_type_aoco_fullrewrite;

--------------------------------------------------------------------------------
-- Test if AT ALTER COLUMN TYPE reindexes rewrite-affected indexes

-- We create indexes on columns and test if these indexes are rewritten
-- when any of the columns are rewritten on which the indexes depend on
-- but other indexes are unaffected
--------------------------------------------------------------------------------

CREATE TABLE alter_type_aoco(a int, b int, c int, d int) using ao_column;

INSERT INTO alter_type_aoco VALUES (20, 1, 2, 3);

CREATE UNIQUE INDEX idx1 on alter_type_aoco(a,b);
CREATE INDEX idx2 on alter_type_aoco using btree(c);
CREATE INDEX idx3 on alter_type_aoco using bitmap(a,b,c,d);

EXECUTE capturerelfilenodebefore ('alter_column_b', 'idx1');
EXECUTE capturerelfilenodebefore ('alter_column_b', 'idx2');
EXECUTE capturerelfilenodebefore ('alter_column_b', 'idx3');

ALTER TABLE alter_type_aoco ALTER COLUMN b TYPE text;

EXECUTE checkrelfilenodediff ('alter_column_b', 'idx1');
EXECUTE checkrelfilenodediff ('alter_column_b', 'idx2');
EXECUTE checkrelfilenodediff ('alter_column_b', 'idx3');
INSERT INTO alter_type_aoco VALUES (20, '2', 3, 4);
EXECUTE capturerelfilenodebefore ('alter_column_c', 'idx1');
EXECUTE capturerelfilenodebefore ('alter_column_c', 'idx2');
EXECUTE capturerelfilenodebefore ('alter_column_c', 'idx3');

ALTER TABLE alter_type_aoco ALTER COLUMN c TYPE text;

EXECUTE checkrelfilenodediff ('alter_column_c', 'idx1');
EXECUTE checkrelfilenodediff ('alter_column_c', 'idx2');
EXECUTE checkrelfilenodediff ('alter_column_c', 'idx3');
INSERT INTO alter_type_aoco VALUES (20, '3', '4', 5);
EXECUTE capturerelfilenodebefore ('alter_column_d', 'idx1');
EXECUTE capturerelfilenodebefore ('alter_column_d', 'idx2');
EXECUTE capturerelfilenodebefore ('alter_column_d', 'idx3');

ALTER TABLE alter_type_aoco ALTER COLUMN d TYPE text;

EXECUTE checkrelfilenodediff ('alter_column_d', 'idx1');
EXECUTE checkrelfilenodediff ('alter_column_d', 'idx2');
EXECUTE checkrelfilenodediff ('alter_column_d', 'idx3');
INSERT INTO alter_type_aoco VALUES (20, '4', '5', '6');
-- data is intact
SELECT * FROM alter_type_aoco;


--------------------------------------------------------------------------------
-- Test if AT ALTER COLUMN TYPE for partitioned table

-- create 2 level partitions with same schema (regular case) and create index on some column
-- alter column on the partition table root and on the partitions and we check rewrite status and data status
-- filenum for partition roots
--------------------------------------------------------------------------------
CREATE TABLE part_alter_col(a int, b int, c int) PARTITION BY RANGE (A) (partition aa start (1) end (5) every (1)) USING ao_column;
INSERT INTO part_alter_col VALUES (1,2,3);
CREATE INDEX part_alter_col_idx1 on part_alter_col(b);
CREATE INDEX part_alter_col_idx2 on part_alter_col(c);
EXECUTE capturerelfilenodebefore ('alter_column_b', 'part_alter_col_1_prt_aa_1');
EXECUTE capturerelfilenodebefore ('alter_column_b', 'part_alter_col_1_prt_aa_1_b_idx');
EXECUTE capturerelfilenodebefore ('alter_column_b', 'part_alter_col_1_prt_aa_1_c_idx');
EXECUTE attribute_encoding_check ('part_alter_col');

ALTER TABLE part_alter_col ALTER COLUMN b TYPE text;

EXECUTE attribute_encoding_check ('part_alter_col');
EXECUTE checkrelfilenodediff ('alter_column_b', 'part_alter_col_1_prt_aa_1');
EXECUTE checkrelfilenodediff ('alter_column_b', 'part_alter_col_1_prt_aa_1_b_idx');
EXECUTE checkrelfilenodediff ('alter_column_b', 'part_alter_col_1_prt_aa_1_c_idx');
SELECT * FROM part_alter_col;
DROP TABLE part_alter_col;
CHECKPOINT;
-- check if all files are dropped correctly
SELECT * FROM gp_toolkit.gp_check_orphaned_files WHERE split_part(filename,'.',1) = (SELECT oid::text FROM pg_class WHERE relname = 'part_alter_col');
--------------------------------------------------------------------------------
-- Test if column rewrite works when AT ALTER COLUMN TYPE for a column
-- and then alter it back to the original type

-- Check reloptions, pg_attribute_encoding, visimap, blkdirectory alongside the rewrite
--------------------------------------------------------------------------------
CREATE TABLE alter_column_back(a int, b int ENCODING (compresstype='zlib', compresslevel=5), c int) using ao_column with (compresstype='zlib', compresslevel=2);
INSERT INTO alter_column_back VALUES (1,2,3), (1,2,4), (1,2,5);
CREATE INDEX alter_column_back_idx1 ON alter_column_back(a,c);
DELETE FROM alter_column_back WHERE c=5;
EXECUTE capturerelfilenodebefore ('alter_column', 'alter_column_back');
SELECT atttypid::regtype FROM pg_attribute WHERE attrelid='alter_column_back'::regclass AND attname='b';

ALTER TABLE alter_column_back ALTER COLUMN b TYPE text;

SELECT c.relname, c.reloptions FROM pg_class c WHERE c.relname LIKE 'alter_column_back';
EXECUTE checkrelfilenodediff ('alter_column', 'alter_column_back');
SELECT atttypid::regtype FROM pg_attribute WHERE attrelid='alter_column_back'::regclass AND attname='b';
INSERT INTO alter_column_back VALUES (1,'2',3);
DELETE FROM alter_column_back where c=4;
EXECUTE capturerelfilenodebefore ('alter_column_back', 'alter_column_back');

ALTER TABLE alter_column_back ALTER COLUMN b TYPE int using b::int;

SELECT c.relname, c.reloptions FROM pg_class c WHERE c.relname LIKE 'alter_column_back';
EXECUTE attribute_encoding_check ('alter_column_back');
SELECT (gp_toolkit.__gp_aovisimap('alter_column_back')).* FROM gp_dist_random('gp_id');
SELECT gp_segment_id, (gp_toolkit.__gp_aoblkdir('alter_column_back')).* FROM gp_dist_random('gp_id');
EXECUTE checkrelfilenodediff ('alter_column_back', 'alter_column_back');
SELECT atttypid::regtype FROM pg_attribute WHERE attrelid='alter_column_back'::regclass AND attname='b';
SELECT * FROM alter_column_back;
DROP TABLE alter_column_back;
CHECKPOINT;
-- check if all files are dropped correctly
SELECT * FROM gp_toolkit.gp_check_orphaned_files WHERE split_part(filename,'.',1) = (SELECT oid::text FROM pg_class WHERE relname = 'alter_column_back');

--------------------------------------------------------------------------------
-- Test if ALTER COLUMN TYPE and SET ACCESS METHOD can be done in the same command
-- Verify if we rewrite the table
--------------------------------------------------------------------------------
CREATE TABLE alter_column_set_am(a int, b int, c int) using ao_column;
INSERT INTO alter_column_set_am VALUES (1,2,3);
EXECUTE capturerelfilenodebefore ('alter_column_set_am_aorow', 'alter_column_set_am');
EXECUTE attribute_encoding_check ('alter_column_set_am');

ALTER TABLE alter_column_set_am SET ACCESS METHOD ao_row, ALTER COLUMN b TYPE text;

EXECUTE attribute_encoding_check ('alter_column_set_am');
EXECUTE checkrelfilenodediff ('alter_column_set_am_aorow', 'alter_column_set_am');
SELECT * FROM alter_column_set_am;
INSERT INTO alter_column_set_am VALUES (1,'2',3);
EXECUTE capturerelfilenodebefore ('alter_column_set_am_aocol', 'alter_column_set_am');
EXECUTE attribute_encoding_check ('alter_column_set_am');

ALTER TABLE alter_column_set_am SET ACCESS METHOD ao_column, ALTER COLUMN c TYPE text;

EXECUTE attribute_encoding_check ('alter_column_set_am');
EXECUTE checkrelfilenodediff ('alter_column_set_am_aocol', 'alter_column_set_am');
SELECT * FROM alter_column_set_am;

--------------------------------------------------------------------------------
-- Test if ALTER COLUMN TYPE and ADD COLUMN can be done in the same command
-- Verify if we don't rewrite the table
--------------------------------------------------------------------------------
CREATE TABLE alter_column_add_col(a int, b int, c int) using ao_column;
INSERT INTO alter_column_add_col VALUES (1,2,3);
EXECUTE capturerelfilenodebefore ('alter_col_add_col', 'alter_column_add_col');
EXECUTE attribute_encoding_check ('alter_column_add_col');

ALTER TABLE alter_column_add_col ADD COLUMN d int, ALTER COLUMN b TYPE text;

EXECUTE attribute_encoding_check ('alter_column_add_col');
EXECUTE checkrelfilenodediff ('alter_column_add_col', 'alter_column_add_col');
SELECT * FROM alter_column_add_col;
INSERT INTO alter_column_add_col VALUES (1,'2',3, 4);
SELECT * FROM alter_column_add_col;

--------------------------------------------------------------------------------
-- Test if ALTER COLUMN TYPE and other AT commands can be done in the same command
-- Verify if we rewrite the table
--------------------------------------------------------------------------------
CREATE TABLE alter_column_other(a int, b int, c int) using ao_column;
INSERT INTO alter_column_other VALUES (1,2,3);
EXECUTE capturerelfilenodebefore ('alter_column_other', 'alter_column_other');
EXECUTE attribute_encoding_check ('alter_column_other');

ALTER TABLE alter_column_other ALTER COLUMN b TYPE text, ALTER COLUMN c SET DEFAULT 5;

EXECUTE attribute_encoding_check ('alter_column_other');
EXECUTE checkrelfilenodediff ('alter_column_other', 'alter_column_other');
SELECT * FROM alter_column_other;
INSERT INTO alter_column_other VALUES (1,'2');
SELECT * FROM alter_column_other;

--------------------------------------------------------------------------------
-- Test if column rewrite works after vacuum on deleted rows
--------------------------------------------------------------------------------
CREATE TABLE alter_column_vacuum(a int, b int) using ao_column;
INSERT INTO alter_column_vacuum SELECT 1,i FROM generate_series(1,1000)i;
DELETE FROM alter_column_vacuum WHERE b>10;
VACUUM alter_column_vacuum;
SELECT * FROM gp_toolkit.__gp_aocsseg('alter_column_vacuum');
-- should succeed
ALTER TABLE alter_column_vacuum ALTER COLUMN b TYPE text;
SELECT * FROM gp_toolkit.__gp_aocsseg('alter_column_vacuum');

--------------------------------------------------------------------------------
-- Test if ALTER COLUMN TYPE works correctly when constraints are involved
--------------------------------------------------------------------------------
CREATE TABLE alter_column_constraints(a int, b int check (b > 0)) USING ao_column;
INSERT INTO alter_column_constraints SELECT i,i FROM generate_series(1,10)i;
-- should error
ALTER TABLE alter_column_constraints ALTER COLUMN b TYPE text;
-- should succeed, and constraint remains
EXECUTE capturerelfilenodebefore ('alter_column_constraints_col_rewrite', 'alter_column_constraints');
ALTER TABLE alter_column_constraints ALTER COLUMN b TYPE bigint;
EXECUTE checkrelfilenodediff ('alter_column_constraints_col_rewrite', 'alter_column_constraints');

EXECUTE capturerelfilenodebefore ('alter_column_constraints_fullrewrite', 'alter_column_constraints');
-- should succeed and relfile changed (not using the column rewrite optimization because there's other command)
ALTER TABLE alter_column_constraints ADD CONSTRAINT checkb2 CHECK (b < 100), ALTER COLUMN b TYPE int;
EXECUTE checkrelfilenodediff ('alter_column_constraints_fullrewrite', 'alter_column_constraints');

--------------------------------------------------------------------------------
-- Test if ALTER COLUMN TYPE works correctly when seg0 has some data
-- Check if we handle rewrite on seg0
--------------------------------------------------------------------------------
CREATE TABLE alter_column_seg0(a int, b int) USING ao_column;
1: BEGIN;
1: ALTER TABLE alter_column_seg0 ADD COLUMN c int;
1: INSERT INTO alter_column_seg0 SELECT 1,i,i FROM generate_series(1,10)i;
1: COMMIT;
INSERT INTO alter_column_seg0 SELECT 1,i,i FROM generate_series(1,10)i;
ALTER TABLE alter_column_seg0 ALTER COLUMN b TYPE text;
SELECT count(*) FROM alter_column_seg0;
SELECT * FROM gp_toolkit.__gp_aocsseg('alter_column_seg0');
DROP TABLE alter_column_seg0;
CHECKPOINT;
SELECT * FROM gp_toolkit.gp_check_orphaned_files WHERE split_part(filename,'.',1) = (SELECT oid::text FROM pg_class WHERE relname = 'alter_column_seg0');

--------------------------------------------------------------------------------
-- Test if ALTER COLUMN TYPE works correctly multiple segfiles are created
-- due to multiple concurrency
-- Check if we handle rewrite on each segfile correctly
--------------------------------------------------------------------------------
CREATE TABLE alter_column_multiple_concurrency(a int, b int) USING ao_column;
1: BEGIN;
2: BEGIN;
1: INSERT INTO alter_column_multiple_concurrency SELECT 1,i FROM generate_series(1,10)i;
2: INSERT INTO alter_column_multiple_concurrency SELECT 1,i FROM generate_series(1,10)i;
1: COMMIT;
2: COMMIT;
ALTER TABLE alter_column_multiple_concurrency ALTER COLUMN b TYPE text;
SELECT count(*) FROM alter_column_multiple_concurrency;
SELECT * FROM gp_toolkit.__gp_aocsseg('alter_column_multiple_concurrency');
DROP TABLE alter_column_multiple_concurrency;
CHECKPOINT;
SELECT * FROM gp_toolkit.gp_check_orphaned_files WHERE split_part(filename,'.',1) = (SELECT oid::text FROM pg_class WHERE relname = 'alter_column_multiple_concurrency');

--------------------------------------------------------------------------------
-- Test if ALTER COLUMN TYPE works correctly when a segfile is in AWAITING_DROP state
-- Check if we handle rewrite on each segfile correctly
--------------------------------------------------------------------------------
CREATE TABLE alter_column_awaiting_drop(a int, b int) USING ao_column;
1: BEGIN;
2: BEGIN;
1: INSERT INTO alter_column_awaiting_drop SELECT 1,i FROM generate_series(1,10)i;
2: INSERT INTO alter_column_awaiting_drop SELECT 1,i FROM generate_series(11,20)i;
1: COMMIT;
2: COMMIT;
DELETE FROM alter_column_awaiting_drop WHERE b > 10;
VACUUM alter_column_awaiting_drop;
SELECT * FROM gp_toolkit.__gp_aocsseg('alter_column_awaiting_drop');
ALTER TABLE alter_column_awaiting_drop ALTER COLUMN b TYPE text;
SELECT count(*) FROM alter_column_awaiting_drop;
SELECT * FROM gp_toolkit.__gp_aocsseg('alter_column_awaiting_drop');
DROP TABLE alter_column_awaiting_drop;
CHECKPOINT;
SELECT * FROM gp_toolkit.gp_check_orphaned_files WHERE split_part(filename,'.',1) = (SELECT oid::text FROM pg_class WHERE relname = 'alter_column_awaiting_drop');

--------------------------------------------------------------------------------
-- Test if ALTER COLUMN TYPE works correctly for 0 inserted rows
--------------------------------------------------------------------------------
CREATE TABLE alter_column_zero_tupcount(a int, b int) USING ao_column;
1: BEGIN;
2: BEGIN;
1: INSERT INTO alter_column_zero_tupcount SELECT 1,i FROM generate_series(1,10)i;
2: INSERT INTO alter_column_zero_tupcount SELECT 1,i FROM generate_series(1,10)i;
1: ABORT;
2: ABORT;
ALTER TABLE alter_column_zero_tupcount ALTER COLUMN b TYPE text;
SELECT count(*) FROM alter_column_zero_tupcount;
SELECT * FROM gp_toolkit.__gp_aocsseg('alter_column_zero_tupcount');
DROP TABLE alter_column_zero_tupcount;
CHECKPOINT;
SELECT * FROM gp_toolkit.gp_check_orphaned_files WHERE split_part(filename,'.',1) = (SELECT oid::text FROM pg_class WHERE relname = 'alter_column_zero_tupcount');

--------------------------------------------------------------------------------
-- Test if ALTER COLUMN TYPE works correctly for generated columns.
-- Check if we error out on ALTERing type columns that have dependent generated columns
--------------------------------------------------------------------------------
CREATE TABLE alter_column_generated_cols(a int, b int, c int GENERATED ALWAYS AS (a+b) STORED, d int GENERATED ALWAYS AS (tableoid::regclass) STORED) USING ao_column;
INSERT INTO alter_column_generated_cols SELECT 1,i FROM generate_series(1,5)i;
SELECT attname, atttypid::regtype FROM pg_attribute WHERE attrelid='alter_column_generated_cols'::regclass and attname in ('b','c','d');
-- b shouldn't be allowed for alter type
ALTER TABLE alter_column_generated_cols ALTER COLUMN b TYPE text;
SELECT attname, atttypid::regtype FROM pg_attribute WHERE attrelid='alter_column_generated_cols'::regclass and attname in ('b','c','d');
ALTER TABLE alter_column_generated_cols ALTER COLUMN c TYPE text;
SELECT attname, atttypid::regtype FROM pg_attribute WHERE attrelid='alter_column_generated_cols'::regclass and attname in ('b','c','d');
ALTER TABLE alter_column_generated_cols ALTER COLUMN d TYPE text;
SELECT attname, atttypid::regtype FROM pg_attribute WHERE attrelid='alter_column_generated_cols'::regclass and attname in ('b','c','d');

--------------------------------------------------------------------------------
-- Test if ALTER COLUMN TYPE blocks concurrent INSERT, and vice versa
--------------------------------------------------------------------------------
CREATE TABLE aoco_concurrent_inserts(a int, b int, c int) USING ao_column;
INSERT INTO aoco_concurrent_inserts SELECT i,i,i FROM generate_series(1,10)i;
1: BEGIN;
1: INSERT INTO aoco_concurrent_inserts SELECT i,i,i FROM generate_series(1,10)i;
1: END;
2&: ALTER TABLE aoco_concurrent_inserts ALTER COLUMN b TYPE text;
1: END;
2<:
-- should see 20 rows
SELECT count(*) FROM aoco_concurrent_inserts;
1: BEGIN;
1: ALTER TABLE aoco_concurrent_inserts ALTER COLUMN c TYPE text;
2&: INSERT INTO aoco_concurrent_inserts SELECT i,i,i FROM generate_series(1,10)i;
1: END;
2<:
-- should see 30 rows
SELECT count(*) FROM aoco_concurrent_inserts;
