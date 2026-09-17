# staging: ensaio de produção (spec da API de manutenção §4). Mesma configuração
# de production — inclusive config.hosts (PlatformHosts.for(Rails.env)) e SMTP —,
# com banco, chaves, credentials e segredos próprios vindos do ambiente e de
# config/credentials/staging.yml.enc. Só entra aqui o que PRECISA ser diferente;
# hoje, nada.
require_relative "production"
