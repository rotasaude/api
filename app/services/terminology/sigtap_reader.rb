# Tabela Unificada SIGTAP (ADR 0028; spec 2026-10-05 §4; desvio 10): arquivos
# de largura fixa, ISO-8859-1, cada um descrito pelo `<arquivo>_layout.txt` que
# vem no mesmo ZIP. Lê só o que o módulo usa: procedimento (sexo, idades em
# meses, complexidade, quantidade máxima e permanência), CBO, CID, instrumento
# de registro e atributo complementar.
module Terminology
  class SigtapReader
    NO_LIMIT = 9999
    CODE = /\A\d{10}\z/
    CBO = /\A\d{6}\z/
    CID = /\A[A-Z]\d{2}[0-9X]?\z/
    # Módulo 31: atributos complementares do procedimento (CO_DETALHE). O nome do
    # arquivo no pacote oficial a conferir (D1); ausente = zero atributos.
    ATTRIBUTE_FILE = "rl_procedimento_detalhe"
    ATTRIBUTE_COLUMN = "CO_DETALHE"
    ATTRIBUTE = /\A\d{3}\z/
    SEXES = %w[M F I N].freeze

    def initialize(archive)
      @archive = archive
    end

    def write(release)
      registries = {}
      each_fixed("tb_registro") { |r| registries[r["CO_REGISTRO"]] = r["NO_REGISTRO"] }
      procedures = []
      each_fixed("tb_procedimento") { |r| procedures << procedure_row(release, r) }
      raise Import::Invalid, "nenhum procedimento no arquivo" if procedures.empty?

      known = procedures.to_set { |p| p[:code] }
      counts = { sigtap_procedures: Import.insert(SigtapProcedure, procedures) }
      # As tabelas de relação são as grandes: entram em lotes, sem acumular.
      counts[:sigtap_procedure_cbos] = stream("rl_procedimento_ocupacao", SigtapProcedureCbo) do |r|
        { release_id: release.id, procedure_code: known_code(known, r), cbo_code: matching(r["CO_OCUPACAO"], CBO, "CBO") }
      end
      counts[:sigtap_procedure_cids] = stream("rl_procedimento_cid", SigtapProcedureCid) do |r|
        { release_id: release.id, procedure_code: known_code(known, r), cid_code: matching(r["CO_CID"], CID, "CID"),
          principal: r["ST_PRINCIPAL"] == "S" }
      end
      counts[:sigtap_procedure_instruments] = stream("rl_procedimento_registro", SigtapProcedureInstrument) do |r|
        code = r["CO_REGISTRO"]
        name = registries.fetch(code) { raise Import::Invalid, "instrumento de registro desconhecido: #{code.inspect}" }
        { release_id: release.id, procedure_code: known_code(known, r), instrument_code: code, instrument_name: name }
      end
      counts[:sigtap_procedure_attributes] = attributes(release, known)
      counts
    end

    private

    def attributes(release, known)
      return 0 unless @archive.include?(/\A#{ATTRIBUTE_FILE}\.txt\z/i)

      stream(ATTRIBUTE_FILE, SigtapProcedureAttribute) do |r|
        { release_id: release.id, procedure_code: known_code(known, r),
          attribute_code: matching(r[ATTRIBUTE_COLUMN], ATTRIBUTE, "atributo") }
      end
    end

    def stream(base, model)
      batch = []
      total = 0
      each_fixed(base) do |r|
        batch << yield(r)
        next if batch.size < Import::BATCH

        total += Import.insert(model, batch)
        batch = []
      end
      total + Import.insert(model, batch)
    end

    def each_fixed(base)
      columns = []
      @archive.each_row(/\A#{base}_layout\.txt\z/i, col_sep: ",") do |r|
        columns << [ r["COLUNA"], Integer(r["INICIO"], 10), Integer(r["TAMANHO"], 10) ]
      end
      raise Import::Invalid, "layout vazio: #{base}" if columns.empty?

      @archive.each_line(/\A#{base}\.txt\z/i) do |line|
        yield columns.to_h { |name, start, size| [ name, line[start - 1, size].to_s.strip ] }
      end
    rescue ArgumentError, TypeError
      raise Import::Invalid, "layout ilegível: #{base}"
    end

    def procedure_row(release, r)
      code = matching(r["CO_PROCEDIMENTO"], CODE, "procedimento")
      raise Import::Invalid, "procedimento #{code} sem nome" if r["NO_PROCEDIMENTO"].blank?

      sex = r["TP_SEXO"].presence
      raise Import::Invalid, "sexo inválido em #{code}: #{sex}" unless sex.nil? || SEXES.include?(sex)

      { release_id: release.id, code: code, name: r["NO_PROCEDIMENTO"], sex: sex,
        age_min_months: age(r["VL_IDADE_MINIMA"], code), age_max_months: age(r["VL_IDADE_MAXIMA"], code),
        complexity: r["TP_COMPLEXIDADE"].presence, amount_sa_cents: amount_cents(r["VL_SA"], code),
        max_quantity: limit(r["QT_MAXIMA_EXECUCAO"], code), max_stay_days: limit(r["QT_DIAS_PERMANENCIA"], code) }
    end

    # Módulo 31: QT_MAXIMA_EXECUCAO e QT_DIAS_PERMANENCIA. 0, 9999 ou vazio = sem limite (nulo).
    def limit(value, code)
      return nil if value.nil? || value.strip.empty?

      number = Integer(value.strip, 10)
      number.zero? || number == NO_LIMIT ? nil : number
    rescue ArgumentError
      raise Import::Invalid, "limite inválido em #{code}: #{value.inspect}"
    end

    # Desvio 14: VL_SA em centavos (sem separador) quando o layout traz a coluna.
    def amount_cents(value, code)
      return nil if value.nil? || value.strip.empty?

      Integer(value.strip, 10).then { |cents| cents.positive? ? cents : nil }
    rescue ArgumentError
      raise Import::Invalid, "valor inválido em #{code}: #{value.inspect}"
    end

    def age(value, code)
      months = Integer(value.to_s, 10)
      months == NO_LIMIT ? nil : months
    rescue ArgumentError
      raise Import::Invalid, "idade inválida em #{code}: #{value.inspect}"
    end

    def known_code(known, row)
      code = row["CO_PROCEDIMENTO"]
      raise Import::Invalid, "relação aponta para procedimento ausente: #{code.inspect}" unless known.include?(code)

      code
    end

    def matching(value, pattern, label)
      raise Import::Invalid, "#{label} inválido: #{value.inspect}" unless value.to_s.match?(pattern)

      value
    end
  end
end
