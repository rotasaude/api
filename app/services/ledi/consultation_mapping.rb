# app/services/ledi/consultation_mapping.rb
# Mapeamento da consulta da APS para o LEDI (ADR 0031; spec §6, Tarefa 1). O
# YAML guarda valor e fonte de cada linha; quem valida itens e monta a ficha lê
# daqui, nunca de literal solto. Carregado uma vez por processo.
module Ledi
  module ConsultationMapping
    PATH = Rails.root.join("config/ledi/consultation_mapping.yml")

    class Missing < StandardError; end

    module_function

    def data = (@data ||= YAML.load_file(PATH).freeze)

    def entry(key) = data.fetch("entries").fetch(key.to_s) { raise Missing, key.to_s }

    def value(key) = entry(key).fetch("value")

    def care_types = coded("care_types")
    def conducts = coded("conducts")

    def care_type?(code) = code.is_a?(Integer) && care_types.any? { |t| t[:code] == code }
    def conduct?(code) = code.is_a?(Integer) && conducts.any? { |c| c[:code] == code }
    def care_type_label(code) = care_types.find { |t| t[:code] == code }&.dig(:label)
    def conduct_label(code) = conducts.find { |c| c[:code] == code }&.dig(:label)

    def situation(status) = value("problem_situation.#{status}")
    def exam_requested = value("exam.requested")
    def exam_group_prefix = value("exam.sigtap_group_prefix")
    def max_exams = value("exam.max_per_ficha")
    def max_conducts = value("conducts.max")
    def local_de_atendimento = value("local_de_atendimento")

    def cid10_allowed?(cbo)
      rule = data.fetch("cid10_cbos")
      case rule.fetch("rule")
      when "physicians_only"
        # Só médicos; e o CBO precisa poder registrar o MIAI (coerência com o módulo 18).
        Array(rule["prefixes"]).any? { |prefix| cbo.to_s.start_with?(prefix) } && Ledi::ScreeningMapping.miai_cbo?(cbo)
      else raise Missing, "cid10_cbos.rule"
      end
    end

    def coded(key)
      data.fetch(key).fetch("codes").map { |row| { code: row.fetch("code"), label: row.fetch("label") } }
    end
    private_class_method :coded
  end
end
