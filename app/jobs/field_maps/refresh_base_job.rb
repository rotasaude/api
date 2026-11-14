# Atualiza a base de onde saem os mapas por município (módulo 24c, ADR 0053;
# Q23, Q32). Job de plataforma, pedido pelo maintenance (não há job
# recorrente: o maintenance avisa quando a base passa de 90 dias).
#
# Lê o índice de builds do Protomaps, recorta a caixa de config/field_maps.yml
# da build mais recente com o CLI (por intervalos HTTP, sem baixar o planeta),
# guarda o arquivo no serviço de arquivos e, só com a nova pronta, apaga a
# anterior. Falha → linha `failed` (`base_missing` sem índice ou sem build;
# `extract_failed` no recorte), e a base pronta anterior continua valendo.
module FieldMaps
  class RefreshBaseJob < ApplicationJob
    queue_as :default

    def perform
      return if FieldMapBase.exists?(state: "copying")

      build = Builds.latest
      return missing! unless build

      base = FieldMapBase.find_or_initialize_by(version: build[:version])
      return if base.ready?

      base.update!(state: "copying", error_code: nil, source_url: build[:url])
      copy!(base, build)
    end

    private

    def copy!(base, build)
      path = Config.cache_dir.join("base", "#{base.version.iso8601}.pmtiles")
      FileUtils.mkdir_p(path.dirname)
      result = Cli.extract(input: build[:url], output: path, bbox: Config.base_bbox, maxzoom: Catalog::MAXZOOM)
      return failed!(base, path) if result.failure?

      key = format(Catalog::KEY_BASE, version: base.version.iso8601)
      Storage.upload(key, path)
      previous = FieldMapBase.where(state: "ready").where.not(id: base.id).to_a
      base.update!(state: "ready", storage_key: key, size_bytes: File.size(path), sha256: Digest::SHA256.file(path).hexdigest,
                   ready_at: Time.current)
      previous.each { |old| discard!(old) }
    rescue StandardError => e
      Rails.logger.error("[field_maps.refresh_base] failed error=#{e.class.name}")
      failed!(base, path)
    end

    # A base anterior sai do serviço de arquivos, do cache local e da tabela.
    def discard!(old)
      Storage.delete(old.storage_key)
      FileUtils.rm_f(Config.cache_dir.join("base", "#{old.version.iso8601}.pmtiles"))
      old.destroy!
    end

    def failed!(base, path)
      FileUtils.rm_f(path)
      base.update!(state: "failed", error_code: "extract_failed", storage_key: nil, size_bytes: nil, sha256: nil, ready_at: nil)
    end

    # Sem índice não há versão: a falha fica na linha do dia, salvo se a base
    # de hoje já está pronta.
    def missing!
      base = FieldMapBase.find_or_initialize_by(version: Time.zone.today)
      return if base.ready?

      base.update!(state: "failed", error_code: "base_missing", source_url: Config.builds_index_url)
    end
  end
end
