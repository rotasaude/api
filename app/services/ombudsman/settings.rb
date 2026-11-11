# Fachada da configuração da ouvidoria (ADR 0051; Q13/Q47): na leitura, cria a
# linha de ombudsman_settings que faltar e a semente de assuntos se a tabela
# estiver vazia (banco vindo do dump; a migração já insere as duas).
module Ombudsman
  module Settings
    module_function

    def ensure_defaults!(now: Time.current)
      OmbudsmanSetting.ensure_defaults!(now: now)
      OmbudsmanSubject.ensure_defaults!(now: now)
      true
    end
  end
end
