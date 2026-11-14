# Mapa offline de um município (módulo 24c, ADR 0053; contrato §3.1, Q30). Uma
# linha por cidade, na plataforma. `state` é o da última geração; o arquivo
# publicado (version, size_bytes, sha256, storage_key, built_at) segue valendo
# enquanto a geração nova roda (`building`) ou falha (`failed`). Nenhum dado de
# pessoa: o arquivo é um recorte do OpenStreetMap.
class FieldMap < PlatformRecord
  belongs_to :city

  validates :state, inclusion: { in: FieldMaps::Catalog::STATES }
  validates :error_code, inclusion: { in: FieldMaps::Catalog::ERROR_CODES }, allow_nil: true

  # A linha da cidade, se já tem arquivo publicado.
  def self.published_for(city_id) = where(city_id: city_id).where.not(storage_key: nil).first

  def published? = storage_key.present?

  # O `map` da sessão do app (session-response-v1); nil sem arquivo publicado.
  def manifest
    return nil unless published?

    { version: version.iso8601, size_bytes: size_bytes, sha256: sha256 }
  end

  def inspect = "#<FieldMap city_id=#{city_id} state=#{state}>"
  alias_method :to_s, :inspect
  def pretty_print(pp) = pp.text(inspect)
end
