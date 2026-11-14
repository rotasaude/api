require "open3"

# O recorte de um arquivo PMTiles pelo CLI go-pmtiles (módulo 24c, ADR 0053;
# Q12: a versão fixada pela prova técnica do campo, instalada na imagem). O
# processo é chamado por lista de argumentos, nunca por shell, e a saída dele
# não vai ao log (pode trazer a URL da build): só o código de saída.
#
# -> Result.ok | Result.fail(:extract_failed)
module FieldMaps
  module Cli
    module_function

    def extract(input:, output:, bbox:, maxzoom:)
      argv = [ Config.pmtiles_bin, "extract", input.to_s, output.to_s, "--bbox=#{bbox.join(',')}", "--maxzoom=#{maxzoom}" ]
      _output, status = Open3.capture2e(*argv)
      return Result.ok if status.success?

      Rails.logger.error("[field_maps.cli] extract failed exit=#{status.exitstatus}")
      Result.fail(:extract_failed)
    rescue SystemCallError => e
      Rails.logger.error("[field_maps.cli] extract failed error=#{e.class.name}")
      Result.fail(:extract_failed)
    end
  end
end
