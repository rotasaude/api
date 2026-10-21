# Estabelecimento do procedimento (contrato §1): unidade de saúde ou
# laboratório municipal (exam_providers com uses_municipal_lab). A UBS é de
# atenção primária e nunca gera BPA (ADR 0039 Invariantes; spec §2 decisão 2).
module Billing
  Establishment = Data.define(:type, :id, :cnes, :name, :kind) do
    def aps? = type == "health_unit" && kind == "ubs"
    def json = { type: type, id: id, cnes: cnes, name: name }
    def key = type == "health_unit" ? { health_unit_id: id } : { exam_provider_id: id }

    def self.for_unit(unit) = new(type: "health_unit", id: unit.id, cnes: unit.cnes, name: unit.name, kind: unit.kind)
    def self.for_lab(provider) = new(type: "lab_provider", id: provider.id, cnes: provider.cnes, name: provider.name, kind: "lab")

    # Do corpo da requisição: unidade ativa ou laboratório municipal ativo.
    def self.find(type, id)
      return nil unless id.is_a?(String) && id.match?(Exams::BaseController::UUID)

      case type
      when "health_unit" then HealthUnit.find_by(id: id, active: true)&.then { |unit| for_unit(unit) }
      when "lab_provider" then ExamProvider.find_by(id: id, uses_municipal_lab: true, active: true)&.then { |lab| for_lab(lab) }
      end
    end

    # De um procedimento ou de uma competência, com o cadastro de agora.
    def self.of(record) = record.health_unit_id ? for_unit(record.health_unit) : for_lab(record.exam_provider)
  end
end
