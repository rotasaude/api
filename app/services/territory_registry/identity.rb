# Identidade do paciente que vai na ficha de cadastro individual (módulo 24a,
# ADR 0042; contrato §15.3): o que mora no paciente, não em `identification`.
# A versão do cadastro guarda este retrato; a validação no posto (Desvio 5)
# compara retratos para saber se precisa de versão nova. Só nomes de campo
# saem daqui para log/evento — nunca os valores.
module TerritoryRegistry
  module Identity
    KEYS = %w[full_name social_name birth_date sex mother_name race_color ethnicity cpf cns no_cpf_reason].freeze

    module_function

    def snapshot(patient)
      KEYS.to_h do |key|
        value = patient.public_send(key)
        [ key, key == "birth_date" ? Patients::MatchKey.iso_date(value) : value ]
      end
    end

    def changed_fields(old, new)
      old = old.to_h.stringify_keys
      new = new.to_h.stringify_keys
      KEYS.reject { |key| old[key] == new[key] }
    end
  end
end
