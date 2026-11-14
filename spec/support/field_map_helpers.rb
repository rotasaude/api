# Módulo 24c: mapa de campo publicado para os specs (o fixture no serviço de
# arquivos de teste e a linha `field_maps` apontando para ele).
module FieldMapHelpers
  FIELD_MAP_FIXTURE = Rails.root.join("spec/fixtures/field_maps/sample.pmtiles")

  def field_map_bytes = File.binread(FIELD_MAP_FIXTURE)
  def field_map_sha = Digest::SHA256.file(FIELD_MAP_FIXTURE).hexdigest

  def published_field_map!(city, state: "ready", **over)
    key = "field-maps/cities/#{city.id}/2026-11-01-#{field_map_sha[0, 12]}.pmtiles"
    FieldMaps::Storage.upload(key, FIELD_MAP_FIXTURE)
    (@field_map_keys ||= []) << key
    FieldMap.create!({ city_id: city.id, state: state, requested_at: Time.current, version: Date.new(2026, 11, 1),
                       size_bytes: File.size(FIELD_MAP_FIXTURE), sha256: field_map_sha, storage_key: key,
                       built_at: Time.current, error_code: (state == "failed" ? "extract_failed" : nil) }.merge(over))
  end
end

RSpec.configure do |config|
  config.include FieldMapHelpers
  config.after { Array(@field_map_keys).each { |key| FieldMaps::Storage.delete(key) } }
end
