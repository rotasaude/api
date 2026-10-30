# Busca de procedimento SIGTAP da consulta odontológica (ADR 0046; contrato
# §16 O5, O21). Só o que a FAO aceita (dicionário FAO, #12
# procedimentosRealizados): grupos 01 a 04, o subgrupo 08.04 e os do grupo 07
# da lista de local e quantidade, sem a escuta inicial (03.01.04.007-9). Por
# código (prefixo) ou nome sem acento, na release SIGTAP ativa da competência
# corrente; até 20, em ordem de código. Cada item leva o local e o máximo da
# FAO, se o TSB/ASB pode registrar e se é prótese.
module DentalCare
  module ProcedureSearch
    GROUPS = %w[01 02 03 04].freeze
    SUBGROUPS = %w[0804].freeze
    LIMIT = 20
    # Busca por código só quando o termo não tem letra (ex.: "07.01.07.012-9").
    CODE_QUERY = /\A[\d.\-\s]+\z/

    module_function

    def release(on: Time.zone.today) = Terminology::Sigtap.release_for(on.strftime("%Y%m"))

    def searchable?(code)
      code = code.to_s
      return false if Catalog::PROHIBITED_PROCEDURES.include?(code)

      GROUPS.include?(code[0, 2]) || SUBGROUPS.include?(code[0, 4]) || (code.start_with?("07") && ProcedureLimits.entry(code).present?)
    end

    # nil sem release ativa.
    def call(query, on: Time.zone.today)
      current = release(on: on)
      return nil unless current

      text = query.is_a?(String) ? query.strip : ""
      return [] if text.empty?

      folded = ClinicalTerms.fold(text)
      digits = text.match?(CODE_QUERY) ? text.delete("^0-9") : ""
      found = index(current).select { |code, _, plain| (digits.present? && code.start_with?(digits)) || plain.include?(folded) }.first(LIMIT)
      auxiliary = DentalAuxiliaryProcedure.where(procedure_code: found.map(&:first)).pluck(:procedure_code)
      found.map { |code, name, _| item(code, name, auxiliary.include?(code)) }
    end

    def item(code, name, auxiliary)
      { sigtap: code, name: name, locations: ProcedureLimits.locations(code), max_quantity: ProcedureLimits.max(code),
        auxiliary_allowed: auxiliary, prosthesis: Catalog::PROSTHESIS_CODES.include?(code) }
    end

    # A release ativa é imutável: o índice (código, nome, nome sem acento) por release.
    def index(release)
      @index ||= {}
      @index[release.id] ||= SigtapProcedure.where(release_id: release.id).order(:code).pluck(:code, :name)
                                            .select { |code, _| searchable?(code) }
                                            .map { |code, name| [ code, name, ClinicalTerms.fold(name) ].freeze }.freeze
    end
    private_class_method :item, :index
  end
end
