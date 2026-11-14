# Gera o mapa offline de uma cidade (módulo 24c, ADR 0053; contrato §3.1;
# Q24, Q30–Q33). Job de plataforma: abre a cidade só para ler o IBGE do
# perfil (CityConnection.with), nunca atribui Current.city.
#
# Recorta, da base guardada, a caixa do município (IBGE vendorizado) mais 2 km.
# O arquivo publicado só troca depois que o novo está no serviço de arquivos, e
# o antigo só sai depois da troca: o app que está baixando nunca fica sem
# arquivo. Conteúdo igual ao publicado não sobe nem apaga nada. Qualquer falha
# deixa o publicado anterior servindo, com a linha em `failed`.
#
# Eventos de plataforma só com city_id, version, size_bytes, sha256 e
# error_code. O arquivo é um recorte do OpenStreetMap: nenhum dado de pessoa.
module FieldMaps
  class BuildJob < ApplicationJob
    queue_as :default

    def perform(city_id)
      city = City.find(city_id)
      map = FieldMap.find_by(city_id: city.id) || FieldMap.create!(city_id: city.id, state: "building", requested_at: Time.current)
      build!(map, city)
    rescue StandardError => e
      # Só a classe: a mensagem pode trazer caminho ou URL.
      Rails.logger.error("[field_maps.build] failed city_id=#{city_id} error=#{e.class.name}")
      failed!(map, "extract_failed") if map
    end

    private

    def build!(map, city)
      base = FieldMapBase.current
      return failed!(map, "base_missing") unless base

      ibge_code = CityConnection.with(city) { CityProfile.current&.ibge_code }
      box = Boundaries.bbox(ibge_code)
      return failed!(map, "boundary_missing") unless box

      Dir.mktmpdir("field-map", tmp_dir) do |dir|
        output = File.join(dir, "city.pmtiles")
        result = Cli.extract(input: local_base(base), output: output, bbox: Boundaries.with_margin(box), maxzoom: Catalog::MAXZOOM)
        next failed!(map, "extract_failed") if result.failure?

        publish!(map, base, output)
      end
    end

    def publish!(map, base, output)
      sha = Digest::SHA256.file(output).hexdigest
      if map.published? && map.sha256 == sha
        map.update!(state: "ready", error_code: nil, built_at: Time.current)
      else
        key = format(Catalog::KEY_CITY, city_id: map.city_id, version: base.version.iso8601, sha12: sha[0, 12])
        Storage.upload(key, output)
        old = map.storage_key
        map.update!(state: "ready", error_code: nil, version: base.version, size_bytes: File.size(output), sha256: sha,
                    storage_key: key, built_at: Time.current)
        Storage.delete(old) if old && old != key
      end
      Platform.audit("field_map.built", city_id: map.city_id, version: map.version.iso8601, size_bytes: map.size_bytes, sha256: map.sha256)
    end

    def failed!(map, error_code)
      map.update!(state: "failed", error_code: error_code)
      Platform.audit("field_map.failed", city_id: map.city_id, error_code: error_code)
    end

    # A base no cache local do worker, conferida pelo SHA-256 (Q32): ausente ou
    # diferente, baixa de novo do serviço de arquivos.
    def local_base(base)
      path = Config.cache_dir.join("base", "#{base.version.iso8601}.pmtiles")
      return path.to_s if path.exist? && Digest::SHA256.file(path).hexdigest == base.sha256

      Storage.fetch_to(base.storage_key, path.to_s)
      raise "base com SHA-256 diferente do registrado" unless Digest::SHA256.file(path).hexdigest == base.sha256

      path.to_s
    end

    def tmp_dir = Config.cache_dir.join("tmp").tap { |dir| FileUtils.mkdir_p(dir) }.to_s
  end
end
