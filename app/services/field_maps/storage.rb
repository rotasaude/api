# O arquivo de mapa no serviço do Active Storage (MinIO em produção, Disk em
# teste), escrito e lido por CHAVE (módulo 24c, ADR 0053). Sem
# ActiveStorage::Blob: nada em active_storage_blobs, e a entrega lê só o
# intervalo pedido, nunca o objeto inteiro.
module FieldMaps
  module Storage
    module_function

    def service = ActiveStorage::Blob.service

    def upload(key, path)
      File.open(path, "rb") { |file| service.upload(key, file, checksum: nil) }
    end

    # Os bytes do intervalo (Range de inteiros, fim inclusivo).
    def chunk(key, range) = service.download_chunk(key, range)

    # Baixa o objeto inteiro para o arquivo, em blocos.
    def fetch_to(key, path)
      FileUtils.mkdir_p(File.dirname(path))
      File.open(path, "wb") { |file| service.download(key) { |part| file.write(part) } }
    end

    def delete(key) = service.delete(key)
    def exist?(key) = service.exist?(key)
  end
end
