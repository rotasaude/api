# Leitura em lote das fontes das boas práticas (ADR 0040; spec §5; plano,
# Desvio 9): só datas, CBO e códigos — nunca valor clínico. No máximo uma
# consulta SQL por fonte, qualquer que seja o número de pacientes: pares,
# consultas, problemas das consultas, escutas, exames (pedido + resultado
# num UNION ALL) e procedimentos. Datas no fuso da cidade (Time.zone).
module CareLines
  module Sources
    BP_PROCEDURE = "0301100039".freeze
    WH_PROCEDURE = "0101040024".freeze
    VITALS = %w[blood_pressure weight_height].freeze

    module_function

    def load(patient_ids:, sources:, since:)
      ids = patient_ids.uniq
      result = ids.to_h { |id| [ id, Hash.new { |h, k| h[k] = [] } ] }
      return {} if ids.empty?

      sources = sources.uniq
      from = since.in_time_zone.beginning_of_day
      vitals = sources.intersect?(VITALS)
      if sources.include?("consultation") || vitals
        consultations!(result, ids, from, sources)
      end
      screenings!(result, ids, from, sources) if vitals
      exams!(result, ids, since, sources.grep(/\Aexam:/).map { |s| s.delete_prefix("exam:") })
      procedure_codes = sources.grep(/\Aprocedure:/).map { |s| s.delete_prefix("procedure:") }
      procedure_codes << BP_PROCEDURE if sources.include?("blood_pressure")
      procedure_codes << WH_PROCEDURE if sources.include?("weight_height")
      procedures!(result, ids, since, procedure_codes.uniq)
      result.transform_values { |by_source| by_source.to_h { |source, list| [ source, list.sort_by(&:on) ] } }
    end

    def consultations!(result, ids, from, sources)
      rows = Consultation.finalized_consultations.where(patient_id: ids).where(finalized_at: from..)
                         .pluck(:id, :patient_id, :finalized_at, :cbo_code, :systolic, :weight_kg, :height_cm)
      codes = if sources.include?("consultation") && rows.any?
                ConsultationProblem.where(consultation_id: rows.map(&:first)).pluck(:consultation_id, :terminology, :code)
                                   .group_by(&:first).transform_values { |list| list.map { |_, terminology, code| [ terminology, code ] }.uniq }
              else
                {}
              end
      rows.each do |id, patient_id, at, cbo, systolic, weight, height|
        on = at.in_time_zone.to_date
        result[patient_id]["consultation"] << Event.new(on: on, cbo: cbo, codes: codes.fetch(id, [])) if sources.include?("consultation")
        result[patient_id]["blood_pressure"] << Event.new(on: on) if systolic && sources.include?("blood_pressure")
        result[patient_id]["weight_height"] << Event.new(on: on) if weight && height && sources.include?("weight_height")
      end
    end

    # A escuta é do par (atendimento.citizen_id); o par leva ao paciente.
    def screenings!(result, ids, from, sources)
      pairs = Citizen.where(patient_id: ids).pluck(:id, :patient_id).to_h
      return if pairs.empty?

      Screening.completed_screenings.joins(:attendance, :current_revision)
               .where(attendances: { citizen_id: pairs.keys }).where(completed_at: from..)
               .pluck("attendances.citizen_id", "screenings.completed_at", "screening_revisions.systolic",
                      "screening_revisions.weight_kg", "screening_revisions.height_cm")
               .each do |citizen_id, at, systolic, weight, height|
        patient_id = pairs.fetch(citizen_id)
        on = at.in_time_zone.to_date
        result[patient_id]["blood_pressure"] << Event.new(on: on) if systolic && sources.include?("blood_pressure")
        result[patient_id]["weight_height"] << Event.new(on: on) if weight && height && sources.include?("weight_height")
      end
    end

    # "Solicitado ou avaliado": pedido (não cancelado nem negado) ou resultado.
    def exams!(result, ids, since, codes)
      return if codes.empty?

      from = since.in_time_zone.beginning_of_day.utc # created_at é UTC sem fuso; released_on é data
      sql = ApplicationRecord.sanitize_sql([ <<~SQL, Time.zone.tzinfo.name, ids, codes, from, ids, codes, since ])
        SELECT o.patient_id, o.sigtap_code, (o.created_at AT TIME ZONE 'UTC' AT TIME ZONE ?)::date AS on_date
          FROM exam_orders o
         WHERE o.patient_id IN (?) AND o.sigtap_code IN (?) AND o.status NOT IN ('cancelled', 'denied') AND o.created_at >= ?
        UNION ALL
        SELECT r.patient_id, r.sigtap_code, r.released_on AS on_date
          FROM exam_results r
         WHERE r.patient_id IN (?) AND r.sigtap_code IN (?) AND r.released_on >= ?
      SQL
      ApplicationRecord.connection.select_all(sql).cast_values.each do |patient_id, code, on|
        result[patient_id]["exam:#{code}"] << Event.new(on: on.is_a?(Date) ? on : Date.iso8601(on.to_s))
      end
    end

    def procedures!(result, ids, since, codes)
      return if codes.empty?

      PerformedProcedure.where(patient_id: ids, status: "recorded", sigtap_code: codes).where(performed_on: since..)
                        .pluck(:patient_id, :sigtap_code, :performed_on).each do |patient_id, code, on|
        source = case code
                 when BP_PROCEDURE then "blood_pressure"
                 when WH_PROCEDURE then "weight_height"
                 else "procedure:#{code}"
                 end
        result[patient_id][source] << Event.new(on: on)
        result[patient_id]["procedure:#{code}"] << Event.new(on: on) if source != "procedure:#{code}"
      end
    end
    private_class_method :consultations!, :screenings!, :exams!, :procedures!
  end
end
