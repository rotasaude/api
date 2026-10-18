# Item de estoque (contrato §5): nome único no laboratório (1..120); tipo;
# unidade (1..20); rendimento (1..100000) só (e sempre) para reagente;
# mínimo (0..100000); dias de alerta (1..365, padrão 30); exames do
# laboratório. Nunca apagado (desativar).
module Lab
  module Inventory
    module SaveSupply
      module_function

      def call(params, provider: nil, supply: nil)
        params = params.to_h.stringify_keys
        provider ||= supply.exam_provider
        name = params["name"].is_a?(String) ? params["name"].strip : ""
        unit = params["unit"].is_a?(String) ? params["unit"].strip : ""
        return Result.fail(:invalid_name) unless name.length.between?(1, 120)
        return Result.fail(:invalid_kind) unless LabSupply::KINDS.include?(params["kind"])
        return Result.fail(:invalid_unit) unless unit.length.between?(1, 20)

        tests = params["tests_per_package"]
        reagent = params["kind"] == "reagent"
        return Result.fail(:invalid_tests_per_package) unless reagent ? (tests.is_a?(Integer) && tests.between?(1, 100_000)) : tests.nil?
        return Result.fail(:invalid_minimum_stock) unless params["minimum_stock"].is_a?(Integer) && params["minimum_stock"].between?(0, 100_000)

        alert_days = params.fetch("expiry_alert_days", 30)
        return Result.fail(:invalid_expiry_alert_days) unless alert_days.is_a?(Integer) && alert_days.between?(1, 365)

        exam_ids = params["lab_exam_ids"]
        valid_exams = exam_ids.is_a?(Array) && exam_ids.all?(String) && exam_ids.uniq.size == exam_ids.size &&
                      exam_ids.all? { |id| id.match?(Exams::BaseController::UUID) } &&
                      LabExam.where(exam_provider_id: provider.id, id: exam_ids).count == exam_ids.size
        return Result.fail(:invalid_exams) unless valid_exams
        return Result.fail(:invalid_active) unless [ true, false ].include?(params["active"])

        ApplicationRecord.transaction(requires_new: true) do
          provider.lock!
          taken = LabSupply.where(exam_provider_id: provider.id).where.not(id: supply&.id).where("lower(name) = ?", name.downcase).exists?
          next Result.fail(:duplicate_name) if taken

          record = supply || LabSupply.new(exam_provider: provider)
          record.update!(name: name, kind: params["kind"], unit: unit, tests_per_package: tests, minimum_stock: params["minimum_stock"],
                         expiry_alert_days: alert_days, lab_exam_ids: exam_ids, active: params["active"])
          Result.ok(supply: record)
        end
      rescue ActiveRecord::RecordNotUnique
        Result.fail(:duplicate_name)
      end
    end
  end
end
