# app/services/clinical_terms.rb
# CIAP-2 e CID-10 da plataforma (ADR 0028/0031) para problemas da consulta:
# a release ativa; o item guarda o código e a release (a leitura usa a
# gravada). CID-10 sem ponto e maiúsculo ("E11.9" → "E119"). A busca filtra em
# Ruby um índice dobrado (sem acento, minúsculo) por release, em memória.
module ClinicalTerms
  Code = Data.define(:terminology, :code, :label, :release_id)
  MODELS = { "ciap2" => "Ciap2Code", "cid10" => "Cid10Code" }.freeze

  module_function

  def release(terminology)
    return nil unless MODELS.key?(terminology.to_s)

    TerminologyRelease.active.where(kind: terminology.to_s).order(activated_at: :desc, id: :desc).first
  end

  def find(terminology, code)
    current = release(terminology)
    return nil if current.nil? || !code.is_a?(String) || code.blank?

    row = model(terminology).find_by(release_id: current.id, code: normalize(code))
    row && Code.new(terminology: terminology.to_s, code: row.code, label: row.description, release_id: current.id)
  end

  def label(terminology, code, release_id)
    return nil unless MODELS.key?(terminology.to_s)

    model(terminology).find_by(release_id: release_id, code: code)&.description
  end

  def cid10_sex(code, release_id) = Cid10Code.find_by(release_id: release_id, code: code)&.sex_restriction

  def search(terminology, query, limit: 20)
    current = release(terminology)
    text = query.is_a?(String) ? query.strip : ""
    return [] if current.nil? || text.empty?

    folded = fold(text)
    plain = folded.delete(".")
    index(terminology, current).select { |code, _label, label_folded| code.downcase.start_with?(plain) || label_folded.include?(folded) }
                               .first(limit)
                               .map { |code, label, _| Code.new(terminology: terminology.to_s, code: code, label: label, release_id: current.id) }
  end

  def normalize(code) = code.to_s.strip.upcase.delete(".")
  def fold(text) = I18n.transliterate(text.to_s).downcase
  def model(terminology) = MODELS.fetch(terminology.to_s).constantize

  def index(terminology, release)
    @index ||= {}
    @index[release.id] ||= model(terminology).where(release_id: release.id).order(:code).pluck(:code, :description)
                                             .map { |code, label| [ code, label, fold(label) ] }.freeze
  end
  private_class_method :model, :index
end
