# app/services/terminology/cid10_reader.rb
# CID-10 do DATASUS (ADR 0028; desvio 10): CID-10-CATEGORIAS.CSV (3 caracteres)
# e CID-10-SUBCATEGORIAS.CSV (4 caracteres, com RESTRSEXO), ";" e ISO-8859-1.
module Terminology
  class Cid10Reader
    CODE = /\A[A-Z]\d{2}[0-9X]?\z/

    def initialize(archive)
      @archive = archive
    end

    def write(release)
      rows = []
      @archive.each_row(/\ACID-10-CATEGORIAS\.CSV\z/i) { |r| rows << row(release, r["CAT"], r["DESCRICAO"], nil) }
      @archive.each_row(/\ACID-10-SUBCATEGORIAS\.CSV\z/i) { |r| rows << row(release, r["SUBCAT"], r["DESCRICAO"], r["RESTRSEXO"]) }
      raise Import::Invalid, "nenhum código CID-10 no arquivo" if rows.empty?

      { cid10_codes: Import.insert(Cid10Code, rows) }
    end

    private

    def row(release, code, description, sex)
      code = code.to_s.strip.upcase
      raise Import::Invalid, "código CID-10 inválido: #{code.inspect}" unless code.match?(CODE)
      raise Import::Invalid, "descrição vazia em #{code}" if description.to_s.strip.empty?

      sex = sex.to_s.strip.upcase.presence
      raise Import::Invalid, "restrição de sexo inválida em #{code}: #{sex}" unless sex.nil? || %w[F M].include?(sex)

      { release_id: release.id, code: code, description: description.strip, sex_restriction: sex }
    end
  end
end
