# Encaminhamento ao CEO (decisão 14; contrato §16 O9; Desvio 11): com a
# regulação utilizável, cada desfecho 1–9 da FAO exige um pedido de regulação
# EM RASCUNHO desta consulta, de especialidade (`specialty`) cujo código esteja
# em Catalog::REFERRAL_SPECIALTIES[desfecho]. Os desfechos 10 (radiologia) e 11
# (outros) não exigem pedido. Devolve as recusas no formato da Requirements
# (`[ { path:, error: } ]`); só quem tem a regulação ligada chama.
module DentalCare
  module Referrals
    ERROR = "dental_referral_request_required".freeze

    module_function

    def missing(consultation)
      drafts = RegulationRequest.where(consultation_id: consultation.id, status: "draft", target_type: "specialty").pluck(:target_code)
      consultation.dental_outcomes.each_with_index.filter_map do |code, index|
        wanted = Catalog::REFERRAL_SPECIALTIES[code]
        next if wanted.nil? || (wanted & drafts).any?

        { path: "dental.dental_outcomes[#{index}]", error: ERROR }
      end
    end
  end
end
