# O que uma resposta do recebimento do PEC significa para a fila (spec §6.4).
# Duplicidade e sessão expirada seguem o que a prova técnica observou
# (config/ledi/pec_observations.yml).
module Ledi
  module Outcome
    module_function

    # Só 400 recusa; sessão expirada pede relogin; todo o resto tenta de novo.
    def classify(status, body)
      return :accepted if (200..299).cover?(status)
      return :unauthorized if Ledi::Observations.session_expired_statuses.include?(status)
      return :retry unless status == 400

      # PROVISÓRIO (rotasaude/api#41): o marcador de duplicidade ainda não foi
      # observado no PEC real; sem ele, todo 400 é recusa.
      marker = Ledi::Observations.duplicate_marker
      marker && body.to_s.include?(marker) ? :accepted : :rejected
    end
  end
end
