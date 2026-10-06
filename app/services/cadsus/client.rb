# Escolhe o backend (ADR 0028): `config.x.cadsus_backend = :simulated` em
# development e test; ausente (staging, production) → PDQv3 SOAP com a
# credencial `cadsus` da cidade. Precisa da credencial nos dois casos: o
# simulado também espelha "sem credencial = indisponível". O segredo é
# decifrado DENTRO do bloco da cidade (chave da cidade, ADR 0007): o cliente
# nasce lá e só ele sai do bloco.
module Cadsus
  module Client
    module_function

    def for(city)
      CityConnection.with(city) do
        credential = IntegrationCredential.find_by(kind: "cadsus")
        raise Unavailable, "credencial do CADSUS não cadastrada" unless credential

        build(credential)
      end
    end

    def build(credential)
      if Rails.configuration.x.cadsus_backend == :simulated
        Simulated.new(username: credential.username)
      else
        SoapPdq.new(url: Rails.configuration.x.cadsus_pdq_url || SoapPdq.default_url,
                    username: credential.username, password: credential.password)
      end
    end
  end
end
