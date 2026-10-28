# Sugestão de notificação da consulta (Desvio 2; contrato §4): só item `add`
# da consulta dispara — rascunho: draft_items["evaluated_problems"]; finalizada:
# consultation_problems (adendos inclusive). `evaluate`, `resolve` e
# `correct_onset` nunca. Uma sugestão por doença da lista, sem duplicidade
# (Duplicates.blocking). Só leitura: sem trilha, sem escrita.
module Surveillance
  module ConsultationSuggestions
    module_function

    # -> [ { disease: Disease, matched_code: String } ], na ordem dos itens.
    def for(consultation, today: Time.zone.today)
      diseases = Diseases.all(today: today)
      seen = {}
      added_problems(consultation).each do |terminology, code|
        disease = Matcher.disease_for(terminology, code, diseases)
        seen[disease.code] ||= { disease: disease, matched_code: code } if disease
      end
      seen.values.reject { |s| Duplicates.blocking(patient_id: consultation.patient_id, disease: s[:disease], today: today) }
    end

    # -> [ [terminology, code] ] dos problemas adicionados pela consulta.
    def added_problems(consultation)
      if consultation.draft?
        Array(consultation.draft_items["evaluated_problems"]).filter_map do |item|
          [ item["terminology"], item["code"] ] if item.is_a?(Hash) && item["action"] == "add"
        end
      else
        consultation.problem_items.where(action: "add").order(:created_at, :id).pluck(:terminology, :code)
      end
    end
  end
end
