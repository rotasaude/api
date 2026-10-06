# app/services/terminology/ciap2_reader.rb
# CIAP-2 (ADR 0028; desvio 10): CSV `codigo;titulo`, UTF-8.
module Terminology
  class Ciap2Reader
    CODE = /\A[A-Z]\d{2}\z/

    def initialize(archive)
      @archive = archive
    end

    def write(release)
      rows = []
      @archive.each_row(/\Aciap2\.csv\z/i, encoding: "UTF-8") do |r|
        code = r["CODIGO"].to_s.strip.upcase
        raise Import::Invalid, "código CIAP-2 inválido: #{code.inspect}" unless code.match?(CODE)
        raise Import::Invalid, "título vazio em #{code}" if r["TITULO"].to_s.strip.empty?

        rows << { release_id: release.id, code: code, description: r["TITULO"].strip }
      end
      raise Import::Invalid, "nenhum código CIAP-2 no arquivo" if rows.empty?

      { ciap2_codes: Import.insert(Ciap2Code, rows) }
    end
  end
end
