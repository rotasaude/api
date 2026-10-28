# CSV semanal da vigilância (módulo 25; contrato §7, K7, K10): uma linha por
# notificação com `suspected_on` na semana epidemiológica (a da SUSPEITA),
# fora de possible/dismissed (a mesma regra de WeekCases). UTF-8 com BOM e `;`
# (Excel pt-BR), cabeçalho fixo. Sem CPF; do CNS só os 4 últimos dígitos.
# Toda célula passa por Exams::Report.safe_cell (injeção de fórmula). A saída
# é a lista nominal da semana: quem chama grava a trilha (Trail.listed!).
require "csv"

module Surveillance
  module Csv
    HEADER = %w[semana notificacao_id data_notificacao data_primeiros_sintomas doenca_codigo doenca cid10_ficha prazo situacao
                classificacao numero_oficial unidade_cnes unidade paciente cns_final sexo nascimento bairro
                residente_outro_municipio ibge_residencia].freeze
    BOM = "﻿".freeze
    SEPARATOR = ";".freeze

    module_function

    # week: Surveillance::EpiWeek -> { csv: String, ids: [uuid] }
    def build(week:)
      diseases = Diseases.all.index_by(&:code)
      rows = DiseaseNotification.where(suspected_on: week.range).where.not(status: WeekCases::NOT_A_CASE)
                                .includes(:patient, :health_unit, :neighborhood).order(:suspected_on, :created_at, :id).to_a
      text = CSV.generate(col_sep: SEPARATOR, row_sep: "\r\n") do |csv|
        csv << HEADER
        rows.each { |n| csv << row(n, week, diseases).map { |cell| Exams::Report.safe_cell(cell) } }
      end
      { csv: BOM + text, ids: rows.map(&:id) }
    end

    def call(week:) = build(week: week).fetch(:csv)

    def row(n, week, diseases)
      patient = n.patient
      [ week.to_s, n.id, date(n.suspected_on), date(n.symptoms_on), n.disease_code, Json.disease(n, diseases).fetch(:name),
        Array(diseases[n.disease_code]&.cid10).join(","), n.deadline, n.status, n.classification, n.official_number,
        n.unit_cnes, n.health_unit.name, patient.display_name, patient.cns.to_s.last(4),
        Catalog::SEX_TO_SINAN.fetch(patient.sex.to_s, "I"), birth(patient), n.neighborhood&.name,
        n.resident_elsewhere ? "sim" : "não", n.residence_ibge ]
    end

    def date(value) = value&.strftime("%d/%m/%Y")

    def birth(patient)
      date(Date.iso8601(patient.birth_date.to_s))
    rescue Date::Error
      nil
    end
    private_class_method :row, :date, :birth
  end
end
