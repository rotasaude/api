# api

Backend Rails 8 do Rota Saúde. Papéis web + worker da mesma imagem (ADR 0001).

Decisões arquiteturais em rotasaude/docs.

## Desenvolvimento

Postgres roda no **host** (não em container). Pré-requisitos:

- Docker + Docker Compose
- Postgres no host com owner e databases provisionados:

      createuser -d rota_saude
      createdb -O rota_saude rota_saude_development
      createdb -O rota_saude rota_saude_test

- `config/master.key` colocado manualmente em `config/` (não está no repo —
  obtenha com o time). Sem ele o Rails não decifra `credentials.yml.enc`.

Subir:

      cp .env.example .env
      docker compose up

Verificar:

      curl -s -o /dev/null -w "%{http_code}\n" http://localhost:3030/up   # 200

Serviços: `api` (web, porta 3030→3000) e `worker` (Solid Queue). Logs:
`docker compose logs -f api`.

### Limitação conhecida (bootstrap-from-zero)

As migrations rodam **incrementalmente sobre um banco já provisionado**. Os
roles `rota_app`/`rota_admin` (ADR-0019) são criados por migration que conecta
como `rota_app`, então um Postgres **vazio** não sobe sozinho. Provisionar do
zero (ou Postgres containerizado efêmero) é follow-up — ver
`rotasaude/docs` e a issue de bootstrap.

## Produção

Deploy via Kamal 2 (`deploy/`). Secrets via 1Password (`deploy/SECRETS.md`).
