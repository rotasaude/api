# app/services/clinical_terms/sigtap_exams.rb
# Exames solicitáveis (ADR 0031; Task 1): procedimento SIGTAP do grupo 02 na
# release ativa da competência corrente (Terminology::Sigtap.release_for). O
# pedido guarda o código e a competência.
module ClinicalTerms
  module SigtapExams
    Exam = Data.define(:code, :label, :competence)

    module_function

    def release(on:) = Terminology::Sigtap.release_for(on.strftime("%Y%m"))

    def find(code, on:)
      current = release(on: on)
      return nil if current.nil? || !code.is_a?(String)

      digits = code.delete("^0-9")
      return nil unless digits.match?(/\A\d{10}\z/) && digits.start_with?(Ledi::ConsultationMapping.exam_group_prefix)

      row = SigtapProcedure.find_by(release_id: current.id, code: digits)
      row && Exam.new(code: row.code, label: row.name, competence: current.version)
    end

    def label(code, competence)
      current = Terminology::Sigtap.release_for(competence)
      current && SigtapProcedure.find_by(release_id: current.id, code: code)&.name
    end

    def search(query, on:, limit: 20)
      current = release(on: on)
      text = query.is_a?(String) ? query.strip : ""
      return [] if current.nil? || text.empty?

      folded = ClinicalTerms.fold(text)
      digits = text.delete("^0-9")
      SigtapProcedure.where(release_id: current.id).where("code LIKE ?", "#{Ledi::ConsultationMapping.exam_group_prefix}%")
                     .order(:code).pluck(:code, :name)
                     .select { |code, name| (digits.present? && code.start_with?(digits)) || ClinicalTerms.fold(name).include?(folded) }
                     .first(limit).map { |code, name| Exam.new(code: code, label: name, competence: current.version) }
    end
  end
end
