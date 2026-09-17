# staging: ensaio de produção (spec da API de manutenção §4). Mesma configuração
# de production — inclusive config.hosts (PlatformHosts.for(Rails.env)) e SMTP —,
# com banco, chaves, credentials e segredos próprios vindos do ambiente e de
# config/credentials/staging.yml.enc. Só entra aqui o que PRECISA ser diferente;
# hoje, só o require_master_key abaixo.
require_relative "production"

Rails.application.configure do
  # A única coisa que staging exige e production não (production continua lendo
  # o arquivo de credentials compartilhado por desenho — ver "Fora deste plano"
  # no plano de staging). Sem isto, RAILS_MASTER_KEY ausente ou errada faz
  # Rails.application.credentials devolver {} em silêncio, e o boot de staging
  # "passaria" com credentials vazias (secret_key_base, AR Encryption,
  # report_signing_key todos nil). Staging precisa falhar fechado.
  config.require_master_key = true
end
