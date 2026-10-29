# CSV livre para digitar no sistema do estado (módulo 26a; contrato §8, §13 G8,
# G10, G12): uma linha por pedido na situação pedida (padrão `external`).
# UTF-8 com BOM, `;` e `\r\n` (Excel pt-BR), cabeçalho fixo, datas dd/mm/aaaa.
# Sem CPF; do CNS só os 4 últimos dígitos. Mostra o CID-10 ou o CIAP-2 que o
# pedido tiver (a outra célula vazia). Toda célula passa por
# Exams::Report.safe_cell (injeção de fórmula). A saída é a lista nominal: quem
# chama grava a trilha de lista (Trail.listed!) com os ids.
require "csv"

module CareRegulation
  module StateCsv
    HEADER = %w[pedido_id data_pedido situacao tipo codigo_alvo alvo cor prazo cid10 ciap2 justificativa paciente cns_final nascimento
                sexo unidade_solicitante unidade_cnes solicitante solicitante_cbo sistema_externo numero_externo].freeze
    BOM = "﻿".freeze
    SEPARATOR = ";".freeze
    DEFAULT_STATUS = "external".freeze
    SEX = { "male" => "M", "female" => "F" }.freeze

    module_function

    # status: um de QUEUE_STATUSES (quem chama valida) -> { csv: String, ids: [uuid] }
    def build(status: DEFAULT_STATUS)
      rows = RegulationRequest.where(status: status).preload(:patient, :requester_unit, requester_user: :professional)
                              .order(:requested_at, :id).to_a
      text = CSV.generate(col_sep: SEPARATOR, row_sep: "\r\n") do |csv|
        csv << HEADER
        rows.each { |r| csv << row(r).map { |cell| Exams::Report.safe_cell(cell) } }
      end
      { csv: BOM + text, ids: rows.map(&:id) }
    end

    def row(r)
      patient = r.patient
      [ r.id, date(r.requested_at&.in_time_zone), r.status, r.target_type, r.target_code, r.target_name, r.effective_color,
        date(r.due_on), r.cid10, r.ciap2, r.justification, patient.display_name, patient.cns.to_s.gsub(/\D/, "").last(4),
        birth(patient), SEX.fetch(patient.sex.to_s, "I"), r.requester_unit.name, r.requester_unit.cnes,
        Screenings::Json.staff_name(r.requester_user), r.requester_cbo, r.external_system, r.external_number ]
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
