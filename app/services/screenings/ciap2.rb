# app/services/screenings/ciap2.rb
# CIAP-2 da plataforma (ADR 0028) para a queixa da escuta: busca na release
# ativa; a revisão guarda o código e a release (a leitura usa a release
# gravada, mesmo depois de outra ser ativada).
module Screenings
  module Ciap2
    Code = Data.define(:code, :label, :release_id)

    module_function

    def release = TerminologyRelease.active.find_by(kind: "ciap2")

    def find(code)
      current = release
      return nil if current.nil? || code.blank?

      row = Ciap2Code.find_by(release_id: current.id, code: code.to_s.strip.upcase)
      row && Code.new(code: row.code, label: row.description, release_id: current.id)
    end

    def label(code, release_id) = Ciap2Code.find_by(release_id: release_id, code: code)&.description

    def search(query, limit: 20)
      current = release
      text = query.to_s.strip
      return [] if current.nil? || text.empty?

      folded = I18n.transliterate(text).downcase
      Ciap2Code.where(release_id: current.id).order(:code).select do |row|
        row.code.downcase.start_with?(folded) || I18n.transliterate(row.description).downcase.include?(folded)
      end.first(limit).map { |row| Code.new(code: row.code, label: row.description, release_id: current.id) }
    end
  end
end
