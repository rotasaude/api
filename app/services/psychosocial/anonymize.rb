# Exclusão LGPD do CAPS (ADR 0049; ADR 0026; contrato §14, §15 P17). Só no
# ramo NÃO retido do Citizens::Erase: quem tem matrícula (em qualquer
# situação), participação em ação (cancelada inclusive), permanência ou caso de
# matriciamento é retido inteiro (Citizens::RequestErasure.psychosocial_recorded?).
# Sobra o encaminhamento sem acolhimento e o acolhimento sem ação, que seguem a
# regra da triagem sem atendimento: as cifradas (motivo do encaminhamento,
# notas do acolhimento) → NULL e anonymized_at, uma vez (filtro anonymized_at
# IS NULL; o trigger recusa a segunda e congela a linha anonimizada). Status,
# datas, CAPS e paciente ficam (contagens). Nada do paciente em log nem em
# evento.
#
# Ordem de travas: o Citizens::Erase chama lock! ANTES de travar o paciente
# (encaminhamentos → paciente), a ordem do Psychosocial::RecordReception
# (encaminhamento FOR UPDATE → FK do paciente). Quem recebe depois acha o
# encaminhamento anonimizado e recusa (referral_not_pending).
module Psychosocial
  module Anonymize
    module_function

    # Trava os encaminhamentos dos pacientes antes do paciente.
    def lock!(patient_ids)
      ids = Array(patient_ids)
      return if ids.empty?

      PsychosocialReferral.where(patient_id: ids).order(:id).lock.pluck(:id)
    end

    # -> Integer (linhas anonimizadas: encaminhamentos + acolhimentos)
    def patients!(patient_ids, now: Time.current)
      ids = Array(patient_ids).uniq
      return 0 if ids.empty?

      PsychosocialReferral.where(patient_id: ids, anonymized_at: nil).update_all(reason: nil, anonymized_at: now, updated_at: now) +
        PsychosocialReception.where(patient_id: ids, anonymized_at: nil).update_all(notes: nil, anonymized_at: now)
    end
  end
end
