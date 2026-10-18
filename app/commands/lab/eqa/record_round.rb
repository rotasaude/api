# Rodada do CEQ (contrato §4; spec §5.10): programa (PNCQ, Controllab ou
# texto), código único por laboratório e programa, data não futura, 1..60
# itens de analitos numéricos de exames do laboratório (um item por
# analito); números como string com ponto (C-E9); inadequado exige ação;
# relatório anual opcional (PDF enviado por /lab/eqa/uploads, consumido aqui —
# ). Só acréscimo: a rodada nasce com o arquivo e
# nunca é alterada (o gatilho de só-acréscimo não permite UPDATE).
module Lab
  module Eqa
    module RecordRound
      module_function

      def call(params, by:, now: Time.current)
        params = params.to_h.stringify_keys
        provider = params["provider_id"].to_s.match?(Exams::BaseController::UUID) ? Lab::Access.labs.find_by(id: params["provider_id"]) : nil
        return Result.fail(:invalid_provider) unless provider

        program = params["program"].is_a?(String) ? params["program"].strip : ""
        code = params["round_code"].is_a?(String) ? params["round_code"].strip : ""
        return Result.fail(:invalid_program) unless program.length.between?(1, 60)
        return Result.fail(:invalid_round_code) unless code.length.between?(1, 40)

        date = ClinicalDocuments::IsoDate.parse(params["round_date"])
        return Result.fail(:invalid_round_date) unless date && date <= now.in_time_zone.to_date

        items = parse_items(params["items"], provider)
        return items if items.is_a?(Result)

        result = nil
        ApplicationRecord.transaction(requires_new: true) do
          provider.lock!
          next result = Result.fail(:duplicate_round) if LabEqaRound.exists?(exam_provider_id: provider.id, program: program, round_code: code)

          round = LabEqaRound.create!(exam_provider: provider, program: program, round_code: code, round_date: date, items: items,
                                      recorded_by_user: by, created_at: now)
          DomainEvents.publish("lab_eqa_round.recorded", lab_eqa_round_id: round.id)
          result = Result.ok(round: round)
        end
        result
      end

      def parse_items(raw, provider)
        return Result.fail(:invalid_items) unless raw.is_a?(Array) && raw.size.between?(1, 60)

        exams = LabExam.where(exam_provider_id: provider.id).includes(:current_version).index_by(&:id)
        items = raw.map do |entry|
          entry = entry.to_unsafe_h if entry.respond_to?(:to_unsafe_h)
          return Result.fail(:invalid_items) unless entry.is_a?(Hash)

          entry = entry.stringify_keys
          analyte = entry["lab_exam_id"].is_a?(String) ? exams[entry["lab_exam_id"]]&.current_version&.analyte(entry["analyte_key"]) : nil
          return Result.fail(:invalid_items) unless analyte && analyte["value_type"] == "numeric"
          return Result.fail(:invalid_items) unless LabEqaRound::ADEQUACY.include?(entry["adequacy"])

          submitted = Lab::Qc::Decimal.json(entry["submitted"])
          target = Lab::Qc::Decimal.json(entry["target"])
          low = entry["acceptable_low"].nil? ? nil : Lab::Qc::Decimal.json(entry["acceptable_low"])
          high = entry["acceptable_high"].nil? ? nil : Lab::Qc::Decimal.json(entry["acceptable_high"])
          return Result.fail(:invalid_value) unless submitted && target
          return Result.fail(:invalid_value) if (!entry["acceptable_low"].nil? && low.nil?) || (!entry["acceptable_high"].nil? && high.nil?)
          return Result.fail(:invalid_value) if low && high && low > high

          action = entry["action"].is_a?(String) ? entry["action"].strip.presence : nil
          return Result.fail(:action_required) if entry["adequacy"] == "inadequate" && action.nil?
          return Result.fail(:invalid_items) if action && action.length > 500

          { "lab_exam_id" => entry["lab_exam_id"], "analyte_key" => analyte["key"], "submitted" => Lab::Qc::Decimal.out(submitted),
            "target" => Lab::Qc::Decimal.out(target), "acceptable_low" => Lab::Qc::Decimal.out(low),
            "acceptable_high" => Lab::Qc::Decimal.out(high), "adequacy" => entry["adequacy"], "action" => action }
        end
        pairs = items.map { |i| i.values_at("lab_exam_id", "analyte_key") }
        pairs.uniq.size == pairs.size ? items : Result.fail(:invalid_items)
      end

      private_class_method :parse_items
    end
  end
end
