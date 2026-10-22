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
      procedures!(result, ids, since, procedure_codes.uniq, sources)
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

    # "Solicitado ou avaliado", UM evento por exame (chave = pedido da consulta,
    # senão a ordem, senão o resultado) com a data mais recente dele: pedido e
    # resultado em dias diferentes, ou resultado substituto, não contam em dobro.
    # Três ramos num SQL só: (A) pedido EFETIVO da consulta finalizada (vale também
    # com exam_tracking desligado, quando não nasce exam_orders): o adendo só
    # acrescenta linhas, então vale a última por (consulta, SIGTAP) em
    # (created_at, id) — a mesma regra de Consultations::Effective — se estiver
    # `requested`; data = dia local de created_at (adendo tem a data própria);
    # salvo se a ordem ligada a ele foi cancelada/negada; (B) ordem não cancelada nem negada;
    # (C) resultado (a ordem dá a chave do pedido da consulta).
    def exams!(result, ids, since, codes)
      return if codes.empty?

      zone = Time.zone.tzinfo.name
      from = since.in_time_zone.beginning_of_day.utc # created_at/finalized_at são UTC sem fuso; released_on é data
      sql = ApplicationRecord.sanitize_sql([ <<~SQL, zone, ids, codes, from, zone, ids, codes, from, ids, codes, since ])
        SELECT patient_id, sigtap_code, MAX(on_date) AS on_date
          FROM (
            SELECT c.patient_id, r.sigtap_code, r.id AS exam_key,
                   (r.created_at AT TIME ZONE 'UTC' AT TIME ZONE ?)::date AS on_date
              FROM consultation_exam_requests r
              JOIN consultations c ON c.id = r.consultation_id
             WHERE c.patient_id IN (?) AND r.sigtap_code IN (?) AND r.status = 'requested'
               AND c.status = 'finalized' AND r.created_at >= ?
               AND NOT EXISTS (SELECT 1 FROM consultation_exam_requests n
                                WHERE n.consultation_id = r.consultation_id AND n.sigtap_code = r.sigtap_code
                                  AND (n.created_at, n.id) > (r.created_at, r.id))
               AND NOT EXISTS (SELECT 1 FROM exam_orders x
                                WHERE x.consultation_exam_request_id = r.id AND x.status IN ('cancelled', 'denied'))
            UNION ALL
            SELECT o.patient_id, o.sigtap_code, COALESCE(o.consultation_exam_request_id, o.id) AS exam_key,
                   (o.created_at AT TIME ZONE 'UTC' AT TIME ZONE ?)::date AS on_date
              FROM exam_orders o
             WHERE o.patient_id IN (?) AND o.sigtap_code IN (?) AND o.status NOT IN ('cancelled', 'denied') AND o.created_at >= ?
            UNION ALL
            SELECT e.patient_id, e.sigtap_code, COALESCE(o.consultation_exam_request_id, o.id, e.id) AS exam_key, e.released_on AS on_date
              FROM exam_results e
              LEFT JOIN exam_orders o ON o.id = e.exam_order_id
             WHERE e.patient_id IN (?) AND e.sigtap_code IN (?) AND e.released_on >= ?
          ) exams
         GROUP BY patient_id, sigtap_code, exam_key
      SQL
      ApplicationRecord.connection.select_all(sql).cast_values.each do |patient_id, code, on|
        result[patient_id]["exam:#{code}"] << Event.new(on: on.is_a?(Date) ? on : Date.iso8601(on.to_s))
      end
    end

    # Só emite as fontes pedidas: 0301100039/0101040024 valem como PA e peso+altura
    # (se pedidas) e como procedure:<código> (se pedido).
    def procedures!(result, ids, since, codes, sources)
      return if codes.empty?

      PerformedProcedure.where(patient_id: ids, status: "recorded", sigtap_code: codes).where(performed_on: since..)
                        .pluck(:patient_id, :sigtap_code, :performed_on).each do |patient_id, code, on|
        targets = [ "procedure:#{code}" ]
        targets << "blood_pressure" if code == BP_PROCEDURE
        targets << "weight_height" if code == WH_PROCEDURE
        (targets & sources).each { |source| result[patient_id][source] << Event.new(on: on) }
      end
    end
    private_class_method :consultations!, :screenings!, :exams!, :procedures!
  end
end
