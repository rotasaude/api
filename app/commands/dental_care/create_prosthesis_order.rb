# Pedido de prótese (ADR 0046; Desvio 12; contrato §16 O10): só o dentista
# autor de uma consulta odontológica (rascunho ou finalizada) do mesmo
# paciente, com SIGTAP de PROSTHESIS_CODES e um laboratório — prestador ativo
# do 26a (`care_provider_id`) ou terceiro por nome (3..120), nunca os dois. O
# pedido nasce em `impression`, na unidade da consulta. Evento só com ids; o
# nome do laboratório nunca sai daqui.
module DentalCare
  module CreateProsthesisOrder
    module_function

    # params: corpo JSON. -> Result.ok(order:) | fail(:missing_role | :not_author | :not_found | :invalid_request, details: { path: })
    def call(params:, by:)
      link = Consultations::Authorization.any_allowed_link(user: by, kind: "dental", role: :dentist)
      return Result.fail(:missing_role) unless link.first == :ok

      consultation = find_consultation(params["consultation_id"])
      return refuse("consultation_id") if consultation == :invalid
      return Result.fail(:not_found) unless consultation
      return Result.fail(:not_author) unless consultation.author_user_id == by.id
      return refuse("consultation_id") unless consultation.dental? && !consultation.discarded?
      return refuse("patient_id") unless params["patient_id"] == consultation.patient_id
      return refuse("sigtap") unless Catalog::PROSTHESIS_CODES.include?(params["sigtap"])

      laboratory = laboratory(params["laboratory"])
      return laboratory if laboratory.is_a?(Result)

      ApplicationRecord.transaction(requires_new: true) do
        order = DentalProsthesisOrder.create!(patient_id: consultation.patient_id, health_unit_id: consultation.attendance.health_unit_id,
                                              consultation: consultation, procedure_code: params["sigtap"], stage: "impression",
                                              created_by_user: by, **laboratory)
        order.stages.create!(stage: "impression", by_user: by)
        DomainEvents.publish("prosthesis_order.created", order_id: order.id, user_id: by.id)
        Result.ok(order: order)
      end
    end

    def find_consultation(id)
      return :invalid unless id.is_a?(String) && id.match?(BaseController::UUID)

      Consultation.find_by(id: id)
    end

    # -> { care_provider_id: } | { laboratory_name: } | Result de recusa.
    def laboratory(raw)
      return refuse("laboratory") unless raw.is_a?(Hash)

      provider_id = raw["care_provider_id"]
      name = raw["name"]
      return refuse("laboratory") unless provider_id.nil? ^ name.nil?

      if provider_id
        ok = provider_id.is_a?(String) && provider_id.match?(BaseController::UUID) && CareProvider.active_providers.exists?(id: provider_id)
        return ok ? { care_provider_id: provider_id } : refuse("laboratory")
      end
      return refuse("laboratory") unless name.is_a?(String) && Catalog::LAB_NAME.cover?(name.strip.length)

      { laboratory_name: name.strip }
    end

    def refuse(path) = Result.fail(:invalid_request, details: { path: path, problems: [ { path: path, error: "invalid_request" } ] })
    private_class_method :find_consultation, :laboratory, :refuse
  end
end
