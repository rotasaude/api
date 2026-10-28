# Alvos reguláveis do módulo 26a (ADR 0044; contrato §13 G3, G11, G12 #6).
#
# - Especialidade: linha de config/regulation/specialties.yml (nome = `label`).
# - Procedimento: da release SIGTAP ativa da competência, regulável quando o
#   grupo está em procedures.yml `groups` (02–04) E algum instrumento está em
#   `bpa_instruments` (01/02). A APAC principal não exclui (G11).
# - Exame ativo no catálogo do 21a (grupo 02) segue pelo pedido de exame: 422
#   invalid_target com hint "exam_order" (G3).
module CareRegulation
  module Targets
    SPECIALTIES_PATH = Rails.root.join("config/regulation/specialties.yml")
    PROCEDURES_PATH = Rails.root.join("config/regulation/procedures.yml")
    MIN_QUERY = 3
    EXAM_GROUP = "02".freeze

    module_function

    # -> Result.ok(target:) | fail(:invalid_target, details: { path: "target_code"[, hint: "exam_order"] })
    def resolve(type:, code:, on: Time.zone.today)
      return invalid unless code.is_a?(String)

      case type
      when "specialty" then (target = specialty(code)) ? Result.ok(target: target) : invalid
      when "procedure" then resolve_procedure(code, on)
      else invalid
      end
    end

    # Especialidade sem `query` = todas, por nome. Procedimento exige `query`
    # com 3+ caracteres (senão []): código por prefixo ou nome dobrado
    # (ClinicalTerms.fold), só reguláveis.
    def search(type:, query:, on: Time.zone.today, limit: 20)
      text = query.is_a?(String) ? query.strip : ""
      case type
      when "specialty" then search_specialties(text, limit)
      when "procedure" then search_procedures(text, on, limit)
      else []
      end
    end

    # Nome do alvo para listar a configuração (lista do enfermeiro), mesmo
    # que ele não seja mais regulável; nil quando não existe.
    def name_for(type:, code:, on: Time.zone.today)
      return specialty(code)&.name if type == "specialty"
      return nil unless type == "procedure"

      release = Terminology::Sigtap.release_for(on.strftime("%Y%m"))
      release && SigtapProcedure.find_by(release_id: release.id, code: code)&.name
    end

    def specialties
      @specialties ||= YAML.safe_load_file(SPECIALTIES_PATH).fetch("specialties").map do |row|
        Target.new(type: "specialty", code: row.fetch("code"), name: row.fetch("label"), group: row.fetch("group"),
                   label: row.fetch("label"))
      end.freeze
    end

    def rules = (@rules ||= YAML.safe_load_file(PROCEDURES_PATH).slice("groups", "bpa_instruments").freeze)

    def specialty(code) = specialties.find { |target| target.code == code }

    def resolve_procedure(code, on)
      return invalid unless code.match?(Catalog::PROCEDURE_CODE)
      return invalid(hint: "exam_order") if exam_catalog?(code)

      release = Terminology::Sigtap.release_for(on.strftime("%Y%m"))
      return invalid unless release && rules.fetch("groups").include?(code[0, 2])

      procedure = SigtapProcedure.find_by(release_id: release.id, code: code)
      bpa = SigtapProcedureInstrument.exists?(release_id: release.id, procedure_code: code, instrument_code: rules.fetch("bpa_instruments"))
      return invalid unless procedure && bpa

      Result.ok(target: Target.new(type: "procedure", code: code, name: procedure.name, group: "procedure", label: procedure.name))
    end

    def exam_catalog?(code) = code[0, 2] == EXAM_GROUP && ExamCatalogItem.exists?(sigtap_code: code, active: true)

    def search_specialties(text, limit)
      terms = ClinicalTerms.fold(text).split
      found = specialties.select do |target|
        folded = ClinicalTerms.fold(target.name)
        terms.all? { |term| folded.include?(term) } || (text.match?(/\A\d+\z/) && target.code.start_with?(text))
      end
      found.sort_by { |target| ClinicalTerms.fold(target.name) }.first(limit)
    end

    def search_procedures(text, on, limit)
      return [] if text.length < MIN_QUERY

      release = Terminology::Sigtap.release_for(on.strftime("%Y%m"))
      return [] unless release

      rows = procedure_index(release)
      matched = if text.match?(/\A\d+\z/)
                  rows.select { |code, _name, _folded| code.start_with?(text) }
                else
                  terms = ClinicalTerms.fold(text).split
                  rows.select { |_code, _name, folded| terms.all? { |term| folded.include?(term) } }
                end
      matched.first(limit).map do |code, name, _folded|
        Target.new(type: "procedure", code: code, name: name, group: "procedure", label: name)
      end
    end

    # [código, nome, nome dobrado] dos procedimentos reguláveis da release
    # (imutável depois de ativa), por nome; em memória como o ClinicalTerms.
    def procedure_index(release)
      @procedure_index ||= {}
      @procedure_index[release.id] ||= begin
        regulable = SigtapProcedureInstrument.where(release_id: release.id, instrument_code: rules.fetch("bpa_instruments"))
                                             .select(:procedure_code)
        SigtapProcedure.where(release_id: release.id).where("substr(code, 1, 2) IN (?)", rules.fetch("groups"))
                       .where(code: regulable).pluck(:code, :name)
                       .map { |code, name| [ code, name, ClinicalTerms.fold(name) ] }
                       .sort_by { |code, _name, folded| [ folded, code ] }.freeze
      end
    end

    def invalid(hint: nil)
      Result.fail(:invalid_target, details: { path: "target_code", hint: hint }.compact)
    end
    private_class_method :specialty, :resolve_procedure, :exam_catalog?, :search_specialties, :search_procedures,
                         :procedure_index, :invalid, :rules
  end
end
