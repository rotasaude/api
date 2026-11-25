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
    MIN_SHARE = 0.5
    COLUMNS = Rails.root.join("config/medications/obm_columns.yml")
    CODE = /\A[@0-9A-Za-z]{1,25}\z/
    DESCRIPTION_MAX = 500
    SEPARATORS = [ ";", ",", "\t" ].freeze
    ATTRIBUTES = %i[vmp_code catmat_code anvisa_registration manufacturer_cnpj description].freeze

    class Invalid < StandardError; end
    class SuspiciousDrop < StandardError; end

    module_function

    def call(csv:, by:, now: Time.current)
      return Result.fail(:file_too_large, message: "limite #{MAX_BYTES} bytes", details: { path: "file" }) if csv.to_s.bytesize > MAX_BYTES

      rows = parse(csv)
      counts = PlatformRecord.transaction(requires_new: true) { apply!(rows, by, now) }
      Result.ok(**counts)
    rescue Invalid, CSV::MalformedCSVError => e
      Result.fail(:invalid_file, message: e.is_a?(Invalid) ? e.message : "csv malformado", details: { path: "file" })
    rescue SuspiciousDrop => e
      Result.fail(:suspicious_drop, message: e.message, details: { path: "file" })
    end

    def parse(csv)
      text = csv.to_s.dup.force_encoding(Encoding::UTF_8)
      raise Invalid, "arquivo não é UTF-8" unless text.valid_encoding?

      text = text.delete_prefix("﻿")
      raise Invalid, "arquivo vazio" if text.strip.empty?

      config = YAML.safe_load_file(COLUMNS)
      table = CSV.parse(text, headers: true, col_sep: separator(text), skip_blanks: true)
      index = column_index(table.headers, config)
      lines = table.each_with_index.map { |row, i| line(row, index, i + 2) }
      raise Invalid, "arquivo sem linhas" if lines.empty?

      dup = lines.map { |l| l[:ampp_code] }.tally.find { |_, n| n > 1 }
      raise Invalid, "AMPP repetida na linha #{lines.reverse.find { |l| l[:ampp_code] == dup.first }[:line]}" if dup

      lines
    end

    def separator(text) = SEPARATORS.max_by { |sep| text.lines.first.to_s.count(sep) }

    def normalize_header(header) = I18n.transliterate(header.to_s.strip).upcase.gsub(/[^A-Z0-9]+/, "_").gsub(/\A_|_\z/, "")

    # coluna lógica → posição no arquivo.
    def column_index(headers, config)
      normalized = headers.map { |header| normalize_header(header) }
      index = config.fetch("columns").to_h do |key, names|
        found = names.filter_map { |name| normalized.index(name) }.uniq
        raise Invalid, "cabeçalho repetido para #{key}" if found.size > 1

        [ key, found.first ]
      end
      missing = config.fetch("required").select { |key| index[key].nil? }
      raise Invalid, "cabeçalho faltando: #{missing.join(', ')}" if missing.any?

      index
    end

    def line(row, index, number)
      cell = ->(key) { index[key] && row[index[key]].to_s.strip.presence }
      ampp = cell.("ampp")
      vmp = cell.("vmp")
      raise Invalid, "linha #{number}: ampp inválida" unless ampp&.match?(CODE)
      raise Invalid, "linha #{number}: vmp inválido" unless vmp&.match?(CODE)

      description = cell.("descricao")
      raise Invalid, "linha #{number}: descricao ausente ou acima de #{DESCRIPTION_MAX}" if description.nil? || description.size > DESCRIPTION_MAX

      { line: number, ampp_code: ampp, vmp_code: vmp, catmat_code: catmat(cell.("catmat"), number), description: description,
        anvisa_registration: digits(cell.("registro_anvisa"), 1..13, "registro_anvisa", number),
        manufacturer_cnpj: digits(cell.("cnpj_fabricante"), 14..14, "cnpj_fabricante", number) }
    end

    def catmat(value, number)
      return nil if value.nil?

      raise Invalid, "linha #{number}: catmat inválido" unless value.match?(/\A\d{1,9}\z/) && value.to_i.positive?

      value.to_i
    end

    # Registro e CNPJ chegam com pontuação; o banco guarda só os dígitos.
    def digits(value, size, name, number)
      return nil if value.nil?

      only = value.gsub(/\D/, "")
      raise Invalid, "linha #{number}: #{name} inválido" unless size.cover?(only.size)

      only
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

    private_class_method :parse, :separator, :normalize_header, :column_index, :line, :catmat, :digits, :apply!, :link_vmp!, :actor
  end
end
