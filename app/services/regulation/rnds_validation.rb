module Regulation
  # Conferência do documento RIRA antes do envio (módulo 26c; Valor 4, Q9,
  # Q15; molde do Rnds::Validation). Pura sobre os fatos (`RiraFacts`):
  #
  #   Regulation::RndsValidation.call(facts:, status:) -> :ok | [:blocked, [String]]
  #
  # Todos os motivos de uma vez, na ordem do `RndsCatalog::BLOCK_REASONS`:
  # - `missing_diagnosis`: sem CID-10 e sem CIAP-2;
  # - `requester_unit_without_cnes`: a unidade solicitante sem CNES;
  # - `performer_without_cnes`: em `booked`/`attended`, o executante sem CNES;
  #   na falta da rede própria (Q22), a unidade do `no_show` sem CNES;
  # - `patient_without_cpf_or_cns`;
  # - `performer_cbo_missing`: em `booked`/`attended`, SIGTAP de grupo em
  #   `CBO_GROUPS` e nenhum CBO do executante;
  # - `specialty_without_sigtap` (Q9, pré-voo M16): alvo `specialty` com o
  #   SIGTAP resolvido não regulável ou fora da competência;
  # - `missing_priority` (Q15): sem cor decidida nem sugerida, sem caráter;
  # - `external_absence_without_schedule` (Q22, Q24): falta sem horário até
  #   ela — só a falta externa registrada antes da Q24, sem a data na linha
  #   `missed` —, parada até a homologação. A rede é a do horário faltado.
  # O esqueleto (`RiraSkeleton`, `skeleton:<caminho>`, Q23) é do chamador. Os
  # motivos são só códigos: nenhum valor do paciente sai daqui.
  module RndsValidation
    # O CBO do executante só é exigido aqui (a falta não o pede).
    SCHEDULED_STATUSES = %w[booked attended].freeze

    module_function

    def call(facts:, status:)
      code, at = RiraBundle.situation(status, facts)
      performer = SCHEDULED_STATUSES.include?(code)
      absence = code == RndsStatus::ABSENCE
      slot = absence ? RiraBundle.absence_slot(facts, at) : nil
      external_absence = absence && slot.nil?
      found = {
        "missing_diagnosis" => facts.cid10.blank? && facts.ciap2.blank?,
        "requester_unit_without_cnes" => facts.requester_cnes.blank?,
        "performer_without_cnes" => (performer && facts.performer_cnes.blank?) || (absence && slot && slot.cnes.blank?),
        "patient_without_cpf_or_cns" => facts.patient_cpf.blank? && facts.patient_cns.blank?,
        "performer_cbo_missing" => performer && RndsLimits::CBO_GROUPS.include?(facts.sigtap.to_s[0, 2]) && facts.performer_cbo.blank?,
        "specialty_without_sigtap" => facts.target_type == "specialty" && !facts.sigtap_valid,
        "missing_priority" => facts.priority.blank?,
        "external_absence_without_schedule" => external_absence
      }
      reasons = RndsCatalog::BLOCK_REASONS.select { |reason| found.fetch(reason) }
      reasons.empty? ? :ok : [ :blocked, reasons ]
    end
  end
end
