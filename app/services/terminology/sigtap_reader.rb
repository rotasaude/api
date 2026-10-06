# Tabela Unificada SIGTAP (ADR 0028; spec 2026-10-05 §4; desvio 10): arquivos
# de largura fixa, ISO-8859-1, cada um descrito pelo `<arquivo>_layout.txt` que
# vem no mesmo ZIP. Lê só o que o módulo usa: procedimento (sexo, idades em
# meses, complexidade), CBO, CID e instrumento de registro.
module Terminology
  class SigtapReader
    NO_LIMIT = 9999
    CODE = /\A\d{10}\z/
    CBO = /\A\d{6}\z/
    CID = /\A[A-Z]\d{2}[0-9X]?\z/
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
      counts
    end

    private

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
        complexity: r["TP_COMPLEXIDADE"].presence }
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
