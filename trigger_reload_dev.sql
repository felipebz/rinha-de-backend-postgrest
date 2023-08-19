-- Trigger para reload do cache do PostgREST.
-- Referência: https://postgrest.org/en/stable/references/schema_cache.html?highlight=reload#automatic-schema-cache-reloading
CREATE OR REPLACE FUNCTION pgrst_watch() RETURNS event_trigger
    LANGUAGE plpgsql
AS $$
BEGIN
    NOTIFY pgrst, 'reload schema';
END;
$$;

CREATE EVENT TRIGGER pgrst_watch
    ON ddl_command_end
EXECUTE PROCEDURE pgrst_watch();