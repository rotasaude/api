# Escolhe o backend (ADR 0028): `config.x.cadsus_backend = :simulated` em
# development e test; ausente (staging, production) → PDQv3 SOAP com a
# credencial `cadsus` da cidade. Precisa da credencial nos dois casos: o
# simulado também espelha "sem credencial = indisponível".
module Cadsus
  module Client
    module_function

    def for(city)
      credential = CityConnection.with(city) { IntegrationCredential.find_by(kind: "cadsus") }
      raise Unavailable, "credencial do CADSUS não cadastrada" unless credential

      if Rails.configuration.x.cadsus_backend == :simulated
        Simulated.new(username: credential.username)
      else
        SoapPdq.new(url: Rails.configuration.x.cadsus_pdq_url || SoapPdq.default_url,
                    username: credential.username, password: credential.password)
      end
    end
  end
end
