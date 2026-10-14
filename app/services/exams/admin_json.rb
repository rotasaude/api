# Formas do contrato §5 (catálogo e prestadores).
module Exams
  module AdminJson
    module_function

    def deadlines(record) = Deadlines::STAGES.to_h { |stage| [ stage, record.days_for(stage) ] }

    def catalog_item(item)
      { id: item.id, sigtap_code: item.sigtap_code, label: label(item.sigtap_code),
        requires_authorization: item.requires_authorization, release_policy: item.release_policy,
        deadlines: deadlines(item), result_fields: item.result_fields, active: item.active }
    end

    def provider(provider)
      { id: provider.id, name: provider.name, cnes: provider.cnes, kind: provider.kind, active: provider.active,
        simulated: provider.simulated, has_fhir_token: provider.fhir_token_active?,
        fhir_token_rotated_at: provider.fhir_token_rotated_at&.iso8601,
        items: provider.items.includes(:exam_catalog_item).map do |pi|
          { catalog_item_id: pi.exam_catalog_item_id, sigtap_code: pi.exam_catalog_item.sigtap_code, deadlines: deadlines(pi) }
        end,
        users: provider.provider_users.includes(:user).map { |pu| { user_id: pu.user_id, email: pu.user.email_address } } }
    end

    def label(code) = ClinicalTerms::SigtapExams.find(code, on: Time.zone.today)&.label || "Procedimento #{code}"
  end
end
