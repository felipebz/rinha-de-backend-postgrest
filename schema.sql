CREATE ROLE web_anon nologin;
CREATE ROLE authenticator noinherit;
GRANT web_anon TO authenticator;

CREATE EXTENSION pg_trgm;

CREATE OR REPLACE FUNCTION immutable_array_to_string(text[], text) RETURNS text AS
$$
SELECT array_to_string($1, $2);
$$ LANGUAGE sql IMMUTABLE;

CREATE TABLE pessoa
(
    id             serial PRIMARY KEY,
    apelido        varchar(32) UNIQUE NOT NULL,
    nome           varchar(100)       NOT NULL,
    nascimento     date               NOT NULL,
    stack          varchar(32)[],
    dados_pesquisa text GENERATED ALWAYS AS (nome||' '||apelido||' '||
                                             coalesce(immutable_array_to_string(stack, ' '), '')) STORED
);
CREATE INDEX pessoa_dados_pesquisa_index ON pessoa USING GIST (DADOS_PESQUISA gist_trgm_ops);
CREATE VIEW pessoa_view AS SELECT id, apelido, nome, nascimento, stack FROM pessoa;
GRANT SELECT, INSERT ON pessoa TO web_anon;
GRANT SELECT ON pessoa_view TO web_anon;
GRANT USAGE ON pessoa_id_seq TO web_anon;

-- Endpoint de criação de pessoas (POST /pessoas)
CREATE OR REPLACE FUNCTION pessoas(jsonb) RETURNS void AS
$$
DECLARE
    id         pessoa.id%type;
    item_stack jsonb;
    stack      jsonb;
BEGIN
    -- Validando os tipos manualmente para retornar o status code exigido na especificação
    IF (jsonb_typeof($1 -> 'apelido') <> 'string' OR
        jsonb_typeof($1 -> 'nome') <> 'string' OR
        jsonb_typeof($1 -> 'nascimento') <> 'string' OR
        jsonb_typeof($1 -> 'stack') NOT IN ('array', 'null')) THEN
        PERFORM set_config('response.status', '400', TRUE);
        RETURN;
    END IF;

    stack := $1 -> 'stack';
    FOR item_stack IN SELECT * FROM jsonb_array_elements(stack) LOOP
        IF (jsonb_typeof(item_stack) <> 'string') THEN
            PERFORM set_config('response.status', '400', TRUE);
            RETURN;
        END IF;
    END LOOP;

    -- Os erros relacionados com o tamanho das variáveis e duplicidade de apelido
    -- são tratados pelo banco de dados aqui
    BEGIN
        INSERT INTO pessoa (apelido, nome, nascimento, stack)
        VALUES ($1 ->> 'apelido',
                $1 ->> 'nome',
                ($1 ->> 'nascimento')::date,
                (SELECT array_agg(value) FROM jsonb_array_elements_text(stack)))
        RETURNING pessoa.id INTO id;
    EXCEPTION
        WHEN OTHERS THEN
            PERFORM set_config('response.status', '422', TRUE);
            RETURN;
    END;

    PERFORM set_config('response.status', '201', TRUE);
    PERFORM set_config('response.headers', '[{"Location": "/pessoas?id='||id|| '"}]', TRUE);
END
$$ LANGUAGE plpgsql;

-- Endpoint de detalhe de pessoas (GET /pessoas/id)
CREATE OR REPLACE FUNCTION pessoas(id integer)
    RETURNS pessoa_view AS
$$
DECLARE
    retorno pessoa_view;
BEGIN
    SELECT *
      INTO STRICT retorno
      FROM pessoa_view
     WHERE pessoa_view.id = pessoas.id;

    RETURN retorno;
EXCEPTION
    WHEN no_data_found THEN
        PERFORM set_config('response.status', '404', TRUE);
        RETURN NULL;
END
$$ LANGUAGE plpgsql;

-- Endpoint de busca de pessoas (GET /pessoas?t=<termo>)
CREATE OR REPLACE FUNCTION pessoas(t varchar)
    RETURNS SETOF pessoa_view AS
$$
SELECT pessoa.id,
       pessoa.apelido,
       pessoa.nome,
       pessoa.nascimento,
       pessoa.stack
  FROM pessoa
 WHERE pessoa.dados_pesquisa ILIKE '%'||t||'%'
 LIMIT 50
$$ LANGUAGE sql;

-- Quando é chamado o endpoint de busca sem o parâmetro t ou com ele vazio, o PostgREST
-- espera que exista uma função sem parâmetros. De acordo com a especificação, caso o parâmetro
-- "t" não seja passado, deve-se retornar o código 400.
CREATE OR REPLACE FUNCTION pessoas()
    RETURNS void AS
$$
BEGIN
    PERFORM set_config('response.status', '400', TRUE);
END;
$$ LANGUAGE plpgsql;

-- Endpoint de contagem de pessoas (GET /contagem-pessoas)
CREATE OR REPLACE FUNCTION "contagem-pessoas"()
    RETURNS numeric AS
$$
SELECT count(1)
  FROM pessoa
$$ LANGUAGE sql;


/*
Essa seria outra forma de implementar o endpoint de criação de pessoas, mas devido à forma como
o PostgREST passa os parâmetros, se o json vier com "nome: 1" (numérico) ou "nome: '1'" (string)
não conseguimos fazer essa distinção aqui, pois sempre entrará como varchar.

Eu poderia fazer uma validação manual tentando converte os valores para numérico e recusando
qualquer valor numérico, independente de ter vindo como string ou não no json, mas
pra ser mais estrito com a especificação, preferi manter a outra versão recebendo jsonb
mais acima.

CREATE OR REPLACE FUNCTION pessoas(
    apelido varchar,
    nome varchar,
    nascimento date,
    stack varchar[]
) RETURNS void AS
$$
DECLARE
    id integer;
BEGIN
    BEGIN
        INSERT INTO pessoa (apelido, nome, nascimento, stack)
        VALUES (apelido, nome, nascimento, stack)
        RETURNING
            pessoa.id INTO id;
    EXCEPTION
        WHEN OTHERS THEN
            PERFORM
                set_config('response.status', '422', TRUE);
            RETURN;
    END;
    PERFORM set_config('response.status', '201', TRUE);
    PERFORM set_config('response.headers', '[{"Location": "/pessoas?id=' || id || '"}]', TRUE);
END
$$ LANGUAGE plpgsql;
*/
