# app/services/medications/obm_import.rb
# Carga OBM (módulo 27b; contrato Q12). O portal OBM não tem API nem download
# automático: o operador baixa o arquivo e o entrega (rake
# medications:import_obm; fora de produção, também importObmCatalog). O CSV é
# lido pelo mapa de cabeçalhos de config/medications/obm_columns.yml, INTEIRO,
# antes de tocar o banco; o upsert (por AMPP), a desativação, o VMP do catálogo
# e a auditoria entram numa transação só.
#   - AMPP ausente da fonte → `active: false` (nunca apagada).
#   - `medication_catalog_items.vmp_code` vem da coluna CATMAT da apresentação;
#     a fonte sem o par não apaga o código já gravado.
#   - apresentação cujo CATMAT não casa com item ativo → `unmatched` (a lista de
#     revisão é ObmPresentation.unmatched).
#   - fonte com menos da metade das ativas → `suspicious_drop`.
# A mensagem de recusa diz coluna e linha, nunca o conteúdo do arquivo. A
# auditoria leva só o ator e as contagens.
require "csv"

module Medications
  module ObmImport
    MAX_BYTES = 5_000_000
    REJECTED_LIMIT = 20
    MIN_SHARE = 0.5
    COLUMNS = Rails.root.join("config/medications/obm_columns.yml")
    CODE = /\A[@0-9A-Za-z]{1,25}\z/
    DESCRIPTION_MAX = 500
    SEPARATORS = [ ";", ",", "\t" ].freeze
    ATTRIBUTES = %i[vmp_code catmat_code anvisa_registration manufacturer_cnpj description].freeze

    # `rejected` leva só posição e código (linha, coluna do mapa, código curto),
    # nunca o conteúdo da célula; a mensagem segue a mesma regra.
    class Invalid < StandardError
      attr_reader :rejected

      def initialize(message, rejected: [])
        super(message)
        @rejected = rejected
      end
    end
    class SuspiciousDrop < StandardError; end

    module_function

    def call(csv:, by:, now: Time.current)
      return Result.fail(:file_too_large, message: "limite #{MAX_BYTES} bytes", details: { path: "file" }) if csv.to_s.bytesize > MAX_BYTES

      rows = parse(csv)
      counts = PlatformRecord.transaction(requires_new: true) { apply!(rows, by, now) }
      Result.ok(**counts)
    rescue Invalid => e
      Result.fail(:invalid_file, message: e.message, details: { path: "file", rejected_lines: e.rejected.first(REJECTED_LIMIT) })
    rescue CSV::MalformedCSVError
      Result.fail(:invalid_file, message: "csv malformado",
                                 details: { path: "file", rejected_lines: [ rejection(1, nil, "malformed_csv") ] })
    rescue SuspiciousDrop => e
      Result.fail(:suspicious_drop, message: e.message, details: { path: "file" })
    end

    def parse(csv)
      text = csv.to_s.dup.force_encoding(Encoding::UTF_8)
      raise Invalid.new("arquivo não é UTF-8", rejected: [ rejection(1, nil, "not_utf8") ]) unless text.valid_encoding?

      text = text.delete_prefix("﻿")
      raise Invalid.new("arquivo vazio", rejected: [ rejection(1, nil, "empty_file") ]) if text.strip.empty?

      config = YAML.safe_load_file(COLUMNS)
      table = CSV.parse(text, headers: true, col_sep: separator(text), skip_blanks: true)
      index = column_index(table.headers, config)
      results = table.each_with_index.map { |row, i| line(row, index, i + 2) }
      raise Invalid.new("arquivo sem linhas", rejected: [ rejection(1, nil, "no_rows") ]) if results.empty?

      problems = results.flat_map { |result| result[:problems] }
      lines = results.filter_map { |result| result[:row] }
      problems += duplicates(lines) if problems.empty?
      raise Invalid.new(problems.first[:message], rejected: problems.map { |problem| problem.except(:message) }) if problems.any?

      lines
    end

    # Todas as repetições, na linha da segunda ocorrência em diante.
    def duplicates(lines)
      seen = Set.new
      lines.filter_map do |l|
        rejection(l[:line], "ampp", "duplicate", message: "AMPP repetida na linha #{l[:line]}") unless seen.add?(l[:ampp_code])
      end
    end

    def rejection(line, column, code, message: nil)
      { line: line, column: column, code: code }.tap { |h| h[:message] = message if message }
    end

    def separator(text) = SEPARATORS.max_by { |sep| text.lines.first.to_s.count(sep) }

    def normalize_header(header) = I18n.transliterate(header.to_s.strip).upcase.gsub(/[^A-Z0-9]+/, "_").gsub(/\A_|_\z/, "")

    # coluna lógica → posição no arquivo.
    def column_index(headers, config)
      normalized = headers.map { |header| normalize_header(header) }
      index = config.fetch("columns").to_h do |key, names|
        found = names.filter_map { |name| normalized.index(name) }.uniq
        raise Invalid.new("cabeçalho repetido para #{key}", rejected: [ rejection(1, key, "duplicate_header") ]) if found.size > 1

        [ key, found.first ]
      end
      missing = config.fetch("required").select { |key| index[key].nil? }
      if missing.any?
        raise Invalid.new("cabeçalho faltando: #{missing.join(', ')}", rejected: missing.map { |key| rejection(1, key, "missing_column") })
      end

      index
    end

    # Uma linha vira { row:, problems: }: todos os problemas dela, não só o
    # primeiro, para o operador corrigir o arquivo de uma vez.
    def line(row, index, number)
      cell = ->(key) { index[key] && row[index[key]].to_s.strip.presence }
      problems = []
      problem = lambda do |column, code, text|
        problems << rejection(number, column, code, message: "linha #{number}: #{text}")
        nil
      end

      ampp = cell.("ampp")
      vmp = cell.("vmp")
      problem.("ampp", ampp ? "invalid" : "missing", "ampp inválida") unless ampp&.match?(CODE)
      problem.("vmp", vmp ? "invalid" : "missing", "vmp inválido") unless vmp&.match?(CODE)

      description = cell.("descricao")
      if description.nil? then problem.("descricao", "missing", "descricao ausente ou acima de #{DESCRIPTION_MAX}")
      elsif description.size > DESCRIPTION_MAX then problem.("descricao", "too_long", "descricao ausente ou acima de #{DESCRIPTION_MAX}")
      end

      catmat = catmat(cell.("catmat")) || (problem.("catmat", "invalid", "catmat inválido") if cell.("catmat"))
      anvisa = digits(cell.("registro_anvisa"), 1..13) || (problem.("registro_anvisa", "invalid", "registro_anvisa inválido") if cell.("registro_anvisa"))
      cnpj = digits(cell.("cnpj_fabricante"), 14..14) || (problem.("cnpj_fabricante", "invalid", "cnpj_fabricante inválido") if cell.("cnpj_fabricante"))
      return { problems: problems } if problems.any?

      { problems: [], row: { line: number, ampp_code: ampp, vmp_code: vmp, catmat_code: catmat, description: description,
                             anvisa_registration: anvisa, manufacturer_cnpj: cnpj } }
    end

    # nil = ausente ou inválido; quem chama distingue pela célula.
    def catmat(value)
      return nil unless value&.match?(/\A\d{1,9}\z/) && value.to_i.positive?

      value.to_i
    end

    # Registro e CNPJ chegam com pontuação; o banco guarda só os dígitos.
    def digits(value, size)
      return nil if value.nil?

      only = value.gsub(/\D/, "")
      size.cover?(only.size) ? only : nil
    end

    def apply!(rows, by, now)
      existing = ObmPresentation.lock.index_by(&:ampp_code)
      active = existing.values.count(&:active)
      raise SuspiciousDrop, "lidas #{rows.size} de #{active} ativas" if active.positive? && rows.size < active * MIN_SHARE

      added = changed = 0
      rows.each do |row|
        before = existing[row[:ampp_code]]
        if before.nil? then added += 1
        elsif !before.active || ATTRIBUTES.any? { |attr| before[attr] != row[attr] } then changed += 1
        end
      end
      records = rows.map do |row|
        row.slice(:ampp_code, *ATTRIBUTES).merge(active: true, imported_at: now, created_at: now, updated_at: now)
      end
      records.each_slice(1_000) do |slice|
        ObmPresentation.upsert_all(slice, unique_by: :ampp_code, record_timestamps: false,
                                          update_only: %i[active imported_at updated_at] + ATTRIBUTES)
      end
      seen = rows.to_set { |row| row[:ampp_code] }
      stale = existing.values.select { |presentation| presentation.active && !seen.include?(presentation.ampp_code) }
      deactivated = ObmPresentation.where(id: stale.map(&:id)).update_all(active: false, updated_at: now)

      linked = link_vmp!(rows, now)
      unmatched = ObmPresentation.unmatched.count
      Platform.audit("obm_catalog.imported", actor: actor(by), added: added, changed: changed, deactivated: deactivated,
                                             unmatched: unmatched)
      { added: added, changed: changed, deactivated: deactivated, vmp_linked: linked, unmatched: unmatched }
    end

    # O VMP do item vem do CATMAT da apresentação. Só item ativo; o item que o
    # arquivo não cita fica como está. Se duas linhas do mesmo CATMAT trouxerem
    # VMP diferente, vale a primeira do arquivo.
    def link_vmp!(rows, now)
      pairs = rows.select { |row| row[:catmat_code] }.uniq { |row| row[:catmat_code] }.to_h { |row| [ row[:catmat_code], row[:vmp_code] ] }
      return 0 if pairs.empty?

      active_codes = MedicationCatalogItem.where(status: "active", catmat_code: pairs.keys).pluck(:catmat_code)
      active_codes.group_by { |code| pairs[code] }.each do |vmp, codes|
        MedicationCatalogItem.where(catmat_code: codes).where("vmp_code IS DISTINCT FROM ?", vmp)
                             .update_all(vmp_code: vmp, updated_at: now)
      end
      active_codes.size
    end

    # Quem carregou: a rake grava `system`; a mutation, `maintenance:<id>`. O
    # id do mantenedor fica na auditoria do maintenance, não aqui.
    def actor(by) = by.to_s.start_with?("maintenance:") ? "maintainer" : "system"

    private_class_method :parse, :separator, :normalize_header, :column_index, :line, :catmat, :digits, :duplicates, :rejection, :apply!, :link_vmp!, :actor
  end
end
