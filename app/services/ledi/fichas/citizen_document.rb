# Documento do cidadão nas fichas LEDI (módulo 24a): o CPF; sem CPF, o CNS com
# o marcador "não possui CPF" e a justificativa do paciente (domínio
# JustificativaNaoPossuiCpf, 2–13 — o mesmo na FAI, campo 48, e na FCI, campo
# 32; vendor/ledi/8.7.0/docs/dicionario-fai.html e dicionario-fci.html). CPF e
# CNS nunca juntos. Sem CPF e sem CNS, os dois nil: quem chama recusa
# (patient_without_identifier), nunca inventa CPF.
module Ledi
  module Fichas
    module CitizenDocument
      def self.for(patient)
        cpf = patient.cpf.presence
        return { cpf: cpf, cns: nil, no_cpf: false, justification: nil } if cpf

        { cpf: nil, cns: patient.cns.presence, no_cpf: true, justification: patient.no_cpf_reason.presence&.to_i }
      end
    end
  end
end
