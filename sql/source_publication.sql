-- PostgreSQL 17/18 publisher. Read-only publication configuration.
SELECT
    publication.pubname AS tag_publication,
    current_database() AS tag_database,
    pg_catalog.pg_get_userbyid(publication.pubowner) AS tag_owner,
    1::bigint AS configured,
    publication.puballtables::int AS all_tables,
    publication.pubinsert::int AS publishes_insert,
    publication.pubupdate::int AS publishes_update,
    publication.pubdelete::int AS publishes_delete,
    publication.pubtruncate::int AS publishes_truncate,
    publication.pubviaroot::int AS publishes_via_root,
    count(tables.tablename)::bigint AS table_count
FROM pg_catalog.pg_publication AS publication
LEFT JOIN pg_catalog.pg_publication_tables AS tables
  ON tables.pubname = publication.pubname
GROUP BY publication.oid, publication.pubname, publication.pubowner,
         publication.puballtables, publication.pubinsert, publication.pubupdate,
         publication.pubdelete, publication.pubtruncate, publication.pubviaroot;
