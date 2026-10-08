# app/services/consultations/effective.rb
# O que vale da consulta depois dos adendos (ADR 0031; Desvio 6): a última
# linha de cada problema; condutas acrescentadas menos as removidas; exames
# pedidos menos os cancelados — na ordem em que entraram. É o que a ficha leva.
module Consultations
  module Effective
    module_function

    def call(consultation)
      problems = consultation.problem_items.order(:created_at, :id).to_a.group_by(&:patient_problem_id).values.map(&:last)
      conducts = consultation.conducts.order(:created_at, :id).each_with_object([]) do |row, acc|
        row.action == "add" ? (acc << row.code unless acc.include?(row.code)) : acc.delete(row.code)
      end
      exams = consultation.exam_requests.order(:created_at, :id).each_with_object({}) do |row, acc|
        row.status == "requested" ? acc[row.sigtap_code] = row : acc.delete(row.sigtap_code)
      end
      { problems: problems, conducts: conducts, exam_requests: exams.values }
    end
  end
end
