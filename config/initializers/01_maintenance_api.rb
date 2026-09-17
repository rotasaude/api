# Trava de boot da API de manutenção (spec §5). Prefixo 01_: depois da checagem
# de credentials (00_) e antes de qualquer initializer que monte rota.
MaintenanceApi.check_boot!
