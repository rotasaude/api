# Isolamento entre ambientes (spec da API de manutenção §4). Sem
# config/credentials/staging.yml.enc, o Rails lê config/credentials.yml.enc em
# silêncio — e staging subiria com as chaves de outro ambiente. Prefixo 00_: roda
# antes de active_record_encryption.rb, para falhar antes de qualquer chave ser
# lida. Ver lib/rota.rb.
Rota.check_credentials!
