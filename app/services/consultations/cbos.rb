# app/services/consultations/cbos.rb
# Quem registra cada tipo de consulta (ADR 0031; ADR 0046, Desvio 1).
# Consulta geral: CBO de nível superior que o layout aceita no Atendimento
# Individual (tabela do MIAI, módulo 18) fora da odontologia (2232). Consulta
# odontológica (módulo 28): cirurgião-dentista (2232*) e TSB/ASB (os quatro
# de nível técnico). O resto (técnico de enfermagem, protético) não registra.
module Consultations
  module Cbos
    module_function

    def kinds_for(cbo)
      return [ "dental" ] if role(cbo)
      return [ "general" ] if Ledi::ScreeningMapping.miai_cbo?(cbo.to_s)

      []
    end

    def role(cbo)
      cbo = cbo.to_s
      return :dentist if cbo.start_with?(DentalCare::Catalog::DENTIST_PREFIX)

      :auxiliary if DentalCare::Catalog::AUXILIARY_CBOS.include?(cbo)
    end

    # Sem kind: a consulta geral (o sentido de antes do módulo 28).
    # Módulo 32a (§14 Q10; preflight C-18): a consulta `urgency` é do médico
    # (225*); kinds_for não a oferece — só a UPA a abre (Consultations::Start
    # exige o encontro) e as opções a acrescentam pelo vínculo na UPA.
    def allowed?(cbo, kind: "general")
      return cbo.to_s.start_with?(Urgency::Catalog::PHYSICIAN_CBO_PREFIX) if kind.to_s == "urgency"

      kinds_for(cbo).include?(kind.to_s)
    end
  end
end
