# Indicadores B1 e B2 da eSB (ADR 0046; spec decisão 13 e "Equipes de saúde
# bucal"; contrato §16 O15; regras em config/dental/indicators.yml).
# `period = "AAAA-MM"`: a janela são os 12 meses que terminam no fim do mês
# (fuso da cidade). Consulta da equipe: `dental` finalizada, não `baseline`,
# na unidade da eSB, de profissional membro da eSB na data e com CBO do B1;
# paciente com CPF ou CNS válido.
# B1 = pares distintos (paciente, profissional) com tipo de consulta 1;
# denominador = população da eSF/eAP associada (CareLines::TeamPopulation),
# nil sem associada ou com associada inativa. B2 = pacientes do B1 com
# desfecho 15 em consulta da equipe a partir da primeira consulta; denominador
# = pacientes do B1. Só contagens: nada do paciente sai daqui.
module DentalCare
  module Indicators
    PATH = Rails.root.join("config/dental/indicators.yml")

    module_function

    def config = (@config ||= YAML.load_file(PATH).freeze)

    def call(team:, period:)
      rows = consultations(team, window(period))
      b1 = rows.select { |row| row[:type] == config.dig("b1", "consultation_type") }
      firsts = b1.group_by { |row| row[:patient_id] }.transform_values { |list| list.map { |row| row[:at] }.min }
      outcome = config.dig("b2", "outcome")
      completed = rows.select { |row| row[:outcomes].include?(outcome) && firsts[row[:patient_id]] && row[:at] >= firsts[row[:patient_id]] }
      { b1: { numerator: b1.map { |row| row.values_at(:patient_id, :professional_id) }.uniq.size, denominator: population(team) },
        b2: { numerator: completed.map { |row| row[:patient_id] }.uniq.size, denominator: firsts.size } }
    end

    # Início do mês 11 meses antes até o início do mês seguinte.
    def window(period)
      last = Date.new(*period.split("-").map(&:to_i), 1)
      first = last << (config.dig("b1", "window_months") - 1)
      first.in_time_zone...last.next_month.in_time_zone
    end

    def population(team)
      associated = team.associated_team
      return nil unless associated&.active

      CareLines::TeamPopulation.members(team: associated).values.sum(&:size)
    end

    # Consultas da equipe na janela, de pacientes com CPF ou CNS válido.
    def consultations(team, range)
      local_date = "((consultations.finalized_at AT TIME ZONE 'UTC') AT TIME ZONE #{Consultation.connection.quote(Time.zone.tzinfo.name)})::date"
      member = ApplicationRecord.sanitize_sql([ <<~SQL, team.id, Time.zone.today ])
        EXISTS (SELECT 1 FROM health_team_members m
                 WHERE m.health_team_id = ? AND m.professional_id = professional_links.professional_id
                   AND m.started_on <= #{local_date} AND #{local_date} <= COALESCE(m.ended_on, ?))
      SQL
      rows = Consultation.joins(:attendance, :professional_link)
                         .where(kind: "dental", status: "finalized", baseline: false, finalized_at: range,
                                cbo_code: config.dig("b1", "cbos"), attendances: { health_unit_id: team.health_unit_id })
                         .where(member)
                         .pluck(:patient_id, "professional_links.professional_id", :dental_consultation_type, :dental_outcomes, :finalized_at)
                         .map { |patient_id, professional_id, type, outcomes, at| { patient_id:, professional_id:, type:, outcomes:, at: } }
      identified = identified(rows.map { |row| row[:patient_id] }.uniq)
      rows.select { |row| identified.include?(row[:patient_id]) }
    end

    # CPF e CNS são cifrados: a conta do dígito é feita aqui.
    def identified(patient_ids)
      Patient.where(id: patient_ids).pluck(:id, :cpf, :cns).filter_map do |id, cpf, cns|
        id if CitizenIdentity::Cpf.normalize(cpf) || Professionals::Cns.valid?(cns)
      end.to_set
    end
  end
end
